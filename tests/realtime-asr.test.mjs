import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import {
  buildMetaHandshake,
  DiarizedTurnAssembler,
  runRealtimeSession,
  validateStartMessage,
} from '../server/realtime-asr.mjs';

class FakeSocket extends EventEmitter {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSED = 3;
  readyState = FakeSocket.OPEN;
  sent = [];
  closed = null;
  send(value, options) { this.sent.push({ value, options }); }
  close(code, reason) { this.closed = { code, reason }; this.readyState = FakeSocket.CLOSED; this.emit('close', code); }
  off(name, listener) { this.removeListener(name, listener); return this; }
}

class FakeUpstream extends FakeSocket {
  static latest = null;
  constructor(url) {
    super(); this.url = url; FakeUpstream.latest = this;
    queueMicrotask(() => this.emit('open'));
  }
  send(value, options) {
    super.send(value, options);
    if (typeof value === 'string') {
      const message = JSON.parse(value);
      if (message.authorization) queueMicrotask(() => this.emit('message', JSON.stringify({ sessionId: 'meta-session' }), false));
    }
  }
}

const flush = () => new Promise(resolve => setTimeout(resolve, 0));

test('realtime start defaults to English/Hindi while remaining language-generic', () => {
  assert.deepEqual(validateStartMessage({ type: 'start' }), { languageBias: ['English', 'Hindi'] });
  assert.deepEqual(validateStartMessage({ type: 'start', languageBias: ['Spanish', 'English', 'Spanish'] }),
    { languageBias: ['Spanish', 'English'] });
  assert.throws(() => validateStartMessage({ type: 'start', languageBias: ['Klingon'] }), /Invalid language/);
});

test('Meta handshake keeps the model key server-side and requests realtime diarization', () => {
  const handshake = buildMetaHandshake('server-secret', { languageBias: ['English', 'Hindi'] });
  assert.deepEqual(handshake, {
    authorization: { accessToken: 'Bearer server-secret' },
    audioEncoding: 'PCM_16KHZ', model: 'muse-voice-transcribe-1.0', mode: 'DIARIZATION',
    partialMode: 'CUMULATIVE', emitAudioProgress: false, languageBias: ['English', 'Hindi'],
  });
});

test('turn assembler replaces cumulative partials and keeps stable session speaker labels', () => {
  const a = new DiarizedTurnAssembler();
  assert.deepEqual(a.consume({ type: 'speechStart', turnId: 1, audioProcessedMs: 100 }), []);
  assert.deepEqual(a.consume({ type: 'transcript', transcript: 'hello', final: false, audioProcessedMs: 180 }),
    [{ type: 'transcript.partial', turnId: 1, speaker: null, text: 'hello', audioProcessedMs: 180 }]);
  assert.deepEqual(a.consume({ type: 'speaker', label: 'A', audioProcessedMs: 200 }),
    [{ type: 'speaker.updated', turnId: 1, speaker: 'P1', audioProcessedMs: 200 }]);
  assert.deepEqual(a.consume({ type: 'transcript', transcript: 'hello there', final: false, audioProcessedMs: 250 }),
    [{ type: 'transcript.partial', turnId: 1, speaker: 'P1', text: 'hello there', audioProcessedMs: 250 }]);
  a.consume({ type: 'speechEnd', turnId: 1, audioProcessedMs: 300 });

  // A later turn can begin before turn 1 finishes post-processing.
  a.consume({ type: 'speechStart', turnId: 2, audioProcessedMs: 320 });
  a.consume({ type: 'speaker', label: 'B', audioProcessedMs: 340 });
  assert.deepEqual(a.consume({ type: 'speechComplete', turnId: 1, transcript: 'Hello there.', audioProcessedMs: 300 }), [{
    type: 'transcript.final', turnId: 1, speaker: 'P1', text: 'Hello there.', startAudioMs: 100, endAudioMs: 300,
    audioProcessedMs: 300,
  }]);
  assert.deepEqual(a.consume({ type: 'speechComplete', turnId: 2, transcript: 'Hi.', audioProcessedMs: 500 }), [{
    type: 'transcript.final', turnId: 2, speaker: 'P2', text: 'Hi.', startAudioMs: 320, endAudioMs: 500,
    audioProcessedMs: 500,
  }]);

  a.consume({ type: 'speechStart', turnId: 3, audioProcessedMs: 600 });
  assert.deepEqual(a.consume({ type: 'speaker', label: 'A', audioProcessedMs: 620 }),
    [{ type: 'speaker.updated', turnId: 3, speaker: 'P1', audioProcessedMs: 620 }]);
});

test('speaker aliases reset for every realtime session', () => {
  const first = new DiarizedTurnAssembler();
  first.consume({ type: 'speechStart', turnId: 1 });
  assert.equal(first.consume({ type: 'speaker', label: 'provider-a' })[0].speaker, 'P1');
  first.consume({ type: 'speechStart', turnId: 2 });
  assert.equal(first.consume({ type: 'speaker', label: 'provider-b' })[0].speaker, 'P2');

  const next = new DiarizedTurnAssembler();
  next.consume({ type: 'speechStart', turnId: 1 });
  assert.equal(next.consume({ type: 'speaker', label: 'provider-b' })[0].speaker, 'P1');
});

