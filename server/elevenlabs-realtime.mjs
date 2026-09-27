import { WebSocket } from 'ws';

export const ELEVENLABS_REALTIME_URL = 'wss://api.elevenlabs.io/v1/speech-to-text/realtime';
export const ELEVENLABS_CHUNK_BYTES = 6400; // 200 ms of PCM16 mono at 16 kHz.
const MAX_QUEUED_CHUNKS = 10; // Bound startup/network buffering to about two seconds.

export function buildElevenLabsRealtimeURL({
  upstreamURL = ELEVENLABS_REALTIME_URL,
  includeTimestamps = true,
  vadSilenceThresholdSecs = 1.0,
} = {}) {
  const url = new URL(upstreamURL);
  url.searchParams.set('model_id', 'scribe_v2_realtime');
  url.searchParams.set('audio_format', 'pcm_16000');
  url.searchParams.set('commit_strategy', 'vad');
  url.searchParams.set('vad_silence_threshold_secs', String(vadSilenceThresholdSecs));
  url.searchParams.set('min_speech_duration_ms', '100');
  url.searchParams.set('min_silence_duration_ms', '100');
  if (includeTimestamps) url.searchParams.set('include_timestamps', 'true');
  return url.toString();
}

export function normalizeElevenLabsEvent(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const common = { source: 'elevenlabs', shadow: true };
  switch (value.message_type) {
  case 'partial_transcript':
    return typeof value.text === 'string'
      ? { type: 'shadow.transcript.partial', ...common, text: value.text }
      : null;
  case 'committed_transcript':
    return typeof value.text === 'string'
      ? { type: 'shadow.transcript.final', ...common, text: value.text }
      : null;
  case 'committed_transcript_with_timestamps':
    return typeof value.text === 'string'
      ? { type: 'shadow.transcript.timestamps', ...common, text: value.text }
      : null;
  case 'warning':
    return { type: 'shadow.warning', ...common };
  default:
    return null;
  }
}

function isErrorEvent(value) {
  const type = value?.message_type;
  return typeof value?.error === 'string' || (typeof type === 'string' && (
    type.endsWith('_error') || [
      'rate_limited', 'quota_exceeded', 'throttled', 'queue_overflow',
      'resource_exhausted', 'session_time_limit_exceeded', 'invalid_request',
    ].includes(type)
  ));
}

function waitForOpen(socket, timeoutMs = 10_000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('ElevenLabs connection timed out.')), timeoutMs);
    const cleanup = () => { clearTimeout(timer); socket.off('open', opened); socket.off('close', closed); socket.off('error', failed); };
    const opened = () => { cleanup(); resolve(); };
    const closed = () => { cleanup(); reject(new Error('ElevenLabs closed before opening.')); };
    const failed = () => { cleanup(); reject(new Error('ElevenLabs connection failed.')); };
    socket.once('open', opened); socket.once('close', closed); socket.once('error', failed);
  });
}

function waitForSessionStarted(socket, timeoutMs = 10_000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('ElevenLabs session handshake timed out.')), timeoutMs);
    const cleanup = () => { clearTimeout(timer); socket.off('message', received); socket.off('close', closed); socket.off('error', failed); };
    const received = data => {
      let value;
      try { value = JSON.parse(String(data)); } catch { return; }
      if (value?.message_type === 'session_started' && typeof value.session_id === 'string' && value.session_id) {
        cleanup(); resolve(value.session_id); return;
      }
      if (isErrorEvent(value)) { cleanup(); reject(new Error('ElevenLabs rejected the realtime session.')); }
    };
    const closed = () => { cleanup(); reject(new Error('ElevenLabs closed during handshake.')); };
    const failed = () => { cleanup(); reject(new Error('ElevenLabs session handshake failed.')); };
    socket.on('message', received); socket.once('close', closed); socket.once('error', failed);
  });
}

