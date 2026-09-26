export const LIMITS = Object.freeze({
  transcriptMs: 60_000, transcriptCount: 40, transcriptChars: 6000,
  frameMs: 10_000, speechMs: 15_000, requestMs: 10_000,
  quietMs: 1500, cooldownMs: 30_000, cueMs: 8000,
  sampleMs: 5000, cueChars: 90, confidence: 0.8,
});

export const cueSchema = {
  type: 'object', additionalProperties: false,
  properties: {
    cue: { type: 'string' }, reason: { type: 'string' },
    confidence: { type: 'number' },
    type: { type: 'string', enum: ['clarify', 'follow_up', 'reminder', 'respond', 'abstain'] },
    should_display: { type: 'boolean' },
    scene: { type: 'string' },
    summary: { type: 'string' },
  },
  required: ['cue', 'reason', 'confidence', 'type', 'should_display', 'scene', 'summary'],
};

const stringList = { type: 'array', items: { type: 'string' } };
export const learnSchema = {
  type: 'object', additionalProperties: false,
  properties: {
    people: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: { id: { type: 'string' }, facts: stringList, topics: stringList, tags: stringList, groups: stringList },
      required: ['id', 'facts', 'topics', 'tags', 'groups'] } },
    groups: { type: 'array', items: { type: 'object', additionalProperties: false,
      properties: { name: { type: 'string' }, topics: stringList, slang: stringList, style: { type: 'string' } },
      required: ['name', 'topics', 'slang', 'style'] } },
  },
  required: ['people', 'groups'],
};

// Profile updates are proposals the wearer reviews; trim rather than reject noisy lists.
export function validateLearn(value, input) {
  if (!value || typeof value !== 'object' || !Array.isArray(value.people) || !Array.isArray(value.groups))
    throw new Error('Invalid structured profile response');
  const clean = (list, max, count = 8) => (Array.isArray(list) ? list : [])
    .filter(s => typeof s === 'string').map(s => s.trim()).filter(s => s && s.length <= max).slice(0, count);
  const ids = new Set(input.people.map(p => p.id));
  const people = value.people.filter(p => p && ids.has(p.id)).map(p => ({
    id: p.id, facts: clean(p.facts, 160), topics: clean(p.topics, 60), tags: clean(p.tags, 30, 6), groups: clean(p.groups, 40, 4),
  }));
  const groups = value.groups.filter(g => g && typeof g.name === 'string' && g.name.trim() && g.name.trim().length <= 40).slice(0, 6)
    .map(g => ({ name: g.name.trim(), topics: clean(g.topics, 60), slang: clean(g.slang, 80), style: typeof g.style === 'string' ? g.style.trim().slice(0, 200) : '' }));
  return { people, groups };
}

export const toneSchema = {
  type: 'object', additionalProperties: false,
  properties: {
    flag: { type: 'boolean' },
    severity: { type: 'string', enum: ['none', 'mild', 'strong'] },
    issue: { type: 'string' }, recovery: { type: 'string' }, rephrase: { type: 'string' },
  },
  required: ['flag', 'severity', 'issue', 'recovery', 'rephrase'],
};
const NO_TONE_ISSUE = Object.freeze({ flag: false, severity: 'none', issue: '', recovery: '', rephrase: '' });

/** Coaching on how the wearer's own line may land. Too-long advice is dropped rather than shown cut off. */
export function validateTone(value) {
  if (!value || typeof value !== 'object' || typeof value.flag !== 'boolean' ||
      !toneSchema.properties.severity.enum.includes(value.severity) ||
      ['issue', 'recovery', 'rephrase'].some(k => typeof value[k] !== 'string')) throw new Error('Invalid structured tone response');
  const fits = (s, words, chars) => s.trim() && s.trim().length <= chars && s.trim().split(/\s+/).length <= words;
  if (!value.flag || value.severity === 'none' || !fits(value.recovery, 20, 140)) return { ...NO_TONE_ISSUE };
  if (/\b(autis\w*|diagnos\w*|disorder)\b/i.test(value.recovery + value.rephrase + value.issue)) return { ...NO_TONE_ISSUE };
  return { flag: true, severity: value.severity, issue: value.issue.trim().slice(0, 80),
    recovery: value.recovery.trim(), rephrase: fits(value.rephrase, 20, 140) ? value.rephrase.trim() : '' };
}

