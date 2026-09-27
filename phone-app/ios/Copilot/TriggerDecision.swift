import Foundation

/// What a finished turn prompts, and why. The note goes to Caption timing so a missing cue can be explained.
/// It never includes what was said.
struct TriggerDecision: Equatable {
  /// The check to send now, if any.
  let trigger: CueTrigger?
  /// Whether to wait for silence and then send a stuck check.
  let stuck: Bool
  /// Why, in words for the timing log.
  let note: String

  static let wearerUnknown = "wearer not detected yet"

  /// Decides what one finished turn prompts. `wearerKnown` is already true when checks do not wait for detection.
  static func forTurn(text: String, role: String, wearerKnown: Bool, sceneChecks: Bool, active: Bool, newest: Bool,
                      early: SpeculativeCue.Outcome) -> TriggerDecision {
    if sceneChecks { return .init(trigger:nil, stuck:false, note:"none: scene checks are on, which run on a timer") }
    if !active { return .init(trigger:nil, stuck:false, note:"none: the session is not active") }
    if !newest { return .init(trigger:nil, stuck:false, note:"none: a newer turn was already heard") }
    if role != "other" { return .init(trigger:nil, stuck:false, note:"none: turn was the wearer's") }
    let stuckNote = wearerKnown ? "stuck check after \(Int(ConversationPolicy.stuckDelayMs / 1000)) s of silence" : "stuck skipped: \(wearerUnknown)"
    switch early {
    case .keep: return .init(trigger:nil, stuck:wearerKnown, note:"question skipped: already checked early with the same words; \(stuckNote)")
    case .rerun: return .init(trigger:.question, stuck:wearerKnown, note:"question: the words changed since the early check")
    case .none, .withdraw: break
    }
    if let trigger = ConversationPolicy.trigger(for:text, wearerKnown:wearerKnown) {
      return .init(trigger:trigger, stuck:wearerKnown, note:"\(trigger.rawValue): \(trigger == .question ? "the turn ends in a question mark" : "the turn has an indirect phrase")")
    }
    let reason = ConversationPolicy.endsWithQuestion(text) ? "question skipped: \(wearerUnknown)" : "none: not a question or an indirect phrase"
    return .init(trigger:nil, stuck:wearerKnown, note:"\(reason); \(stuckNote)")
  }
}

/// The state an automatic conversation check has to pass before it is sent, in the order it is tested.
struct CueGate: Equatable {
  var uploadsDisabled = false
  var active = true
  var checkInFlight = false
  /// Missing camera frames or audio, in the app's own words.
  var inputIssue: String? = nil
  var hasSpeech = true
  var sinceStartMs = Double.infinity
  var sinceDismissMs = Double.infinity
  var cueShowing = false

  /// Why this check will not be sent, or nil when nothing stops it.
  func skip(for trigger: CueTrigger) -> String? {
    if uploadsDisabled { return "uploads are off (offline or capture test)" }
    if !active { return "the session is not active" }
    // Silence only asks when nothing already covers the moment.
    if trigger == .stuck, cueShowing { return "cue already showing" }
    if checkInFlight { return "check in flight" }
    if let inputIssue { return "input not live: \(inputIssue)" }
    if !hasSpeech { return "no clear speech to send" }
    if sinceStartMs < 1500 { return "session started under 1.5 s ago" }
    if sinceDismissMs < SurroundingsPolicy.dismissQuietMs {
      return "dismiss quiet period, \(String(format:"%.1f", (SurroundingsPolicy.dismissQuietMs - sinceDismissMs) / 1000)) s left"
    }
    return nil
  }
}

extension WearerDetector {
  /// Each voice heard, with its turn count and average level, for the timing log. Labels and levels only.
  var levelsNote: String {
    let voices = voiceLevels.map { "\($0.label) \(String(format:"%.0f", $0.levelDbFS)) dBFS ×\($0.turns)" }
    return voices.isEmpty ? "no labeled voice with a level yet" : voices.joined(separator:", ")
  }
}

extension SessionModel {
  /// One line for the capture screens.
  var voiceLine: String { "Your voice: \(wearerKnown ? "learned" : "learning")" }
}
