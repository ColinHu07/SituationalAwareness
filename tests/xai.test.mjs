import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from '../server/index.mjs';
import { createProvider, SYSTEM_PROMPT, SURROUNDINGS_PROMPT, XAI_MAX_TOKENS } from '../server/model.mjs';
import { validateInput } from '../server/validation.mjs';
import { cueSchema, conversationCueSchema } from '../shared/protocol.mjs';
import { CUE, NOW, input, surroundingsInput, wav, completion } from './fixtures.mjs';

// These tests intercept fetch; they do not contact xAI or Meta or prove live model behavior.
const MUSE_KEY = 'synthetic-muse-key-never-valid', XAI_KEY = 'synthetic-xai-key-never-valid';
const muse = { MODEL_MODE: 'live', MUSE_API_KEY: MUSE_KEY }, env = { ...muse, XAI_API_KEY: XAI_KEY };
const chat = () => validateInput({ ...input(), frame: null, trigger: 'question', aboutMe: 'I study CS at Tech.' }, NOW);
function recording(environment, body = completion()) {
  const calls = [];
  const provider = createProvider(environment, async (url, options) => {
    calls.push({ url, auth: options.headers.Authorization, body: typeof options.body === 'string' ? JSON.parse(options.body) : null });
    return { ok: true, json: async () => body };
  });
  return { provider, calls };
}

test('a conversation check goes to a non-reasoning Grok model with the same prompt and strict schema', async () => {
  const { provider, calls } = recording(env);
  const response = await provider.cue({ ...chat(), frame: input().frame });
  assert.equal(calls.length, 1);
  const [{ url, auth, body }] = calls;
  assert.equal(url, 'https://api.x.ai/v1/chat/completions');
  assert.equal(auth, `Bearer ${XAI_KEY}`);
  assert.equal(JSON.stringify(calls).includes(MUSE_KEY), false, 'The Muse key never reaches xAI');
  assert.equal(body.model, 'grok-4.20-non-reasoning'); assert.match(body.model, /non-reasoning/);
  assert.equal('reasoning_effort' in body, false, 'A non-reasoning model takes no reasoning setting');
  assert.equal(body.max_completion_tokens, XAI_MAX_TOKENS); assert.ok(XAI_MAX_TOKENS <= 512);
  assert.equal(body.stream, false);
  assert.equal(body.messages[0].content, SYSTEM_PROMPT);
  assert.deepEqual(body.messages[1].content.map(part => part.type), ['text'], 'Text only, even when the client supplied an image');
  assert.deepEqual(Object.keys(JSON.parse(body.messages[1].content[0].text)).sort(), ['aboutMe', 'groups', 'people', 'recent', 'topics', 'trigger']);
  assert.equal(body.response_format.type, 'json_schema');
  assert.equal(body.response_format.json_schema.strict, true);
  assert.deepEqual(body.response_format.json_schema.schema, conversationCueSchema);
  assert.deepEqual(response.result, { ...CUE, scene: '' });
});

test('every live cue reports apiMs with the provider and model that answered', async () => {
  const grok = (await recording(env).provider.cue(chat())).metrics;
  assert.deepEqual([grok.provider, grok.model, grok.simulated], ['xai', 'grok-4.20-non-reasoning', false]);
  assert.ok(Number.isFinite(grok.apiMs) && grok.apiMs >= 0);
  assert.equal(grok.estimatedCostUsd, (200 * 1.25 + 800 * 0.2 + 100 * 2.5) / 1e6, 'Grok checks are costed at Grok prices');
  const scene = (await recording(env).provider.cue(surroundingsInput())).metrics;
  assert.deepEqual([scene.provider, scene.model], ['muse', 'muse-spark-1.3']);
  assert.ok(Number.isFinite(scene.apiMs));
  assert.equal(scene.estimatedCostUsd, (200 * 1.25 + 800 * 0.15 + 100 * 4.25) / 1e6);
  const fallback = (await recording(muse).provider.cue(chat())).metrics;
  assert.deepEqual([fallback.provider, fallback.model], ['muse', 'muse-spark-1.3']);
  assert.ok(Number.isFinite(fallback.apiMs));
  const priced = (await recording({ ...env, XAI_INPUT_PRICE_PER_MILLION: '2', XAI_CACHED_INPUT_PRICE_PER_MILLION: '1', XAI_OUTPUT_PRICE_PER_MILLION: '3' }).provider.cue(chat())).metrics;
  assert.equal(priced.estimatedCostUsd, (200 * 2 + 800 * 1 + 100 * 3) / 1e6);
});

