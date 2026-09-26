import test from 'node:test';
import assert from 'node:assert/strict';
import { validateToneInput, validateInput, InputError } from '../server/validation.mjs';
import { createProvider, mockTone, TONE_PROMPT } from '../server/model.mjs';
import { validateTone } from '../shared/protocol.mjs';
import { NOW, input, completion } from './fixtures.mjs';

const body = (text = 'Honestly, this idea is stupid.') => ({ line: { text, endMs: NOW - 1000 },
  recent: [{ text: 'I think we should launch next week.', speaker: 'other' }, { text, speaker: 'wearer' }],
  scene: 'office meeting', speakerKnown: true, people: [], groups: [] });

test('tone input carries one recent wearer line plus bounded context', () => {
  assert.equal(validateToneInput(body(), NOW).scene, 'office meeting');
  assert.throws(() => validateToneInput({ ...body(), line: { text: 'x', endMs: NOW - 200_000 } }, NOW), InputError);
  assert.throws(() => validateToneInput({ ...body(), recent: Array(13).fill({ text: 'hi' }) }, NOW), InputError);
  assert.throws(() => validateToneInput({ ...body(), recent: [{ text: 'hi', speaker: 'boss' }] }, NOW), InputError);
  assert.throws(() => validateToneInput({ ...body(), speakerKnown: 'yes' }, NOW), InputError);
});

test('cue transcripts may label the wearer and others', () => {
  const value = input(); value.transcript[0].speaker = 'wearer';
  assert.equal(validateInput(value, NOW).transcript[0].speaker, 'wearer');
  value.transcript[0].speaker = 'me';
  assert.throws(() => validateInput(value, NOW), InputError);
});

test('cue transcripts keep tone roles separate from session speaker aliases', () => {
  const value = input();
  value.transcript[0].speaker = 'other';
  value.transcript[0].speakerAlias = 'P1';
  assert.deepEqual(validateInput(value, NOW).transcript[0], {
    ...value.transcript[0], confidence: value.transcript[0].confidence ?? null,
  });

  value.transcript[0].speaker = 'P1';
  assert.throws(() => validateInput(value, NOW), InputError);
  value.transcript[0].speaker = 'wearer';
  value.transcript[0].speakerAlias = 'wearer';
  assert.throws(() => validateInput(value, NOW), InputError);
});

test('tone results are bounded and never show half advice', () => {
  const ok = { flag: true, severity: 'strong', issue: 'Called the idea stupid', recovery: 'Sorry, that came out harsh. I have concerns about the timeline.', rephrase: "I'm not sure this fits yet. Can we look at alternatives?" };
  assert.deepEqual(validateTone(ok), ok);
  assert.equal(validateTone({ ...ok, recovery: 'word '.repeat(25) }).flag, false);
  assert.equal(validateTone({ ...ok, rephrase: 'word '.repeat(25) }).rephrase, '');
  assert.equal(validateTone({ ...ok, severity: 'none' }).flag, false);
  assert.equal(validateTone({ ...ok, recovery: 'Your autism made that blunt.' }).flag, false);
  assert.throws(() => validateTone({ ...ok, severity: 'extreme' }));
});

test('mock tone flags only blunt wording', () => {
  assert.equal(mockTone(validateToneInput(body(), NOW)).flag, true);
  assert.equal(mockTone(validateToneInput(body('I have a few concerns about the timeline.'), NOW)).flag, false);
});

test('live tone check uses the strict schema and minimal reasoning for speed', async () => {
  let sent;
  const provider = createProvider({ MODEL_MODE: 'live', MUSE_API_KEY: 'synthetic-test-key-never-valid' }, async (_, options) => {
    sent = JSON.parse(options.body);
    return { ok: true, json: async () => completion({ flag: false, severity: 'none', issue: '', recovery: '', rephrase: '' }) };
  });
  const { result } = await provider.tone(validateToneInput(body(), NOW));
  assert.equal(result.flag, false);
  assert.equal(sent.messages[0].content, TONE_PROMPT);
  assert.equal(sent.reasoning_effort, 'minimal');
  assert.equal(sent.response_format.json_schema.strict, true);
});