export class ElevenLabsShadowASR {
  constructor({
    apiKey,
    upstreamURL = ELEVENLABS_REALTIME_URL,
    WebSocketClass = WebSocket,
    chunkBytes = ELEVENLABS_CHUNK_BYTES,
    onEvent = () => {},
    onFailure = () => {},
  } = {}) {
    if (!apiKey) throw new Error('ELEVENLABS_API_KEY is required for shadow realtime transcription.');
    this.apiKey = apiKey;
    this.upstreamURL = upstreamURL;
    this.WebSocketClass = WebSocketClass;
    this.chunkBytes = chunkBytes;
    this.onEvent = onEvent;
    this.onFailure = onFailure;
    this.socket = null;
    this.ready = false;
    this.stopped = false;
    this.pending = Buffer.alloc(0);
    this.queued = [];
    this.failed = false;
  }

  async start() {
    if (this.socket) throw new Error('ElevenLabs shadow session already started.');
    this.stopped = false;
    const url = buildElevenLabsRealtimeURL({ upstreamURL: this.upstreamURL });
    const socket = new this.WebSocketClass(url, { headers: { 'xi-api-key': this.apiKey } });
    this.socket = socket;
    const sessionPromise = waitForSessionStarted(socket);
    await waitForOpen(socket);
    const sessionId = await sessionPromise;
    if (this.socket !== socket || this.stopped) throw new Error('ElevenLabs shadow session stopped during startup.');
    this.ready = true;
    this.onEvent({ type: 'shadow.ready', source: 'elevenlabs', shadow: true, sessionId });
    socket.on('message', data => this.receive(data));
    socket.on('close', code => {
      if (this.socket === socket) {
        this.ready = false;
        this.socket = null;
        if (!this.stopped && code !== 1000) this.fail('ElevenLabs shadow connection closed.');
      }
    });
    socket.on('error', () => {
      if (this.socket === socket && !this.stopped) this.fail('ElevenLabs shadow connection failed.');
    });
    this.flushQueued();
  }

  sendPCM(data) {
    if (this.stopped || !data?.length) return;
    this.pending = this.pending.length ? Buffer.concat([this.pending, Buffer.from(data)]) : Buffer.from(data);
    while (this.pending.length >= this.chunkBytes) {
      const chunk = this.pending.subarray(0, this.chunkBytes);
      this.pending = this.pending.subarray(this.chunkBytes);
      this.enqueueOrSend(Buffer.from(chunk));
    }
  }

  stop({ commit = false } = {}) {
    if (this.stopped) return;
    this.stopped = true;
    if (this.pending.length) {
      const final = this.pending;
      this.pending = Buffer.alloc(0);
      if (this.ready && this.socket) this.sendChunk(final, commit);
    }
    this.queued = [];
    const socket = this.socket;
    this.socket = null;
    this.ready = false;
    if (socket && (socket.readyState === this.WebSocketClass.OPEN || socket.readyState === this.WebSocketClass.CONNECTING)) {
      socket.close(1000, 'Shadow session ended.');
    }
  }

  enqueueOrSend(chunk) {
    if (this.ready && this.socket) { this.sendChunk(chunk); return; }
    this.queued.push(chunk);
    if (this.queued.length > MAX_QUEUED_CHUNKS) this.queued.shift();
  }

  flushQueued() {
    if (!this.ready || !this.socket) return;
    const queued = this.queued;
    this.queued = [];
    for (const chunk of queued) this.sendChunk(chunk);
  }

  sendChunk(chunk, commit = false) {
    if (!this.ready || !this.socket || this.socket.readyState !== this.WebSocketClass.OPEN) return;
    this.socket.send(JSON.stringify({
      message_type: 'input_audio_chunk',
      audio_base_64: Buffer.from(chunk).toString('base64'),
      ...(commit ? { commit: true } : {}),
    }));
  }

  receive(data) {
    let value;
    try { value = JSON.parse(String(data)); } catch { return; }
    if (isErrorEvent(value)) { this.fail('ElevenLabs shadow transcription became unavailable.'); return; }
    const event = normalizeElevenLabsEvent(value);
    if (event) this.onEvent(event);
  }

  fail(message) {
    if (this.failed || this.stopped) return;
    this.failed = true;
    const socket = this.socket;
    this.socket = null;
    this.ready = false;
    this.pending = Buffer.alloc(0);
    this.queued = [];
    if (socket && (socket.readyState === this.WebSocketClass.OPEN || socket.readyState === this.WebSocketClass.CONNECTING)) {
      socket.close(1011, 'Shadow provider unavailable.');
    }
    this.onFailure(message);
  }
}
