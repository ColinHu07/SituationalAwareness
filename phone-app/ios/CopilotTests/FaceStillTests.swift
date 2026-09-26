import XCTest
import UIKit
@testable import Copilot

@MainActor
final class FaceStillTests: XCTestCase {
  // Unit vectors on a circle: distance between angles a and b is 2·sin(|a−b|/2).
  private func vector(_ angle: Float) -> [Float] {
    var result = [Float](repeating:0, count:512)
    result[0] = cos(angle); result[1] = sin(angle)
    return result
  }
  private func sample(_ angle: Float, video: Bool = false) -> FaceSample {
    FaceSample(thumbnail:Data(), embedding:vector(angle), modelID:FaceEmbedding.modelID, capturedAt:video ? Date() : nil)
  }
  private func face(_ angle: Float, side: CGFloat = 160) -> FaceRecognizer.DetectedFace {
    let image = UIGraphicsImageRenderer(size:CGSize(width:side, height:side)).image { _ in UIColor.gray.setFill(); UIRectFill(CGRect(x:0, y:0, width:side, height:side)) }
    return .init(embedding:vector(angle), crop:image.cgImage!, area:side * side)
  }

  func testOnlyConfidentNewLookingStillsOfTheRightPersonAreKept() {
    let sam = Person(name:"Sam", faces:[sample(0)])
    let people = [sam, Person(name:"Priya", faces:[sample(1.8)])]
    let kept = FaceRecognizer.stillWorthKeeping(face(0.35), personID:sam.id, distance:0.35, people:people)
    XCTAssertEqual(kept?.fromVideo, true, "New angle, confident match")
    XCTAssertNil(FaceRecognizer.stillWorthKeeping(face(0.1), personID:sam.id, distance:0.1, people:people), "Near-duplicate of a saved photo")
    XCTAssertNil(FaceRecognizer.stillWorthKeeping(face(0.9), personID:sam.id, distance:0.87, people:people), "Match not confident enough")
    XCTAssertNil(FaceRecognizer.stillWorthKeeping(face(0.35, side:90), personID:sam.id, distance:0.35, people:people), "Face too small")
    let lookalike = [sam, Person(name:"Twin", faces:[sample(0.5)])]
    XCTAssertNil(FaceRecognizer.stillWorthKeeping(face(0.35), personID:sam.id, distance:0.35, people:lookalike), "Also resembles someone else")
  }

  func testUploadedPhotosAreNeverPushedOutByVideoStills() {
    let uploads = (0..<8).map { sample(Float($0) * 0.01) }
    let stills = (0..<15).map { sample(Float($0) * 0.01, video:true) }
    let kept = FaceRecognizer.trimmed(uploads + stills)
    XCTAssertEqual(kept.filter { !$0.fromVideo }.map(\.id), uploads.map(\.id))
    XCTAssertEqual(kept.filter(\.fromVideo).map(\.id), stills.suffix(12).map(\.id), "Newest 12 stills")
  }

  func testStillsNeedPresenceAndRespectPerConversationLimits() {
    let store = PeopleStore(fileURL:nil)
    let sam = store.addPerson("Sam")!
    store.people[0].faces = [sample(0)]
    let model = SessionModel(people:store)
    let match = FaceMatch(personID:sam, distance:0.4)
    model.saveStills([(match, face(0.4))], at:0)
    XCTAssertEqual(store.people[0].faces.count, 1, "Not saved until Sam is confirmed here")
    model.applyFaceMatches([sam], at:0); model.applyFaceMatches([sam], at:1000)
    XCTAssertTrue(model.presentIDs.contains(sam))
    model.saveStills([(match, face(0.4))], at:2000)
    model.saveStills([(match, face(0.9))], at:5000)
    XCTAssertEqual(store.people[0].faces.count, 2, "At most one still every 20 seconds")
    model.saveStills([(match, face(0.9))], at:23_000)
    model.saveStills([(match, face(1.3))], at:44_000)
    model.saveStills([(match, face(1.7))], at:65_000)
    XCTAssertEqual(store.people[0].faces.filter(\.fromVideo).count, 3, "At most three per conversation")
    XCTAssertEqual(model.stillsSaved, 3)
    model.saveFaceStills = false
    model.stop()
    XCTAssertEqual(model.stillsSaved, 0)
  }

  func testNewlyIntroducedPersonsFaceIsSavedDuringTheConversation() async throws {
    let store = PeopleStore(fileURL:nil)
    let model = SessionModel(people:store)
    model.simulate = true; model.localMock = true; model.consent = true
    model.start()
    try await Task.sleep(for:.milliseconds(100))
    model.addSimulationLine("Hey everyone, this is my friend Dev")
    let dev = try XCTUnwrap(store.people.first { $0.name == "Dev" })
    let now = nowMs()
    model.considerFaceCandidate([face(0.6)], at:now)
    XCTAssertTrue(dev.faces.isEmpty)
    model.considerFaceCandidate([face(0.62)], at:now + 1000)
    let saved = try XCTUnwrap(store.people.first { $0.id == dev.id }?.faces.first)
    XCTAssertTrue(saved.fromVideo, "Saved after two consistent sightings, before Stop")
    model.stop()
  }
}
