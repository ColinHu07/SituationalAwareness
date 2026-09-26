import test from 'node:test';
import assert from 'node:assert/strict';
import { Session, LIMITS, validateCue, boundedTranscript, abstain } from '../shared/protocol.mjs';
import { CUE, NOW, input, deferred } from './fixtures.mjs';

function session() {
  let clock = NOW;
  const value = new Session({ now: () => clock });
  value.start(true);
  value.append(input(clock).transcript[0].text, input(clock).transcript[0]);
  return { value, advance: ms => { clock += ms; }, now: () => clock };
}
const result = cue => ({ result: cue ?? CUE, metrics: { apiMs: 25, estimatedCostUsd: 0.001 } });

test('start requires deliberate consent and a connected device', () => {
  const s = new Session();
  assert.throws(() => s.start(false), /consent/);
  assert.equal(s.state, 'stopped');
  s.disconnect(); assert.throws(() => s.start(true), /Connect/);
  s.reconnect(); assert.equal(s.state, 'paused');
  s.start(true); assert.equal(s.state, 'running');
});

for (const action of ['pause', 'stop', 'dismiss', 'disconnect', 'speechStart', 'subjectChange']) {
  test(`${action} immediately clears a cue, cancels the request and rejects a late result`, async () => {
    const { value: s } = session(), pending = deferred();
    let signal;
    const work = s.suggest((_payload, abort) => { signal = abort; return pending.promise; });
    s.cue = { ...CUE, expiresAtMs: NOW + 8000 };
    const revision = s.revision;
    if (action === 'subjectChange') s.append('Different subject: lunch.', { startMs: NOW, endMs: NOW });
    else s[action]();
    assert.equal(signal.aborted, true);
    assert.ok(s.revision > revision);
    assert.equal(s.cue, null);
    pending.resolve(result());
    assert.equal(await work, false);
    assert.equal(s.cue, null);
    assert.equal(s.pending, null);
    assert.equal(s.metrics.stale, 1);
  });
}

test('pause clears captured context and resume needs new speech', () => {
  const { value: s } = session();
  s.setFrame(input().frame); s.pause();
  assert.deepEqual(s.transcript, []); assert.equal(s.frame, null);
  s.append('Ignored while paused.'); assert.deepEqual(s.transcript, []);
  s.start(true); assert.equal(s.ready(true), false);
});

test('stop clears saved topics, frames, transcripts and dedup memory', async () => {
  const { value: s } = session();
  s.context = ['internship']; s.setFrame(input().frame);
  await s.suggest(async () => result()); s.stop();
  assert.deepEqual(s.context, []); assert.deepEqual(s.transcript, []);
  assert.equal(s.frame, null); assert.equal(s.cue, null); assert.equal(s.seen.size, 0);
  assert.equal(s.state, 'stopped');
});

test('one in-flight model request is permitted; new samples are dropped', async () => {
  const { value: s } = session(), pending = deferred(); let calls = 0;
  const first = s.suggest(() => { calls++; return pending.promise; });
  assert.equal(await s.suggest(() => { calls++; return result(); }, true), false);
  assert.equal(calls, 1);
  pending.resolve(result()); assert.equal(await first, true);
});

test('quiet interval and speech confidence gate automatic and manual requests', () => {
  const { value: s, advance } = session();
  s.speechStart(); assert.equal(s.ready(true), false);
  s.append('Is it ready?', { endMs: NOW, startMs: NOW, confidence: 0.64 });
  advance(LIMITS.quietMs); assert.equal(s.ready(true), false);
  s.append('Is it ready?', { endMs: NOW, startMs: NOW, confidence: 0.65 });
  assert.equal(s.ready(true), true);
});

test('display cooldown applies to automatic requests; manual requests still deduplicate', async () => {
  const { value: s } = session();
  assert.equal(await s.suggest(async () => result()), true);
  assert.equal(s.ready(), false); assert.equal(s.ready(true), true);
  assert.equal(await s.suggest(async () => result({ ...CUE, cue: 'ASK what they meant by Friday!' }), true), false);
  assert.equal(s.metrics.displayed, 1); assert.equal(s.metrics.suppressed, 1);
  s.dismiss(); assert.equal(s.cue, null); assert.equal(s.ready(), false);
});