export function abstain(reason = 'Insufficient concrete conversational evidence.', scene = '') {
  return { cue: '', reason, confidence: 0, type: 'abstain', should_display: false, scene };
}

/** Short lowercase label for the setting ("library", "funeral"), or "" when unclear. */
export function normalizeScene(value) {
  return typeof value === 'string' ? value.trim().toLowerCase().replace(/[^a-z0-9 '&-]/g, '').slice(0, 40) : '';
}

export function validateCue(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      // scene and summary are optional for fixtures and older providers.
      !Object.keys(value).every(k => cueSchema.required.includes(k)) ||
      !cueSchema.required.filter(k => !['scene', 'summary'].includes(k)).every(k => k in value) ||
      (value.scene !== undefined && (typeof value.scene !== 'string' || value.scene.length > 60)) ||
      (value.summary !== undefined && typeof value.summary !== 'string') ||
      typeof value.cue !== 'string' || typeof value.reason !== 'string' ||
      typeof value.should_display !== 'boolean' ||
      !Number.isFinite(value.confidence) || value.confidence < 0 || value.confidence > 1 ||
      !cueSchema.properties.type.enum.includes(value.type) || value.reason.length > 400 ||
      value.cue.length > LIMITS.cueChars || value.cue.trim().split(/\s+/).length > 14) {
    throw new Error('Invalid structured cue response');
  }
  const scene = normalizeScene(value.scene);
  // A one-sentence memory of this moment, sent back on later checks. Kept even when abstaining.
  const summary = typeof value.summary === 'string' ? value.summary.trim().slice(0, 200) : '';
  const withSummary = result => summary ? { ...result, summary } : result;
  if (!value.should_display) return withSummary(abstain(value.reason, scene));
  if (!value.cue.trim() || value.type === 'abstain') throw new Error('Inconsistent cue response');
  // This guard is additional defense, not a substitute for model evaluation.
  if (/\b(autis\w*|alzheimer\w*|diagnos\w*|depress\w*|angry|anxious|lying|attracted|emotion|facial expression)\b/i.test(value.cue)) {
    return withSummary(abstain('Unsupported personal inference blocked.', scene));
  }
  const { summary: _, ...rest } = value;
  return withSummary({ ...rest, cue: value.cue.trim(), scene });
}

export function boundedTranscript(items, now = Date.now()) {
  const recent = items.filter(x => x.endMs >= now - LIMITS.transcriptMs && x.endMs <= now + 1000)
    .sort((a, b) => a.endMs - b.endMs).slice(-LIMITS.transcriptCount);
  let count = 0;
  return recent.reverse().filter(x => { count += x.text.length; return count <= LIMITS.transcriptChars; }).reverse();
}

export function normalizeCue(s) { return s.toLowerCase().replace(/[^a-z0-9]/g, ''); }

/** Local policy. Pause, stop, every utterance, and dismiss invalidate in-flight work. */
export class Session {
  constructor({ now = () => Date.now(), onChange = () => {} } = {}) {
    this.now = now; this.onChange = onChange; this.state = 'stopped'; this.revision = 0;
    this.transcript = []; this.frame = null; this.context = []; this.cue = null;
    this.connected = true; this.speaking = false; this.pending = null;
    this.lastDisplay = -Infinity; this.seen = new Map(); this.lastReason = 'Start when everyone agrees.';
    this.metrics = { requests: 0, displayed: 0, suppressed: 0, stale: 0, errors: 0, uploadBytes: 0, apiMs: [], transcriptionMs: [], latencyMs: [], costUsd: 0, costUnknown: false };
  }
  invalidate(reason) {
    if (this.pending) this.metrics.costUnknown = true; // cancellation cannot recall already accepted provider work
    this.revision++; this.pending?.controller.abort(); this.cue = null;
    this.lastReason = reason; this.onChange();
  }
  start(consented) {
    if (!consented) throw new Error('Confirm all participants consent before starting.');
    if (!this.connected) throw new Error('Connect a device before starting.');
    this.state = 'running'; this.invalidate('Listening for useful context.');
  }
  pause() { this.state = 'paused'; this.transcript = []; this.frame = null; this.speaking = false; this.invalidate('Paused. Capture stopped; context cleared.'); }
  stop() {
    this.state = 'stopped'; this.transcript = []; this.frame = null; this.context = [];
    this.seen.clear(); this.speaking = false; this.lastDisplay = -Infinity;
    this.invalidate('Stopped. Session content cleared.');
  }
  dismiss() { this.lastDisplay = this.now(); this.invalidate('Dismissed. Giving you space.'); }
  disconnect() { this.connected = false; this.pause(); this.lastReason = 'Device disconnected. Reconnect, then start deliberately.'; this.onChange(); }
  reconnect() { this.connected = true; this.onChange(); }
  speechStart() { if (this.state === 'running') { this.speaking = true; this.invalidate('Conversation in progress.'); } }
  append(text, { startMs = this.now(), endMs = this.now(), confidence = null } = {}) {
    if (this.state !== 'running' || !text.trim()) return;
    this.speaking = false;
    this.transcript = boundedTranscript([...this.transcript, { text: text.trim().slice(0, 500), startMs, endMs, confidence }], this.now());
    this.invalidate('Waiting for a natural pause.');
  }
  setFrame(frame) { if (this.state === 'running') this.frame = frame; }
  tick() {
    this.transcript = boundedTranscript(this.transcript, this.now());
    if (this.frame && this.now() - this.frame.capturedAtMs > LIMITS.frameMs) this.frame = null;
    if (this.cue && this.now() >= this.cue.expiresAtMs) { this.cue = null; this.onChange(); }
    for (const [key, at] of this.seen) if (this.now() - at > 120_000) this.seen.delete(key);
  }
  ready(manual = false) {
    this.tick();
    const last = this.transcript.at(-1);
    return this.state === 'running' && this.connected && !this.pending && !this.speaking && !!last &&
      this.now() - last.endMs >= LIMITS.quietMs && this.now() - last.endMs <= LIMITS.speechMs &&
      (last.confidence === null || last.confidence >= 0.65) &&
      (manual || this.now() - this.lastDisplay >= LIMITS.cooldownMs);
  }
  async suggest(call, manual = false) {
    if (!this.ready(manual)) return false;
    const revision = this.revision, began = this.now(), controller = new AbortController();
    const payload = { transcript: this.transcript, frame: this.frame, context: this.context.slice(0, 5), manual };
    this.pending = { revision, controller }; this.metrics.requests++;
    this.metrics.uploadBytes += new TextEncoder().encode(JSON.stringify(payload)).length;
    this.lastReason = 'Considering recent context…'; this.onChange();
    let timeout;
    try {
      const response = await Promise.race([
        call(payload, controller.signal),
        new Promise((_, reject) => { timeout = setTimeout(() => { controller.abort(); reject(new Error('Request timed out')); }, LIMITS.requestMs); }),
      ]);
      this.metrics.apiMs.push(response.metrics?.apiMs ?? this.now() - began);
      this.metrics.apiMs = this.metrics.apiMs.slice(-100);
      this.metrics.costUsd += response.metrics?.estimatedCostUsd ?? 0;
      if (response.metrics?.estimatedCostUsd == null) this.metrics.costUnknown = true;
      if (this.state !== 'running' || revision !== this.revision || this.now() - began > LIMITS.requestMs || !this.connected) {
        this.metrics.stale++; return false;
      }
      const value = validateCue(response.result);
      const last = this.transcript.at(-1), key = normalizeCue(value.cue);
      if (!value.should_display || value.confidence < LIMITS.confidence || this.seen.has(key) || this.speaking ||
          !last || this.now() - last.endMs > LIMITS.speechMs) {
        this.metrics.suppressed++; this.lastReason = 'No cue needed.'; return false;
      }
      this.cue = { ...value, expiresAtMs: this.now() + LIMITS.cueMs };
      this.seen.set(key, this.now()); this.lastDisplay = this.now(); this.metrics.displayed++;
      this.metrics.latencyMs.push(this.now() - (payload.frame?.capturedAtMs ?? last.endMs));
      this.metrics.latencyMs = this.metrics.latencyMs.slice(-100);
      this.lastReason = 'One brief cue. Dismiss any time.'; return true;
    } catch (e) {
      this.metrics.costUnknown = true;
      if (revision === this.revision) { this.metrics.errors++; this.lastReason = e.name === 'AbortError' ? 'Request cancelled.' : 'Network or model unavailable. No cue shown.'; }
      return false;
    } finally {
      clearTimeout(timeout); if (this.pending?.revision === revision) this.pending = null; this.onChange();
    }
  }
}
