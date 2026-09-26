import { boundedTranscript, LIMITS } from '../shared/protocol.mjs';
export class InputError extends Error { constructor(message) { super(message); this.status = 400; } }
const require = (condition, message) => { if (!condition) throw new InputError(message); };
export function validateInput(body, now = Date.now()) {
  require(body && typeof body === 'object' && !Array.isArray(body), 'Expected a JSON object');
  const analysisMode = body.analysisMode === undefined ? 'conversation' : body.analysisMode;
  require(['conversation', 'surroundings'].includes(analysisMode), 'Invalid analysisMode');
  require(Array.isArray(body.transcript) && body.transcript.length <= 40, 'Transcript must have at most 40 entries');
  for (const item of body.transcript) {
    require(item && typeof item.text === 'string' && item.text.length <= 500 && item.text.trim(), 'Invalid transcript text');
    require(Number.isFinite(item.startMs) && Number.isFinite(item.endMs) && item.startMs <= item.endMs &&
      item.endMs <= now + 1000 && item.startMs >= now - 120_000, 'Invalid transcript timestamp');
    require(item.confidence == null || (Number.isFinite(item.confidence) && item.confidence >= 0 && item.confidence <= 1), 'Invalid speech confidence');
    require(item.speaker === undefined || ['wearer', 'other'].includes(item.speaker) || (typeof item.speaker === 'string' && /^P[1-9][0-9]?$/.test(item.speaker)), 'Invalid speaker');
  }
  require(Array.isArray(body.context) && body.context.length <= 5 && body.context.every(s => typeof s === 'string' && s.length <= 160), 'Invalid session topics');
  require(typeof body.manual === 'boolean', 'manual must be boolean');
  require(body.currentScene === undefined || (typeof body.currentScene === 'string' && body.currentScene.length <= 40), 'Invalid currentScene');
  // Earlier one-sentence summaries from this session, and the cue now on screen.
  const recentMoments = body.recentMoments ?? [];
  require(Array.isArray(recentMoments) && recentMoments.length <= 8 && recentMoments.every(m => m && isText(m.summary, 200) &&
    Number.isFinite(m.atMs) && m.atMs <= now + 1000 && m.atMs >= now - 30 * 60_000), 'Invalid recentMoments');
  require(body.previousCue === undefined || isText(body.previousCue, LIMITS.cueChars), 'Invalid previousCue');
  const { people, groups } = validateProfiles(body);
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
    require(Number.isFinite(audio.windowMs) && audio.windowMs > 0 && audio.windowMs <= 10000 &&
      Number.isFinite(audio.activityRatio) && audio.activityRatio >= 0 && audio.activityRatio <= 1 &&
      Number.isFinite(audio.rmsDbFS) && audio.rmsDbFS >= -120 && audio.rmsDbFS <= 0 &&
      ['glasses_hfp', 'glasses_pcm', 'phone'].includes(audio.source), 'Invalid audio context statistics');
    // Energy alone cannot establish a setting or identify speech, sounds, or mood.
    if (analysisMode === 'surroundings' && now - audio.capturedAtMs <= LIMITS.frameMs) audioContext = audio;
  }
  return { transcript: boundedTranscript(body.transcript.map(x => ({ ...x, confidence: x.confidence ?? null })), now),
    frame, context: body.context, manual: body.manual, analysisMode, audioContext, people, groups, currentScene: body.currentScene ?? '',
    recentMoments: recentMoments.map(({ atMs, summary }) => ({ atMs, summary })), previousCue: body.previousCue ?? '' };
}

