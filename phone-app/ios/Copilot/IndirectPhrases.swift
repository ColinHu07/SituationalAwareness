import Foundation

/// Common phrases that usually mean more than their literal words.
/// When someone else says one, the model is asked to explain the usual meaning of the words.
/// Matching looks at words only. It never reads faces, tone, or emotions.
enum IndirectPhrases {
  /// Lowercase, straight apostrophes, no other punctuation. Add new phrases in the same form.
  static let all: [String] = [
    // Wrapping up
    "it's getting late",
    "i should let you go",
    "i'll let you go",
    "i don't want to keep you",
    "i should get going",
    "nice talking to you",
    "i have an early morning",
    // Friendly, but not a firm plan
    "we should hang out sometime",
    "let's grab coffee sometime",
    "maybe another time",
    "let's play it by ear",
    "we'll see how it goes",
    // A soft no, or not deciding yet
    "i'll think about it",
    "i'll get back to you",
    "let's circle back",
    // Reassurance
    "no worries",
    "don't worry about it",
    // Disagreeing politely
    "if you say so",
    "let's agree to disagree",
    "with all due respect",
    "no offense",
    // Acceptance, or a polite request
    "it is what it is",
    "when you get a chance",
    "would you mind",
  ]

  /// The first listed phrase that appears in `text` as whole words, ignoring case and punctuation.
  static func match(in text: String) -> String? {
    let words = " " + normalize(text) + " "
    return all.first { words.contains(" " + $0 + " ") }
  }

  /// Lowercase words separated by single spaces. Apostrophes are kept so contractions still match.
  static func normalize(_ text: String) -> String {
    let straightened = text.lowercased()
      .replacingOccurrences(of:"\u{2019}", with:"'").replacingOccurrences(of:"\u{2018}", with:"'")
    let kept = straightened.map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
    return String(kept).split(separator:" ").joined(separator:" ")
  }
}
