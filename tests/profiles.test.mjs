import test from 'node:test';
import assert from 'node:assert/strict';
import { validateInput, validateLearnInput, InputError } from '../server/validation.mjs';
import { createProvider, mockCue, mockLearn, LEARN_PROMPT, SYSTEM_PROMPT, SURROUNDINGS_PROMPT } from '../server/model.mjs';
import { validateLearn } from '../shared/protocol.mjs';
import { NOW, input, completion } from './fixtures.mjs';

const jake = { id: 'p1', name: 'Jake', groups: ['Football team'], tags: ['football'], topics: ['fantasy football'], notes: ['Tryout on Friday'] };
const group = { name: 'Football team', topics: ['playoffs'], slang: ['mid = mediocre'], style: 'Fast, lots of teasing.', notes: [] };
function learnInput(now = NOW) {
  return { transcript: [
    { text: 'Jake, how did the tryout go?', startMs: now - 3_600_000, endMs: now - 3_599_000 },
    { text: 'I love fantasy football so much', startMs: now - 60_000, endMs: now - 58_000 },
  ], people: [jake], groups: [group], otherGroupNames: ['D&D group'], wordsPerMinute: 185 };
}

test('cue input carries optional people and group profiles', () => {
  const value = validateInput({ ...input(), people: [jake], groups: [group] }, NOW);
  assert.deepEqual(value.people, [jake]); assert.deepEqual(value.groups, [group]);
  assert.throws(() => validateInput({ ...input(), people: [{ ...jake, notes: ['x'.repeat(161)] }] }, NOW), InputError);
  assert.throws(() => validateInput({ ...input(), groups: Array(9).fill(group) }, NOW), InputError);
});

test('learn input accepts an hour-long conversation and requires identified people', () => {
  assert.deepEqual(validateLearnInput(learnInput(), NOW).people, [jake]);
  assert.throws(() => validateLearnInput({ ...learnInput(), people: [] }, NOW), InputError);
  assert.throws(() => validateLearnInput({ ...learnInput(), people: [{ ...jake, id: undefined }] }, NOW), InputError);
  assert.throws(() => validateLearnInput({ ...learnInput(), transcript: [] }, NOW), InputError);
  const old = learnInput(); old.transcript[0].startMs = NOW - 7 * 3_600_000;
  assert.throws(() => validateLearnInput(old, NOW), InputError);
});

test('profile updates drop unknown people and trim noisy lists', () => {
  const result = validateLearn({ people: [{ id: 'p1', facts: ['ok', 'x'.repeat(200), 3], topics: [], tags: Array(10).fill('t'), groups: ['A'] },
    { id: 'stranger', facts: ['no'], topics: [], tags: [], groups: [] }],
    groups: [{ name: ' Football team ', topics: ['draft'], slang: [], style: 'Fast.' }, { name: '', topics: [], slang: [], style: '' }] }, validateLearnInput(learnInput(), NOW));
  assert.deepEqual(result.people, [{ id: 'p1', facts: ['ok'], topics: [], tags: Array(6).fill('t'), groups: ['A'] }]);
  assert.deepEqual(result.groups, [{ name: 'Football team', topics: ['draft'], slang: [], style: 'Fast.' }]);
  assert.throws(() => validateLearn({ people: 'x', groups: [] }, learnInput()));
});

test('mock learner records named mentions, liked topics and pace for the shared group', () => {
  const result = mockLearn(validateLearnInput(learnInput(), NOW));
  assert.deepEqual(result.people[0].facts, ['Jake, how did the tryout go?']);
  assert.deepEqual(result.people[0].topics, ['fantasy football so much']);
  assert.equal(result.groups[0].name, 'Football team'); assert.match(result.groups[0].style, /^Fast pace/);
});

test('mock cue suggests a saved topic only when explicitly asked', () => {
  assert.equal(mockCue({ transcript: [], manual: true, people: [jake] }).cue, 'Ask Jake about fantasy football.');
  assert.equal(mockCue({ transcript: [], manual: false, people: [jake] }).should_display, false);
});

test('live learn sends strict profile schema and prompts use profiles as background', async () => {
  let body;
  const provider = createProvider({ MODEL_MODE: 'live', MUSE_API_KEY: 'synthetic-test-key-never-valid' }, async (_, options) => {
    body = JSON.parse(options.body);
    return { ok: true, json: async () => completion({ people: [{ id: 'p1', facts: ['Made the team'], topics: [], tags: ['football'], groups: [] }], groups: [] }) };
  });
  const { result } = await provider.learn(validateLearnInput(learnInput(), NOW));
  assert.equal(body.messages[0].content, LEARN_PROMPT);
  assert.equal(body.response_format.json_schema.strict, true);
  assert.deepEqual(result.people[0].facts, ['Made the team']);
  for (const prompt of [SYSTEM_PROMPT, SURROUNDINGS_PROMPT]) assert.match(prompt, /background memory, not current evidence/);
});

test('cues carry a normalized scene label, even when abstaining', async () => {
  const { validateCue, abstain } = await import('../shared/protocol.mjs');
  const base = { cue: 'Looks like a funeral. Stay quiet and somber.', reason: 'Casket and flowers.', confidence: 0.9, type: 'reminder', should_display: true };
  assert.equal(validateCue({ ...base, scene: ' Funeral ' }).scene, 'funeral');
  assert.deepEqual(validateCue({ ...base, should_display: false, scene: 'Library' }), abstain('Casket and flowers.', 'library'));
  assert.equal(validateCue(base).scene, '', 'scene is optional for fixtures');
  assert.throws(() => validateCue({ ...base, scene: 5 }));
  assert.equal(mockCue({ transcript: [{ text: "We're at the funeral now" }], analysisMode: 'surroundings', manual: false }).scene, 'funeral');
  for (const prompt of [SYSTEM_PROMPT, SURROUNDINGS_PROMPT]) assert.match(prompt, /Looks like a funeral\. Stay quiet and somber\./);
  assert.equal(validateInput({ ...input(), currentScene: 'library' }, NOW).currentScene, 'library');
  assert.throws(() => validateInput({ ...input(), currentScene: 'x'.repeat(41) }, NOW), InputError);
});
