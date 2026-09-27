import Foundation

/// The moment that prompts a conversation check. Sent to the server as `trigger`.
enum CueTrigger: String {
  /// Someone else finished a turn ending in a question mark.
  case question
  /// Someone else finished a turn, then nobody spoke for a few seconds.
  case stuck
  /// Someone else used a phrase from `IndirectPhrases`.
  case indirect
  /// The wearer asked for help with Analyze.
  case manual
}

// Conversation checks fire at a moment, not on a timer. Scene checks keep `SurroundingsPolicy`.
enum ConversationPolicy {
  /// Silence after someone else's turn before a "stuck" check.
  static let stuckDelayMs = 3_000.0
  /// A conversation cue clears itself after this long.
  static let cueLifetimeMs = 8_000.0
  /// Cues below this confidence are not shown.
  static let displayConfidence = 0.8
  /// Only the last few turns are sent, as text.
  static let turnCount = 3
  /// Longest `aboutMe` the server accepts.
  static let aboutMeCharacters = 500
  /// Shown when the wearer asks and nothing fits, so an explicit request always gets an answer.
  static let nothingToAdd = "Nothing to add"

  /// "wearer" or "other". A turn is the wearer's when it carries the caption label found to be theirs,
  /// or was already labeled from their voice level. Unknown voices are "other".
  static func role(_ speaker: String?, wearerLabel: String?) -> String {
    guard let speaker, speaker == "wearer" || speaker == wearerLabel else { return "other" }
    return "wearer"
  }

  /// The check to run as soon as someone else's turn finishes, if any.
  /// A question comes first because someone is waiting for an answer.
  /// Until the wearer's voice is known, a question could be their own, so only a phrase counts.
  static func trigger(for text: String, wearerKnown: Bool = true) -> CueTrigger? {
    if wearerKnown, endsWithQuestion(text) { return .question }
    if IndirectPhrases.match(in:text) != nil { return .indirect }
    return nil
  }

  static func endsWithQuestion(_ text: String) -> Bool {
    let closers = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:"\"'\u{201D}\u{2019})]"))
    let trimmed = text.trimmingCharacters(in:closers)
    return trimmed.hasSuffix("?") || trimmed.hasSuffix("\u{FF1F}")
  }

  /// The last few reliable turns, oldest first, labeled "wearer" or "other" instead of realtime labels.
  static func turns(from transcript: [TranscriptEntry], wearerLabel: String?) -> [TranscriptEntry] {
    transcript.filter { ($0.confidence ?? 1) >= 0.65 }.suffix(turnCount).map { entry in
      var entry = entry
      entry.speaker = role(entry.speaker, wearerLabel:wearerLabel)
      return entry
    }
  }

  static func isNothingToAdd(_ text: String) -> Bool { IndirectPhrases.normalize(text) == IndirectPhrases.normalize(nothingToAdd) }
}

extension ConversationPolicy {
  /// The text to show for a model result, or nil to show nothing new.
  /// A scene check passes no trigger and keeps its own confidence bar.
  /// A manual check always shows something, because the wearer asked.
  static func displayText(for result: CueResult, trigger: CueTrigger?) -> String? {
    let text = result.cue.trimmingCharacters(in:.whitespacesAndNewlines)
    let minimum = trigger == nil ? SurroundingsPolicy.displayConfidence : displayConfidence
    let fits = result.should_display && result.confidence.isFinite && result.confidence >= minimum && result.confidence <= 1
      && ["clarify", "follow_up", "reminder", "respond", "meaning"].contains(result.type)
      && !text.isEmpty && text.count <= 90 && text.split(whereSeparator:\.isWhitespace).count <= 14
      && (trigger == nil || !isNothingToAdd(text))
    if fits { return text }
    return trigger == .manual ? nothingToAdd : nil
  }

  /// What the wearer shared about themselves, bounded for the request. Scene checks send none.
  /// The server counts UTF-16 units, so scripts with combining marks are clipped by that measure.
  static func aboutMe(_ text: String, for trigger: CueTrigger?) -> String? {
    var clipped = String(text.trimmingCharacters(in:.whitespacesAndNewlines).prefix(aboutMeCharacters))
    while clipped.utf16.count > aboutMeCharacters { clipped.removeLast() }
    return trigger == nil || clipped.isEmpty ? nil : clipped
  }

  /// Offline demo fixtures mirroring the server's mock. Live meanings come from the model.
  static func demoMeaning(for text: String) -> String? {
    switch IndirectPhrases.match(in:text) {
    case "it's getting late": "Often means: they may want to wrap up."
    case "we should hang out sometime": "Often means: a friendly gesture, not a firm plan."
    case "no worries": "Often means: it's fine, no need to apologize."
    default: nil
    }
  }
}
