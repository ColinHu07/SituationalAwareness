import Foundation

/// When each step toward one cue happened, on the phone's clock in milliseconds. No words are recorded.
struct CueTiming: Equatable {
  /// The moment that prompted the check, or "scene".
  let trigger: String
  /// Sent on a partial caption, before the turn was finalized.
  let early: Bool
  var turn: Int?
  /// Last audio of the turn the cue answers. For an early check it is known once the turn is finalized.
  var speechEndMs: Double?
  var finalReceivedMs: Double?
  let requestSentMs: Double
  var responseReceivedMs: Double?
  var cueShownMs: Double?

  var label: String { early ? "\(trigger), early" : trigger }
  /// An early check waits for its turn to finish, so every step can be measured from the end of speech.
  var isComplete: Bool { cueShownMs != nil && (!early || finalReceivedMs != nil) }

  /// A step measured from the end of speech, or from the request when there was no speech.
  /// An early check can send, and even show its cue, before the speech ends: those read as negative.
  func offset(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    let delta = (value - (speechEndMs ?? requestSentMs)).rounded()
    return delta < 0 ? "\u{2212}\(Int(-delta)) ms" : "+\(Int(delta)) ms"
  }

  var steps: String {
    "final received \(offset(finalReceivedMs)); request sent \(offset(requestSentMs)); response received \(offset(responseReceivedMs)); cue shown \(offset(cueShownMs))"
  }
}

/// Follows one check at a time from the end of speech to the cue on screen.
struct CueTimingLog {
  private(set) var current: CueTiming?
  /// The most recent cue that reached the screen with all of its steps known.
  private(set) var lastShown: CueTiming?
  private var lastFinal: (turn: Int?, speechEndMs: Double, receivedMs: Double)?

  /// A turn was finalized. Returns the timing when this completes an early check whose cue is already showing.
  mutating func turnFinal(turn: Int?, speechEndMs: Double, at time: Double) -> CueTiming? {
    lastFinal = (turn, speechEndMs, time)
    guard var timing = current, timing.early, timing.finalReceivedMs == nil, let turn, timing.turn == turn else { return nil }
    timing.speechEndMs = speechEndMs; timing.finalReceivedMs = time
    current = timing
    return finish()
  }

  /// A check was sent. One sent for a finished turn takes that turn's times.
  mutating func requested(trigger: String, early: Bool, speechEndMs: Double?, at time: Double) {
    var timing = CueTiming(trigger:trigger, early:early, speechEndMs:early ? nil : speechEndMs, requestSentMs:time)
    if !early, let speechEndMs, let lastFinal, abs(lastFinal.speechEndMs - speechEndMs) < 1 {
      timing.turn = lastFinal.turn; timing.finalReceivedMs = lastFinal.receivedMs
    }
    current = timing
  }

  /// Names the turn an early check was sent for, so its final can be matched later.
  mutating func sentEarly(for turn: Int) {
    guard current?.early == true, current?.turn == nil else { return }
    current?.turn = turn
  }

  mutating func answered(at time: Double) {
    guard current?.responseReceivedMs == nil else { return }
    current?.responseReceivedMs = time
  }

  /// The cue reached the screen. Returns the timing once every step is known.
  mutating func shown(at time: Double) -> CueTiming? {
    guard current != nil, current?.cueShownMs == nil else { return nil }
    current?.cueShownMs = time
    return finish()
  }

  private mutating func finish() -> CueTiming? {
    guard let timing = current, timing.isComplete else { return nil }
    lastShown = timing
    return timing
  }
}
