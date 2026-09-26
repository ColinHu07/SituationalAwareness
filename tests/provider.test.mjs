import test from 'node:test';
import assert from 'node:assert/strict';
import { createProvider, mockCue } from '../server/model.mjs';
import { CUE, input, wav, completion } from './fixtures.mjs';

// These tests intercept fetch; they do not contact Meta or prove live model behavior.
const env = { MODEL_MODE: 'live', MUSE_API_KEY: 'synthetic-test-key-never-valid' };
const stub = body => async () => ({ ok: true, json: async () => body });

test('documented Chat Completions request sends actual supplied image and strict schema', async () => {
  let captured;
  const provider = createProvider(env, async (url, options) => {
    captured = { url, options, body: JSON.parse(options.body) };
    return { ok: true, json: async () => completion() };
  });
  const response = await provider.cue(input());
  assert.equal(captured.url, 'https://api.meta.ai/v1/chat/completions');
  assert.equal(captured.options.headers.Authorization, `Bearer ${env.MUSE_API_KEY}`);
  assert.equal(captured.body.model, 'muse-spark-1.3');
  assert.equal(captured.body.reasoning_effort, 'low');
  assert.ok(captured.body.max_completion_tokens >= 1024);
  assert.equal(captured.body.response_format.type, 'json_schema');
  const schema = captured.body.response_format.json_schema;
  assert.equal(schema.strict, true); assert.equal(schema.schema.additionalProperties, false);
  assert.deepEqual([...schema.schema.required].sort(), Object.keys(schema.schema.properties).sort());
  const parts = captured.body.messages.at(-1).content;
  assert.equal(parts.find(x => x.type === 'image_url').image_url.url, input().frame.dataUrl);
  assert.equal(JSON.parse(parts.find(x => x.type === 'text').text).frameCapturedAtMs, input().frame.capturedAtMs);
  assert.deepEqual(response.result, CUE); assert.equal(response.metrics.simulated, false);
  assert.equal(response.metrics.inputTokens, 1000); assert.equal(response.metrics.cachedTokens, 800);
  assert.equal(response.metrics.outputTokens, 100);
  assert.equal(response.metrics.estimatedCostUsd, (200 * 1.25 + 800 * 0.15 + 100 * 4.25) / 1e6);
});

test('absent image is not replaced with fabricated visual context', async () => {
  const provider = createProvider(env, async (_url, options) => {
    const content = JSON.parse(options.body).messages.at(-1).content;
    assert.deepEqual(content.map(x => x.type), ['text']);
    return { ok: true, json: async () => completion() };
  });
  await provider.cue({ ...input(), frame: null });
});

test('missing provider token accounting remains unknown rather than measured zero', async () => {
  const response = await createProvider(env, stub(completion(CUE, { usage: undefined }))).cue(input());
  assert.equal(response.metrics.inputTokens, null); assert.equal(response.metrics.estimatedCostUsd, null);
});

for (const [label, body] of [
  ['missing choices', {}],
  ['truncated output', completion(CUE, { choices: [{ finish_reason: 'length', message: { content: JSON.stringify(CUE) } }] })],
  ['refusal', completion(CUE, { choices: [{ finish_reason: 'stop', message: { content: null, refusal: 'no' } }] })],
  ['invalid JSON', completion(CUE, { choices: [{ finish_reason: 'stop', message: { content: '{' } }] })],
  ['extra output keys', completion({ ...CUE, identity: 'Person A' })],
  ['confidence outside range', completion({ ...CUE, confidence: 2 })],
]) {
  test(`provider parsing rejects ${label}`, async () => {
    await assert.rejects(createProvider(env, stub(body)).cue(input()));
  });
}

test('provider errors are sanitized and 429 is preserved for backoff', async () => {
  for (const [upstream, expected] of [[429, 429], [401, 502], [500, 502]]) {
    let read = false;
    const provider = createProvider(env, async () => ({ ok: false, status: upstream, json: async () => { read = true; return { secret: 'participant content' }; } }));
    await assert.rejects(provider.cue(input()), error => error.status === expected && !error.message.includes('participant content'));
    assert.equal(read, false);
  }
});

test('caller cancellation reaches the upstream fetch signal', async () => {
  const controller = new AbortController(); let capturedSignal;
  const provider = createProvider(env, async (_url, options) => {
    capturedSignal = options.signal;
    return new Promise((_resolve, reject) => options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true }));
  });
  const work = provider.cue(input(), controller.signal);
  controller.abort(); await assert.rejects(work, { name: 'AbortError' });
  assert.equal(capturedSignal.aborted, true);
});

test('ASR uses the documented multipart JSON request and supplied audio bytes', async () => {
  const bytes = wav(); let captured;
  const provider = createProvider(env, async (url, options) => {
    captured = { url, options };
    return { ok: true, json: async () => ({ transcript: 'What did you mean by Friday?', audioDurationMs: 1000 }) };
  });
  const response = await provider.transcribe(bytes);
  assert.equal(captured.url, 'https://api.meta.ai/v1/asr/transcribe');
  assert.equal(captured.options.headers.Accept, 'application/json');
  assert.deepEqual(JSON.parse(await captured.options.body.get('request').text()), { mode: 'ENDPOINTING', model: 'muse-voice-transcribe-1.0', audioEncoding: 'WAV' });
  assert.deepEqual(Buffer.from(await captured.options.body.get('audio').arrayBuffer()), bytes);
  assert.equal(response.text, 'What did you mean by Friday?'); assert.equal(response.confidence, null);
  assert.equal(response.simulated, false);
  assert.equal(response.estimatedCostUsd, 0.18 / 3600);
});

test('ASR never substitutes canned transcript for a malformed response or mock mode', async () => {
  await assert.rejects(createProvider(env, stub({ error: 'missing transcript' })).transcribe(wav()), /Invalid transcription/);
  await assert.rejects(createProvider({ MODEL_MODE: 'mock' }).transcribe(wav()), error => error.status === 503);
});

test('mock fixture remains explicitly simulated and abstains when latest subject changes', async () => {
  const provider = createProvider({ MODEL_MODE: 'mock' }, () => { throw new Error('Mock must not use network'); });
  const response = await provider.cue(input());
  assert.equal(response.metrics.simulated, true); assert.match(response.result.reason, /SIMULATED/);
  const newer = input(); newer.transcript.push({ text: 'Let us talk about lunch instead.', startMs: 1, endMs: 2 });
  assert.equal(mockCue(newer).should_display, false);
});

test('live credential is required and Contributor model is prohibited', () => {
  assert.throws(() => createProvider({ MODEL_MODE: 'live' }), /requires MUSE_API_KEY/);
  assert.throws(() => createProvider({ ...env, MUSE_MODEL: 'muse-spark-1.3-contributor' }), /standard/);
});