const isText = (s, max) => typeof s === 'string' && s.length <= max;
const isList = (a, count, max) => Array.isArray(a) && a.length <= count && a.every(s => isText(s, max));
// Wearer-kept profiles of people present and their friend groups. Optional for older clients.
function validateProfiles(body, { requireIds = false } = {}) {
  const people = body.people ?? [], groups = body.groups ?? [];
  require(Array.isArray(people) && people.length <= 8, 'Invalid people');
  for (const p of people) require(p && typeof p === 'object' && isText(p.name, 60) && p.name.trim() &&
    (requireIds ? isText(p.id, 64) && p.id : p.id === undefined || isText(p.id, 64)) &&
    isList(p.groups, 8, 40) && isList(p.tags, 12, 40) && isList(p.topics, 20, 80) && isList(p.notes, 40, 160), 'Invalid person profile');
  require(Array.isArray(groups) && groups.length <= 8, 'Invalid groups');
  for (const g of groups) require(g && typeof g === 'object' && isText(g.name, 40) && g.name.trim() &&
    isList(g.topics, 20, 80) && isList(g.slang, 20, 80) && isText(g.style, 200) && isList(g.notes, 20, 160), 'Invalid group profile');
  return {
    people: people.map(({ id, name, groups, tags, topics, notes }) => ({ ...(id ? { id } : {}), name, groups, tags, topics, notes })),
    groups: groups.map(({ name, topics, slang, style, notes }) => ({ name, topics, slang, style, notes })),
  };
}

// One line the wearer just said, with a little surrounding conversation, to check how it may land.
export function validateToneInput(body, now = Date.now()) {
  require(body && typeof body === 'object' && !Array.isArray(body), 'Expected a JSON object');
  const line = body.line;
  require(line && isText(line.text, 500) && line.text.trim() && Number.isFinite(line.endMs) &&
    line.endMs <= now + 1000 && line.endMs >= now - 120_000, 'Invalid line');
  require(Array.isArray(body.recent) && body.recent.length <= 12, 'recent must have at most 12 entries');
  for (const item of body.recent) require(item && isText(item.text, 500) &&
    (item.speaker === undefined || ['wearer', 'other'].includes(item.speaker)), 'Invalid recent entry');
  require(body.scene === undefined || isText(body.scene, 40), 'Invalid scene');
  require(typeof body.speakerKnown === 'boolean', 'speakerKnown must be boolean');
  const { people, groups } = validateProfiles(body);
  return { line: { text: line.text, endMs: line.endMs }, recent: body.recent.map(({ text, speaker }) => ({ text, ...(speaker ? { speaker } : {}) })),
    scene: body.scene ?? '', speakerKnown: body.speakerKnown, people, groups };
}

// A whole finished conversation, sent once on Stop so profiles can learn from it.
export function validateLearnInput(body, now = Date.now()) {
  require(body && typeof body === 'object' && !Array.isArray(body), 'Expected a JSON object');
  require(Array.isArray(body.transcript) && body.transcript.length > 0 && body.transcript.length <= 400, 'Transcript must have 1-400 entries');
  let chars = 0;
  for (const item of body.transcript) {
    require(item && isText(item.text, 500) && item.text.trim(), 'Invalid transcript text');
    require(Number.isFinite(item.startMs) && Number.isFinite(item.endMs) && item.startMs <= item.endMs &&
      item.endMs <= now + 1000 && item.startMs >= now - 6 * 3_600_000, 'Invalid transcript timestamp');
    chars += item.text.length;
  }
  require(chars <= 60_000, 'Transcript too long');
  const { people, groups } = validateProfiles(body, { requireIds: true });
  require(people.length > 0, 'At least one person is required');
  require(isList(body.otherGroupNames ?? [], 40, 40), 'Invalid group names');
  require(body.wordsPerMinute == null || (Number.isFinite(body.wordsPerMinute) && body.wordsPerMinute >= 0 && body.wordsPerMinute <= 400), 'Invalid wordsPerMinute');
  return { transcript: body.transcript.map(({ text, startMs, endMs }) => ({ text, startMs, endMs })), people, groups,
    otherGroupNames: body.otherGroupNames ?? [], wordsPerMinute: body.wordsPerMinute ?? null };
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
