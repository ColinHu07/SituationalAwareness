import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from '../server/index.mjs';
import { createProvider } from '../server/model.mjs';

const TOKEN = 'synthetic-proxy-token-for-tests-only-123456789';

async function serverFor(t, localizer) {
  const server = createServer({
    env: { HOST:'127.0.0.1', COPILOT_PROXY_TOKEN:TOKEN, MODEL_MODE:'mock' },
    provider: createProvider({ MODEL_MODE:'mock' }),
    localizer,
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  t.after(async () => { const closed = new Promise(resolve => server.close(resolve)); server.closeAllConnections(); await closed; });
  return `http://127.0.0.1:${server.address().port}`;
}

test('localization endpoint authenticates and forwards only validated text context', async t => {
  let captured;
  const url = await serverFor(t, { localize: async input => {
    captured = input;
    return { result:{ translation:'ok' }, metrics:{} };
  } });
  const body = { text:'कल मिलना थोड़ा मुश्किल होगा।', speaker:'P1', targetLanguage:'English', context:[] };
  const unauthorized = await fetch(`${url}/api/localize`, {
    method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body),
  });
  assert.equal(unauthorized.status, 401);
  const response = await fetch(`${url}/api/localize`, {
    method:'POST', headers:{'Content-Type':'application/json', Authorization:`Bearer ${TOKEN}`}, body:JSON.stringify(body),
  });
  assert.equal(response.status, 200);
  assert.deepEqual(captured, body);
});

test('localization endpoint rejects unexpected personal metadata before provider use', async t => {
  let calls = 0;
  const url = await serverFor(t, { localize: async () => { calls++; return {}; } });
  const response = await fetch(`${url}/api/localize`, {
    method:'POST', headers:{'Content-Type':'application/json', Authorization:`Bearer ${TOKEN}`},
    body:JSON.stringify({ text:'hello', targetLanguage:'English', context:[], identity:'Sam' }),
  });
  assert.equal(response.status, 400);
  assert.equal(calls, 0);
});
