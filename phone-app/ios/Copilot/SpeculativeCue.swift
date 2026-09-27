import Foundation

/// A question can be answered before its turn is finalized. While someone else's turn is still a partial
/// caption, a partial that looks like a question and has stopped changing sends the question check early.
/// When the turn is finalized its words are compared with the ones that were checked, and the check runs
/// again only if they changed.
struct SpeculativeCue {
  /// What to do with a finished turn.
  enum Outcome: Equatable {
    /// No early check covers this turn. Handle it as usual.
    case none
    /// The early check saw the same words. Nothing more to ask.
    case keep
    /// The words changed and are still a question. Ask again and replace the cue.
    case rerun
    /// The turn was the wearer's own, or was not a question after all. Take the early answer back.
    case withdraw
  }

  /// A partial counts once its words have not changed for this long, so a sentence is not checked halfway.
  static let settleMs = 300.0
  /// A partial that only opens like a question needs this many words, so "What" alone is not checked.
  static let minimumWords = 4
  /// A partial that already ends in a question mark needs fewer.
  static let minimumWordsWithMark = 2
  /// How a question put to the wearer usually opens.
  static let openers: [[String]] = [
    ["what"], ["how"], ["where"], ["when"], ["why"], ["who"], ["which"],
    ["are", "you"], ["do", "you"], ["did", "you"], ["have", "you"], ["can", "you"], ["would", "you"],
    ["could", "you"], ["will", "you"], ["were", "you"], ["should", "you"],
  ]
  /// Words that may come before the opener: "So, where do you study".
  static let leadIns: Set<String> = ["so", "and", "but", "well", "hey", "hi", "oh", "ok", "okay", "um", "uh"]
  /// Words whose arrival or loss does not change what was asked.
  static let minorWords: Set<String> = leadIns.union(["er", "like", "please", "now", "then", "right", "just", "actually", "really"])

  /// The turn whose early check is in play, the words it was sent with, and the session's cue generation then.
  private(set) var turn: Int?
  private(set) var text = ""
  private var generation = 0
  private var failed = false
  /// Turns that have had their one early check. Bounded, oldest first.
  private var used: [Int] = []
  private var latest: (turn: Int, text: String, changedAt: Double)?

  /// Lowercase words. Contractions keep their first part, so "what's" opens like "what".
  static func words(_ text: String) -> [String] {
    IndirectPhrases.normalize(text).split(separator:" ").compactMap { word in
      let head = word.split(separator:"'", omittingEmptySubsequences:false).first.map(String.init) ?? ""
      return head.isEmpty ? nil : head
    }
  }

  /// Whether a partial caption already reads as a question put to the wearer.
  static func looksLikeQuestion(_ text: String) -> Bool {
    let all = words(text)
    if ConversationPolicy.endsWithQuestion(text) { return all.count >= minimumWordsWithMark }
    let spoken = Array(all.drop(while: leadIns.contains))
    return all.count >= minimumWords && openers.contains { spoken.starts(with:$0) }
  }

  /// Whether a finished turn is a question. Finished turns are punctuated, so one that ends a sentence
  /// any other way is not, however it opens.
  static func isQuestion(final text: String) -> Bool {
    if ConversationPolicy.endsWithQuestion(text) { return true }
    let closers = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:"\"'\u{201D}\u{2019})]"))
    guard let last = text.trimmingCharacters(in:closers).last, !".!\u{3002}\u{0964}\u{2026}".contains(last) else { return false }
    return looksLikeQuestion(text)
  }

  /// Punctuation, case and filler words are not a change. A different, added or missing word is.
  static func changedMeaningfully(from early: String, to final: String) -> Bool {
    words(early).filter { !minorWords.contains($0) } != words(final).filter { !minorWords.contains($0) }
  }

  /// Notes a partial caption or speaker update of an unfinished turn. Returns how long until its words
  /// have settled, or nil when the turn has no words to wait for or has had its early check.
  /// The same words again, or a label without words, do not restart the wait.
  mutating func heard(turn id: Int, text: String?, at time: Double) -> Double? {
    if let text = text?.trimmingCharacters(in:.whitespacesAndNewlines), !text.isEmpty,
       latest?.turn != id || latest?.text != text { latest = (id, text, time) }
    guard !used.contains(id), let latest, latest.turn == id else { return nil }
    return max(0, latest.changedAt + Self.settleMs - time)
  }

  /// The words to check now and when they were last heard, or nil. They must have settled and look like a
  /// question. The speaker must be labeled and must not be the wearer. The wearer's own label has to be
  /// known first, unless checks do not wait for the wearer to be detected.
  func consider(turn id: Int, speaker: String?, wearerLabel: String?, waitForWearer: Bool = true, at time: Double) -> (text: String, heardAt: Double)? {
    guard !used.contains(id), let latest, latest.turn == id, time - latest.changedAt >= Self.settleMs - 5,
          let speaker, wearerLabel != nil || !waitForWearer, speaker != "wearer", speaker != wearerLabel,
          Self.looksLikeQuestion(latest.text) else { return nil }
    return (latest.text, latest.changedAt)
  }

  /// The early check for a turn was sent. It is the only one that turn gets.
  mutating func sent(turn id: Int, text: String, generation: Int) {
    turn = id; self.text = text; self.generation = generation; failed = false
    used.append(id)
    if used.count > 32 { used.removeFirst(used.count - 32) }
  }

  /// The early check got no answer, so the finished turn is handled as usual.
  mutating func requestFailed() { failed = true }

  /// Decides what a finished turn needs. `generation` differs from the one at sending when the early check
  /// was dropped by other speech or the wearer dismissed its cue, which leaves nothing to keep.
  mutating func finalize(turn id: Int?, text final: String, role: String, generation now: Int) -> Outcome {
    // A finished turn has no partial left to settle.
    if let id, latest?.turn == id { latest = nil }
    guard let id, id == turn else { return .none }
    turn = nil
    guard !failed, generation == now else { return .none }
    guard role == "other" else { return .withdraw }
    guard Self.changedMeaningfully(from:text, to:final) else { return .keep }
    return Self.isQuestion(final:final) ? .rerun : .withdraw
  }
}
