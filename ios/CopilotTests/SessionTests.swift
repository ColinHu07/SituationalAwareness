import XCTest
@testable import Copilot

@MainActor
final class SessionTests: XCTestCase {
  private func activeModel() async throws -> SessionModel {
    let model = SessionModel()
    model.simulate = true; model.localMock = true; model.consent = true
    model.start()
    try await Task.sleep(for:.milliseconds(100))
    XCTAssertEqual(model.phase,.active)
    return model
  }
  func testStartRequiresConsent() async {
    let model = SessionModel()
    model.start()
    XCTAssertEqual(model.phase,.stopped)
  }
  func testPhoneIsDefaultAndDoesNotRequirePairedGlasses() {
    let model = SessionModel()
    XCTAssertEqual(model.captureMode,.phone)
    XCTAssertFalse(model.canStart)
    model.consent = true
    XCTAssertTrue(model.canStart)
    model.captureMode = .regularGlasses
    XCTAssertFalse(model.canStart)
    model.selectedAudioUID = "explicitly-selected-hfp"
    XCTAssertTrue(model.canStart)
    XCTAssertFalse(model.captureMode.hasGlassesDisplay)
    model.captureMode = .displayGlasses
    XCTAssertTrue(model.captureMode.hasGlassesDisplay)
  }
  func testCaptionAndSavedNoteSurviveSuggestionDismissal() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.contextText = "Small iced latte"
    model.addSimulationLine("Would you like that hot or iced?")
    XCTAssertEqual(model.captionText,"Would you like that hot or iced?")
    XCTAssertEqual(model.savedNote,"Small iced latte")
    model.manualDisplayTest()
    XCTAssertNotNil(model.cue)
    model.dismiss()
    XCTAssertNil(model.cue)
    XCTAssertEqual(model.captionText,"Would you like that hot or iced?")
    XCTAssertEqual(model.savedNote,"Small iced latte")
  }
  func testCaptionFreshnessOrderingAndExpiry() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    let time = nowMs()
    model.setCaption("Newest",capturedAtMs:time)
    model.setCaption("Late prior result",capturedAtMs:time-1000)
    model.setCaption("Future",capturedAtMs:time+5000)
    XCTAssertEqual(model.captionText,"Newest")
    model.expireCaption(at:time+15001)
    XCTAssertNil(model.captionText)
    model.setCaption("Expired",capturedAtMs:time-16000)
    XCTAssertNil(model.captionText)
  }
  func testPauseErasesCaptionsButPreservesUserNotesUntilStop() async throws {
    let model = try await activeModel()
    model.contextText = "Oat milk"
    model.addSimulationLine("What milk would you like?")
    model.pause()
    XCTAssertNil(model.captionText)
    XCTAssertEqual(model.savedNote,"Oat milk")
    model.setCaption("Late ASR",capturedAtMs:nowMs())
    XCTAssertNil(model.captionText)
    model.stop()
    XCTAssertNil(model.savedNote)
  }
  func testPhoneBackgroundPausesAndDoesNotRestartItself() async throws {
    // Uses a simulated active session; no real microphone/camera is requested.
    let model = try await activeModel()
    model.addSimulationLine("The counter is open.")
    model.captureMode = .phone
    model.sceneBecameInactive()
    XCTAssertEqual(model.phase,.paused)
    XCTAssertNil(model.captionText)
    XCTAssertTrue(model.transcript.isEmpty)
    model.stop()
    model.sceneBecameInactive()
    XCTAssertEqual(model.phase,.stopped)
  }
  func testCaptureTestNeverRequestsModelSuggestions() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.connectionTestOnly = true
    model.addSimulationLine("Would you like that hot or iced?")
    try await Task.sleep(for:.milliseconds(1600))
    model.requestCue(manual:true)
    XCTAssertEqual(model.requests,0)
    XCTAssertFalse(model.isThinking)
  }
  func testNewSpeechCancelsInFlightCue() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.addSimulationLine("Can you have it ready by Friday?")
    try await Task.sleep(for:.milliseconds(1600))
    model.requestCue(manual:true)
    XCTAssertTrue(model.isThinking)
    model.addSimulationLine("Let's talk about lunch instead.")
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertNil(model.cue)
    XCTAssertFalse(model.isThinking)
  }
  func testPauseStopsPendingCueAndErasesSpeech() async throws {
    let model = try await activeModel()
    model.addSimulationLine("Can you have it ready by Friday?")
    try await Task.sleep(for:.milliseconds(1600))
    model.requestCue(manual:true)
    model.pause()
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.phase,.paused)
    XCTAssertNil(model.cue)
    XCTAssertNil(model.latestFrame)
    XCTAssertTrue(model.transcript.isEmpty)
    model.stop()
  }
  func testMockCueDismissAndDedup() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.addSimulationLine("Can you have it ready by Friday?")
    try await Task.sleep(for:.milliseconds(1600))
    model.requestCue(manual:true)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"Ask what they meant by Friday.")
    XCTAssertEqual(model.shown,1)
    model.dismiss()
    XCTAssertNil(model.cue)
    model.requestCue(manual:true)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertNil(model.cue)
    XCTAssertEqual(model.shown,1)
  }
  func testTranscriptBoundsAndStopErasure() async throws {
    let model = try await activeModel()
    for _ in 0..<30 { model.addSimulationLine(String(repeating:"a",count:700)) }
    XCTAssertEqual(model.transcript.count,12)
    XCTAssertTrue(model.transcript.allSatisfy { $0.text.count == 500 })
    model.contextText = "Remember internship"
    model.stop()
    XCTAssertTrue(model.transcript.isEmpty)
    XCTAssertEqual(model.contextText,"")
    XCTAssertNil(model.latestFrame)
    XCTAssertFalse(model.consent)
  }
  func testWAVUsesMonoPCM16At16k() {
    let audio = ConversationMicrophone.wav([0, 1234, -1234])
    XCTAssertEqual(audio.count,50)
    XCTAssertEqual(String(data:audio.prefix(4),encoding:.utf8),"RIFF")
    XCTAssertEqual(Array(audio[22..<24]),[1,0])
    XCTAssertEqual(Array(audio[24..<28]),[0x80,0x3e,0,0])
    XCTAssertEqual(Array(audio[34..<36]),[16,0])
    XCTAssertEqual(Array(audio[40..<44]),[6,0,0,0])
  }
}