test('cooldown expires and fresh different evidence can produce a new cue', async () => {
  const { value: s, advance, now } = session();
  await s.suggest(async () => result()); advance(LIMITS.cooldownMs);
  s.append('My robotics project is going well.', { startMs: now() - 3000, endMs: now() - 2000 });
  assert.equal(s.ready(), true);
  assert.equal(await s.suggest(async () => result({ ...CUE, cue: 'Ask how their robotics project is going.', type: 'follow_up' })), true);
});

test('expired cue and stale frame are cleared without waiting for a response', async () => {
  const { value: s, advance } = session(); s.setFrame(input().frame);
  await s.suggest(async () => result()); advance(LIMITS.cueMs); s.tick();
  assert.equal(s.cue, null); assert.equal(s.frame, null);
});

test('old speech, an over-deadline response and low confidence never display', async () => {
  const first = session(); first.advance(LIMITS.speechMs);
  assert.equal(first.value.ready(true), false);
  const second = session(), pending = deferred();
  const work = second.value.suggest(() => pending.promise);
  second.advance(LIMITS.requestMs + 1); pending.resolve(result());
  assert.equal(await work, false); assert.equal(second.value.cue, null);
  const third = session();
  assert.equal(await third.value.suggest(async () => result({ ...CUE, confidence: 0.79 })), false);
  assert.equal(third.value.cue, null);
});

test('request timeout aborts capture-related work and a later resolution cannot display', async t => {
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const { value: s } = session(), pending = deferred(); let signal;
  const work = s.suggest((_payload, abort) => { signal = abort; return pending.promise; });
  t.mock.timers.tick(LIMITS.requestMs);
  assert.equal(await work, false); assert.equal(signal.aborted, true);
  assert.equal(s.pending, null); assert.equal(s.cue, null); assert.equal(s.metrics.errors, 1);
  pending.resolve(result()); await Promise.resolve(); assert.equal(s.cue, null);
});

test('abstention and provider/network failure leave no cue, then allow recovery', async () => {
  const { value: s } = session();
  assert.equal(await s.suggest(async () => result(abstain())), false);
  assert.equal(await s.suggest(async () => { throw new Error('network down'); }), false);
  assert.equal(s.pending, null); assert.equal(s.cue, null); assert.equal(s.metrics.errors, 1);
  assert.equal(await s.suggest(async () => result()), true);
  assert.equal(s.metrics.displayed, 1); assert.ok(s.metrics.uploadBytes > 0);
});

test('transcript retention is ordered and bounded by age, count and characters', () => {
  const rows = Array.from({ length: 80 }, (_, i) => ({ text: String(i).padEnd(500, 'x'), startMs: NOW - 80000 + i * 1000, endMs: NOW - 80000 + i * 1000 }));
  const bounded = boundedTranscript([...rows, { text: 'future', endMs: NOW + 2000 }], NOW);
  assert.ok(bounded.length <= LIMITS.transcriptCount);
  assert.ok(bounded.reduce((n, x) => n + x.text.length, 0) <= LIMITS.transcriptChars);
  assert.ok(bounded.every(x => x.endMs >= NOW - LIMITS.transcriptMs && x.endMs <= NOW));
  assert.equal(bounded.at(-1).text, rows.at(-1).text);
  assert.deepEqual([...bounded].sort((a,b) => a.endMs - b.endMs), bounded);
  const short = rows.map(x => ({ ...x, text: 'a' }));
  assert.equal(boundedTranscript(short, NOW).length, LIMITS.transcriptCount);
});

test('structured cue validation rejects malformed or unbounded output', () => {
  for (const invalid of [null, [], { ...CUE, extra: true }, { ...CUE, reason: 5 }, { ...CUE, confidence: NaN }, { ...CUE, confidence: 1.1 }, { ...CUE, confidence: -0.1 }, { ...CUE, type: 'emotion' }, { ...CUE, cue: 'x'.repeat(91) }, { ...CUE, cue: 'one '.repeat(15) }, { ...CUE, should_display: 'true' }, { ...CUE, cue: '' }]) {
    assert.throws(() => validateCue(invalid));
  }
  assert.deepEqual(validateCue({ ...CUE, should_display: false }), abstain(CUE.reason));
  assert.equal(validateCue({ ...CUE, cue: 'They are angry.' }).should_display, false);
});