test('relay waits for Meta acknowledgement, forwards raw PCM, and never sends the model key to the client', async () => {
  const client = new FakeSocket();
  await runRealtimeSession(client, { apiKey: 'server-secret', WebSocketClass: FakeUpstream, sessionId: 'local-session' });
  client.emit('message', Buffer.from(JSON.stringify({ type: 'start', languageBias: ['English', 'Hindi'] })), false);
  await flush(); await flush();
  const ready = client.sent.map(x => typeof x.value === 'string' ? JSON.parse(x.value) : null).find(x => x?.type === 'ready');
  assert.deepEqual(ready, { type: 'ready', sessionId: 'meta-session' });
  assert.equal(JSON.stringify(client.sent).includes('server-secret'), false);

  const upstream = FakeUpstream.latest;
  const pcm = Buffer.from([0, 0, 1, 0, 2, 0]);
  client.emit('message', pcm, true);
  assert.deepEqual(upstream.sent.at(-1), { value: pcm, options: { binary: true } });
  for (const event of [
    { type: 'speechStart', turnId: 1, audioProcessedMs: 0 },
    { type: 'speaker', label: 'A' },
    { type: 'transcript', transcript: 'Hello' },
    { type: 'speechStart', turnId: 2, audioProcessedMs: 200 },
    { type: 'speaker', label: 'B' },
    { type: 'transcript', transcript: 'Hi there' },
    { type: 'speechComplete', turnId: 1, transcript: 'Hello.', audioProcessedMs: 190 },
  ]) upstream.emit('message', JSON.stringify(event), false);
  const captions = client.sent.map(x => JSON.parse(x.value)).filter(x => x.type.startsWith('transcript.'));
  assert.deepEqual(captions.map(({ type, turnId, speaker, text }) => ({ type, turnId, speaker, text })), [
    { type: 'transcript.partial', turnId: 1, speaker: 'P1', text: 'Hello' },
    { type: 'transcript.partial', turnId: 2, speaker: 'P2', text: 'Hi there' },
    { type: 'transcript.final', turnId: 1, speaker: 'P1', text: 'Hello.' },
  ]);
  client.emit('message', JSON.stringify({ type: 'endStream' }), false);
  assert.deepEqual(JSON.parse(upstream.sent.at(-1).value), { type: 'endStream' });
  client.close(1000, 'Stopped');
  assert.equal(upstream.closed?.code, 1000);
});

test('idle authenticated realtime clients cannot occupy a relay slot indefinitely', async () => {
  const client = new FakeSocket();
  await runRealtimeSession(client, {
    apiKey: 'server-secret', WebSocketClass: FakeUpstream, startTimeoutMs: 5,
  });
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(client.closed?.code, 1008);
});

test('opt-in diagnostics correlate audio offsets, provider boundaries and round trips without extra content', async () => {
  const client = new FakeSocket();
  await runRealtimeSession(client, { apiKey: 'server-secret', WebSocketClass: FakeUpstream });
  client.emit('message', JSON.stringify({ type:'start', diagnostics:true }), false);
  await flush(); await flush();
  const upstream = FakeUpstream.latest;
  assert.equal(JSON.parse(upstream.sent[0].value).emitAudioProgress, true);
  client.emit('message', Buffer.alloc(3200), true);
  client.emit('message', JSON.stringify({type:'timing.ping',clientSentMs:12345}), false);
  upstream.emit('message', JSON.stringify({type:'audioProgress',audioProcessedMs:80}), false);
  upstream.emit('message', JSON.stringify({type:'speechStart',turnId:1,audioProcessedMs:20}), false);
  upstream.emit('message', JSON.stringify({type:'speechEnd',turnId:1,audioProcessedMs:90}), false);
  const messages = client.sent.map(x=>JSON.parse(x.value));
  const forwarded = messages.find(x=>x.type==='audio.forwarded');
  assert.equal(forwarded.timing.audioReceivedMs,100);
  assert.equal(forwarded.timing.audioForwardedMs,100);
  assert.equal(forwarded.timing.upstreamQueuedMs,0);
  assert.ok(forwarded.timing.serverElapsedMs >= 0);
  assert.equal(messages.find(x=>x.type==='timing.pong').clientSentMs,12345);
  assert.equal(messages.find(x=>x.type==='audio.progress').audioProcessedMs,80);
  assert.equal(messages.find(x=>x.type==='speech.start').turnId,1);
  assert.equal(messages.find(x=>x.type==='speech.end').audioProcessedMs,90);
  assert.ok(messages.every(x=>!('text' in x)));
  assert.equal(JSON.stringify(messages).includes('server-secret'),false);
  assert.throws(()=>validateStartMessage({type:'start',diagnostics:'yes'}),/Invalid diagnostics/);
  client.close(1000,'Done');
});

test('invalid and oversized client frames close safely without echoing participant content', async () => {
  const invalid = new FakeSocket();
  await runRealtimeSession(invalid, { apiKey: 'server-secret', WebSocketClass: FakeUpstream });
  invalid.emit('message', Buffer.from('{"participant":"private participant words"}'), false);
  await flush();
  assert.equal(invalid.closed?.code, 1008);
  assert.equal(invalid.closed?.reason, 'Realtime transcription unavailable.');
  assert.equal(JSON.stringify(invalid.closed).includes('private participant words'), false);

  const oversized = new FakeSocket();
  await runRealtimeSession(oversized, { apiKey: 'server-secret', WebSocketClass: FakeUpstream });
  oversized.emit('message', Buffer.from(JSON.stringify({ type: 'start' })), false);
  await flush(); await flush();
  oversized.emit('message', Buffer.alloc(64 * 1024 + 1), true);
  assert.equal(oversized.closed?.code, 1009);
  assert.equal(oversized.closed?.reason, 'Realtime transcription unavailable.');
});
