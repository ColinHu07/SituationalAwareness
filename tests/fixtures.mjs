// Synthetic test fixtures only. No recorded participant media or external credentials.
export const NOW = 1_800_000_000_000;
// Valid original 32×32 solid-color PNG for image transport tests.
export const PNG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAK0lEQVR4nGO4//oJTRHDqAWjFoxaMGrBqAWjFoxaMGrBqAWjFoxaMFQsAABHEbiX+36ZeQAAAABJRU5ErkJggg==';
export const CUE = Object.freeze({ cue: 'Ask what they meant by Friday.', reason: 'Recent speech asks whether it will be ready Friday.', confidence: 0.94, type: 'clarify', should_display: true });
export function input(now = NOW) {
  return { transcript: [{ text: 'Will you have it ready Friday?', startMs: now - 3000, endMs: now - 2000, confidence: null }],
    frame: { dataUrl: PNG, capturedAtMs: now - 2500 }, context: ['Mention my internship'], manual: false };
}
export function surroundingsInput(now = NOW) {
  return { ...input(now), analysisMode: 'surroundings', transcript: [],
    audioContext: { capturedAtMs: now - 1000, windowMs: 4000, activityRatio: 0.05, rmsDbFS: -65, source: 'glasses_hfp' } };
}
export function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
export function wav(samples = 16000) {
  const bytes = Buffer.alloc(44 + samples * 2);
  bytes.write('RIFF', 0); bytes.writeUInt32LE(bytes.length - 8, 4); bytes.write('WAVE', 8);
  bytes.write('fmt ', 12); bytes.writeUInt32LE(16, 16); bytes.writeUInt16LE(1, 20);
  bytes.writeUInt16LE(1, 22); bytes.writeUInt32LE(16000, 24); bytes.writeUInt32LE(32000, 28);
  bytes.writeUInt16LE(2, 32); bytes.writeUInt16LE(16, 34); bytes.write('data', 36);
  bytes.writeUInt32LE(samples * 2, 40);
  return bytes;
}
export function audioInput(now = NOW) {
  return { mimeType: 'audio/wav', sampleRate: 16000, audioBase64: wav().toString('base64'), startedAtMs: now - 2000, endedAtMs: now - 1000 };
}
export function completion(result = CUE, extra = {}) {
  return { choices: [{ finish_reason: 'stop', message: { content: JSON.stringify(result) } }],
    usage: { prompt_tokens: 1000, completion_tokens: 100, prompt_tokens_details: { cached_tokens: 800 }, completion_tokens_details: { reasoning_tokens: 50 } }, ...extra };
}