test('scene checks stay on Muse with their image, prompt and full schema', async () => {
  const { provider, calls } = recording(env);
  await provider.cue(surroundingsInput());
  const [{ url, auth, body }] = calls;
  assert.equal(url, 'https://api.meta.ai/v1/chat/completions');
  assert.equal(auth, `Bearer ${MUSE_KEY}`);
  assert.equal(JSON.stringify(calls).includes(XAI_KEY), false, 'The xAI key never reaches Meta');
  assert.equal(body.model, 'muse-spark-1.3'); assert.equal(body.reasoning_effort, 'minimal');
  assert.equal(body.max_completion_tokens, 4096);
  assert.equal(body.messages[0].content, SURROUNDINGS_PROMPT);
  assert.deepEqual(body.messages[1].content.map(part => part.type), ['text', 'image_url']);
  assert.deepEqual(body.response_format.json_schema.schema, cueSchema);
});

test('without an xAI key a conversation check falls back to Muse unchanged', async () => {
  for (const environment of [muse, { ...muse, XAI_API_KEY: '' }]) {
    const { provider, calls } = recording(environment);
    await provider.cue(chat());
    assert.equal(calls[0].url, 'https://api.meta.ai/v1/chat/completions');
    assert.equal(calls[0].auth, `Bearer ${MUSE_KEY}`);
    assert.equal(calls[0].body.model, 'muse-spark-1.3'); assert.equal(calls[0].body.reasoning_effort, 'minimal');
    assert.equal(calls[0].body.messages[0].content, SYSTEM_PROMPT);
    assert.deepEqual(calls[0].body.response_format.json_schema.schema, conversationCueSchema);
    assert.equal(provider.conversationModel, 'muse-spark-1.3');
  }
  assert.equal(createProvider(env).conversationModel, 'grok-4.20-non-reasoning');
  assert.equal(createProvider({ ...env, XAI_MODEL: 'grok-next-non-reasoning' }).conversationModel, 'grok-next-non-reasoning');
});

