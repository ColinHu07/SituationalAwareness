import XCTest
import AVFoundation
import os
import MWDATCore
@testable import Copilot

@MainActor
final class SessionTests: XCTestCase {
  func testStoppedStreamingKeepsControlsAndConsentButClearsContext() async throws {
    let model = try await activeModel()
    model.contextText = "Private session note"
    model.addSimulationLine("Some private speech")
    model.manualDisplayTest()
    model.captureMode = .displayGlasses
    model.stopStreaming()
    XCTAssertEqual(model.phase,.paused)
    XCTAssertTrue(model.glassesControlsReady)
    XCTAssertTrue(model.canStart)
    XCTAssertTrue(model.consent)
    XCTAssertNil(model.cue)
    XCTAssertNil(model.latestFrame)
    XCTAssertNil(model.latestAudioContext)
    XCTAssertTrue(model.transcript.isEmpty)
    XCTAssertTrue(model.contextText.isEmpty)
    model.stop()
    XCTAssertFalse(model.consent)
    XCTAssertFalse(model.glassesControlsReady)
  }

  func testOldDisplayButtonsCannotControlNewScreen() {
    let controller = GlassesController()
    var starts = 0
    var stops = 0
    controller.onResume = { starts += 1 }
    controller.onStop = { stops += 1 }
    let oldRevision = controller.displayRevision
    controller.show(nil,paused:true,ready:true)
    controller.perform(.start,revision:oldRevision)
    controller.perform(.stop,revision:oldRevision)
    XCTAssertEqual(starts,0)
    XCTAssertEqual(stops,0)
    controller.perform(.start,revision:controller.displayRevision)
    XCTAssertEqual(starts,1)
  }

  func testCameraStopWaitsForCompletionAndHasBoundedFailure() async {
    var stopped = false
    let finish = Task { @MainActor in
      try? await Task.sleep(for:.milliseconds(80))
      stopped = true
    }
    let completed = await GlassesController.waitForStop(timeout:.seconds(1)) { stopped }
    XCTAssertTrue(completed)
    await finish.value
    let timedOut = await GlassesController.waitForStop(timeout:.milliseconds(60)) { false }
    XCTAssertFalse(timedOut)
  }

  func testOpeningGlassesControlsRequiresConsent() {
    let model = SessionModel()
    model.captureMode = .displayGlasses
    model.openGlassesControls()
    XCTAssertEqual(model.phase,.stopped)
    XCTAssertFalse(model.openingGlassesControls)
  }
  func testGlassesAppUpdateErrorPreservesActionableRecovery() {
    let controller = GlassesController()
    var failure: String?
    controller.onFailure = { failure = $0 }
    controller.report(DeviceSessionError.datAppOnTheGlassesUpdateRequired)
    XCTAssertTrue(controller.updateRequired)
    XCTAssertEqual(failure,GlassesController.updateInstructions)
    XCTAssertEqual(controller.lastError,GlassesController.updateInstructions)
    controller.report(DeviceSessionError.noEligibleDevice)
    XCTAssertFalse(controller.updateRequired)
    XCTAssertNotEqual(failure,GlassesController.updateInstructions)
  }
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
    XCTAssertTrue(model.analyzesSurroundings)
    model.phoneCameraEnabled = false
    XCTAssertFalse(model.analyzesSurroundings)
    model.phoneCameraEnabled = true
    model.captureMode = .regularGlasses
    XCTAssertFalse(model.canStart)
    model.selectedAudioUID = "explicitly-selected-hfp"
    XCTAssertTrue(model.canStart)
    XCTAssertFalse(model.captureMode.hasGlassesDisplay)
    model.captureMode = .displayGlasses
    XCTAssertTrue(model.captureMode.hasGlassesDisplay)
    model.selectedAudioUID = ""
    XCTAssertTrue(model.canStart, "Display ambient PCM needs no HFP selection")
    XCTAssertTrue(model.analyzesSurroundings)
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

