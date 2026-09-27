import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from '../server/index.mjs';
import { createProvider, SYSTEM_PROMPT, SURROUNDINGS_PROMPT, XAI_MAX_TOKENS, XAI_TIMEOUT_MS } from '../server/model.mjs';
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
  assert.deepEqual(Object.keys(JSON.parse(body.messages[1].content[0].text)).sort(), ['aboutMe', 'groups', 'people', 'recent', 'summary', 'topics', 'trigger']);
  assert.equal(body.response_format.type, 'json_schema');
  assert.equal(body.response_format.json_schema.strict, true);
  assert.deepEqual(body.response_format.json_schema.schema, conversationCueSchema);
  assert.deepEqual(response.result, { ...CUE, scene: '' });
  assert.equal('fallbackFrom' in response.metrics, false, 'An answer from Grok is not a fallback');
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

const MUSE_CUE = { cue: 'Say you study CS at Tech.', reason: 'They asked "Where do you study now?".', confidence: 0.9, type: 'respond', should_display: true };
const XAI = 'https://api.x.ai/v1/chat/completions', MUSE = 'https://api.meta.ai/v1/chat/completions';
// Grok does whatever the test says; Muse answers normally.
function failing(grok, museAnswer = async () => ({ ok: true, json: async () => completion(MUSE_CUE) })) {
  const calls = [];
  const provider = createProvider(env, async (url, options) => {
    calls.push({ url, auth: options.headers.Authorization, body: JSON.parse(options.body), signal: options.signal });
    return url === XAI ? grok(options) : museAnswer(options);
  });
  return { provider, calls };
}

for (const [label, reason, grok] of [
  ['a rate limit', 'rate_limited', async () => ({ ok: false, status: 429, json: async () => ({}) })],
  ['a rejected key', 'unavailable', async () => ({ ok: false, status: 401, json: async () => ({}) })],
  ['a server error', 'unavailable', async () => ({ ok: false, status: 500, json: async () => ({}) })],
  ['a network failure', 'error', async () => { throw new TypeError('fetch failed'); }],
  ['a truncated answer', 'error', async () => ({ ok: true, json: async () => completion(CUE, { choices: [{ finish_reason: 'length', message: { content: '{"cue":"Ask' } }] }) })],
  ['an answer outside the schema', 'error', async () => ({ ok: true, json: async () => completion({ ...CUE, identity: 'Person A' }) })],
]) {
  test(`after ${label} from Grok the same request is retried once on Muse`, async () => {
    const { provider, calls } = failing(grok);
    const response = await provider.cue(chat());
    assert.deepEqual(calls.map(call => call.url), [XAI, MUSE], 'Grok first, then exactly one Muse attempt');
    const [first, second] = calls;
    assert.deepEqual([first.auth, second.auth], [`Bearer ${XAI_KEY}`, `Bearer ${MUSE_KEY}`], 'Each provider only receives its own key');
    assert.deepEqual(second.body.messages, first.body.messages, 'Same prompt and same turns');
    assert.deepEqual(second.body.response_format, first.body.response_format, 'Same strict schema');
    assert.equal(second.body.messages[0].content, SYSTEM_PROMPT);
    assert.deepEqual([second.body.model, second.body.reasoning_effort, second.body.max_completion_tokens], ['muse-spark-1.3', 'minimal', 4096]);
    assert.deepEqual(response.result, { ...MUSE_CUE, scene: '' }, 'The cue shown is the one Muse gave');
    const { metrics } = response;
    assert.deepEqual([metrics.provider, metrics.model, metrics.fallbackFrom, metrics.fallbackReason], ['muse', 'muse-spark-1.3', 'xai', reason]);
    assert.ok(metrics.fallbackAfterMs >= 0 && metrics.apiMs >= metrics.fallbackAfterMs, 'apiMs covers both attempts');
    assert.equal(metrics.estimatedCostUsd, (200 * 1.25 + 800 * 0.15 + 100 * 4.25) / 1e6, 'Costed at Muse prices');
  });
}

