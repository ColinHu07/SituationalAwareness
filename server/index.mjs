import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { timingSafeEqual } from 'node:crypto';
import { spawn } from 'node:child_process';
import { networkInterfaces } from 'node:os';
import { createProvider, recentConversation, conversationTurns, triggerFor } from './model.mjs';
import { attachRealtimeASR } from './realtime-asr.mjs';
import { validateInput, validateAudio, validateLearnInput, validateToneInput } from './validation.mjs';
import { abstain, LIMITS } from '../shared/protocol.mjs';

export function createServer({ env = process.env, provider = createProvider(env) } = {}) {
  const token = env.COPILOT_PROXY_TOKEN || '';
  const host = env.HOST || '127.0.0.1';
  if ((provider.mode === 'live' || !['127.0.0.1', 'localhost', '::1'].includes(host)) && token.length < 32)
    throw new Error('A separate COPILOT_PROXY_TOKEN of at least 32 characters is required for live or non-loopback use.');
  let active = 0;
  // Four slots: the phone transcribes and asks for a cue at the same time, with headroom for cancelled work.
  const recent = [], MAX_PER_MINUTE = 120, MAX_ACTIVE = 4;
  const files = { '/': '../web/index.html', '/app.mjs': '../web/app.mjs', '/style.css': '../web/style.css', '/shared/protocol.mjs': '../shared/protocol.mjs' };
  const server = http.createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Content-Security-Policy', "default-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'");
    const json = (status, data) => {
      // Timing and provider only, never content: enough to compare Grok and Muse latency from the log.
      // provider is the one that answered; fallback names the one that failed first, why, and after how long.
      const timing = path === '/api/cue' && data.metrics ? ` provider=${data.metrics.provider ?? 'none'} model=${data.metrics.model ?? 'none'} apiMs=${Math.round(data.metrics.apiMs)}` +
        (data.metrics.fallbackFrom ? ` fallback=${data.metrics.fallbackFrom}:${data.metrics.fallbackReason}:${Math.round(data.metrics.fallbackAfterMs)}ms` : '') : '';
      if (path.startsWith('/api/')) console.log(`${new Date().toISOString()} ${req.method} ${path} ${status} from ${req.socket.remoteAddress}${timing}`);
      if (!res.destroyed) { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(data)); } };
    const path = (req.url || '/').split('?')[0];
    const provided = Buffer.from((req.headers.authorization || '').replace(/^Bearer /, '')), expected = Buffer.from(token);
    const tokenValid = !token || (provided.length === expected.length && timingSafeEqual(provided, expected));
    const controller = new AbortController();
    let acquired = false;
    res.on('close', () => { if (!res.writableEnded) controller.abort(); });
    try {
      // A local page cannot be used as a cross-origin proxy; native requests omit Origin.
      if (req.headers.origin && req.headers.origin !== `http://${req.headers.host}` && req.headers.origin !== `https://${req.headers.host}`) return json(403, { error: 'Cross-origin requests are disabled.' });
      if (req.method === 'GET' && path === '/api/health') return json(200, { ok: true, modelMode: provider.mode, model: provider.model, conversationModel: provider.conversationModel ?? provider.model, requiresToken: !!token, hardware: 'unverified', defaults: LIMITS, ...(req.headers.authorization ? { tokenValid } : {}) });
      if (req.method === 'GET' && files[path]) {
        const data = await readFile(new URL(files[path], import.meta.url));
        res.writeHead(200, { 'Content-Type': path.endsWith('.mjs') ? 'text/javascript' : path.endsWith('.css') ? 'text/css' : 'text/html' }); return res.end(data);
      }
      if (req.method !== 'POST' || !['/api/cue','/api/transcribe','/api/learn','/api/tone'].includes(path)) return json(404, { error: 'Not found' });
      if (!tokenValid) return json(401, { error: 'Enter the proxy token, not the model API key.' });
      if (!(req.headers['content-type'] || '').startsWith('application/json')) return json(415, { error: 'Expected application/json' });
      while (recent.length && recent[0] < Date.now() - 60000) recent.shift();
      if (active >= MAX_ACTIVE || recent.length >= MAX_PER_MINUTE) return json(429, { error: 'Busy. Drop this sample and wait; do not queue.' });
      active++; acquired = true; recent.push(Date.now());
      let bytes = 0; const chunks = [];
      for await (const chunk of req) { bytes += chunk.length; if (bytes > 1_000_000) { json(413, { error: 'Payload exceeds 1 MB' }); req.destroy(); return; } chunks.push(chunk); }
      let body; try { body = JSON.parse(Buffer.concat(chunks).toString()); } catch { return json(400, { error: 'Invalid JSON' }); }
      if (path === '/api/cue') {
        const input = validateInput(body), surroundings = input.analysisMode === 'surroundings';
        const last = (surroundings ? recentConversation(input.transcript) : conversationTurns(input.transcript)).at(-1);
        // An explicit request may look back over the rolling transcript; an automatic moment needs speech that just happened.
        const maxAge = !surroundings && triggerFor(input) === 'manual' ? LIMITS.transcriptMs : LIMITS.speechMs;
        const recentSpeech = last && Date.now() - last.endMs <= maxAge && (last.confidence === null || last.confidence >= 0.65);
        const recentScene = surroundings && input.frame !== null;
        if (!recentSpeech && !recentScene)
          return json(200, { result: abstain(surroundings ? 'A recent image or clear speech is required.' : 'Recent clear speech is required.'), metrics: { apiMs: 0, estimatedCostUsd: 0, simulated: provider.mode === 'mock' } });
        return json(200, await provider.cue(input, controller.signal));
      }
      if (path === '/api/learn') return json(200, await provider.learn(validateLearnInput(body), controller.signal));
      if (path === '/api/tone') return json(200, await provider.tone(validateToneInput(body), controller.signal));
      return json(200, await provider.transcribe(validateAudio(body), controller.signal));
    } catch (error) {
      const status = error.name === 'TimeoutError' || error.name === 'AbortError' ? 504 : error.status || 502;
      json(status, { error: status === 400 ? error.message : status === 503 ? error.message : 'Processing unavailable. No cue shown; try again after a pause.' });
    } finally { if (acquired) active--; }
  });
  attachRealtimeASR(server, { env, token });
  return server;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (existsSync('.env')) process.loadEnvFile('.env');
  const server = createServer();
  server.requestTimeout = 15000; server.headersTimeout = 10000;
  const host = process.env.HOST || '127.0.0.1', port = Number(process.env.PORT || 8787);
  server.listen(port, host, () => {
    console.log(`Aside: http://${host}:${port} • ${process.env.MODEL_MODE === 'live' ? 'LIVE provider' : 'SIMULATED provider'} • content is not logged or persisted`);
    // Announce on the local network so the phone app can find this server without typing an IP.
    if (process.platform === 'darwin' && !['127.0.0.1', 'localhost', '::1'].includes(host)) {
      // Private LAN addresses first; link-local (169.254) last since those interfaces come and go.
      const ips = Object.values(networkInterfaces()).flat().filter(a => a && a.family === 'IPv4' && !a.internal).map(a => a.address)
        .sort((x, y) => x.startsWith('169.254.') - y.startsWith('169.254.'));
      const advert = spawn('dns-sd', ['-R', 'Aside', '_aside._tcp', 'local', String(port), `ips=${ips.join(',')}`], { stdio: 'ignore' });
      advert.on('error', () => console.log('Local network announcement unavailable; enter the server URL in the app.'));
      for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { advert.kill(); process.exit(0); });
      process.on('exit', () => advert.kill());
      console.log('Announcing on the local network as _aside._tcp');
    }
  });
}
