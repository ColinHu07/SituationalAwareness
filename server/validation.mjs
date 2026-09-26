import { boundedTranscript, LIMITS } from '../shared/protocol.mjs';
import { LOCALIZATION_LANGUAGES } from './localization.mjs';
export class InputError extends Error { constructor(message) { super(message); this.status = 400; } }
const require = (condition, message) => { if (!condition) throw new InputError(message); };
export function validateInput(body, now = Date.now()) {
  require(body && typeof body === 'object' && !Array.isArray(body), 'Expected a JSON object');
  const analysisMode = body.analysisMode === undefined ? 'conversation' : body.analysisMode;
  require(['conversation', 'surroundings'].includes(analysisMode), 'Invalid analysisMode');
  require(Array.isArray(body.transcript) && body.transcript.length <= 40, 'Transcript must have at most 40 entries');
  const transcript = [];
  for (const item of body.transcript) {
    require(item && typeof item === 'object' && !Array.isArray(item) &&
      Object.keys(item).every(key => ['text', 'startMs', 'endMs', 'confidence', 'speaker'].includes(key)), 'Invalid transcript fields');
    require(item && typeof item.text === 'string' && item.text.length <= 500 && item.text.trim(), 'Invalid transcript text');
    require(Number.isFinite(item.startMs) && Number.isFinite(item.endMs) && item.startMs <= item.endMs &&
      item.endMs <= now + 1000 && item.startMs >= now - 120_000, 'Invalid transcript timestamp');
    require(item.confidence == null || (Number.isFinite(item.confidence) && item.confidence >= 0 && item.confidence <= 1), 'Invalid speech confidence');
    require(item.speaker == null || (typeof item.speaker === 'string' && /^P(?:[1-9]|[1-9][0-9])$/.test(item.speaker)), 'Invalid speaker label');
    transcript.push({ text:item.text, startMs:item.startMs, endMs:item.endMs, confidence:item.confidence ?? null,
      ...(item.speaker == null ? {} : { speaker:item.speaker }) });
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
  let audioContext = null;
  if (body.audioContext != null) {
    const audio = body.audioContext;
    require(audio && typeof audio === 'object' && !Array.isArray(audio) &&
      Object.keys(audio).sort().join() === ['activityRatio', 'capturedAtMs', 'rmsDbFS', 'source', 'windowMs'].sort().join(), 'Invalid audioContext');
    require(Number.isFinite(audio.capturedAtMs) && audio.capturedAtMs <= now + 1000, 'Invalid audio context timestamp');
    require(Number.isFinite(audio.windowMs) && audio.windowMs > 0 && audio.windowMs <= 6000 &&
      Number.isFinite(audio.activityRatio) && audio.activityRatio >= 0 && audio.activityRatio <= 1 &&
      Number.isFinite(audio.rmsDbFS) && audio.rmsDbFS >= -120 && audio.rmsDbFS <= 0 &&
      ['glasses_hfp', 'glasses_pcm', 'phone'].includes(audio.source), 'Invalid audio context statistics');
    // Energy alone cannot establish a setting or identify speech, sounds, or mood.
    if (analysisMode === 'surroundings' && now - audio.capturedAtMs <= LIMITS.frameMs) audioContext = audio;
  }
  return { transcript: boundedTranscript(transcript, now),
    frame, context: body.context, manual: body.manual, analysisMode, audioContext };
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


export function validateLocalizationInput(body) {
  require(body && typeof body === 'object' && !Array.isArray(body) &&
    Object.keys(body).every(key => ['text','speaker','targetLanguage','context'].includes(key)), 'Invalid localization fields');
  require(typeof body.text === 'string' && body.text.trim() && body.text.length <= 500, 'Invalid localization text');
  require(body.speaker == null || (typeof body.speaker === 'string' && /^P(?:[1-9]|[1-9][0-9])$/.test(body.speaker)), 'Invalid speaker label');
  require(typeof body.targetLanguage === 'string' && LOCALIZATION_LANGUAGES.includes(body.targetLanguage), 'Unsupported target language');
  require(Array.isArray(body.context) && body.context.length <= 2, 'Localization context must have at most 2 turns');
  const context = body.context.map(item => {
    require(item && typeof item === 'object' && !Array.isArray(item) &&
      Object.keys(item).every(key => ['text','speaker'].includes(key)), 'Invalid localization context fields');
    require(typeof item.text === 'string' && item.text.trim() && item.text.length <= 500, 'Invalid localization context text');
    require(item.speaker == null || (typeof item.speaker === 'string' && /^P(?:[1-9]|[1-9][0-9])$/.test(item.speaker)), 'Invalid localization context speaker');
    return { text:item.text.trim(), ...(item.speaker == null ? {} : { speaker:item.speaker }) };
  });
  return { text:body.text.trim(), ...(body.speaker == null ? {} : { speaker:body.speaker }),
    targetLanguage:body.targetLanguage, context };
}
