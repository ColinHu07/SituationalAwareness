import { randomUUID, timingSafeEqual } from 'node:crypto';
import { WebSocket, WebSocketServer } from 'ws';

const META_REALTIME_URL = 'wss://api.meta.ai/v1/asr/realtime';
const MAX_CLIENT_FRAME_BYTES = 64 * 1024;
const DEFAULT_LANGUAGE_BIAS = Object.freeze(['English', 'Hindi']);
const SUPPORTED_LANGUAGES = new Set([
  'Arabic', 'Bengali', 'Dutch', 'English', 'French', 'German', 'Hebrew', 'Hindi',
  'Indonesian', 'Italian', 'Japanese', 'Kannada', 'Korean', 'Malay', 'Mandarin Chinese',
  'Marathi', 'Polish', 'Portuguese', 'Spanish', 'Tagalog', 'Tamil', 'Telugu', 'Thai',
  'Turkish', 'Vietnamese',
]);

function safeTokenMatch(header, expected) {
  if (!expected) return true;
  const value = typeof header === 'string' ? header.replace(/^Bearer\s+/i, '') : '';
  const provided = Buffer.from(value), wanted = Buffer.from(expected);
  return provided.length === wanted.length && timingSafeEqual(provided, wanted);
}

function rejectUpgrade(socket, status, message) {
  const body = `${message}\n`;
  socket.write(`HTTP/1.1 ${status}\r\nConnection: close\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
  socket.destroy();
}

export function validateStartMessage(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || value.type !== 'start')
    throw new Error('Expected realtime ASR start message.');
  const languages = value.languageBias ?? DEFAULT_LANGUAGE_BIAS;
  if (!Array.isArray(languages) || languages.length < 1 || languages.length > 6 ||
      languages.some(language => typeof language !== 'string' || !SUPPORTED_LANGUAGES.has(language)))
    throw new Error('Invalid language bias.');
  return { languageBias: [...new Set(languages)] };
}

export function buildMetaHandshake(apiKey, { languageBias }) {
  return {
    authorization: { accessToken: `Bearer ${apiKey}` },
    audioEncoding: 'PCM_16KHZ',
    model: 'muse-voice-transcribe-1.0',
    mode: 'DIARIZATION',
    partialMode: 'CUMULATIVE',
    emitAudioProgress: false,
    languageBias,
  };
}

export class DiarizedTurnAssembler {
  constructor() {
    this.activeTurnId = null;
    this.turns = new Map();
    this.speakerNumbers = new Map();
    this.nextSpeakerNumber = 1;
  }

  speakerName(label) {
    if (!label) return null;
    if (!this.speakerNumbers.has(label)) this.speakerNumbers.set(label, this.nextSpeakerNumber++);
    return `P${this.speakerNumbers.get(label)}`;
  }

  consume(event) {
    if (!event || typeof event !== 'object' || Array.isArray(event) || typeof event.type !== 'string') return [];
    const output = [];
    switch (event.type) {
    case 'speechStart': {
      if (!Number.isInteger(event.turnId)) return [];
      this.activeTurnId = event.turnId;
      this.turns.set(event.turnId, {
        turnId: event.turnId,
        startAudioMs: Number.isFinite(event.audioProcessedMs) ? event.audioProcessedMs : null,
        endAudioMs: null,
        partial: '',
        speakerLabel: null,
      });
      break;
    }
    case 'transcript': {
      const turn = this.turns.get(this.activeTurnId);
      if (!turn || typeof event.transcript !== 'string') return [];
      turn.partial = event.transcript;
      output.push({
        type: 'transcript.partial', turnId: turn.turnId,
        speaker: this.speakerName(turn.speakerLabel), text: event.transcript,
        audioProcessedMs: Number.isFinite(event.audioProcessedMs) ? event.audioProcessedMs : null,
      });
      break;
    }
    case 'speaker': {
      const turn = this.turns.get(this.activeTurnId);
      if (!turn || typeof event.label !== 'string' || !/^[A-Za-z0-9_-]{1,16}$/.test(event.label)) return [];
      turn.speakerLabel = event.label;
      output.push({
        type: 'speaker.updated', turnId: turn.turnId, speaker: this.speakerName(event.label),
        audioProcessedMs: Number.isFinite(event.audioProcessedMs) ? event.audioProcessedMs : null,
      });
      break;
    }
    case 'speechEnd': {
      const turn = this.turns.get(event.turnId);
      if (turn && Number.isFinite(event.audioProcessedMs)) turn.endAudioMs = event.audioProcessedMs;
      break;
    }
    case 'speechComplete': {
      if (!Number.isInteger(event.turnId) || typeof event.transcript !== 'string') return [];
      const turn = this.turns.get(event.turnId) ?? {
        turnId: event.turnId, startAudioMs: null, endAudioMs: null, partial: '', speakerLabel: null,
      };
      if (Number.isFinite(event.audioProcessedMs)) turn.endAudioMs = event.audioProcessedMs;
      output.push({
        type: 'transcript.final', turnId: event.turnId,
        speaker: this.speakerName(turn.speakerLabel),
        text: event.transcript,
        startAudioMs: turn.startAudioMs,
        endAudioMs: turn.endAudioMs,
        audioProcessedMs: Number.isFinite(event.audioProcessedMs) ? event.audioProcessedMs : null,
      });
      this.turns.delete(event.turnId);
      if (this.activeTurnId === event.turnId) this.activeTurnId = null;
      break;
    }
    }
    return output;
  }
}

function waitForOpen(socket, timeoutMs = 10_000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Upstream ASR connection timed out.')), timeoutMs);
    const cleanup = () => { clearTimeout(timer); socket.off('open', opened); socket.off('close', closed); socket.off('error', failed); };
    const opened = () => { cleanup(); resolve(); };
    const closed = () => { cleanup(); reject(new Error('Upstream ASR closed before opening.')); };
    const failed = () => { cleanup(); reject(new Error('Upstream ASR connection failed.')); };
    socket.once('open', opened); socket.once('close', closed); socket.once('error', failed);
  });
}

function waitForHandshake(socket, timeoutMs = 10_000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Upstream ASR handshake timed out.')), timeoutMs);
    const cleanup = () => { clearTimeout(timer); socket.off('message', received); socket.off('close', closed); socket.off('error', failed); };
    const received = data => {
      try {
        const value = JSON.parse(String(data));
        if (typeof value.sessionId !== 'string' || !value.sessionId) return;
        cleanup(); resolve(value.sessionId);
      } catch { /* ignore non-handshake frames until timeout */ }
    };
    const closed = () => { cleanup(); reject(new Error('Upstream ASR closed during handshake.')); };
    const failed = () => { cleanup(); reject(new Error('Upstream ASR handshake failed.')); };
    socket.on('message', received); socket.once('close', closed); socket.once('error', failed);
  });
}

export async function runRealtimeSession(client, {
  apiKey,
  upstreamURL = META_REALTIME_URL,
  WebSocketClass = WebSocket,
  sessionId = randomUUID(),
  startTimeoutMs = 10_000,
} = {}) {
  let upstream = null, started = false, ready = false, ending = false;
  const assembler = new DiarizedTurnAssembler();

  const sendClient = value => {
    if (client.readyState === WebSocket.OPEN) client.send(JSON.stringify(value));
  };
  const failClient = (code = 1011) => {
    if (client.readyState === WebSocket.OPEN || client.readyState === WebSocket.CONNECTING)
      client.close(code, 'Realtime transcription unavailable.');
  };

  const startTimer = setTimeout(() => {
    if (!started) failClient(1008);
  }, startTimeoutMs);

  const start = async value => {
    const config = validateStartMessage(value);
    if (started) throw new Error('ASR session already started.');
    started = true;
    clearTimeout(startTimer);
    const url = `${upstreamURL}?sessionId=${encodeURIComponent(sessionId)}`;
    upstream = new WebSocketClass(url);
    await waitForOpen(upstream);
    upstream.send(JSON.stringify(buildMetaHandshake(apiKey, config)));
    const metaSessionId = await waitForHandshake(upstream);
    ready = true;
    sendClient({ type: 'ready', sessionId: metaSessionId });

    upstream.on('message', (data, isBinary) => {
      if (isBinary) return;
      let event;
      try { event = JSON.parse(String(data)); } catch { return; }
      if (event.type === 'error') { failClient(1011); return; }
      for (const normalized of assembler.consume(event)) sendClient(normalized);
    });
    upstream.on('close', code => {
      if (client.readyState === WebSocket.OPEN)
        client.close(code === 1000 ? 1000 : code === 1008 || code === 1013 ? code : 1011,
          code === 1000 ? 'Complete.' : 'Realtime transcription unavailable.');
    });
    upstream.on('error', () => failClient(1011));
  };

  client.on('message', async (data, isBinary) => {
    try {
      if (isBinary) {
        if (!ready || ending || data.length === 0 || data.length > MAX_CLIENT_FRAME_BYTES) {
          failClient(data.length > MAX_CLIENT_FRAME_BYTES ? 1009 : 1008); return;
        }
        upstream.send(data, { binary: true });
        return;
      }
      const value = JSON.parse(String(data));
      if (!started) { await start(value); return; }
      if (value?.type === 'endStream' && ready && !ending) {
        ending = true; upstream.send(JSON.stringify({ type: 'endStream' })); return;
      }
      failClient(1008);
    } catch { failClient(1008); }
  });

  client.on('close', () => {
    clearTimeout(startTimer);
    if (!upstream || ending) return;
    if (upstream.readyState === WebSocket.OPEN) {
      upstream.close(1000, 'Client ended session.');
    } else if (upstream.readyState === WebSocket.CONNECTING) {
      // Stop pending upstream work when consent/capture ends before the provider connects.
      if (typeof upstream.terminate === 'function') upstream.terminate();
      else upstream.close(1000, 'Client ended session.');
    }
  });
}

export function attachRealtimeASR(server, {
  env = process.env,
  token = env.COPILOT_PROXY_TOKEN || '',
  upstreamURL = META_REALTIME_URL,
  WebSocketClass = WebSocket,
  maxSessions = 4,
} = {}) {
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_CLIENT_FRAME_BYTES });
  let active = 0;

  server.on('upgrade', (request, socket, head) => {
    let pathname;
    try { pathname = new URL(request.url || '/', 'http://localhost').pathname; } catch { socket.destroy(); return; }
    if (pathname !== '/api/asr/realtime') { socket.destroy(); return; }
    if (env.MODEL_MODE !== 'live' || !env.MUSE_API_KEY) { rejectUpgrade(socket, '503 Service Unavailable', 'Realtime transcription requires live mode.'); return; }
    if (!safeTokenMatch(request.headers.authorization, token)) { rejectUpgrade(socket, '401 Unauthorized', 'Unauthorized.'); return; }
    if (request.headers.origin) { rejectUpgrade(socket, '403 Forbidden', 'Browser WebSocket clients are disabled.'); return; }
    if (active >= maxSessions) { rejectUpgrade(socket, '429 Too Many Requests', 'Too many realtime sessions.'); return; }

    wss.handleUpgrade(request, socket, head, client => {
      active++;
      client.once('close', () => { active = Math.max(0, active - 1); });
      runRealtimeSession(client, { apiKey: env.MUSE_API_KEY, upstreamURL, WebSocketClass }).catch(() => {
        if (client.readyState === WebSocket.OPEN) client.close(1011, 'Realtime transcription unavailable.');
      });
    });
  });

  return wss;
}