  func testSilentLibraryProducesSceneCueAndRespectsAutomaticCooldown() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.addSimulationScene("library")
    XCTAssertTrue(model.transcript.isEmpty)
    try await Task.sleep(for:.milliseconds(1600))
    model.requestCue(manual:true)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"This looks like a library. Keep your voice low.")
    let count = model.requests
    model.requestCue(manual:false)
    XCTAssertEqual(model.requests,count)
    model.dismiss()
    model.requestCue(manual:false)
    XCTAssertEqual(model.requests,count)
  }

  func testSurroundingsRejectsStaleImageAndAudioOnlyEvidence() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.simulateSurroundings = true
    model.latestAudioContext = AudioContext(capturedAtMs:nowMs(),windowMs:1000,activityRatio:0,rmsDbFS:-80,source:"glasses_pcm")
    model.latestFrame = SampledFrame(dataUrl:"data:image/jpeg;base64,unused",capturedAtMs:nowMs()-11000)
    try await Task.sleep(for:.milliseconds(1600))
    model.requestCue(manual:true)
    XCTAssertEqual(model.requests,0)
    XCTAssertNil(model.cue)
  }

  func testNewSceneCancelsPendingLibraryCue() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.addSimulationScene("library")
    try await Task.sleep(for:.milliseconds(1600))
    model.requestCue(manual:true)
    XCTAssertTrue(model.isThinking)
    model.addSimulationScene("group")
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertNotEqual(model.cue,"This looks like a library. Keep your voice low.")
  }

  func testSurroundingsUsesExplicitSpeechForSupportiveCue() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.simulateSurroundings = true
    model.addSimulationLine("I've had a rough day. I need some space.")
    try await Task.sleep(for:.milliseconds(1600))
    model.requestCue(manual:true)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"They mentioned a hard day. Listen and give them space.")
  }

  func testAdaptiveCadenceAndPauseErasesAudioSummary() async throws {
    let model = try await activeModel()
    model.simulateSurroundings = true
    let timestamp = nowMs()
    XCTAssertEqual(model.analysisInterval(at:timestamp,reducedPower:false),20)
    model.lastVoiceAt = timestamp
    XCTAssertEqual(model.analysisInterval(at:timestamp,reducedPower:false),8)
    XCTAssertEqual(model.analysisInterval(at:timestamp,reducedPower:true),30)
    XCTAssertEqual(model.analysisInterval(at:timestamp+30001,reducedPower:false),20)
    model.latestAudioContext = AudioContext(capturedAtMs:timestamp,windowMs:1000,activityRatio:0.5,rmsDbFS:-30,source:"glasses_pcm")
    model.pause()
    XCTAssertNil(model.latestAudioContext)
    XCTAssertEqual(model.nextAnalysisAt,0)
    model.stop()
  }

  func testAmbientPCMConversionBoundedChunksAndStop() throws {
    let microphone = ConversationMicrophone()
    let chunks = OSAllocatedUnfairLock(initialState:[AudioChunk]())
    let contexts = OSAllocatedUnfairLock(initialState:[AudioContext]())
    microphone.onChunk = { chunk in chunks.withLock { $0.append(chunk) } }
    microphone.onContext = { context in contexts.withLock { $0.append(context) } }
    microphone.prepareStreamPCM()
    let format = try XCTUnwrap(AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000))
    buffer.frameLength = 16000
    let data = try XCTUnwrap(buffer.floatChannelData?[0])
    for i in 0..<16000 { data[i] = 0.05 }
    let timestamp = nowMs()
    for i in 1...6 { microphone.receiveStreamPCM(buffer,at:timestamp+Double(i)*1000) }
    let captured = chunks.withLock { $0 }
    XCTAssertEqual(captured.count,1)
    let chunk = try XCTUnwrap(captured.first)
    XCTAssertEqual(Data(base64Encoded:chunk.audioBase64)?.count,192044)
    XCTAssertEqual(chunk.endedAtMs-chunk.startedAtMs,6000,accuracy:1)
    let summaries = contexts.withLock { $0 }
    XCTAssertEqual(summaries.count,6)
    XCTAssertTrue(summaries.allSatisfy { $0.source == "glasses_pcm" && $0.activityRatio == 1 && $0.rmsDbFS < 0 })
    microphone.stop()
    microphone.receiveStreamPCM(buffer,at:timestamp+7000)
    XCTAssertEqual(contexts.withLock { $0.count },6)
  }

  func testGlassesClockPreservesRelativeAudioVideoTimeAndRejectsLateFrames() {
    let clock = GlassesStreamClock()
    XCTAssertFalse(clock.hasVideo)
    func pts(_ seconds: Double) -> CMTime { CMTime(seconds:seconds,preferredTimescale:1000) }
    XCTAssertEqual(clock.timestamp(for:pts(10),audio:false,arrival:100000),100000)
    XCTAssertTrue(clock.hasVideo)
    XCTAssertEqual(clock.timestamp(for:pts(10.1),audio:true,arrival:100150),100100)
    XCTAssertEqual(clock.timestamp(for:pts(10.5),audio:false,arrival:100550),100500)
    XCTAssertNil(clock.timestamp(for:pts(10.3),audio:false,arrival:100600))
    XCTAssertNil(clock.timestamp(for:pts(12),audio:true,arrival:100600))
    XCTAssertNil(clock.timestamp(for:pts(10.7),audio:true,arrival:116000))
    clock.stop()
    XCTAssertNil(clock.timestamp(for:pts(10.8),audio:true,arrival:100900))
  }

  func testSceneSelectionExplicitlyChecksDuringCooldown() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.addSimulationScene("library")
    try await Task.sleep(for:.milliseconds(1600))
    model.requestCue(manual:true)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"This looks like a library. Keep your voice low.")
    model.addSimulationScene("group")
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"People are talking. Wait for a pause before joining in.")
  }

  func testFreshSceneSurvivesSpeechExpiringDuringInference() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.addSimulationScene("library")
    try await Task.sleep(for:.milliseconds(1600))
    let time = nowMs()
    model.transcript = [TranscriptEntry(text:"We have arrived.",startMs:time-16000,endMs:time-14900,confidence:nil)]
    model.lastVoiceAt = time-14900
    model.requestCue(manual:true)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"This looks like a library. Keep your voice low.")
  }

  func testUnalignedPCMFramesNeverExceedSixSeconds() throws {
    let microphone = ConversationMicrophone()
    let chunks = OSAllocatedUnfairLock(initialState:[AudioChunk]())
    microphone.onChunk = { chunk in chunks.withLock { $0.append(chunk) } }
    microphone.prepareStreamPCM()
    defer { microphone.stop() }
    let format = try XCTUnwrap(AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:1024))
    buffer.frameLength = 1024
    let data = try XCTUnwrap(buffer.floatChannelData?[0])
    for i in 0..<1024 { data[i] = 0.05 }
    let time = nowMs()
    for i in 1...188 { microphone.receiveStreamPCM(buffer,at:time+Double(i)*64) }
    let captured = chunks.withLock { $0 }
    XCTAssertEqual(captured.count,2)
    XCTAssertTrue(captured.allSatisfy { Data(base64Encoded:$0.audioBase64)?.count == 192044 })
    XCTAssertTrue(captured.allSatisfy { abs($0.endedAtMs-$0.startedAtMs-6000) < 1 })
  }

  func testLiveGlassesNeedFreshCameraAndAudio() {
    let model = SessionModel()
    model.captureMode = .displayGlasses
    let time = nowMs()
    XCTAssertNotNil(model.liveInputIssue(at:time))
    model.latestFrame = SampledFrame(dataUrl:"test",capturedAtMs:time)
    XCTAssertNotNil(model.liveInputIssue(at:time), "Camera alone does not prove a full live capture path")
    model.latestAudioContext = AudioContext(capturedAtMs:time,windowMs:1000,activityRatio:0,rmsDbFS:-80,source:"glasses_pcm")
    XCTAssertNil(model.liveInputIssue(at:time), "Silent ambient PCM is valid live audio")
    XCTAssertNotNil(model.liveInputIssue(at:time+10001))
    model.captureMode = .phone
    model.phoneCameraEnabled = false
    model.latestFrame = nil
    model.latestAudioContext = AudioContext(capturedAtMs:time,windowMs:1000,activityRatio:0,rmsDbFS:-80,source:"phone")
    XCTAssertNil(model.liveInputIssue(at:time), "Explicit audio-only phone mode needs no frame")
  }

  func testStalledCapturePausesAndClearsCueAndResult() async throws {
    let model = try await activeModel()
    model.manualDisplayTest()
    model.lastSceneSummary = "A previous observation"
    model.lastAnalysisOutcome = "Social cue ready."
    model.captureMode = .phone
    let time = nowMs()
    model.latestFrame = SampledFrame(dataUrl:"test",capturedAtMs:time)
    model.latestAudioContext = AudioContext(capturedAtMs:time,windowMs:1000,activityRatio:0,rmsDbFS:-80,source:"phone")
    model.checkCaptureHealth(at:time+13000)
    XCTAssertEqual(model.phase,.paused)
    XCTAssertNil(model.cue)
    XCTAssertNil(model.lastSceneSummary)
    XCTAssertNil(model.lastAnalysisOutcome)
    XCTAssertNil(model.latestFrame)
    XCTAssertNil(model.latestAudioContext)
    model.stop()
  }

  func testNoUploadManualDisplayTestDoesNotCallMuse() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.connectionTestOnly = true
    model.manualDisplayTest()
    XCTAssertNotNil(model.cue)
    model.requestCue(manual:true)
    XCTAssertEqual(model.requests,0)
    XCTAssertEqual(model.uploadedBytes,0)
  }

  func testDevelopmentConnectionRejectsUnsafeOrIncompleteSetup() {
    let token = String(repeating:"x",count:32)
    XCTAssertNotNil(DevelopmentConnection.settings(from:["ASIDE_PROXY_URL":"https://test.example", "ASIDE_PROXY_TOKEN":token]))
    XCTAssertNil(DevelopmentConnection.settings(from:["ASIDE_PROXY_URL":"http://test.example", "ASIDE_PROXY_TOKEN":token]))
    XCTAssertNil(DevelopmentConnection.settings(from:["ASIDE_PROXY_URL":"https://user:password@test.example", "ASIDE_PROXY_TOKEN":token]))
    XCTAssertNil(DevelopmentConnection.settings(from:["ASIDE_PROXY_URL":"https://test.example?token=secret", "ASIDE_PROXY_TOKEN":token]))
    XCTAssertNil(DevelopmentConnection.settings(from:["ASIDE_PROXY_URL":"https://test.example", "ASIDE_PROXY_TOKEN":"short"]))
    XCTAssertNil(DevelopmentConnection.settings(from:[:]))
  }
}