test('tone, learning and transcription stay on Muse when an xAI key is set', async () => {
  const urls = [];
  const provider = createProvider(env, async (url, options) => {
    urls.push(url); assert.equal(options.headers.Authorization, `Bearer ${MUSE_KEY}`);
    const result = url.endsWith('asr/transcribe') ? { transcript: 'Hello.' }
      : completion(JSON.parse(options.body).response_format.json_schema.name === 'tone_check'
        ? { flag: false, severity: 'none', issue: '', recovery: '', rephrase: '' } : { people: [], groups: [] });
    return { ok: true, json: async () => result };
  });
  await provider.tone({ line: { text: 'That works for me.', speaker: 'wearer' }, recent: [], scene: '', speakerKnown: true, people: [] });
  await provider.learn({ transcript: [{ text: 'I love chess.' }], people: [], groups: [], wordsPerMinute: null });
  await provider.transcribe(wav());
  assert.equal(urls.length, 3);
  for (const url of urls) assert.match(url, /^https:\/\/api\.meta\.ai\/v1\//);
});

test('a live key is still required for Muse, and mock mode never uses the network', async () => {
  assert.throws(() => createProvider({ MODEL_MODE: 'live', XAI_API_KEY: XAI_KEY }), /requires MUSE_API_KEY/);
  const provider = createProvider({ MODEL_MODE: 'mock', XAI_API_KEY: XAI_KEY }, () => { throw new Error('Mock must not use network'); });
  const response = await provider.cue(chat());
  assert.deepEqual([response.metrics.simulated, response.metrics.provider, response.metrics.apiMs], [true, 'mock', 0]);
  assert.match(response.result.reason, /SIMULATED/);
});

test('Grok failures are sanitized and never retried on Muse', async () => {
  for (const [upstream, expected] of [[429, 429], [401, 502], [500, 502]]) {
    const calls = [];
    const provider = createProvider(env, async url => { calls.push(url); return { ok: false, status: upstream, json: async () => ({ secret: 'participant content' }) }; });
    await assert.rejects(provider.cue(chat()), error => error.status === expected && !error.message.includes('participant content'));
    assert.deepEqual(calls, ['https://api.x.ai/v1/chat/completions']);
  }
  for (const body of [
    completion(CUE, { choices: [{ finish_reason: 'length', message: { content: JSON.stringify(CUE).slice(0, 40) } }] }),
    completion({ ...CUE, identity: 'Person A' }), completion({ ...CUE, confidence: 2 }),
  ]) {
    const { provider, calls } = recording(env, body);
    await assert.rejects(provider.cue(chat()));
    assert.equal(calls.length, 1, 'One billable attempt, no silent second provider');
  }
});

test('caller cancellation reaches the xAI request', async () => {
  const controller = new AbortController(); let captured;
  const provider = createProvider(env, async (url, options) => {
    captured = { url, signal: options.signal };
    return new Promise((_resolve, reject) => options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true }));
  });
  const work = provider.cue(chat(), controller.signal);
  controller.abort(); await assert.rejects(work, { name: 'AbortError' });
  assert.equal(captured.url, 'https://api.x.ai/v1/chat/completions'); assert.equal(captured.signal.aborted, true);
});

test('the server logs apiMs and provider for every cue request, without content', async t => {
  const lines = []; t.mock.method(console, 'log', line => lines.push(String(line)));
  const { provider } = recording(env);
  const server = createServer({ env: { HOST: '127.0.0.1', COPILOT_PROXY_TOKEN: 'synthetic-proxy-token-for-tests-only-123456789' }, provider });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  t.after(async () => { const closed = new Promise(resolve => server.close(resolve)); server.closeAllConnections(); await closed; });
  const base = `http://127.0.0.1:${server.address().port}`, headers = { 'Content-Type': 'application/json', Authorization: 'Bearer synthetic-proxy-token-for-tests-only-123456789' };
  const post = body => fetch(`${base}/api/cue`, { method: 'POST', headers, body: JSON.stringify(body) });
  const now = Date.now();
  const grok = await (await post({ ...input(now), frame: null, trigger: 'question' })).json();
  assert.deepEqual([grok.metrics.provider, grok.metrics.model], ['xai', 'grok-4.20-non-reasoning']);
  await post(surroundingsInput(now));
  await post({ ...input(now), frame: null, transcript: [] });
  const cues = lines.filter(line => line.includes('/api/cue'));
  assert.equal(cues.length, 3);
  assert.match(cues[0], /POST \/api\/cue 200 .* provider=xai model=grok-4\.20-non-reasoning apiMs=\d+$/);
  assert.match(cues[1], /provider=muse model=muse-spark-1\.3 apiMs=\d+$/);
  assert.match(cues[2], /provider=none model=none apiMs=0$/, 'A check that never reached a model is still logged');
  assert.equal(lines.some(line => line.includes('Friday') || line.includes(XAI_KEY) || line.includes(MUSE_KEY)), false);
  const health = await (await fetch(`${base}/api/health`)).json();
  assert.deepEqual([health.model, health.conversationModel], ['muse-spark-1.3', 'grok-4.20-non-reasoning']);
});
