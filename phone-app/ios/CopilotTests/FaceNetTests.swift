import XCTest
import UIKit
@testable import Copilot

final class FaceNetTests: XCTestCase {
  private func vector(_ angle: Float = 0) -> [Float] {
    var result = [Float](repeating:0, count:512)
    result[0] = cos(angle); result[1] = sin(angle)
    return result
  }
  private func sample(_ angle: Float = 0) -> FaceSample {
    FaceSample(thumbnail:Data(), embedding:vector(angle), modelID:FaceEmbedding.modelID)
  }
  private func face(_ angle: Float = 0) -> FaceRecognizer.DetectedFace {
    let image = UIGraphicsImageRenderer(size:CGSize(width:160, height:160)).image { _ in UIColor.gray.setFill(); UIRectFill(CGRect(x:0,y:0,width:160,height:160)) }
    return .init(embedding:vector(angle), crop:image.cgImage!, area:25600)
  }

  func testUnitDistanceRejectsMalformedVectors() {
    XCTAssertEqual(FaceEmbedding.distance(vector(), vector())!, 0, accuracy:0.00001)
    XCTAssertEqual(FaceEmbedding.distance(vector(), vector(.pi))!, 2, accuracy:0.00001)
    XCTAssertNil(FaceEmbedding.normalized([]))
    XCTAssertNil(FaceEmbedding.normalized([Float](repeating:0, count:512)))
    XCTAssertNil(FaceEmbedding.normalized([Float](repeating:.nan, count:512)))
    XCTAssertNil(FaceEmbedding.normalized([Float](repeating:.infinity, count:512)))
  }

  func testOldPhotosLoadButAreNeverCompared() throws {
    let legacy = FaceSample(print:Data([1,2]), thumbnail:Data([3]))
    let encoded = try JSONEncoder().encode(legacy)
    let decoded = try JSONDecoder().decode(FaceSample.self, from:encoded)
    XCTAssertEqual(decoded, legacy)
    XCTAssertFalse(decoded.isCompatible)
    XCTAssertTrue(FaceGallery(people:[Person(name:"Sam", faces:[decoded])]).isEmpty)
    var future = sample(); future.modelID = "other-model"
    XCTAssertTrue(FaceGallery(people:[Person(name:"Sam", faces:[future])]).isEmpty)
  }

  func testMatchesCorrectProfileAndRejectsUnknown() {
    let sam = Person(name:"Sam", faces:[sample(),sample(0.1)])
    let priya = Person(name:"Priya", faces:[sample(1.8)])
    let gallery = FaceGallery(people:[sam,priya])
    XCTAssertEqual(FaceRecognizer.match([face(0.05)], gallery:gallery).map(\.personID), [sam.id])
    XCTAssertEqual(FaceRecognizer.match([face(1.85)], gallery:gallery).map(\.personID), [priya.id])
    XCTAssertTrue(FaceRecognizer.match([face(-1.8)], gallery:gallery).isEmpty)
  }

  func testAmbiguousProfilesRemainUnknown() {
    let gallery = FaceGallery(people:[Person(name:"A", faces:[sample()]), Person(name:"B", faces:[sample(0.05)])])
    XCTAssertTrue(FaceRecognizer.match([face()], gallery:gallery).isEmpty)
  }

  func testMultiplePhotosRequireMoreThanOneLuckyMatch() {
    let gallery = FaceGallery(people:[Person(name:"A", faces:[sample(), sample(.pi)])])
    XCTAssertTrue(FaceRecognizer.match([face()], gallery:gallery).isEmpty)
  }

  func testTwoFacesCannotClaimOneProfile() {
    let gallery = FaceGallery(people:[Person(name:"A", faces:[sample()])])
    XCTAssertTrue(FaceRecognizer.match([face(), face(0.1)], gallery:gallery).isEmpty)
  }

  func testTwoDistinctFriendsCanMatchSameFrame() {
    let a = Person(name:"A", faces:[sample()]), b = Person(name:"B", faces:[sample(1.8)])
    XCTAssertEqual(Set(FaceRecognizer.match([face(),face(1.8)], gallery:FaceGallery(people:[a,b])).map(\.personID)), Set([a.id,b.id]))
  }

  func testEnrollmentRejectsCrossProfileAndWrongPerson() throws {
    let a = Person(name:"A", faces:[sample()]), b = Person(name:"B", faces:[sample(1.8)])
    XCTAssertThrowsError(try FaceRecognizer.validateEnrollment(sample(), personID:b.id, people:[a,b]))
    XCTAssertThrowsError(try FaceRecognizer.validateEnrollment(sample(.pi), personID:a.id, people:[a]))
    XCTAssertNoThrow(try FaceRecognizer.validateEnrollment(sample(0.1), personID:a.id, people:[a,b]))
  }

  func testGalleryInvalidatesOnReassignmentAndEmbeddingEdit() {
    let a = Person(name:"A", faces:[sample()]); var b = Person(name:"B", faces:a.faces)
    XCTAssertNotEqual(FaceGallery.key(for:[a]), FaceGallery.key(for:[b]))
    let before = FaceGallery.key(for:[b]); b.faces[0].embedding = vector(1)
    XCTAssertNotEqual(before, FaceGallery.key(for:[b]))
  }

  func testOneFrameCannotCountAsTwoSightings() {
    let id = UUID(); var presence = PresenceTracker()
    XCTAssertEqual(presence.recordFaces([id,id], at:1000), [])
    XCTAssertEqual(presence.recordFaces([id], at:1000), [])
    XCTAssertEqual(presence.recordFaces([id], at:2000), [id])
  }

  func testBundledModelExecutesAndReturnsUnitEmbedding() throws {
    // Synthetic pixels exercise model packaging/inference, not real-world identity accuracy.
    let crop = face().crop
    let first = try FaceNetEncoder.shared.embedding(for:crop)
    let second = try FaceNetEncoder.shared.embedding(for:crop)
    XCTAssertEqual(first.count, 512)
    XCTAssertEqual(first.reduce(0) { $0 + $1 * $1 }, 1, accuracy:0.001)
    XCTAssertLessThan(try XCTUnwrap(FaceEmbedding.distance(first, second)), 0.001)
  }
}
