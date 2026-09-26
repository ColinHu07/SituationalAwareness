import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { timingSafeEqual } from 'node:crypto';
import { createProvider } from './model.mjs';
import { validateInput, validateAudio } from './validation.mjs';
import { abstain, LIMITS } from '../shared/protocol.mjs';

export function createServer({ env = process.env, provider = createProvider(env) } = {}) {
  const token = env.COPILOT_PROXY_TOKEN || '';
  const host = env.HOST || '127.0.0.1';
  if ((provider.mode === 'live' || !['127.0.0.1', 'localhost', '::1'].includes(host)) && token.length < 32)
    throw new Error('A separate COPILOT_PROXY_TOKEN of at least 32 characters is required for live or non-loopback use.');
  let active = 0;
  const recent = [], MAX_PER_MINUTE = 60;
  const files = { '/': '../web/index.html', '/app.mjs': '../web/app.mjs', '/style.css': '../web/style.css', '/shared/protocol.mjs': '../shared/protocol.mjs' };
  return http.createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Content-Security-Policy', "default-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'");
    const json = (status, data) => { if (!res.destroyed) { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(data)); } };
    const path = (req.url || '/').split('?')[0];
    const controller = new AbortController();
    let acquired = false;
    res.on('close', () => { if (!res.writableEnded) controller.abort(); });
    try {
      // A local page cannot be used as a cross-origin proxy; native requests omit Origin.
      if (req.headers.origin && req.headers.origin !== `http://${req.headers.host}` && req.headers.origin !== `https://${req.headers.host}`) return json(403, { error: 'Cross-origin requests are disabled.' });
      if (req.method === 'GET' && path === '/api/health') return json(200, { ok: true, modelMode: provider.mode, model: provider.model, requiresToken: !!token, hardware: 'unverified', defaults: LIMITS });
      if (req.method === 'GET' && files[path]) {
        const data = await readFile(new URL(files[path], import.meta.url));
        res.writeHead(200, { 'Content-Type': path.endsWith('.mjs') ? 'text/javascript' : path.endsWith('.css') ? 'text/css' : 'text/html' }); return res.end(data);
      }
      if (req.method !== 'POST' || !['/api/cue','/api/transcribe'].includes(path)) return json(404, { error: 'Not found' });
      const provided = Buffer.from((req.headers.authorization || '').replace(/^Bearer /, '')), expected = Buffer.from(token);
      if (token && (provided.length !== expected.length || !timingSafeEqual(provided, expected))) return json(401, { error: 'Enter the proxy token, not the model API key.' });
      if (!(req.headers['content-type'] || '').startsWith('application/json')) return json(415, { error: 'Expected application/json' });
      while (recent.length && recent[0] < Date.now() - 60000) recent.shift();
      if (active >= 2 || recent.length >= MAX_PER_MINUTE) return json(429, { error: 'Busy. Drop this sample and wait; do not queue.' });
      active++; acquired = true; recent.push(Date.now());
      let bytes = 0; const chunks = [];
      for await (const chunk of req) { bytes += chunk.length; if (bytes > 1_000_000) { json(413, { error: 'Payload exceeds 1 MB' }); req.destroy(); return; } chunks.push(chunk); }
      let body; try { body = JSON.parse(Buffer.concat(chunks).toString()); } catch { return json(400, { error: 'Invalid JSON' }); }
      if (path === '/api/cue') {
        const input = validateInput(body), last = input.transcript.at(-1);
        const recentSpeech = last && Date.now() - last.endMs <= LIMITS.speechMs && (last.confidence === null || last.confidence >= 0.65);
        const recentScene = input.analysisMode === 'surroundings' && input.frame !== null;
        if (!recentSpeech && !recentScene)
          return json(200, { result: abstain(input.analysisMode === 'surroundings' ? 'A recent image or clear speech is required.' : 'Recent clear speech is required.'), metrics: { apiMs: 0, estimatedCostUsd: 0, simulated: provider.mode === 'mock' } });
        return json(200, await provider.cue(input, controller.signal));
      }
      return json(200, await provider.transcribe(validateAudio(body), controller.signal));
    } catch (error) {
      const status = error.name === 'TimeoutError' || error.name === 'AbortError' ? 504 : error.status || 502;
      json(status, { error: status === 400 ? error.message : status === 503 ? error.message : 'Processing unavailable. No cue shown; try again after a pause.' });
    } finally { if (acquired) active--; }
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const server = createServer();
  server.requestTimeout = 15000; server.headersTimeout = 10000;
  const host = process.env.HOST || '127.0.0.1', port = Number(process.env.PORT || 8787);
  server.listen(port, host, () => console.log(`Aside: http://${host}:${port} • ${process.env.MODEL_MODE === 'live' ? 'LIVE provider' : 'SIMULATED provider'} • content is not logged or persisted`));
}
