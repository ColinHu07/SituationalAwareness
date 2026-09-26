import Foundation
import Observation

struct Person: Codable, Identifiable, Hashable {
  var id = UUID()
  var name: String
  var groupIDs: [UUID] = []
  var tags: [String] = []
  var topics: [String] = []
  var notes: [String] = []
  var lastSeen: Date?
  /// Enrolled face samples for on-device recognition. Empty means never recognized by face.
  var faces: [FaceSample] = []
}
extension Person {
  // Profiles saved before a field existed still load.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    id = try c.decode(UUID.self, forKey:.id)
    name = try c.decode(String.self, forKey:.name)
    groupIDs = try c.decodeIfPresent([UUID].self, forKey:.groupIDs) ?? []
    tags = try c.decodeIfPresent([String].self, forKey:.tags) ?? []
    topics = try c.decodeIfPresent([String].self, forKey:.topics) ?? []
    notes = try c.decodeIfPresent([String].self, forKey:.notes) ?? []
    lastSeen = try c.decodeIfPresent(Date.self, forKey:.lastSeen)
    faces = try c.decodeIfPresent([FaceSample].self, forKey:.faces) ?? []
  }
}

struct PeopleGroup: Codable, Identifiable, Hashable {
  var id = UUID()
  var name: String
  var topics: [String] = []
  var slang: [String] = []
  var style = ""
  var notes: [String] = []
}

// Wire formats for /api/cue and /api/learn.
struct PersonContext: Encodable {
  var id: String?
  let name: String
  let groups: [String]
  let tags: [String]
  let topics: [String]
  let notes: [String]
}
struct GroupContext: Encodable { let name: String; let topics: [String]; let slang: [String]; let style: String; let notes: [String] }
struct LearnRequest: Encodable {
  let transcript: [TranscriptEntry]
  let people: [PersonContext]
  let groups: [GroupContext]
  let otherGroupNames: [String]
  let wordsPerMinute: Double?
}
struct LearnResult: Decodable {
  struct PersonUpdate: Decodable { let id: String; let facts: [String]; let topics: [String]; let tags: [String]; let groups: [String] }
  struct GroupUpdate: Decodable { let name: String; let topics: [String]; let slang: [String]; let style: String }
  let people: [PersonUpdate]
  let groups: [GroupUpdate]
}
struct LearnResponse: Decodable { let result: LearnResult }

// One proposed profile change; the wearer approves each before it is saved.
struct LearnItem: Identifiable {
  enum Target: Hashable { case person(UUID), group(String) }
  enum Field { case fact, topic, tag, group, slang, style, face }
  let id = UUID()
  let target: Target
  let field: Field
  let value: String
  var face: FaceSample? = nil
  var include = true
  var icon: String {
    switch field {
    case .face: "faceid"
    case .fact: "note.text"
    case .topic: "bubble.left"
    case .tag: "tag"
    case .group: "person.3"
    case .slang: "character.bubble"
    case .style: "waveform"
    }
  }
}
struct LearnReview: Identifiable { let id = UUID(); var items: [LearnItem] }

@Observable @MainActor
final class PeopleStore {
  var people: [Person] = [] { didSet { save() } }
  var groups: [PeopleGroup] = [] { didSet { save() } }
  @ObservationIgnored private let fileURL: URL?
  @ObservationIgnored private var loading = false

  nonisolated static var defaultURL: URL? {
    try? FileManager.default.url(for:.applicationSupportDirectory, in:.userDomainMask, appropriateFor:nil, create:true)
      .appendingPathComponent("people.json")
  }
  /// A nil URL keeps profiles in memory only (tests).
  init(fileURL: URL?) {
    self.fileURL = fileURL
    load()
  }
  convenience init() { self.init(fileURL:Self.defaultURL) }
  private struct Snapshot: Codable { var people: [Person]; var groups: [PeopleGroup] }
  private func load() {
    guard let fileURL, let data = try? Data(contentsOf:fileURL),
          let snapshot = try? JSONDecoder().decode(Snapshot.self, from:data) else { return }
    loading = true; people = snapshot.people; groups = snapshot.groups; loading = false
  }
  private func save() {
    guard !loading, let fileURL, let data = try? JSONEncoder().encode(Snapshot(people:people, groups:groups)) else { return }
    try? data.write(to:fileURL, options:[.atomic, .completeFileProtection])
  }

