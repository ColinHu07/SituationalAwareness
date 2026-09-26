import XCTest
import UIKit
@testable import Copilot

@MainActor
final class PresenceTests: XCTestCase {
  private func activeModel(_ store: PeopleStore) async throws -> SessionModel {
    let model = SessionModel(people:store)
    model.simulate = true; model.localMock = true
    model.start()
    try await Task.sleep(for:.milliseconds(100))
    XCTAssertEqual(model.phase,.active)
    return model
  }

  func testFaceNeedsTwoHitsInWindowAndNameAddsRightAway() {
    let sam = UUID(), ava = UUID()
    var tracker = PresenceTracker()
    XCTAssertEqual(tracker.recordFaces([sam], at:0), [])
    XCTAssertEqual(tracker.recordFaces([sam], at:11_000), [], "Hits 11 s apart are not two hits in 10 s")
    XCTAssertEqual(tracker.recordFaces([sam], at:15_000), [sam])
    XCTAssertEqual(tracker.sources[sam], [.face])
    XCTAssertEqual(tracker.recordNames([ava], at:20_000), [ava])
    XCTAssertEqual(tracker.sources[ava], [.name])
  }

  func testOneFacePlusRecentNameCountsAsSeen() {
    let sam = UUID()
    var tracker = PresenceTracker()
    _ = tracker.recordFaces([sam], at:0)
    XCTAssertEqual(tracker.recordNames([sam], at:25_000), [sam])
    XCTAssertEqual(tracker.sources[sam], [.name, .face])
  }

  func testPeopleDropOffWithoutEvidence() {
    let seen = UUID(), named = UUID()
    var tracker = PresenceTracker()
    _ = tracker.recordFaces([seen], at:0); _ = tracker.recordFaces([seen], at:1_000)
    _ = tracker.recordNames([named], at:1_000)
    XCTAssertEqual(tracker.expire(at:100_000), [])
    XCTAssertEqual(tracker.expire(at:122_000), [named], "Only named, never seen: gone after 2 minutes")
    _ = tracker.recordNames([seen], at:200_000) // mentioned again keeps them
    XCTAssertEqual(tracker.expire(at:450_000), [])
    XCTAssertEqual(tracker.expire(at:501_000), [seen], "Seen: gone after 5 minutes without evidence")
    XCTAssertTrue(tracker.confirmed.isEmpty)
    XCTAssertEqual(tracker.everConfirmed, [seen, named], "Still counted as part of this conversation")
  }

  func testNotHereStaysOutUntilIntroduced() {
    let sam = UUID()
    var tracker = PresenceTracker()
    _ = tracker.recordNames([sam], at:0)
    tracker.dismiss(sam)
    XCTAssertEqual(tracker.recordNames([sam], at:1_000), [])
    _ = tracker.recordFaces([sam], at:2_000)
    XCTAssertEqual(tracker.recordFaces([sam], at:3_000), [])
    tracker.introduce(sam, at:4_000)
    XCTAssertTrue(tracker.confirmed.contains(sam))
  }

  func testNameMatchingUsesWholeFirstOrFullName() {
    let store = PeopleStore(fileURL:nil)
    let sam = store.addPerson("Sam Lee")!, al = store.addPerson("Al")!
    XCTAssertEqual(PresenceTracker.mentionedPeople(in:"Hey Sam, over here", people:store.people), [sam])
    XCTAssertEqual(PresenceTracker.mentionedPeople(in:"hey sam, over here", people:store.people), [], "Names must be capitalized")
    XCTAssertEqual(PresenceTracker.mentionedPeople(in:"Samantha said so", people:store.people), [])
    XCTAssertEqual(PresenceTracker.mentionedPeople(in:"That's also true, Al.", people:store.people), [al])
  }

  func testSessionUpdatesWhosHereAutomaticallyAndStopClearsIt() async throws {
    let store = PeopleStore(fileURL:nil)
    let sam = store.addPerson("Sam")!, jo = store.addPerson("Jo")!
    let model = try await activeModel(store)
    model.addSimulationLine("Jo, did you finish the lab?")
    XCTAssertEqual(model.presentIDs, [jo], "Hearing a name adds them")
    XCTAssertEqual(model.presenceIcon(for:jo), "person.wave.2")
    let t = nowMs()
    model.applyFaceMatches([sam], at:t); model.applyFaceMatches([sam], at:t + 1000)
    XCTAssertTrue(model.presentIDs.contains(sam))
    XCTAssertEqual(model.presenceIcon(for:sam), "faceid")
    model.markNotHere(sam) // correcting a wrong match
    model.applyFaceMatches([sam], at:t + 2000); model.applyFaceMatches([sam], at:t + 3000)
    XCTAssertFalse(model.presentIDs.contains(sam))
    model.expirePresence(at:t + 200_000)
    XCTAssertFalse(model.presentIDs.contains(jo), "Named only, not mentioned again: drops off")
    model.stop()
    XCTAssertTrue(model.presentIDs.isEmpty)
    XCTAssertTrue(model.presence.confirmed.isEmpty)
  }

