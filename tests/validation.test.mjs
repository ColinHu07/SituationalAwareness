import test from 'node:test';
import assert from 'node:assert/strict';
import { validateInput, validateAudio, InputError } from '../server/validation.mjs';
import { NOW, input, surroundingsInput, audioInput, wav } from './fixtures.mjs';

test('recent coherent transcript and matching image bytes pass without alteration', () => {
  assert.deepEqual(validateInput(input(), NOW), { ...input(), analysisMode: 'conversation', audioContext: null });
});

test('surroundings accepts silent scenes and fresh bounded audio observations', () => {
  assert.deepEqual(validateInput(surroundingsInput(), NOW), surroundingsInput());
  for (const source of ['phone', 'glasses_pcm']) {
    const direct = surroundingsInput(); direct.audioContext.source = source;
    assert.equal(validateInput(direct, NOW).audioContext.source, source);
  }
  const withoutAudio = surroundingsInput(); delete withoutAudio.audioContext;
  assert.equal(validateInput(withoutAudio, NOW).audioContext, null);
});

test('expired audio energy is dropped and conversation mode never forwards it', () => {
  const expired = surroundingsInput(); expired.audioContext.capturedAtMs = NOW - 10001;
  assert.equal(validateInput(expired, NOW).audioContext, null);
  assert.equal(validateInput({ ...surroundingsInput(), analysisMode: 'conversation' }, NOW).audioContext, null);
});

for (const [label, change] of [
  ['unknown analysis mode', b => ({ ...b, analysisMode: 'always_watch' })],
  ['null analysis mode', b => ({ ...b, analysisMode: null })],
  ['array audio context', b => ({ ...b, audioContext: [] })],
  ['unrecognized audio observations', b => { b.audioContext.emotion = 'calm'; return b; }],
  ['missing audio source', b => { delete b.audioContext.source; return b; }],
  ['unknown audio source', b => { b.audioContext.source = 'video'; return b; }],
  ['future audio energy', b => { b.audioContext.capturedAtMs = NOW + 1001; return b; }],
  ['invalid audio timestamp', b => { b.audioContext.capturedAtMs = 'now'; return b; }],
  ['overlong energy window', b => { b.audioContext.windowMs = 6001; return b; }],
  ['empty energy window', b => { b.audioContext.windowMs = 0; return b; }],
  ['activity ratio below zero', b => { b.audioContext.activityRatio = -0.1; return b; }],
  ['activity ratio above one', b => { b.audioContext.activityRatio = 1.1; return b; }],
  ['nonnumeric activity ratio', b => { b.audioContext.activityRatio = 'quiet'; return b; }],
  ['energy above full scale', b => { b.audioContext.rmsDbFS = 1; return b; }],
  ['energy below accepted floor', b => { b.audioContext.rmsDbFS = -121; return b; }],
]) {
  test(`surroundings validation rejects ${label}`, () => assert.throws(() => validateInput(change(surroundingsInput()), NOW), InputError));
}

test('old transcript and frames are dropped instead of forwarded to the model', () => {
  const body = input(); body.transcript[0].startMs = NOW - 80000; body.transcript[0].endMs = NOW - 70000;
  body.frame.capturedAtMs = NOW - 10001;
  const valid = validateInput(body, NOW);
  assert.deepEqual(valid.transcript, []); assert.equal(valid.frame, null);
});

for (const [label, change] of [
  ['missing body', () => null], ['array body', () => []],
  ['too many transcript entries', b => ({ ...b, transcript: Array(41).fill(b.transcript[0]) })],
  ['empty speech', b => { b.transcript[0].text = ' '; return b; }],
  ['oversized speech', b => { b.transcript[0].text = 'x'.repeat(501); return b; }],
  ['reversed speech clock', b => { b.transcript[0].startMs = NOW; return b; }],
  ['future speech', b => { b.transcript[0].endMs = NOW + 1001; return b; }],
  ['unbounded confidence', b => { b.transcript[0].confidence = 2; return b; }],
  ['too many topics', b => ({ ...b, context: Array(6).fill('topic') })],
  ['oversized topic', b => ({ ...b, context: ['x'.repeat(161)] })],
  ['manual string', b => ({ ...b, manual: 'true' })],
  ['remote image URL', b => { b.frame.dataUrl = 'https://example.com/private-image'; return b; }],
  ['MIME mismatch', b => { b.frame.dataUrl = b.frame.dataUrl.replace('image/png', 'image/jpeg'); return b; }],
  ['invalid image base64', b => { b.frame.dataUrl = 'data:image/png;base64,<>bad'; return b; }],
  ['future frame', b => { b.frame.capturedAtMs = NOW + 1001; return b; }],
]) {
  test(`input validation rejects ${label}`, () => assert.throws(() => validateInput(change(input()), NOW), InputError));
}

test('confidence missing from supported STT is preserved as unknown', () => {
  const body = input(); delete body.transcript[0].confidence;
  assert.equal(validateInput(body, NOW).transcript[0].confidence, null);
});

test('WAV validation accepts genuine PCM16 mono header and bounds encoded duration', () => {
  assert.deepEqual(validateAudio(audioInput(), NOW), wav());
  const oversized = audioInput(); oversized.audioBase64 = wav(320001).toString('base64');
  assert.throws(() => validateAudio(oversized, NOW), InputError);
});

for (const [label, change] of [
  ['8kHz without conversion', b => ({ ...b, sampleRate: 8000 })],
  ['stale recording', b => ({ ...b, startedAtMs: NOW - 61000 })],
  ['long capture interval', b => ({ ...b, startedAtMs: NOW - 30000 })],
  ['future audio', b => ({ ...b, endedAtMs: NOW + 1001 })],
  ['wrong MIME', b => ({ ...b, mimeType: 'audio/mp3' })],
  ['non-WAV bytes', b => ({ ...b, audioBase64: Buffer.alloc(100).toString('base64') })],
  ['stereo WAV', b => { const bytes = wav(); bytes.writeUInt16LE(2, 22); b.audioBase64 = bytes.toString('base64'); return b; }],
  ['24-bit WAV', b => { const bytes = wav(); bytes.writeUInt16LE(24, 34); b.audioBase64 = bytes.toString('base64'); return b; }],
  ['truncated data chunk', b => { const bytes = wav(); bytes.writeUInt32LE(bytes.length, 40); b.audioBase64 = bytes.toString('base64'); return b; }],
]) {
  test(`audio validation rejects ${label}`, () => assert.throws(() => validateAudio(change(audioInput()), NOW), InputError));
}
