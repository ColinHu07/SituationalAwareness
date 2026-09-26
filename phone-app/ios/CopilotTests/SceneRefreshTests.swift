import XCTest
@testable import Copilot

@MainActor
final class SceneRefreshTests: XCTestCase {
  func testAutomaticCameraCheckDoesNotWaitForTranscription() {
    let model = SessionModel(people:PeopleStore(fileURL:nil))
    defer { model.stop() }
    model.phase = .active
    model.endpoint = "invalid-endpoint"
    model.latestFrame = SampledFrame(dataUrl:"test",capturedAtMs:nowMs())
    model.latestAudioContext = AudioContext(capturedAtMs:nowMs(),windowMs:1000,activityRatio:1,rmsDbFS:-20,source:"phone")
    model.isTranscribing = true
    model.requestCue(manual:false)
    XCTAssertEqual(model.requests,1,"Ongoing transcription must not starve camera analysis")
    model.requestCue(manual:false)
    XCTAssertEqual(model.requests,1,"Only one scene request may run at a time")
  }

  func testSceneCanUpdateAgainWhileTranscriptionContinues() async throws {
    let model = SessionModel(people:PeopleStore(fileURL:nil))
    model.simulate = true
    model.localMock = true
    model.start()
    defer { model.stop() }
    try await Task.sleep(for:.milliseconds(1700))
    model.isTranscribing = true
    model.addSimulationScene("library")
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"This looks like a library. Keep your voice low.")
    let firstUpdate = model.lastAnalysisAtMs
    model.addSimulationScene("group")
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"People are talking. Wait for a pause before joining in.")
    XCTAssertGreaterThan(model.lastAnalysisAtMs,firstUpdate)
    XCTAssertTrue(model.isTranscribing)
  }
}
