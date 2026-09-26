import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from '../server/index.mjs';
import { createProvider } from '../server/model.mjs';
import { Session } from '../shared/protocol.mjs';
import { CUE, input, audioInput, deferred } from './fixtures.mjs';

const TOKEN = 'synthetic-proxy-token-for-tests-only-123456789';
const providerResult = { result: CUE, metrics: { apiMs: 0, estimatedCostUsd: 0, simulated: true } };

async function serverFor(t, provider = createProvider({ MODEL_MODE: 'mock' }), extra = {}) {
  const server = createServer({ env: { HOST: '127.0.0.1', ...extra }, provider });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  t.after(async () => { const closed = new Promise(resolve => server.close(resolve)); server.closeAllConnections(); await closed; });
  const url = `http://127.0.0.1:${server.address().port}`;
  return {
    url,
    post: (body, { path = '/api/cue', headers = {}, ...options } = {}) => fetch(`${url}${path}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', ...headers },
      body: typeof body === 'string' ? body : JSON.stringify(body), ...options,
    }),
  };
}

test('health reports simulated status, unverified hardware and no cache', async t => {
  const server = await serverFor(t);
  const response = await fetch(`${server.url}/api/health`), body = await response.json();
  assert.equal(response.status, 200); assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(body.modelMode, 'mock'); assert.equal(body.hardware, 'unverified');
  assert.equal(body.requiresToken, false); assert.equal(JSON.stringify(body).includes(TOKEN), false);
});

test('live and non-loopback listeners require an independent long proxy token', () => {
  const provider = { mode: 'live', model: 'muse-spark-1.3' };
  assert.throws(() => createServer({ env: { HOST: '127.0.0.1' }, provider }), /at least 32/);
  assert.throws(() => createServer({ env: { HOST: '0.0.0.0' }, provider: { mode: 'mock' } }), /at least 32/);
});

test('HTTP authentication rejects missing/wrong token before processing', async t => {
  let calls = 0;
  const server = await serverFor(t, { mode: 'mock', cue: async () => { calls++; return providerResult; } }, { COPILOT_PROXY_TOKEN: TOKEN });
  for (const authorization of [undefined, 'Bearer wrong-token', `Bearer ${TOKEN}x`]) {
    const response = await server.post(input(Date.now()), { headers: authorization ? { Authorization: authorization } : {} });
    assert.equal(response.status, 401);
  }
  assert.equal(calls, 0);
  const ok = await server.post(input(Date.now()), { headers: { Authorization: `Bearer ${TOKEN}` } });
  assert.equal(ok.status, 200); assert.equal(calls, 1);
});

test('cross-origin API calls cannot use the local server as a proxy', async t => {
  const server = await serverFor(t);
  const response = await server.post(input(Date.now()), { headers: { Origin: 'https://untrusted.example' } });
  assert.equal(response.status, 403);
  const same = await server.post(input(Date.now()), { headers: { Origin: server.url } });
  assert.equal(same.status, 200);
});

test('malformed JSON, payload schema, MIME and unknown routes fail explicitly', async t => {
  let calls = 0;
  const server = await serverFor(t, { mode: 'mock', cue: async () => { calls++; return providerResult; } });
  const malformed = await server.post('{'); assert.equal(malformed.status, 400);
  const invalid = await server.post({}); assert.equal(invalid.status, 400);
  const mime = await server.post(input(Date.now()), { headers: { 'Content-Type': 'text/plain' } }); assert.equal(mime.status, 415);
  const unknown = await server.post(input(Date.now()), { path: '/api/arbitrary-proxy' }); assert.equal(unknown.status, 404);
  assert.equal(calls, 0);
});

test('expired or low-confidence speech abstains without model calls', async t => {
  let calls = 0;
  const server = await serverFor(t, { mode: 'mock', cue: async () => { calls++; return providerResult; } });
  const stale = input(Date.now() - 20000);
  const low = input(Date.now()); low.transcript[0].confidence = 0.4;
  for (const body of [stale, low, { ...input(Date.now()), transcript: [] }]) {
    const response = await server.post(body), result = await response.json();
    assert.equal(response.status, 200); assert.equal(result.result.should_display, false);
  }
  assert.equal(calls, 0);
});

test('an expired frame is dropped while fresh clear speech can be processed', async t => {
  let captured;
  const server = await serverFor(t, { mode: 'mock', cue: async body => { captured = body; return providerResult; } });
  const body = input(Date.now()); body.frame.capturedAtMs -= 15000;
  const response = await server.post(body);
  assert.equal(response.status, 200); assert.equal(captured.frame, null);
});

test('provider failure cannot leak upstream participant content into HTTP errors', async t => {
  const server = await serverFor(t, { mode: 'mock', cue: async () => { throw new Error('private participant words and synthetic-key'); } });
  const response = await server.post(input(Date.now())), text = await response.text();
  assert.equal(response.status, 502); assert.doesNotMatch(text, /participant words|synthetic-key/);
});

test('provider timeout and rate limit are distinguishable for client recovery', async t => {
  for (const [failure, expected] of [[new DOMException('late', 'TimeoutError'), 504], [Object.assign(new Error('rate limit'), { status: 429 }), 429]]) {
    const server = await serverFor(t, { mode: 'mock', cue: async () => { throw failure; } });
    assert.equal((await server.post(input(Date.now()))).status, expected);
  }
});

test('server concurrency is bounded and overflow is dropped without queuing', async t => {
  const gates = [deferred(), deferred()], started = deferred(); let calls = 0;
  const server = await serverFor(t, { mode: 'mock', cue: () => { const index = calls++; if (calls === 2) started.resolve(); return gates[index].promise; } });
  const first = server.post(input(Date.now())), second = server.post(input(Date.now()));
  await started.promise;
  assert.equal((await server.post(input(Date.now()))).status, 429); assert.equal(calls, 2);
  for (const gate of gates) gate.resolve(providerResult);
  assert.equal((await first).status, 200); assert.equal((await second).status, 200);
});

test('client disconnect propagates cancellation to provider work', async t => {
  const started = deferred(), aborted = deferred();
  const server = await serverFor(t, { mode: 'mock', cue: (_body, signal) => {
    started.resolve();
    return new Promise((_resolve, reject) => signal.addEventListener('abort', () => { aborted.resolve(); reject(signal.reason); }, { once: true }));
  } });
  const controller = new AbortController(), work = server.post(input(Date.now()), { signal: controller.signal });
  await started.promise; controller.abort();
  await assert.rejects(work, { name: 'AbortError' }); await aborted.promise;
});

test('mock transcription is explicitly unavailable and malformed WAV is rejected first', async t => {
  const server = await serverFor(t);
  assert.equal((await server.post(audioInput(Date.now()), { path: '/api/transcribe' })).status, 503);
  assert.equal((await server.post({ ...audioInput(Date.now()), audioBase64: 'bad' }, { path: '/api/transcribe' })).status, 400);
});

test('mock end-to-end flow displays a cue then clears it on subject change and pause', async t => {
  const server = await serverFor(t);
  const session = new Session(); session.start(true);
  session.append('Can you have it ready Friday?', { startMs: Date.now() - 3000, endMs: Date.now() - 2000 });
  const call = async (payload, signal) => { const response = await server.post(payload, { signal }); assert.equal(response.status, 200); return response.json(); };
  assert.equal(await session.suggest(call), true);
  assert.equal(session.cue.cue, CUE.cue); assert.match(session.cue.reason, /SIMULATED/);
  session.append('Let us talk about lunch instead.'); assert.equal(session.cue, null);
  session.dismiss(); session.pause(); assert.equal(session.state, 'paused'); assert.equal(session.cue, null);
  assert.deepEqual(session.transcript, []);
});
