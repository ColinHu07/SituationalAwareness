import Foundation

/// A confirmed, session-local link between Muse's raw diarization label and a saved profile.
struct SpeakerIdentityContext: Encodable, Equatable {
  let label: String
  let personId: String
  let name: String
}

/// Resolves session-local P1/P2 labels without changing the raw labels kept by ASR state.
/// Combines evidence from explicit self-introduction, direct-address + adjacent reply, and
/// conservative single-partner fusion. Face presence is supporting evidence only, never sole identification.
struct SpeakerIdentityResolver {
  struct Evidence: Equatable {
    var selfIntroduced: Bool = false
    var directAddressCount: Int = 0
    var singlePartner: Bool = false

    var strength: Int {
      if selfIntroduced { return 100 }
      if directAddressCount > 0 { return 10 + directAddressCount * 5 }
      if singlePartner { return 5 }
      return 0
    }

    var isResolved: Bool { strength > 0 }
  }

  struct RecentTurn: Equatable {
    let label: String
    let text: String
    let endMs: Double
  }

  private enum BindResult { case bound, unchanged, conflict }

  private(set) var personByLabel: [String: UUID] = [:]
  private(set) var evidenceByLabel: [String: Evidence] = [:]
  private(set) var wearerLabel: String?
  private(set) var finalizedTurnCounts: [String: Int] = [:]
  private(set) var conflictingLabels: Set<String> = []
  private(set) var recentTurns: [RecentTurn] = []

  static func validLabel(_ value: String) -> Bool {
    guard value.hasPrefix("P"), let number = Int(value.dropFirst()), (1...99).contains(number) else { return false }
    return value == "P\(number)"
  }

  func personID(for label: String) -> UUID? { personByLabel[label] }
  func label(for personID: UUID) -> String? { personByLabel.first(where: { $0.value == personID })?.key }
  func isWearer(_ label: String) -> Bool { label == "wearer" || wearerLabel == label }

  func displayName(for label: String, people: [Person]) -> String {
    if isWearer(label) { return "You" }
    guard let id = personByLabel[label], let person = people.first(where: { $0.id == id }) else { return label }
    return person.name
  }

  func evidence(for label: String) -> Evidence? { evidenceByLabel[label] }

