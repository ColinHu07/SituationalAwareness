import Foundation

/// A confirmed, session-local link between Muse's raw diarization label and a saved profile.
struct SpeakerIdentityContext: Encodable, Equatable {
  let label: String
  let personId: String
  let name: String
}

/// Resolves session-local P1/P2 labels without changing the raw labels kept by ASR state.
/// Face presence can satisfy a presence prerequisite, but never identifies which voice is speaking.
struct SpeakerIdentityResolver {
  private enum BindResult { case bound, unchanged, conflict }

  private(set) var personByLabel: [String: UUID] = [:]
  private(set) var wearerLabel: String?
  private(set) var finalizedTurnCounts: [String: Int] = [:]
  private(set) var conflictingLabels: Set<String> = []

  static func validLabel(_ value: String) -> Bool {
    guard value.hasPrefix("P"), let number = Int(value.dropFirst()), (1...99).contains(number) else { return false }
    return value == "P\(number)"
  }

  func personID(for label: String) -> UUID? { personByLabel[label] }
  func isWearer(_ label: String) -> Bool { label == "wearer" || wearerLabel == label }

  func displayName(for label: String, people: [Person]) -> String {
    if isWearer(label) { return "You" }
    guard let id = personByLabel[label], let person = people.first(where: { $0.id == id }) else { return label }
    return person.name
  }

  /// Only mappings whose supplied profile is present are eligible for a cue request.
  func contexts(people: [Person]) -> [SpeakerIdentityContext] {
    let profiles = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return personByLabel.compactMap { label, id in
      guard let person = profiles[id] else { return nil }
      return SpeakerIdentityContext(label:label, personId:id.uuidString, name:String(person.name.prefix(60)))
    }.sorted { lhs, rhs in
      (Int(lhs.label.dropFirst()) ?? 0) < (Int(rhs.label.dropFirst()) ?? 0)
    }
  }

  /// Records one finalized diarized turn and applies only narrow self-identification or
  /// the wearer-known, single-person, two-turn fusion rule.
  @discardableResult
  mutating func observeFinalTurn(label: String?, text: String, people: [Person], presentPersonIDs: Set<UUID>) -> Bool {
    guard let label, Self.validLabel(label) else { return false }
    finalizedTurnCounts[label, default:0] += 1
    var changed = false
    if let claim = Self.selfIdentifiedName(in:text) {
      let matches = Self.people(named:claim, in:people)
      guard matches.count == 1, let person = matches.first, presentPersonIDs.contains(person.id) else {
        conflictingLabels.insert(label)
        return false
      }
      switch bind(label:label, to:person.id) {
      case .bound: changed = true
      case .unchanged: break
      case .conflict: conflictingLabels.insert(label)
      }
    }
    return resolveUniquePerson(people:people, presentPersonIDs:presentPersonIDs) || changed
  }

  /// An explicit "That was me" action can distinguish one diarization label as the wearer.
  @discardableResult
  mutating func markWearer(label: String, people: [Person], presentPersonIDs: Set<UUID>) -> Bool {
    guard Self.validLabel(label) else { return false }
    var changed = false
    if personByLabel[label] != nil || (wearerLabel != nil && wearerLabel != label) {
      conflictingLabels.insert(label)
      return false
    }
    if wearerLabel == nil { wearerLabel = label; changed = true }
    return resolveUniquePerson(people:people, presentPersonIDs:presentPersonIDs) || changed
  }

  /// Realtime reconnects may reuse P labels for different voices.
  mutating func resetLabelMappings() {
    personByLabel = [:]
    wearerLabel = nil
    finalizedTurnCounts = [:]
    conflictingLabels = []
  }

  /// Kept separate to make the conversation-end lifecycle explicit if session state grows later.
  mutating func resetSession() { resetLabelMappings() }

  /// Exposed within the app so the standalone caption screen can confirm an existing
  /// profile's presence from the same narrow self-introduction before resolving it.
  static func selfIdentifiedPerson(in text: String, people: [Person]) -> Person? {
    guard let name = selfIdentifiedName(in:text) else { return nil }
    let matches = Self.people(named:name, in:people)
    return matches.count == 1 ? matches[0] : nil
  }

  private mutating func resolveUniquePerson(people: [Person], presentPersonIDs: Set<UUID>) -> Bool {
    guard let wearerLabel else { return false }
    let nonWearerLabels = finalizedTurnCounts.keys.filter { $0 != wearerLabel }
    guard nonWearerLabels.count == 1, let label = nonWearerLabels.first,
          finalizedTurnCounts[label, default:0] >= 2, !conflictingLabels.contains(label) else { return false }
    let present = people.filter { presentPersonIDs.contains($0.id) }
    guard present.count == 1, let person = present.first else { return false }
    switch bind(label:label, to:person.id) {
    case .bound: return true
    case .unchanged: return false
    case .conflict: conflictingLabels.insert(label); return false
    }
  }

  private mutating func bind(label: String, to personID: UUID) -> BindResult {
    if let existing = personByLabel[label] { return existing == personID ? .unchanged : .conflict }
    if wearerLabel == label || personByLabel.contains(where: { $0.key != label && $0.value == personID }) { return .conflict }
    personByLabel[label] = personID
    return .bound
  }

  private static func people(named claimedName: String, in people: [Person]) -> [Person] {
    let claim = normalizedName(claimedName)
    let parts = claim.split(separator:" ")
    return people.filter { person in
      let full = normalizedName(person.name)
      if parts.count > 1 { return full.caseInsensitiveCompare(claim) == .orderedSame }
      let first = full.split(separator:" ").first.map(String.init) ?? full
      return full.caseInsensitiveCompare(claim) == .orderedSame || first.caseInsensitiveCompare(claim) == .orderedSame
    }
  }

  private static func normalizedName(_ value: String) -> String {
    value.split(whereSeparator:\.isWhitespace).joined(separator:" ")
  }

  /// Deliberately narrow: an explicit first-person name statement with one optional surname.
  private static func selfIdentifiedName(in text: String) -> String? {
    let name = #"(\p{Lu}[\p{L}'’-]{1,30}(?:\s+\p{Lu}[\p{L}'’-]{1,30})?)"#
    let patterns = [
      #"(?i:(?:^|[.!?]\s+)(?:(?:hi|hey|hello)[,!]?\s+)?my name(?: is|['’]s)\s+)"# + name + #"(?=\s*[,.!?]?\s*$)"#,
      #"(?i:(?:^|[.!?]\s+)(?:(?:hi|hey|hello)[,!]?\s+)?(?:i['’]m|i am)\s+)"# + name + #"(?=\s*[,.!?]?\s*$)"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern:pattern),
            let match = regex.firstMatch(in:text, range:NSRange(text.startIndex..., in:text)),
            let range = Range(match.range(at:1), in:text) else { continue }
      return normalizedName(String(text[range]))
    }
    return nil
  }
}
