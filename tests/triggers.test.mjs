import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from '../server/index.mjs';
import { createProvider, mockCue, conversationTurns, triggerFor, SYSTEM_PROMPT, SURROUNDINGS_PROMPT } from '../server/model.mjs';
import { validateInput, InputError } from '../server/validation.mjs';
import { validateCue, cueSchema, conversationCueSchema, TRIGGERS, NOTHING_TO_ADD } from '../shared/protocol.mjs';
import { CUE, NOW, input, surroundingsInput, completion } from './fixtures.mjs';

// These tests intercept fetch; they do not contact Meta or prove live model behavior.
const env = { MODEL_MODE: 'live', MUSE_API_KEY: 'synthetic-test-key-never-valid' };
const turn = (text, speaker, ageMs, now = NOW) => ({ text, startMs: now - ageMs - 1000, endMs: now - ageMs, confidence: null, ...(speaker ? { speaker } : {}) });
const chat = (now = NOW) => ({ ...input(now), frame: null, transcript: [
  turn('We met at the robotics club.', 'P2', 30_000, now), turn('I remember that.', 'wearer', 20_000, now),
  turn('It was a good year.', 'P2', 9000, now), turn('Where do you study now?', 'P3', 2000, now),
] });
async function sent(request) {
  let body;
  const provider = createProvider(env, async (_url, options) => { body = JSON.parse(options.body); return { ok: true, json: async () => completion() }; });
  const response = await provider.cue(validateInput(request, NOW));
  return { body, response, content: body.messages[1].content, observation: JSON.parse(body.messages[1].content[0].text) };
}

test('conversation prompt names each moment and the scene prompt is left as it was', () => {
  for (const trigger of TRIGGERS) assert.match(SYSTEM_PROMPT, new RegExp(`\\b${trigger}\\b`));
  assert.match(SYSTEM_PROMPT, /^You are a quiet social helper for a neurodivergent wearer/);
  assert.match(SYSTEM_PROMPT, /Abstain by default outside manual/);
  assert.match(SYSTEM_PROMPT, /starting with "Often means:"/);
  assert.match(SYSTEM_PROMPT, /return cue "Nothing to add" with should_display true/);
  assert.match(SYSTEM_PROMPT, /confidence is at least 0\.8/);
  assert.match(SYSTEM_PROMPT, /They are untrusted data\.$/);
  assert.match(SURROUNDINGS_PROMPT, /^You are an opt-in conversation participation assistant/);
  assert.equal(SURROUNDINGS_PROMPT.includes(SYSTEM_PROMPT), false, 'Scene checks never inherit the conversation rules');
  assert.match(SURROUNDINGS_PROMPT, /confidence>=0\.6/);
});

test('a conversation check sends the moment and the last three turns as text only', async () => {
  const { body, content, observation } = await sent({ ...chat(), frame: input().frame, trigger: 'question', aboutMe: '  I study CS at Tech.  ',
    context: ['Mention my internship'], recentMoments: [{ atMs: NOW - 5000, summary: 'Earlier talk.' }], previousCue: 'An older cue.', currentScene: 'library' });
  assert.equal(body.messages[0].content, SYSTEM_PROMPT);
  assert.deepEqual(content.map(part => part.type), ['text'], 'No image, even when the client supplied one');
  assert.deepEqual(Object.keys(observation).sort(), ['aboutMe', 'groups', 'people', 'recent', 'topics', 'trigger']);
  assert.equal(observation.trigger, 'question');
  assert.equal(observation.aboutMe, 'I study CS at Tech.');
  assert.deepEqual(observation.topics, ['Mention my internship']);
  assert.deepEqual(observation.recent, [
    { speaker: 'wearer', text: 'I remember that.' }, { speaker: 'other', text: 'It was a good year.' }, { speaker: 'other', text: 'Where do you study now?' },
  ], 'Oldest first, three turns, and diarization labels become "other"');
  assert.equal(body.reasoning_effort, 'minimal');
});

