import test from 'node:test';
import assert from 'node:assert/strict';
import { checkElevenLabsHealth, elevenLabsConfiguredHealth, ELEVENLABS_REALTIME_TOKEN_URL } from '../server/elevenlabs-health.mjs';

function response(status, body = null) {
  return { status, async json() { return body; } };
}


test('configured ElevenLabs health starts unchecked so the main Muse checkpoint can return immediately', () => {
  assert.deepEqual(elevenLabsConfiguredHealth({ enabled: true, apiKey: 'secret' }), {
    enabled: true, configured: true, reachable: null, authenticated: null, authorized: null, status: 'unchecked',
  });
});
test('ElevenLabs health is inert when shadow mode is disabled', async () => {
  let calls = 0;
  const result = await checkElevenLabsHealth({
    enabled: false,
    apiKey: 'secret',
    fetchImpl: async () => { calls++; return response(200, { token: 'should-not-be-used' }); },
  });
  assert.equal(calls, 0);
  assert.deepEqual(result, {
    enabled: false, configured: true, reachable: null, authenticated: null, authorized: null, status: 'disabled',
  });
});

test('ElevenLabs health reports a missing server key without making a request', async () => {
  let calls = 0;
  const result = await checkElevenLabsHealth({
    enabled: true,
    fetchImpl: async () => { calls++; return response(200, { token: 'unused' }); },
  });
  assert.equal(calls, 0);
  assert.equal(result.status, 'missing_key');
  assert.equal(result.configured, false);
  assert.equal(result.authorized, false);
});

test('ElevenLabs health verifies realtime Scribe authorization without exposing the issued token', async () => {
  let request;
  const result = await checkElevenLabsHealth({
    enabled: true,
    apiKey: 'server-secret',
    fetchImpl: async (url, options) => {
      request = { url, options };
      return response(200, { token: 'sutkn_health_check_secret' });
    },
  });
  assert.equal(request.url, ELEVENLABS_REALTIME_TOKEN_URL);
  assert.equal(request.options.method, 'POST');
  assert.equal(request.options.headers['xi-api-key'], 'server-secret');
  assert.deepEqual(result, {
    enabled: true, configured: true, reachable: true, authenticated: true, authorized: true, status: 'ready',
  });
  assert.equal(JSON.stringify(result).includes('sutkn_health_check_secret'), false);
});

test('ElevenLabs health distinguishes invalid keys and forbidden realtime Scribe access', async () => {
  const invalid = await checkElevenLabsHealth({
    enabled: true, apiKey: 'bad', fetchImpl: async () => response(401),
  });
  assert.equal(invalid.status, 'invalid_key');
  assert.equal(invalid.authenticated, false);

  const forbidden = await checkElevenLabsHealth({
    enabled: true, apiKey: 'scoped', fetchImpl: async () => response(403),
  });
  assert.equal(forbidden.status, 'forbidden');
  assert.equal(forbidden.authenticated, null);
  assert.equal(forbidden.authorized, false);
});

test('ElevenLabs health degrades independently on rate limits and network errors', async () => {
  const limited = await checkElevenLabsHealth({
    enabled: true, apiKey: 'key', fetchImpl: async () => response(429),
  });
  assert.equal(limited.status, 'rate_limited');
  assert.equal(limited.reachable, true);

  const unavailable = await checkElevenLabsHealth({
    enabled: true, apiKey: 'key', fetchImpl: async () => { throw new Error('offline'); },
  });
  assert.equal(unavailable.status, 'unavailable');
  assert.equal(unavailable.reachable, false);
});
