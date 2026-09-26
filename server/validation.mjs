import { boundedTranscript, LIMITS } from '../shared/protocol.mjs';
export class InputError extends Error { constructor(message) { super(message); this.status = 400; } }
const require = (condition, message) => { if (!condition) throw new InputError(message); };
export function validateInput(body, now = Date.now()) {
  require(body && typeof body === 'object' && !Array.isArray(body), 'Expected a JSON object');
  require(Array.isArray(body.transcript) && body.transcript.length <= 40, 'Transcript must have at most 40 entries');
  for (const item of body.transcript) {
    require(item && typeof item.text === 'string' && item.text.length <= 500 && item.text.trim(), 'Invalid transcript text');
    require(Number.isFinite(item.startMs) && Number.isFinite(item.endMs) && item.startMs <= item.endMs &&
      item.endMs <= now + 1000 && item.startMs >= now - 120_000, 'Invalid transcript timestamp');
    require(item.confidence == null || (Number.isFinite(item.confidence) && item.confidence >= 0 && item.confidence <= 1), 'Invalid speech confidence');
  }
  require(Array.isArray(body.context) && body.context.length <= 5 && body.context.every(s => typeof s === 'string' && s.length <= 160), 'Invalid session topics');
  require(typeof body.manual === 'boolean', 'manual must be boolean');
  let frame = null;
  if (body.frame != null) {
    require(typeof body.frame.dataUrl === 'string' && body.frame.dataUrl.length <= 700_000 &&
      /^data:image\/(jpeg|png);base64,[A-Za-z0-9+/]+={0,2}$/.test(body.frame.dataUrl), 'Expected a small base64 JPEG or PNG');
    const bytes = Buffer.from(body.frame.dataUrl.split(',')[1], 'base64');
    const jpeg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
    const png = bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]));
    require(body.frame.dataUrl.startsWith('data:image/jpeg') ? jpeg : png, 'Image bytes do not match MIME type');
    require(Number.isFinite(body.frame.capturedAtMs) && body.frame.capturedAtMs <= now + 1000, 'Invalid frame timestamp');
    if (now - body.frame.capturedAtMs <= LIMITS.frameMs) frame = body.frame;
  }
  return { transcript: boundedTranscript(body.transcript.map(x => ({ ...x, confidence: x.confidence ?? null })), now),
    frame, context: body.context, manual: body.manual };
}

export function validateAudio(body, now = Date.now()) {
  require(body?.mimeType === 'audio/wav' && body.sampleRate === 16000 && typeof body.audioBase64 === 'string' &&
    body.audioBase64.length <= 900_000 && /^[A-Za-z0-9+/]+={0,2}$/.test(body.audioBase64), 'Expected PCM16 mono 16kHz WAV');
  require(Number.isFinite(body.startedAtMs) && Number.isFinite(body.endedAtMs) && body.startedAtMs <= body.endedAtMs &&
    body.endedAtMs <= now + 1000 && body.startedAtMs >= now - 60_000 && body.endedAtMs - body.startedAtMs <= 20_000, 'Audio must be recent and at most 20 seconds');
  const audio = Buffer.from(body.audioBase64, 'base64');
  require(audio.length >= 44 && audio.length <= 640_044 && audio.toString('ascii',0,4) === 'RIFF' &&
    audio.toString('ascii',8,12) === 'WAVE', 'Invalid WAV');
  let offset = 12, validFormat = false, dataLength = 0;
  while (offset + 8 <= audio.length) {
    const name = audio.toString('ascii', offset, offset + 4), size = audio.readUInt32LE(offset + 4);
    require(offset + 8 + size <= audio.length, 'Truncated WAV');
    if (name === 'fmt ') {
      require(size >= 16, 'Invalid WAV format');
      validFormat = audio.readUInt16LE(offset+8) === 1 && audio.readUInt16LE(offset+10) === 1 &&
        audio.readUInt32LE(offset+12) === 16000 && audio.readUInt16LE(offset+22) === 16;
    }
    if (name === 'data') dataLength += size;
    offset += 8 + size + (size % 2);
  }
  require(validFormat && dataLength > 0 && dataLength <= 640000 && dataLength % 2 === 0, 'WAV must contain <=20s PCM16 mono 16kHz audio');
  return audio;
}
