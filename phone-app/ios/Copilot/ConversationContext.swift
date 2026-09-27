import Foundation

/// A rolling view of cumulative ASR updates, independent of the phone's caption history.
/// Character arrival times approximate speech timing; Muse does not supply word timestamps.
/// Revisions and finalization preserve those times so a long turn cannot revive old words.
struct ConversationWindow {
  private struct CharacterSample { let value: Character; let atMs: Double }
  private struct Turn {
    var characters: [CharacterSample] = []
    var fullLength = 0
    var speakerAlias: String?
    var final = false
  }
  private var turns: [Int:Turn] = [:]
  private var order: [Int] = []

  mutating func consume(_ event: RealtimeASREvent, at time: Double) {
    guard let id = event.turnId else { return }
    var turn = turns[id] ?? Turn()
    if let speakerAlias = event.speaker, SpeakerIdentityResolver.validLabel(speakerAlias) {
      turn.speakerAlias = speakerAlias
    }
    if let text = event.text, !turn.final {
      let full = Array(text)
      let incoming = Array(full.suffix(4000))
      let shift = max(0, full.count - 4000) - max(0, turn.fullLength - 4000)
      let previous = Array(turn.characters.dropFirst(max(0, shift)))
      var prefix = 0
      while prefix < min(previous.count, incoming.count), previous[prefix].value == incoming[prefix] { prefix += 1 }
      var suffix = 0
      while suffix < min(previous.count, incoming.count) - prefix,
            previous[previous.count - suffix - 1].value == incoming[incoming.count - suffix - 1] { suffix += 1 }
      // Corrections keep the old span's timestamp; newly appended speech gets the new timestamp.
      let replaced = previous.dropFirst(prefix).dropLast(suffix)
      let changedAt = replaced.first?.atMs ?? time
      turn.characters = Array(previous.prefix(prefix))
        + incoming.dropFirst(prefix).dropLast(suffix).map { CharacterSample(value:$0, atMs:changedAt) }
        + Array(previous.suffix(suffix))
      turn.fullLength = full.count
    }
    if event.type == "transcript.final" { turn.final = true }
    if turns[id] == nil { order.append(id) }
    turns[id] = turn
    while order.count > 32 { turns.removeValue(forKey:order.removeFirst()) }
  }

  func entries(at time: Double) -> [TranscriptEntry] {
    turns.values.compactMap { turn in
      let recent = turn.characters.filter { $0.atMs >= time - SurroundingsPolicy.contextWindowMs && $0.atMs <= time + 1000 }
      let text = String(recent.map(\.value).suffix(500)).trimmingCharacters(in:.whitespacesAndNewlines)
      guard text.contains(where: { $0.isLetter || $0.isNumber }), let start = recent.map(\.atMs).min(), let end = recent.map(\.atMs).max() else { return nil }
      return TranscriptEntry(text:text, startMs:min(start,end), endMs:max(start,end), confidence:nil,
                             speakerAlias:turn.speakerAlias)
    }.sorted { $0.endMs < $1.endMs }.suffix(12).map { $0 }
  }
}

/// Aggregate capture energy over the same recent window, without classifying sounds.
struct AmbientWindow {
  private var samples: [AudioContext] = []
  mutating func append(_ sample: AudioContext) {
    samples.append(sample)
    samples = Array(samples.filter { $0.capturedAtMs > sample.capturedAtMs - SurroundingsPolicy.contextWindowMs }.suffix(12))
  }
  func context(at time: Double) -> AudioContext? {
    guard let latest = samples.last, time - latest.capturedAtMs <= SurroundingsPolicy.contextWindowMs else { return nil }
    let recent = samples.filter { $0.source == latest.source && $0.capturedAtMs <= time + 1000 }
    var duration = 0.0, energy = 0.0, activity = 0.0
    for sample in recent {
      let weight = max(0, min(sample.windowMs, sample.capturedAtMs - (time - SurroundingsPolicy.contextWindowMs)))
      duration += weight
      energy += pow(10, sample.rmsDbFS / 10) * weight
      activity += sample.activityRatio * weight
    }
    guard duration > 0 else { return nil }
    return AudioContext(capturedAtMs:latest.capturedAtMs, windowMs:min(duration,SurroundingsPolicy.contextWindowMs),
                        activityRatio:activity/duration, rmsDbFS:max(-120,10 * log10(max(1e-12,energy/duration))), source:latest.source)
  }
}