  @discardableResult func addPerson(_ name: String) -> UUID? {
    let name = name.trimmingCharacters(in:.whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    let person = Person(name:name); people.append(person); return person.id
  }
  @discardableResult func addGroup(_ name: String) -> UUID? {
    let name = name.trimmingCharacters(in:.whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    if let existing = group(named:name) { return existing.id }
    let group = PeopleGroup(name:name); groups.append(group); return group.id
  }
  func deleteGroup(_ id: UUID) {
    groups.removeAll { $0.id == id }
    for index in people.indices { people[index].groupIDs.removeAll { $0 == id } }
  }
  func group(named name: String) -> PeopleGroup? {
    groups.first { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in:.whitespaces)) == .orderedSame }
  }
  func members(of groupID: UUID) -> [Person] { people.filter { $0.groupIDs.contains(groupID) } }
  func groupNames(for person: Person) -> [String] {
    person.groupIDs.compactMap { id in groups.first { $0.id == id }?.name }
  }
  func addFace(_ sample: FaceSample, to id: UUID) {
    guard let index = people.firstIndex(where: { $0.id == id }) else { return }
    people[index].faces = FaceRecognizer.trimmed(people[index].faces + [sample])
  }
  func markSeen(_ ids: Set<UUID>) {
    let now = Date()
    for index in people.indices where ids.contains(people[index].id) { people[index].lastSeen = now }
  }

  func context(for person: Person, includeID: Bool = false) -> PersonContext {
    PersonContext(id:includeID ? person.id.uuidString : nil, name:String(person.name.prefix(60)),
                  groups:Array(groupNames(for:person).prefix(8)).map { String($0.prefix(40)) },
                  tags:Array(person.tags.prefix(12)).map { String($0.prefix(40)) },
                  topics:Array(person.topics.suffix(20)).map { String($0.prefix(80)) },
                  notes:Array(person.notes.suffix(40)).map { String($0.prefix(160)) })
  }
  func context(for group: PeopleGroup) -> GroupContext {
    GroupContext(name:String(group.name.prefix(40)), topics:Array(group.topics.suffix(20)).map { String($0.prefix(80)) },
                 slang:Array(group.slang.suffix(20)).map { String($0.prefix(80)) }, style:String(group.style.prefix(200)),
                 notes:Array(group.notes.suffix(20)).map { String($0.prefix(160)) })
  }
  /// Groups that any of these people belong to, most shared first.
  func groups(of present: [Person]) -> [PeopleGroup] {
    let counts = Dictionary(present.flatMap(\.groupIDs).map { ($0, 1) }, uniquingKeysWith:+)
    return groups.filter { counts[$0.id] != nil }.sorted { counts[$0.id]! > counts[$1.id]! }
  }