test('a Grok check that has not answered after 3 seconds is abandoned for Muse', async t => {
  assert.equal(XAI_TIMEOUT_MS, 3000);
  // The real limit is recorded, then shortened so the test does not wait three seconds.
  const limits = [], timeout = AbortSignal.timeout.bind(AbortSignal);
  t.mock.method(AbortSignal, 'timeout', ms => { limits.push(ms); return timeout(ms === XAI_TIMEOUT_MS ? 20 : ms); });
  const { provider, calls } = failing(options => new Promise((_resolve, reject) =>
    options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true })));
  const response = await provider.cue(chat());
  assert.deepEqual(limits, [3000, 20_000], 'Grok gets three seconds; Muse keeps the usual limit');
  assert.deepEqual(calls.map(call => call.url), [XAI, MUSE]);
  assert.equal(calls[0].signal.aborted, true, 'The slow Grok request is cancelled, not left running');
  assert.equal(calls[1].signal.aborted, false);
  assert.deepEqual(response.result, { ...MUSE_CUE, scene: '' });
  assert.deepEqual([response.metrics.provider, response.metrics.fallbackFrom, response.metrics.fallbackReason], ['muse', 'xai', 'timeout']);
  assert.ok(response.metrics.fallbackAfterMs >= 15 && response.metrics.apiMs >= response.metrics.fallbackAfterMs);
});

test('a shorter API_TIMEOUT_MS also limits the Grok attempt', async t => {
  const limits = [], timeout = AbortSignal.timeout.bind(AbortSignal);
  t.mock.method(AbortSignal, 'timeout', ms => { limits.push(ms); return timeout(ms); });
  await recording({ ...env, API_TIMEOUT_MS: '1000' }).provider.cue(chat());
  assert.deepEqual(limits, [1000]);
});

test('when Muse fails as well there is no cue, after exactly two attempts', async () => {
  const { provider, calls } = failing(async () => ({ ok: false, status: 500, json: async () => ({ secret: 'participant content' }) }),
    async () => ({ ok: false, status: 429, json: async () => ({ secret: 'participant content' }) }));
  await assert.rejects(provider.cue(chat()), error => error.status === 429 && !error.message.includes('participant content'));
  assert.deepEqual(calls.map(call => call.url), [XAI, MUSE]);
});

test('scene checks and Muse-only setups are never retried', async () => {
  for (const [environment, request] of [[env, surroundingsInput()], [muse, chat()]]) {
    const calls = [];
    const provider = createProvider(environment, async url => { calls.push(url); return { ok: false, status: 500, json: async () => ({}) }; });
    await assert.rejects(provider.cue(request), error => error.status === 502);
    assert.deepEqual(calls, [MUSE]);
  }
});

test('caller cancellation reaches the xAI request and does not start a Muse one', async () => {
  const controller = new AbortController();
  const { provider, calls } = failing(options => new Promise((_resolve, reject) =>
    options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true })));
  const work = provider.cue(chat(), controller.signal);
  controller.abort(); await assert.rejects(work, { name: 'AbortError' });
  assert.deepEqual(calls.map(call => call.url), [XAI]); assert.equal(calls[0].signal.aborted, true);
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
  assert.equal(cues.some(line => line.includes('fallback=')), false);
  const health = await (await fetch(`${base}/api/health`)).json();
  assert.deepEqual([health.model, health.conversationModel], ['muse-spark-1.3', 'grok-4.20-non-reasoning']);
});

test('the server log names the provider that answered and the one that failed first', async t => {
  const lines = []; t.mock.method(console, 'log', line => lines.push(String(line)));
  const { provider } = failing(async () => ({ ok: false, status: 500, json: async () => ({}) }));
  const token = 'synthetic-proxy-token-for-tests-only-123456789';
  const server = createServer({ env: { HOST: '127.0.0.1', COPILOT_PROXY_TOKEN: token }, provider });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  t.after(async () => { const closed = new Promise(resolve => server.close(resolve)); server.closeAllConnections(); await closed; });
  const response = await fetch(`http://127.0.0.1:${server.address().port}/api/cue`, { method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` }, body: JSON.stringify({ ...input(Date.now()), frame: null, trigger: 'question' }) });
  const body = await response.json();
  assert.equal(response.status, 200); assert.equal(body.result.cue, MUSE_CUE.cue);
  assert.deepEqual([body.metrics.provider, body.metrics.fallbackFrom, body.metrics.fallbackReason], ['muse', 'xai', 'unavailable']);
  const cues = lines.filter(line => line.includes('/api/cue'));
  assert.equal(cues.length, 1);
  assert.match(cues[0], /POST \/api\/cue 200 .* provider=muse model=muse-spark-1\.3 apiMs=\d+ fallback=xai:unavailable:\d+ms$/);
  assert.equal(lines.some(line => line.includes('Tech') || line.includes(XAI_KEY) || line.includes(MUSE_KEY)), false);
});