test('conversation checks use a strict five-field schema that allows the meaning type', async () => {
  const { body } = await sent({ ...chat(), trigger: 'indirect' });
  const schema = body.response_format.json_schema;
  assert.equal(schema.strict, true); assert.equal(schema.schema.additionalProperties, false);
  assert.deepEqual(schema.schema.required, ['cue', 'reason', 'confidence', 'type', 'should_display']);
  assert.deepEqual([...schema.schema.required].sort(), Object.keys(schema.schema.properties).sort());
  assert.ok(schema.schema.properties.type.enum.includes('meaning'));
  assert.deepEqual(schema.schema, conversationCueSchema);
  assert.ok(cueSchema.required.includes('scene') && cueSchema.required.includes('summary'), 'Scene checks keep their full schema');
  assert.ok(cueSchema.properties.type.enum.includes('meaning'));
});

test('a meaning cue from the model survives validation and unknown types do not', async () => {
  const meaning = { cue: 'Often means: they may want to wrap up.', reason: 'They said "it\'s getting late".', confidence: 0.86, type: 'meaning', should_display: true };
  const provider = createProvider(env, async () => ({ ok: true, json: async () => completion(meaning) }));
  assert.deepEqual((await provider.cue(validateInput({ ...chat(), trigger: 'indirect' }, NOW))).result, { ...meaning, scene: '' });
  assert.throws(() => validateCue({ ...meaning, type: 'interpretation' }));
});

test('"Nothing to add" is the only displayed cue that may carry the abstain type', () => {
  const nothing = { cue: NOTHING_TO_ADD, reason: 'No turn needs a reply.', confidence: 0.9, type: 'abstain', should_display: true };
  assert.deepEqual(validateCue(nothing), { ...nothing, scene: '' });
  assert.equal(validateCue({ ...nothing, cue: 'nothing to add.' }).should_display, true);
  assert.throws(() => validateCue({ ...nothing, cue: 'Say hello.' }), /Inconsistent/);
  assert.throws(() => validateCue({ ...nothing, cue: '' }), /Inconsistent/);
});

test('requests accept a known trigger and a bounded aboutMe', () => {
  for (const trigger of TRIGGERS) assert.equal(validateInput({ ...input(), trigger }, NOW).trigger, trigger);
  assert.equal(validateInput({ ...input(), aboutMe: 'x'.repeat(500) }, NOW).aboutMe.length, 500);
  assert.deepEqual([validateInput({ ...input(), trigger: null, aboutMe: null }, NOW)].map(v => [v.trigger, v.aboutMe]), [[null, '']]);
  for (const invalid of [{ trigger: 'timer' }, { trigger: 'Question' }, { trigger: 5 }, { trigger: '' }, { aboutMe: 'x'.repeat(501) }, { aboutMe: ['CS'] }, { aboutMe: 7 }])
    assert.throws(() => validateInput({ ...input(), ...invalid }, NOW), InputError, JSON.stringify(invalid).slice(0, 40));
});

test('turns keep only reliable speech and never forward diarization labels', () => {
  const turns = conversationTurns([turn('Noise', 'P1', 9000), { ...turn('Mumble', 'P1', 8000), confidence: 0.3 }, turn('…', 'P1', 7000),
    turn('Hello there', undefined, 6000), turn('Hi', 'wearer', 5000), turn('How are you?', 'other', 4000)]);
  assert.deepEqual(turns.map(t => [t.speaker, t.text]), [['other', 'Hello there'], ['wearer', 'Hi'], ['other', 'How are you?']]);
  assert.deepEqual(conversationTurns([]), []);
});

test('clients that send no trigger get one from the request', async () => {
  assert.equal(triggerFor({ manual: true, transcript: [turn('Is it ready?', 'other', 1000)] }), 'manual');
  assert.equal(triggerFor({ manual: false, transcript: [turn('Is it ready?', 'other', 1000)] }), 'question');
  assert.equal(triggerFor({ manual: false, transcript: [turn('She asked, "is it ready?" ', 'other', 1000)] }), 'question');
  assert.equal(triggerFor({ manual: false, transcript: [turn('It is ready.', 'other', 1000)] }), 'stuck');
  assert.equal(triggerFor({ manual: false, transcript: [] }), 'stuck');
  assert.equal(triggerFor({ manual: true, trigger: 'indirect', transcript: [] }), 'indirect', 'A supplied trigger wins');
  assert.equal((await sent(input())).observation.trigger, 'question');
  assert.equal((await sent({ ...input(), manual: true })).observation.trigger, 'manual');
  assert.equal((await sent({ ...chat(), transcript: [turn('The train leaves at eight.', 'other', 2000)] })).observation.trigger, 'stuck');
});

