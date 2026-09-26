import XCTest
@testable import Copilot

@MainActor
final class ToneTests: XCTestCase {
  private func activeModel() async throws -> SessionModel {
    UserDefaults.standard.removeObject(forKey:"copilot.wearerVoiceDbFS")
    let model = SessionModel(people:PeopleStore(fileURL:nil))
    model.simulate = true; model.localMock = true; model.consent = true
    model.start()
    try await Task.sleep(for:.milliseconds(100))
    XCTAssertEqual(model.phase,.active)
    return model
  }

  func testBluntLineGetsRecoveryAndNeutralLineDoesNot() async throws {
    let model = try await activeModel()
    model.addSimulationLine("I have a few questions about the timeline.")
    try await Task.sleep(for:.milliseconds(500))
    XCTAssertNil(model.toneFeedback)
    model.addSimulationLine("Honestly, this idea is stupid.")
    try await Task.sleep(for:.milliseconds(500))
    let feedback = try XCTUnwrap(model.toneFeedback)
    XCTAssertEqual(feedback.said, "Honestly, this idea is stupid.")
    XCTAssertEqual(feedback.recovery, "Sorry, that came out harsh. Let me explain my concern.")
    XCTAssertTrue(feedback.strong)
    model.dismissTone()
    XCTAssertNil(model.toneFeedback)
    model.stop()
  }

  func testSwitchedOffOrStoppedMeansNoCoaching() async throws {
    let model = try await activeModel()
    model.toneCheckEnabled = false
    model.addSimulationLine("That makes no sense at all.")
    try await Task.sleep(for:.milliseconds(500))
    XCTAssertNil(model.toneFeedback)
    model.toneCheckEnabled = true
    model.addSimulationLine("That makes no sense at all.")
    model.stop()
    try await Task.sleep(for:.milliseconds(500))
    XCTAssertNil(model.toneFeedback, "Stop cancels a pending check")
  }

  func testCalibratedVoiceLevelSeparatesWearerFromOthers() {
    UserDefaults.standard.removeObject(forKey:"copilot.wearerVoiceDbFS")
    let model = SessionModel(people:PeopleStore(fileURL:nil))
    XCTAssertNil(model.speaker(forLevel:-20), "Unknown until calibrated")
    model.transcript = [TranscriptEntry(text:"Morning everyone", startMs:0, endMs:1, confidence:nil, levelDbFS:-22)]
    model.markLastLineAsMine()
    XCTAssertEqual(model.wearerVoiceDbFS, -22)
    XCTAssertEqual(model.transcript[0].speaker, "wearer")
    XCTAssertEqual(model.speaker(forLevel:-25), "wearer")
    XCTAssertEqual(model.speaker(forLevel:-35), "other", "Much quieter voices are someone else")
    model.resetWearerVoice()
    XCTAssertNil(model.wearerVoiceDbFS)
  }

  func testOtherPeoplesLinesAreNotChecked() async throws {
    let model = try await activeModel()
    model.wearerVoiceDbFS = -20
    let other = TranscriptEntry(text:"This idea is stupid", startMs:nowMs() - 2000, endMs:nowMs(), confidence:nil, speaker:"other", levelDbFS:-40)
    model.checkTone(other)
    try await Task.sleep(for:.milliseconds(500))
    XCTAssertNil(model.toneFeedback)
    model.resetWearerVoice()
    model.stop()
  }

  func testSpeechLevelIsLouderForLouderAudio() {
    let quiet = (0..<16000).map { Int16(sin(Double($0) / 5) * 800) }
    let loud = (0..<16000).map { Int16(sin(Double($0) / 5) * 8000) }
    let silence = [Int16](repeating:0, count:16000)
    XCTAssertGreaterThan(ConversationMicrophone.speechLevel(loud), ConversationMicrophone.speechLevel(quiet) + 15)
    XCTAssertEqual(ConversationMicrophone.speechLevel(silence), -120)
  }
}
