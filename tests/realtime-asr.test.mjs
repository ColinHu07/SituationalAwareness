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
  constructor(url) {
    super(); this.url = url;
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

test('relay waits for Meta acknowledgement, forwards raw PCM, and never sends the model key to the client', async () => {
  const client = new FakeSocket();
  await runRealtimeSession(client, { apiKey: 'server-secret', WebSocketClass: FakeUpstream, sessionId: 'local-session' });
  client.emit('message', Buffer.from(JSON.stringify({ type: 'start', languageBias: ['English', 'Hindi'] })), false);
  await flush(); await flush();
  const ready = client.sent.map(x => typeof x.value === 'string' ? JSON.parse(x.value) : null).find(x => x?.type === 'ready');
  assert.deepEqual(ready, { type: 'ready', sessionId: 'meta-session' });
  assert.equal(JSON.stringify(client.sent).includes('server-secret'), false);
});

test('idle authenticated realtime clients cannot occupy a relay slot indefinitely', async () => {
  const client = new FakeSocket();
  await runRealtimeSession(client, {
    apiKey: 'server-secret', WebSocketClass: FakeUpstream, startTimeoutMs: 5,
  });
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(client.closed?.code, 1008);
});