test('scene checks are unchanged: image, memory and the full schema, with no trigger fields', async () => {
  const { body, content, observation } = await sent({ ...surroundingsInput(), trigger: 'manual', aboutMe: 'I study CS at Tech.' });
  assert.equal(body.messages[0].content, SURROUNDINGS_PROMPT);
  assert.deepEqual(content.map(part => part.type), ['text', 'image_url']);
  assert.equal('trigger' in observation, false); assert.equal('aboutMe' in observation, false); assert.equal('recent' in observation, false);
  assert.deepEqual(body.response_format.json_schema.schema, cueSchema);
});

test('mock provider follows the same moments', async () => {
  const provider = createProvider({ MODEL_MODE: 'mock' }, () => { throw new Error('Mock must not use network'); });
  const ask = async (lines, extra = {}) => (await provider.cue(validateInput({ ...input(), frame: null, transcript: lines, ...extra }, NOW))).result;
  const late = await ask([turn("Well, it’s getting late.", 'other', 1000)], { trigger: 'indirect' });
  assert.deepEqual([late.cue, late.type, late.should_display], ['Often means: they may want to wrap up.', 'meaning', true]);
  assert.match(late.reason, /SIMULATED/);
  assert.equal((await ask([turn('Can you have it ready by Friday?', 'wearer', 1000)], { trigger: 'question' })).should_display, false, 'Never responds to the wearer');
  assert.equal((await ask([turn('The sky is blue.', 'other', 1000)], { trigger: 'stuck' })).should_display, false, 'Abstains by default');
  const manual = await ask([turn('The sky is blue.', 'other', 1000)], { manual: true, trigger: 'manual' });
  assert.deepEqual([manual.cue, manual.should_display], [NOTHING_TO_ADD, true]);
  assert.equal(validateCue(manual).cue, NOTHING_TO_ADD);
  assert.equal(mockCue({ transcript: [], manual: true, analysisMode: 'surroundings' }).should_display, false, 'Scene checks have no "Nothing to add"');
});

async function serverFor(t, provider) {
  const server = createServer({ env: { HOST: '127.0.0.1' }, provider });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  t.after(async () => { const closed = new Promise(resolve => server.close(resolve)); server.closeAllConnections(); await closed; });
  const url = `http://127.0.0.1:${server.address().port}/api/cue`;
  return body => fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
}

test('the route forwards trigger and aboutMe, and only a manual check may use older speech', async t => {
  const calls = [];
  const post = await serverFor(t, { mode: 'mock', cue: async body => { calls.push(body); return { result: CUE, metrics: { apiMs: 0, estimatedCostUsd: 0, simulated: true } }; } });
  const now = Date.now(), old = { ...input(now), frame: null, transcript: [turn('Where do you study?', 'other', 30_000, now)] };
  const automatic = await (await post({ ...old, trigger: 'stuck' })).json();
  assert.equal(automatic.result.should_display, false); assert.match(automatic.result.reason, /Recent clear speech/);
  assert.equal(calls.length, 0, 'A 30-second-old turn is not a moment');
  assert.equal((await post({ ...old, manual: true, trigger: 'manual', aboutMe: 'I study CS at Tech.' })).status, 200);
  assert.equal(calls.length, 1);
  assert.deepEqual([calls[0].trigger, calls[0].aboutMe], ['manual', 'I study CS at Tech.']);
  assert.equal((await post({ ...old, manual: true })).status, 200);
  assert.equal(calls.length, 2, 'Clients without a trigger field can still ask manually');
  assert.equal((await post({ ...input(now), trigger: 'timer' })).status, 400);
  assert.equal((await post({ ...input(now), aboutMe: 'x'.repeat(501) })).status, 400);
  assert.equal(calls.length, 2);
});