  func testProfilesSavedBeforeFacesStillLoad() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at:url) }
    let old = #"{"people":[{"id":"\#(UUID().uuidString)","name":"Ava","groupIDs":[],"tags":[],"topics":[],"notes":[]}],"groups":[]}"#
    try Data(old.utf8).write(to:url)
    let store = PeopleStore(fileURL:url)
    XCTAssertEqual(store.people.map(\.name), ["Ava"])
    XCTAssertTrue(store.people[0].faces.isEmpty)
  }

  func testEnrollmentRejectsPhotoWithoutFace() {
    let blank = UIGraphicsImageRenderer(size:CGSize(width:300, height:300)).image { context in
      UIColor.gray.setFill(); context.fill(CGRect(x:0, y:0, width:300, height:300))
    }
    XCTAssertThrowsError(try FaceRecognizer.enroll(from:blank))
    XCTAssertTrue(FaceGallery(people:[]).isEmpty)
  }
}

@MainActor
final class IntroductionTests: XCTestCase {
  func testIntroductionPhrasesNeedACapitalizedName() {
    XCTAssertEqual(PresenceTracker.introducedNames(in:"Hey, my name is Priya."), ["Priya"])
    XCTAssertEqual(PresenceTracker.introducedNames(in:"This is my roommate Dev"), ["Dev"])
    XCTAssertEqual(PresenceTracker.introducedNames(in:"Nice to meet you, Sam!"), ["Sam"])
    XCTAssertEqual(PresenceTracker.introducedNames(in:"Hi, I'm Lena"), ["Lena"])
    XCTAssertEqual(PresenceTracker.introducedNames(in:"I'm Omar, nice to meet you"), ["Omar"])
    XCTAssertEqual(PresenceTracker.introducedNames(in:"I'm so tired today"), [])
    XCTAssertEqual(PresenceTracker.introducedNames(in:"this is great"), [])
    XCTAssertEqual(PresenceTracker.introducedNames(in:"Hi, I'm Sorry"), [])
  }

  func testIntroductionCreatesPersonAndMarksThemPresent() async throws {
    let store = PeopleStore(fileURL:nil)
    let jo = store.addPerson("Jo Park")!
    let model = SessionModel(people:store)
    model.simulate = true; model.localMock = true
    model.start()
    try await Task.sleep(for:.milliseconds(100))
    model.addSimulationLine("Hey everyone, this is my friend Priya")
    let priya = try XCTUnwrap(store.people.first { $0.name == "Priya" })
    XCTAssertTrue(model.presentIDs.contains(priya.id))
    XCTAssertEqual(model.presenceIcon(for:priya.id), "person.badge.plus")
    model.addSimulationLine("Meet Jo")
    XCTAssertTrue(model.presentIDs.contains(jo), "Introducing an existing person confirms them without a duplicate")
    XCTAssertEqual(store.people.count, 2)
    model.stop()
    XCTAssertEqual(store.people.count, 2, "New people stay in People after the conversation")
    XCTAssertTrue(model.presentIDs.isEmpty)
  }

  func testNotHereIsUndoneOnlyByAnIntroduction() async throws {
    let store = PeopleStore(fileURL:nil)
    let model = SessionModel(people:store)
    model.simulate = true; model.localMock = true
    model.start()
    try await Task.sleep(for:.milliseconds(100))
    model.addSimulationLine("My name is Priya")
    let priya = try XCTUnwrap(store.people.first).id
    model.markNotHere(priya)
    model.addSimulationLine("Thanks Priya")
    XCTAssertFalse(model.presentIDs.contains(priya))
    model.addSimulationLine("Call me Priya")
    XCTAssertTrue(model.presentIDs.contains(priya))
    model.stop()
  }

  func testFaceItemsApplyToProfile() {
    let store = PeopleStore(fileURL:nil)
    let id = store.addPerson("Priya")!
    let face = FaceSample(print:Data([1]), thumbnail:Data())
    store.apply([LearnItem(target:.person(id), field:.face, value:"Recognize this face as Priya", face:face)])
    XCTAssertEqual(store.people[0].faces, [face])
    var declined = LearnItem(target:.person(id), field:.face, value:"declined", face:FaceSample(print:Data([2]), thumbnail:Data()))
    declined.include = false
    store.apply([declined])
    XCTAssertEqual(store.people[0].faces.count, 1)
  }
}