  func confidence(for label: String) -> String {
    guard let ev = evidenceByLabel[label] else { return "unresolved" }
    if ev.selfIntroduced { return "very_strong" }
    if ev.directAddressCount > 1 { return "strong_repeated" }
    if ev.directAddressCount == 1 { return "strong" }
    if ev.singlePartner { return "moderate" }
    return "unresolved"
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

  /// Records one finalized diarized turn and updates the evidence-fusion state.
  @discardableResult
  mutating func observeFinalTurn(
    label: String?,
    text: String,
    endMs: Double = 0,
    people: [Person],
    presentPersonIDs: Set<UUID>,
    hasCompetingUnknownPerson: Bool = false
  ) -> Bool {
    guard let label, Self.validLabel(label) else { return false }
    let trimmed = text.trimmingCharacters(in:.whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    finalizedTurnCounts[label, default:0] += 1
    var changed = false

    // A. Explicit self-identification (Very strong)
    var selfIdentified = false
    if let matches = Self.selfIdentifiedPeople(in:trimmed, people:people) {
      if matches.count == 1, let person = matches.first {
        switch bind(label:label, to:person.id, evidence:Evidence(selfIntroduced:true)) {
        case .bound: changed = true; selfIdentified = true
        case .unchanged: selfIdentified = true
        case .conflict: conflictingLabels.insert(label)
        }
      } else {
        conflictingLabels.insert(label)
      }
    }

    // B. Direct address + immediate response (Strong)
    if !selfIdentified, let prev = recentTurns.last, prev.label != label, !isWearer(label) {
      let timeDiff = (endMs > 0 && prev.endMs > 0) ? (endMs - prev.endMs) : 0
      let withinWindow = timeDiff >= 0 && timeDiff <= 8000
      if withinWindow {
        let addressedNames = PresenceTracker.addressedNames(in:prev.text)
        let presentPeople = people.filter { presentPersonIDs.contains($0.id) }
        var addressedPeople: [Person] = []
        for name in addressedNames {
          for person in Self.people(named:name, in:presentPeople) where !addressedPeople.contains(where: { $0.id == person.id }) {
            addressedPeople.append(person)
          }
        }
        if addressedPeople.count == 1, let target = addressedPeople.first, target.id != personByLabel[prev.label] {
          let currentEv = evidenceByLabel[label] ?? Evidence()
          let newEv = Evidence(
            selfIntroduced:currentEv.selfIntroduced,
            directAddressCount:currentEv.directAddressCount + 1,
            singlePartner:currentEv.singlePartner
          )
          switch bind(label:label, to:target.id, evidence:newEv) {
          case .bound: changed = true
          case .unchanged: break
          case .conflict: conflictingLabels.insert(label)
          }
        }
      }
    }

    // Record turn in bounded history
    recentTurns.append(RecentTurn(label:label, text:trimmed, endMs:endMs))
    if recentTurns.count > 12 { recentTurns.removeFirst(recentTurns.count - 12) }

    // C. Single-partner fusion (Moderate)
    if resolveUniquePerson(people:people, presentPersonIDs:presentPersonIDs, hasCompetingUnknownPerson:hasCompetingUnknownPerson) {
      changed = true
    }

    return changed
  }

  /// An explicit "That was me" action can distinguish one diarization label as the wearer.
  @discardableResult
  mutating func markWearer(
    label: String,
    people: [Person],
    presentPersonIDs: Set<UUID>,
    hasCompetingUnknownPerson: Bool = false
  ) -> Bool {
    guard Self.validLabel(label) else { return false }
    var changed = false
    if personByLabel[label] != nil || (wearerLabel != nil && wearerLabel != label) {
      conflictingLabels.insert(label)
      return false
    }
    if wearerLabel == nil { wearerLabel = label; changed = true }
    return resolveUniquePerson(people:people, presentPersonIDs:presentPersonIDs, hasCompetingUnknownPerson:hasCompetingUnknownPerson) || changed
  }

  /// Invalidate an active mapping when a person is dismissed / marked "Not here".
  @discardableResult
  mutating func invalidate(personID: UUID) -> Bool {
    var removed = false
    for (label, id) in personByLabel where id == personID {
      personByLabel.removeValue(forKey:label)
      evidenceByLabel.removeValue(forKey:label)
      removed = true
    }
    return removed
  }

  /// Invalidate an active mapping for a specific label.
  @discardableResult
  mutating func invalidate(label: String) -> Bool {
    guard personByLabel[label] != nil else { return false }
    personByLabel.removeValue(forKey:label)
    evidenceByLabel.removeValue(forKey:label)
    return true
  }

  /// Realtime reconnects may reuse P labels for different voices.
  mutating func resetLabelMappings() {
    personByLabel = [:]
    evidenceByLabel = [:]
    wearerLabel = nil
    finalizedTurnCounts = [:]
    conflictingLabels = []
    recentTurns = []
  }

  /// Kept separate to make the conversation-end lifecycle explicit if session state grows later.
  mutating func resetSession() { resetLabelMappings() }

  /// Exposed within the app so the same narrow self-introduction can also update presence.
  static func selfIdentifiedPerson(in text: String, people: [Person]) -> Person? {
    guard let matches = selfIdentifiedPeople(in:text, people:people) else { return nil }
    return matches.count == 1 ? matches[0] : nil
  }

  private mutating func resolveUniquePerson(
    people: [Person],
    presentPersonIDs: Set<UUID>,
    hasCompetingUnknownPerson: Bool
  ) -> Bool {
    guard let wearerLabel else { return false }
    guard !hasCompetingUnknownPerson else { return false }
    let nonWearerLabels = finalizedTurnCounts.keys.filter { $0 != wearerLabel }
    guard nonWearerLabels.count == 1, let label = nonWearerLabels.first,
          finalizedTurnCounts[label, default:0] >= 2, !conflictingLabels.contains(label) else { return false }
    let present = people.filter { presentPersonIDs.contains($0.id) }
    guard present.count == 1, let person = present.first else { return false }
    switch bind(label:label, to:person.id, evidence:Evidence(singlePartner:true)) {
    case .bound: return true
    case .unchanged: return false
    case .conflict: conflictingLabels.insert(label); return false
    }
  }

  private mutating func bind(label: String, to personID: UUID, evidence: Evidence) -> BindResult {
    if wearerLabel == label { return .conflict }

    // Case 1: Label already mapped to this person
    if let existing = personByLabel[label], existing == personID {
      var current = evidenceByLabel[label] ?? Evidence()
      current.selfIntroduced = current.selfIntroduced || evidence.selfIntroduced
      current.directAddressCount = max(current.directAddressCount, evidence.directAddressCount)
      current.singlePartner = current.singlePartner || evidence.singlePartner
      evidenceByLabel[label] = current
      return .unchanged
    }

    // Check if this label is already mapped to a different person
    if let existing = personByLabel[label], existing != personID {
      let existingStrength = evidenceByLabel[label]?.strength ?? 0
      guard evidence.strength > existingStrength else { return .conflict }
    }

    // Check if another label is already mapped to this person
    if let otherLabel = personByLabel.first(where: { $0.key != label && $0.value == personID })?.key {
      let otherStrength = evidenceByLabel[otherLabel]?.strength ?? 0
      guard evidence.strength > otherStrength else { return .conflict }
      personByLabel.removeValue(forKey: otherLabel)
      evidenceByLabel.removeValue(forKey: otherLabel)
    }

    personByLabel[label] = personID
    evidenceByLabel[label] = evidence
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

  /// Prefer exact aliases from supplied profiles so explicit introductions still work when
  /// ASR lowercases a name or includes a natural continuation after it.
  private static func selfIdentifiedPeople(in text: String, people: [Person]) -> [Person]? {
    let aliases = Set(people.flatMap { person -> [String] in
      let full = normalizedName(person.name)
      let first = full.split(separator:" ").first.map(String.init) ?? full
      return [full, first].filter { $0.count >= 2 }
    }).sorted { lhs, rhs in
      lhs.count == rhs.count ? lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending : lhs.count > rhs.count
    }
    let greeting = #"(?:(?:hi|hey|hello)(?:[,!]?\s+(?:everyone|everybody|all|there))?[,!]?\s+|(?:well|so|um|uh|actually|no|sorry)[,!]?\s+)?"#
    let intro = #"(?:my name(?: is|['’]s)|i['’]m|i am)\s+"#
    let lead = #"(?:^|[.!?]\s+)"# + greeting + intro
    let tail = #"(?=\s*(?:$|[,.;!?]|\b(?:and|from|nice|pleased|good|glad|here)\b))"#
    for alias in aliases {
      let escaped = NSRegularExpression.escapedPattern(for:alias)
      guard let regex = try? NSRegularExpression(pattern:lead + escaped + tail, options:[.caseInsensitive]),
            regex.firstMatch(in:text, range:NSRange(text.startIndex..., in:text)) != nil else { continue }
      return Self.people(named:alias, in:people)
    }
    guard let claim = selfIdentifiedName(in:text) else { return nil }
    return Self.people(named:claim, in:people)
  }

  /// Deliberately narrow: an explicit first-person name statement with one optional surname.
  private static func selfIdentifiedName(in text: String) -> String? {
    let name = #"([\p{L}'’-]{1,30}(?:\s+[\p{L}'’-]{1,30})?)"#
    let ending = #"(?=\s*(?:$|[,.;!?]|\b(?:and|from|nice|pleased|good|glad|here)\b))"#
    let greeting = #"(?:(?:hi|hey|hello)(?:[,!]?\s+(?:everyone|everybody|all|there))?[,!]?\s+|(?:well|so|um|uh|actually|no|sorry)[,!]?\s+)?"#
    let patterns = [
      #"(?:^|[.!?]\s+)"# + greeting + #"my name(?: is|['’]s)\s+"# + name + ending,
      #"(?:^|[.!?]\s+)"# + greeting + #"(?:i['’]m|i am)\s+"# + name + ending,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern:pattern, options:[.caseInsensitive]),
            let match = regex.firstMatch(in:text, range:NSRange(text.startIndex..., in:text)),
            let range = Range(match.range(at:1), in:text) else { continue }
      return normalizedName(String(text[range]))
    }
    return nil
  }
}
