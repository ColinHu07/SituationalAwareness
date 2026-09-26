import XCTest
@testable import Copilot

@MainActor
final class PeopleTests: XCTestCase {
  private func activeModel(_ store: PeopleStore) async throws -> SessionModel {
    let model = SessionModel(people:store)
    model.simulate = true; model.localMock = true
    model.start()
    try await Task.sleep(for:.milliseconds(100))
    XCTAssertEqual(model.phase,.active)
    return model
  }

  func testStopProposesProfileUpdatesThatSaveOnlyWhenApproved() async throws {
    let store = PeopleStore(fileURL:nil)
    let team = try XCTUnwrap(store.addGroup("Football team"))
    let jake = try XCTUnwrap(store.addPerson("Jake"))
    store.people[0].groupIDs = [team]
    let model = try await activeModel(store)
    model.addSimulationLine("Jake, how did the tryout go?") // naming Jake puts him in Who's here
    XCTAssertEqual(model.presentIDs, [jake])
    model.addSimulationLine("I love fantasy football")
    model.stop()
    try await Task.sleep(for:.milliseconds(100))
    var review = try XCTUnwrap(model.learnReview)
    XCTAssertTrue(review.items.contains { $0.field == .fact && $0.value == "Jake, how did the tryout go?" })
    XCTAssertTrue(review.items.contains { $0.target == .group("Football team") && $0.value == "fantasy football" })
    XCTAssertTrue(store.people[0].notes.isEmpty, "Nothing is saved before review")
    XCTAssertNotNil(store.people[0].lastSeen)
    // Declined items are not saved.
    for index in review.items.indices where review.items[index].field == .fact { review.items[index].include = false }
    store.apply(review.items)
    XCTAssertTrue(store.people[0].notes.isEmpty)
    XCTAssertEqual(store.people[0].topics, ["fantasy football"])
    XCTAssertEqual(store.groups[0].topics, ["fantasy football"])
  }

  func testNoPeopleMeansNoLearningAndSessionLogClearsOnStop() async throws {
    let store = PeopleStore(fileURL:nil)
    let model = try await activeModel(store)
    model.addSimulationLine("I love chess")
    XCTAssertEqual(model.sessionLog.count, 1)
    model.stop()
    try await Task.sleep(for:.milliseconds(100))
    XCTAssertNil(model.learnReview)
    XCTAssertTrue(model.sessionLog.isEmpty)
  }

  func testPresentPeopleShapeCuesAndSuggestedGroupsAreCreated() async throws {
    let store = PeopleStore(fileURL:nil)
    let sam = try XCTUnwrap(store.addPerson("Sam"))
    store.people[0].topics = ["Warhammer"]
    store.apply([LearnItem(target:.person(sam), field:.group, value:"Nerd crew"), LearnItem(target:.person(sam), field:.tag, value:"Board Games")])
    XCTAssertEqual(store.groupNames(for:store.people[0]), ["Nerd crew"])
    XCTAssertEqual(store.people[0].tags, ["board games"])
    XCTAssertEqual(store.context(for:store.people[0]).groups, ["Nerd crew"])
    let model = try await activeModel(store)
    model.addSimulationLine("Sam, so what's new?")
    try await Task.sleep(for:.milliseconds(1600))
    model.requestCue(manual:true)
    try await Task.sleep(for:.milliseconds(700))
    XCTAssertEqual(model.cue, "Ask Sam about Warhammer.")
  }

  func testProfilesPersistToDisk() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at:url) }
    let store = PeopleStore(fileURL:url)
    store.addPerson("Ava"); store.addGroup("Robotics club")
    let reloaded = PeopleStore(fileURL:url)
    XCTAssertEqual(reloaded.people.map(\.name), ["Ava"])
    XCTAssertEqual(reloaded.groups.map(\.name), ["Robotics club"])
  }

  func testWordsPerMinuteNeedsEnoughSpeech() {
    let words = Array(repeating:"word", count:30).joined(separator:" ")
    XCTAssertEqual(SessionModel.wordsPerMinute([TranscriptEntry(text:words, startMs:0, endMs:10000, confidence:nil)]), 180)
    XCTAssertNil(SessionModel.wordsPerMinute([TranscriptEntry(text:"hi there", startMs:0, endMs:10000, confidence:nil)]))
  }
}