  func reviewItems(for result: LearnResult) -> [LearnItem] {
    var items: [LearnItem] = []
    for update in result.people {
      guard let person = people.first(where: { $0.id.uuidString == update.id }) else { continue }
      let target = LearnItem.Target.person(person.id)
      items += Self.fresh(update.facts, existing:person.notes).map { LearnItem(target:target, field:.fact, value:$0) }
      items += Self.fresh(update.topics, existing:person.topics).map { LearnItem(target:target, field:.topic, value:$0) }
      items += Self.fresh(update.tags, existing:person.tags).map { LearnItem(target:target, field:.tag, value:$0) }
      items += Self.fresh(update.groups, existing:groupNames(for:person)).map { LearnItem(target:target, field:.group, value:$0) }
    }
    for update in result.groups {
      let existing = group(named:update.name)
      let target = LearnItem.Target.group(existing?.name ?? update.name)
      items += Self.fresh(update.topics, existing:existing?.topics ?? []).map { LearnItem(target:target, field:.topic, value:$0) }
      items += Self.fresh(update.slang, existing:existing?.slang ?? []).map { LearnItem(target:target, field:.slang, value:$0) }
      let style = update.style.trimmingCharacters(in:.whitespacesAndNewlines)
      if !style.isEmpty, style != existing?.style { items.append(LearnItem(target:target, field:.style, value:style)) }
    }
    return items
  }
  func apply(_ items: [LearnItem]) {
    for item in items where item.include {
      switch item.target {
      case .person(let id):
        guard let index = people.firstIndex(where: { $0.id == id }) else { continue }
        switch item.field {
        case .face:
          if let face = item.face { people[index].faces = FaceRecognizer.trimmed(people[index].faces + [face]) }
        case .fact, .slang, .style: people[index].notes = Self.merged(people[index].notes, item.value, cap:40)
        case .topic: people[index].topics = Self.merged(people[index].topics, item.value, cap:20)
        case .tag: people[index].tags = Self.merged(people[index].tags, item.value.lowercased(), cap:12)
        case .group:
          if let groupID = addGroup(item.value), !people[index].groupIDs.contains(groupID) { people[index].groupIDs.append(groupID) }
        }
      case .group(let name):
        guard let groupID = addGroup(name), let index = groups.firstIndex(where: { $0.id == groupID }) else { continue }
        switch item.field {
        case .topic: groups[index].topics = Self.merged(groups[index].topics, item.value, cap:20)
        case .slang: groups[index].slang = Self.merged(groups[index].slang, item.value, cap:20)
        case .style: groups[index].style = item.value
        case .face: break
        case .fact, .tag, .group: groups[index].notes = Self.merged(groups[index].notes, item.value, cap:20)
        }
      }
    }
  }
  func label(for target: LearnItem.Target) -> String {
    switch target {
    case .person(let id): people.first { $0.id == id }?.name ?? "Unknown"
    case .group(let name): name
    }
  }

  static func fresh(_ values: [String], existing: [String]) -> [String] {
    var seen = Set(existing.map { $0.lowercased() })
    return values.map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
  }
  static func merged(_ list: [String], _ value: String, cap: Int) -> [String] {
    guard !list.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return list }
    return Array((list + [value]).suffix(cap))
  }

  /// Local fixture learner for the offline simulated demo; mirrors server mockLearn.
  static func mockLearn(_ request: LearnRequest) -> LearnResult {
    let lines = request.transcript.map { $0.text.trimmingCharacters(in:.whitespaces) }
    let pattern = try! NSRegularExpression(pattern:#"\b(?:i love|i like|i'm into|we love|my favorite \w+ is)\s+([^.,!?]{2,40})"#, options:.caseInsensitive)
    var topics: [String] = []
    for line in lines {
      for match in pattern.matches(in:line, range:NSRange(line.startIndex..., in:line)) {
        if let range = Range(match.range(at:1), in:line) { topics.append(line[range].trimmingCharacters(in:.whitespaces).lowercased()) }
      }
    }
    topics = Array(fresh(topics, existing:[]).prefix(5))
    let people = request.people.map { person in
      let first = person.name.split(separator:" ").first.map(String.init) ?? person.name
      let facts = lines.filter { line in
        line.count <= 160 && line.range(of:"\\b\(NSRegularExpression.escapedPattern(for:first))\\b", options:[.regularExpression, .caseInsensitive]) != nil
      }
      return LearnResult.PersonUpdate(id:person.id ?? "", facts:Array(facts.prefix(3)), topics:request.people.count == 1 ? topics : [], tags:[], groups:[])
    }
    let sets = request.people.map { Set($0.groups) }
    let shared = sets.dropFirst().reduce(sets.first ?? []) { $0.intersection($1) }
    let pace = request.wordsPerMinute.map { "\($0 > 170 ? "Fast" : $0 < 110 ? "Slow" : "Moderate") pace, about \(Int($0)) words per minute." } ?? ""
    let groups = request.groups.first { shared.contains($0.name) }.map { [LearnResult.GroupUpdate(name:$0.name, topics:topics, slang:[], style:pace)] } ?? []
    return LearnResult(people:people, groups:groups)
  }
}
