import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import {
  buildElevenLabsRealtimeURL,
  ELEVENLABS_CHUNK_BYTES,
  ElevenLabsShadowASR,
  normalizeElevenLabsEvent,
} from '../server/elevenlabs-realtime.mjs';

class FakeElevenLabsSocket extends EventEmitter {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSED = 3;
  static latest = null;
  readyState = FakeElevenLabsSocket.OPEN;
  sent = [];
  closed = null;
  constructor(url, options) {
    super(); this.url = url; this.options = options; FakeElevenLabsSocket.latest = this;
    queueMicrotask(() => {
      this.emit('open');
      queueMicrotask(() => this.emit('message', JSON.stringify({message_type:'session_started',session_id:'sess-1'})));
    });
  }
  send(value) { this.sent.push(value); }
  close(code, reason) { this.closed = {code,reason}; this.readyState = FakeElevenLabsSocket.CLOSED; this.emit('close', code); }
  off(name, listener) { this.removeListener(name, listener); return this; }
}

const flush = () => new Promise(resolve => setTimeout(resolve, 0));

test('ElevenLabs URL selects realtime Scribe, PCM16/16k, VAD and timestamps', () => {
  const url = new URL(buildElevenLabsRealtimeURL());
  assert.equal(url.origin, 'wss://api.elevenlabs.io');
  assert.equal(url.searchParams.get('model_id'), 'scribe_v2_realtime');
  assert.equal(url.searchParams.get('audio_format'), 'pcm_16000');
  assert.equal(url.searchParams.get('commit_strategy'), 'vad');
  assert.equal(url.searchParams.get('include_timestamps'), 'true');
});

test('ElevenLabs events normalize into non-authoritative shadow events', () => {
  assert.deepEqual(normalizeElevenLabsEvent({message_type:'partial_transcript',text:'hel'}),
    {type:'shadow.transcript.partial',source:'elevenlabs',shadow:true,text:'hel'});
  assert.deepEqual(normalizeElevenLabsEvent({message_type:'committed_transcript',text:'hello'}),
    {type:'shadow.transcript.final',source:'elevenlabs',shadow:true,text:'hello'});
  assert.equal(normalizeElevenLabsEvent({message_type:'session_started'}), null);
});

test('shadow adapter authenticates server-side and sends bounded base64 PCM chunks', async () => {
  const events = [], failures = [];
  const shadow = new ElevenLabsShadowASR({
    apiKey:'eleven-secret', WebSocketClass:FakeElevenLabsSocket,
    onEvent:event=>events.push(event), onFailure:message=>failures.push(message),
  });
  await shadow.start();
  const socket = FakeElevenLabsSocket.latest;
  assert.equal(socket.options.headers['xi-api-key'], 'eleven-secret');
  assert.equal(socket.url.includes('eleven-secret'), false);
  assert.ok(events.some(x=>x.type==='shadow.ready'));

  const pcm = Buffer.alloc(ELEVENLABS_CHUNK_BYTES, 9);
  shadow.sendPCM(pcm);
  const sent = JSON.parse(socket.sent.at(-1));
  assert.equal(sent.message_type, 'input_audio_chunk');
  assert.deepEqual(Buffer.from(sent.audio_base_64,'base64'), pcm);

  socket.emit('message', JSON.stringify({message_type:'partial_transcript',text:'hello'}));
  await flush();
  assert.ok(events.some(x=>x.type==='shadow.transcript.partial' && x.text==='hello'));
  assert.deepEqual(failures, []);
  shadow.stop();
});

test('ElevenLabs provider errors stop only the shadow adapter', async () => {
  const failures = [];
  const shadow = new ElevenLabsShadowASR({
    apiKey:'eleven-secret', WebSocketClass:FakeElevenLabsSocket,
    onFailure:message=>failures.push(message),
  });
  await shadow.start();
  const socket = FakeElevenLabsSocket.latest;
  socket.emit('message', JSON.stringify({message_type:'rate_limited',error:'slow down'}));
  assert.equal(failures.length, 1);
  assert.equal(shadow.ready, false);
  assert.equal(socket.closed?.code, 1011);
});
