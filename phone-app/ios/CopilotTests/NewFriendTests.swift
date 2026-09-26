import XCTest
import UIKit
@testable import Copilot

@MainActor
final class NewFriendTests: XCTestCase {
  private func face(_ angle: Float) -> FaceRecognizer.DetectedFace {
    var vector = [Float](repeating:0, count:512)
    vector[0] = cos(angle); vector[1] = sin(angle)
    let image = UIGraphicsImageRenderer(size:CGSize(width:160, height:160)).image { _ in UIColor.gray.setFill(); UIRectFill(CGRect(x:0, y:0, width:160, height:160)) }
    return .init(embedding:vector, crop:image.cgImage!, area:25600)
  }
  private func activeModel(_ store: PeopleStore) async throws -> SessionModel {
    let model = SessionModel(people:store)
    model.simulate = true; model.localMock = true; model.consent = true
    model.start()
    try await Task.sleep(for:.milliseconds(100))
    XCTAssertEqual(model.phase, .active)
    return model
  }

  func testAddressedNamesOnlyCountWhenSpokenToSomeone() {
    XCTAssertEqual(PresenceTracker.addressedNames(in:"Hey Marcus, how's it going?"), ["Marcus"])
    XCTAssertEqual(PresenceTracker.addressedNames(in:"oh hey Marcus I missed you"), ["Marcus"])
    XCTAssertEqual(PresenceTracker.addressedNames(in:"Marcus, did you finish the lab?"), ["Marcus"])
    XCTAssertEqual(PresenceTracker.addressedNames(in:"See you tomorrow, Lena."), ["Lena"])
    XCTAssertEqual(PresenceTracker.addressedNames(in:"Thanks, Priya!"), ["Priya"])
    XCTAssertEqual(PresenceTracker.addressedNames(in:"Did Marcus text you?"), [], "Talking about someone, not to them")
    XCTAssertEqual(PresenceTracker.addressedNames(in:"Hey Guys, over here"), [])
    XCTAssertEqual(PresenceTracker.addressedNames(in:"Thanks, Friday works"), [])
    XCTAssertEqual(PresenceTracker.addressedNames(in:"Well, that's fine."), [])
  }

  func testNameThenFaceCreatesFriendWithThatFace() async throws {
    let store = PeopleStore(fileURL:nil)
    let model = try await activeModel(store)
    model.addSimulationLine("Hey Marcus, good to see you")
    XCTAssertTrue(store.people.isEmpty, "Waits for a face")
    let now = nowMs()
    model.trackUnknownFaces([face(0.6)], at:now)
    XCTAssertTrue(store.people.isEmpty, "One sighting is not enough")
    model.trackUnknownFaces([face(0.61)], at:now + 1000)
    let marcus = try XCTUnwrap(store.people.first { $0.name == "Marcus" })
    XCTAssertEqual(marcus.faces.count, 1)
    XCTAssertTrue(marcus.faces[0].fromVideo)
    XCTAssertTrue(model.presentIDs.contains(marcus.id))
    model.stop()
  }

  func testFaceThenNameAlsoWorks() async throws {
    let store = PeopleStore(fileURL:nil)
    let model = try await activeModel(store)
    let now = nowMs()
    model.trackUnknownFaces([face(0.6)], at:now - 2000)
    model.trackUnknownFaces([face(0.6)], at:now - 1000)
    model.addSimulationLine("Thanks, Lena!")
    XCTAssertNotNil(store.people.first { $0.name == "Lena" && $0.faces.count == 1 })
    model.stop()
  }

  func testNoFriendWhenAmbiguousOrOnlyTalkedAbout() async throws {
    let store = PeopleStore(fileURL:nil)
    let model = try await activeModel(store)
    let now = nowMs()
    // Two strangers in view: can't tell which one is Marcus.
    model.trackUnknownFaces([face(0.6), face(2.4)], at:now - 2000)
    model.trackUnknownFaces([face(0.6), face(2.4)], at:now - 1000)
    model.addSimulationLine("Hey Marcus, good to see you")
    XCTAssertTrue(store.people.isEmpty)
    model.stop()

    let other = try await activeModel(store)
    let later = nowMs()
    other.trackUnknownFaces([face(0.6)], at:later - 2000)
    other.trackUnknownFaces([face(0.6)], at:later - 1000)
    other.addSimulationLine("Did Marcus text you about Friday?")
    XCTAssertTrue(store.people.isEmpty, "Mentioning an absent friend creates no one")
    other.stop()
  }

  func testNewFaceThatLooksLikeAnExistingFriendIsNotDuplicated() async throws {
    let store = PeopleStore(fileURL:nil)
    let sam = store.addPerson("Sam")!
    var vector = [Float](repeating:0, count:512); vector[0] = cos(0.6); vector[1] = sin(0.6)
    store.people[0].faces = [FaceSample(thumbnail:Data(), embedding:vector, modelID:FaceEmbedding.modelID)]
    let model = try await activeModel(store)
    let now = nowMs()
    model.trackUnknownFaces([face(0.62)], at:now - 2000)
    model.trackUnknownFaces([face(0.62)], at:now - 1000)
    model.addSimulationLine("Hey Marcus, good to see you")
    XCTAssertEqual(store.people.map(\.id), [sam], "Same face as Sam: no new profile")
    model.stop()
  }
}
