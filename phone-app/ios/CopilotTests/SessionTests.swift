import XCTest
import AVFoundation
import os
import MWDATCore
@testable import Copilot

@MainActor
final class SessionTests: XCTestCase {
  func testSceneOnlyStartsAnalysisWithoutSpeechAndSkipsASR() {
    let model = SessionModel()
    model.glassesConversationEnabled = false
    model.captureMode = .displayGlasses
    model.phase = .active
    model.consent = true
    model.endpoint = "invalid-endpoint" // Never contact a real service in this test.
    model.latestFrame = SampledFrame(dataUrl:"test",capturedAtMs:nowMs())
    model.transcribe(AudioChunk(audioBase64:"test",startedAtMs:nowMs()-1000,endedAtMs:nowMs()))
    XCTAssertFalse(model.isTranscribing)
    XCTAssertTrue(model.transcript.isEmpty)
    model.requestCue(manual:false)
    XCTAssertEqual(model.requests,1,"A camera frame automatically starts scene analysis without any speech")
    XCTAssertTrue(model.isThinking)
    model.requestCue(manual:false)
    XCTAssertEqual(model.requests,1,"Only one analysis may run at a time")
    XCTAssertEqual(model.analysisInterval(reducedPower:false),10)
    XCTAssertEqual(model.analysisInterval(reducedPower:true),15)
    model.stop()
  }

  func testSceneOnlyDisplayHasAutomaticAnalysisAndTwoControls() {
    let screen = GlassesScreen(cue:"This looks like a library. Keep your voice low.",caption:nil,note:nil,
      paused:false,captionsEnabled:false,ready:false,starting:false,testOnly:false,sceneOnly:true)
    XCTAssertEqual(screen.labels,["Pause","Stop"])
    XCTAssertEqual(screen.actions,[.pause,.stop])
    XCTAssertNotNil(screen.cue)
  }

  func testStartupFailureKeepsDisplayAndAllowsRetry() {
    let model = SessionModel()
    model.captureMode = .displayGlasses
    model.consent = true
    model.phase = .starting
    model.glasses.displayReady = true
    model.captureFailed("Camera permission denied")
    XCTAssertEqual(model.phase,.paused)
    XCTAssertTrue(model.canStart)
    XCTAssertTrue(model.consent)
    XCTAssertTrue(model.glasses.displayReady)
    XCTAssertEqual(model.notice,"Camera permission denied")
    XCTAssertEqual(model.glasses.requestedScreen?.mode,.paused)
    XCTAssertEqual(model.glasses.requestedScreen?.labels,["Resume","Stop","Close"])
    XCTAssertEqual(model.glasses.requestedScreen?.status,"Capture paused. Check phone, then Resume.")
    XCTAssertNil(model.latestFrame)
    XCTAssertNil(model.latestAudioContext)
    // A late failure cannot replace the original actionable error after pause.
    model.captureFailed("Late transport error")
    XCTAssertEqual(model.notice,"Camera permission denied")
    model.stop()
  }

  func testRecoveryMessageDoesNotLeakIntoNextStream() {
    let screen = GlassesScreen(cue:nil,caption:nil,note:nil,paused:false,
      captionsEnabled:true,ready:false,starting:false,testOnly:false,status:"Previous failure")
    XCTAssertNil(screen.status)
    XCTAssertEqual(screen.title,"Streaming")
  }

  func testQuietGlassesPCMStillReachesTranscription() throws {
    let microphone = ConversationMicrophone()
    let chunks = OSAllocatedUnfairLock(initialState:[AudioChunk]())
    microphone.onChunk = { chunk in chunks.withLock { $0.append(chunk) } }
    microphone.prepareStreamPCM()
    defer { microphone.stop() }
    let format = try XCTUnwrap(AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000))
    buffer.frameLength = 16000
    let data = try XCTUnwrap(buffer.floatChannelData?[0])
    for i in 0..<16000 { data[i] = 0.001 * sin(Float(i) * 0.08) }
    let time = nowMs()
    for i in 1...6 { microphone.receiveStreamPCM(buffer,at:time+Double(i)*1000) }
    let captured = chunks.withLock { $0 }
    XCTAssertEqual(captured.count,1,"Below-threshold audio must reach ASR, not be dropped as silence")
    XCTAssertEqual(Data(base64Encoded:try XCTUnwrap(captured.first).audioBase64)?.count,192044)
  }

  func testManualAnalyzeWaitsForTranscriptionAndShowsProgress() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.addSimulationLine("Can you have it ready by Friday?")
    model.isTranscribing = true
    model.requestCue(manual:true)
    XCTAssertNotNil(model.pendingManualAnalysisAt)
    XCTAssertEqual(model.analysisFeedback,"Finishing speech, then analyzing…")
    XCTAssertEqual(model.requests,0)
    model.isTranscribing = false
    try await Task.sleep(for:.milliseconds(2300))
    XCTAssertNil(model.pendingManualAnalysisAt)
    XCTAssertGreaterThan(model.requests,0)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertNotNil(model.cue)
  }

  func testAnalysisFeedbackStaysVisibleWithoutCaptionsOrExtraButtons() {
    let screen = GlassesScreen(cue:nil,caption:"Hello there",note:nil,paused:false,captionsEnabled:true,
      ready:false,starting:false,testOnly:false,feedback:"Analyzing…")
    XCTAssertEqual(screen.title,"Analyzing…")
    XCTAssertNil(screen.detail)
    XCTAssertEqual(screen.labels,["Pause","Analyze","Stop"])
  }

  func testOrdinarySpeechStillGetsAFallbackCue() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.addSimulationLine("The sky is blue.")
    try await Task.sleep(for:.milliseconds(1600))
    model.requestCue(manual:true)
    XCTAssertEqual(model.analysisFeedback,"Analyzing…")
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"Keep listening, then ask a follow-up question.")
    XCTAssertEqual(model.analysisFeedback,"Social cue")
    XCTAssertEqual(model.moments.last?.summary,"SIMULATED: conversation mentioning \"The sky is blue.\".")
  }
  func testNewCueWaitsForDwellAndSameCueDoesNotRedraw() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.addSimulationLine("Can you have it ready by Friday?")
    try await Task.sleep(for:.milliseconds(1600))
    model.requestCue(manual:true)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"Ask what they meant by Friday.")
    model.requestCue(manual:true)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.shown,1,"An unchanged cue is kept, not re-shown")
    model.addSimulationLine("How is the robotics project?")
    model.requestCue(manual:true)
    try await Task.sleep(for:.milliseconds(1000))
    XCTAssertEqual(model.cue,"Ask what they meant by Friday.","A different cue waits until the current one has been up 10 seconds")
    try await Task.sleep(for:.milliseconds(8500))
    XCTAssertEqual(model.cue,"Ask how their robotics project is going.")
    model.contextChanged()
    XCTAssertEqual(model.cue,"Ask how their robotics project is going.","Editing notes or people keeps the cue on screen")
  }
  func testSessionMemorySkipsRepeatsAndKeepsTheLatestEight() {
    let model = SessionModel(people:PeopleStore(fileURL:nil))
    for index in 0..<10 { model.remember("Moment \(index)", at:Double(index)) }
    model.remember("moment 9", at:10)
    model.remember("  ", at:11)
    XCTAssertEqual(model.moments.map(\.summary), (2..<10).map { "Moment \($0)" })
  }
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
    controller.displayReady = true
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

  func testLensDoesNotRedrawForHiddenCaptionsOrModelProgress() {
    let controller = GlassesController()
    controller.displayReady = true
    controller.show(nil,status:"Watching surroundings")
    let revision = controller.displayRevision
    controller.show(nil,caption:"A new transcript",status:"Analyzing surroundings…")
    controller.show(nil,caption:"Another transcript",status:"Transcribing speech")
    XCTAssertEqual(controller.displayRevision,revision)
    controller.show("Keep your voice low.")
    XCTAssertEqual(controller.displayRevision,revision+1)
    controller.show("Keep your voice low.",caption:"More speech",status:"Watching surroundings")
    XCTAssertEqual(controller.displayRevision,revision+1)
    controller.clear()
    controller.show("Keep your voice low.")
    XCTAssertEqual(controller.displayRevision,revision+3,"Closing invalidates the cached screen")
  }

  func testLensControlsStayCompactWithCueAndCaption() {
    let screen = GlassesScreen(cue:String(repeating:"x",count:150),caption:"  Caption\n\ttext  ",note:"Note",paused:false,
      captionsEnabled:true,ready:false,starting:false,testOnly:false)
    XCTAssertEqual(screen.labels,["Pause","Analyze","Stop"])
    XCTAssertEqual(screen.cue?.count,90)
    XCTAssertNil(screen.detail,"Captions stay on the phone even if an older caller enables them")
    let test = GlassesScreen(cue:nil,caption:nil,note:nil,paused:false,captionsEnabled:false,ready:false,starting:false,testOnly:true)
    XCTAssertEqual(test.labels,["Pause","Test cue","Stop"])
  }

  func testCaptionArgumentsNeverReachLensEvenWhenCueIsRemoved() {
    let controller = GlassesController()
    controller.displayReady = true
    controller.show("Ask what they meant.",caption:"We can meet Friday.",captionsEnabled:true)
    let revision = controller.displayRevision
    controller.show("Ask what they meant.",caption:"Friday afternoon works.",captionsEnabled:true)
    XCTAssertEqual(controller.displayRevision,revision,"New captions must not redraw the lens")
    XCTAssertEqual(controller.requestedScreen?.cue,"Ask what they meant.")
    XCTAssertNil(controller.requestedScreen?.detail)
    controller.show(nil,caption:"Friday afternoon works.",captionsEnabled:true)
    XCTAssertNil(controller.requestedScreen?.cue)
    XCTAssertNil(controller.requestedScreen?.detail)
    controller.show("Ask what they meant.",caption:"Friday afternoon works.",captionsEnabled:false)
    XCTAssertEqual(controller.requestedScreen?.cue,"Ask what they meant.")
    XCTAssertNil(controller.requestedScreen?.detail,"Turning captions off must still work during a cue")
  }

  func testCombinedDisplayClearsSpeechOutsideActiveCapture() {
    for (paused, ready, starting) in [(true,false,false), (true,true,false), (false,false,true)] {
      let screen = GlassesScreen(cue:"Ask what they meant.",caption:"Private speech",note:nil,
        paused:paused,captionsEnabled:true,ready:ready,starting:starting,testOnly:false)
      XCTAssertNil(screen.cue)
      XCTAssertNil(screen.detail)
    }
    let excerpt = GlassesScreen(cue:"A cue",caption:String(repeating:"a",count:100),note:nil,
      paused:false,captionsEnabled:true,ready:false,starting:false,testOnly:false)
    XCTAssertNil(excerpt.detail)
  }

  func testPhoneStartGlassesOnlyOpensControls() {
    let model = SessionModel()
    model.captureMode = .displayGlasses
    model.consent = true
    model.startFromPhone()
    XCTAssertTrue(model.openingGlassesControls)
    XCTAssertEqual(model.phase,.starting)
    XCTAssertEqual(model.requests,0)
    XCTAssertNil(model.latestFrame)
    model.stop() // Cancel before any SDK work; test must not access hardware.
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

  func testOpeningGlassesControlsIsAnExplicitStartAction() {
    let model = SessionModel()
    model.captureMode = .displayGlasses
    XCTAssertEqual(model.phase,.stopped)
    model.openGlassesControls()
    XCTAssertEqual(model.phase,.starting)
    XCTAssertTrue(model.openingGlassesControls)
    XCTAssertTrue(model.consent)
    model.stop()
  }

  func testPhoneStartBeginsCaptureWhenGlassesControlsAreAlreadyReady() {
    let model = SessionModel()
    model.captureMode = .displayGlasses
    model.phase = .paused
    model.glassesControlsReady = true
    model.startFromPhone()
    XCTAssertEqual(model.phase,.starting)
    XCTAssertFalse(model.openingGlassesControls,"The second Start must start capture, not reopen the ready screen")
    XCTAssertFalse(model.glassesControlsReady)
    model.stop()
  }

  func testGlassesConversationIsOptionalAndProfilesRemainAvailable() {
    let model = SessionModel(people:PeopleStore(fileURL:nil))
    model.captureMode = .displayGlasses
    XCTAssertFalse(model.sceneOnly, "Glasses captions are enabled by default")
    XCTAssertNotNil(model.people.addPerson("Sam"))
    model.glassesConversationEnabled = false
    XCTAssertTrue(model.sceneOnly)
    XCTAssertEqual(model.people.people.first?.name,"Sam")
  }

  func testNoUploadModeDoesNotLearnProfilesAfterStop() async throws {
    let store = PeopleStore(fileURL:nil)
    _ = store.addPerson("Sam")
    let model = SessionModel(people:store)
    model.simulate = true; model.connectionTestOnly = true
    model.start()
    try await Task.sleep(for:.milliseconds(100))
    model.addSimulationLine("Sam, I love robotics.")
    model.requestCue(manual:true)
    XCTAssertEqual(model.requests,0)
    model.stop()
    try await Task.sleep(for:.milliseconds(100))
    XCTAssertFalse(model.isLearning)
    XCTAssertNil(model.learnReview)
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
  func testPhoneIsDefaultAndDoesNotRequirePairedGlasses() {
    let model = SessionModel()
    XCTAssertEqual(model.captureMode,.phone)
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
  func testOngoingSpeechKeepsInFlightAndDisplayedCue() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.addSimulationLine("Can you have it ready by Friday?")
    try await Task.sleep(for:.milliseconds(1600))
    model.requestCue(manual:true)
    XCTAssertTrue(model.isThinking)
    // Conversation keeps going while the cue is being prepared.
    model.addSimulationLine("Let's talk about lunch instead.")
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue, "Ask what they meant by Friday.")
    XCTAssertFalse(model.isThinking)
    // More speech does not clear a cue that is already showing; Dismiss does.
    model.addSimulationLine("Anyway, how was your weekend?")
    XCTAssertEqual(model.cue, "Ask what they meant by Friday.")
    model.dismiss()
    XCTAssertNil(model.cue)
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
    model.requestCue(manual:false)
    XCTAssertEqual(model.requests,1,"Automatic checks stay quiet for 10 seconds after a dismissal")
    model.requestCue(manual:true)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"Ask what they meant by Friday.","Asking again explicitly brings the advice back")
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

  func testConversationCadenceSpeedsUpAndPauseErasesAudioSummary() async throws {
    let model = try await activeModel()
    model.simulateSurroundings = true
    let timestamp = nowMs()
    XCTAssertEqual(model.analysisInterval(at:timestamp,reducedPower:false),10)
    model.lastVoiceAt = timestamp
    XCTAssertEqual(model.analysisInterval(at:timestamp,reducedPower:false),2)
    XCTAssertEqual(model.analysisInterval(at:timestamp,reducedPower:true),4)
    XCTAssertEqual(model.analysisInterval(at:timestamp+30001,reducedPower:false),10)
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

  func testSceneOnlyNeedsFreshCameraAndPhoneStillRequiresAudio() {
    let model = SessionModel()
    model.glassesConversationEnabled = false
    model.captureMode = .displayGlasses
    let time = nowMs()
    XCTAssertNotNil(model.liveInputIssue(at:time))
    model.latestFrame = SampledFrame(dataUrl:"test",capturedAtMs:time)
    XCTAssertNil(model.liveInputIssue(at:time), "Scene-only checks can proceed without ambient audio")
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

  func testDelayedGlassesDataCanRecoverWithoutPausingOrAnalyzingStaleContent() {
    let model = SessionModel()
    defer { model.stop() }
    model.captureMode = .displayGlasses; model.phase = .active
    let time = nowMs()
    model.latestFrame = SampledFrame(dataUrl:"test",capturedAtMs:time-12000)
    model.latestAudioContext = AudioContext(capturedAtMs:time-12000,windowMs:1000,activityRatio:0,rmsDbFS:-80,source:"glasses_pcm")
    model.captureActivity = CaptureActivity(videoReceivedAtMs:time-100,audioReceivedAtMs:time-100)
    model.cue = "An old cue"
    model.checkCaptureHealth(at:time)
    XCTAssertEqual(model.phase,.active,"Delayed content is not proof of a disconnected stream")
    XCTAssertNil(model.cue,"Do not keep obsolete advice visible while transport catches up")
    XCTAssertTrue(model.notice.contains("delayed"))
    model.requestCue(manual:false)
    XCTAssertEqual(model.requests,0,"Arrival time must not turn stale content into fresh evidence")
    XCTAssertEqual(model.latestFrame?.capturedAtMs,time-12000)
    model.latestFrame = SampledFrame(dataUrl:"test",capturedAtMs:time)
    model.latestAudioContext = AudioContext(capturedAtMs:time,windowMs:1000,activityRatio:0,rmsDbFS:-80,source:"glasses_pcm")
    model.checkCaptureHealth(at:time)
    XCTAssertEqual(model.phase,.active)
    XCTAssertEqual(model.notice,"")
  }

  func testGlassesStillPauseIfEitherRequiredTransportActuallyStops() {
    for lostVideo in [true,false] {
      let model = SessionModel()
      model.captureMode = .displayGlasses; model.phase = .active
      let time = nowMs()
      model.latestFrame = SampledFrame(dataUrl:"test",capturedAtMs:time-12000)
      model.latestAudioContext = AudioContext(capturedAtMs:time-12000,windowMs:1000,activityRatio:0,rmsDbFS:-80,source:"glasses_pcm")
      model.captureActivity = CaptureActivity(videoReceivedAtMs:time-(lostVideo ? 12000 : 100),audioReceivedAtMs:time-(lostVideo ? 100 : 12000))
      model.checkCaptureHealth(at:time)
      XCTAssertEqual(model.phase,.paused)
      XCTAssertTrue(model.captionDiagnostics.entries.contains { $0.line.contains("Capture paused:") })
      model.stop()
    }
  }

  func testVoiceStreamKeepsAmbientPCMAndReducesVideoBandwidth() {
    let spoken = GlassesController.cameraConfiguration(withDisplay:true,voiceAudioEnabled:true)
    XCTAssertEqual(spoken.frameRate,2)
    if case .pcm(let sampleRate,let channels) = spoken.audioCodec {
      XCTAssertEqual(sampleRate,.rate16000)
      XCTAssertEqual(channels,1)
    } else { XCTFail("Voice mode must retain the ambient multi-speaker input") }
    XCTAssertEqual(GlassesController.cameraConfiguration(withDisplay:true,voiceAudioEnabled:false).frameRate,15)
    XCTAssertNil(GlassesController.cameraConfiguration(withDisplay:false,voiceAudioEnabled:true).audioCodec,"Regular glasses already receive their mic through HFP")
  }

  func testSceneIsRecognizedShownAndRemindedOnce() async throws {
    let model = try await activeModel()
    try await Task.sleep(for:.milliseconds(1600)) // checks start 1.5 s into a session
    model.addSimulationScene("funeral")
    try await Task.sleep(for:.milliseconds(700))
    XCTAssertEqual(model.currentScene, "funeral")
    XCTAssertEqual(model.cue, "Looks like a funeral. Stay quiet and somber.")
    model.dismiss()
    model.requestCue(manual:true)
    try await Task.sleep(for:.milliseconds(700))
    XCTAssertNil(model.cue, "No repeat reminder while the setting is unchanged")
    XCTAssertEqual(model.currentScene, "funeral")
    model.stop()
    XCTAssertNil(model.currentScene)
  }

  func testDevelopmentConnectionRejectsUnsafeOrIncompleteSetup() {
    let token = String(repeating:"x",count:32)
    XCTAssertNotNil(DevelopmentConnection.settings(from:["ASIDE_PROXY_URL":"https://test.example", "ASIDE_PROXY_TOKEN":token]))
    XCTAssertNil(DevelopmentConnection.settings(from:["ASIDE_PROXY_URL":"http://test.example", "ASIDE_PROXY_TOKEN":token]))
    XCTAssertNil(DevelopmentConnection.settings(from:["ASIDE_PROXY_URL":"https://user:password@test.example", "ASIDE_PROXY_TOKEN":token]))
    XCTAssertNil(DevelopmentConnection.settings(from:["ASIDE_PROXY_URL":"https://test.example?token=secret", "ASIDE_PROXY_TOKEN":token]))
    XCTAssertNil(DevelopmentConnection.settings(from:["ASIDE_PROXY_URL":"https://test.example", "ASIDE_PROXY_TOKEN":"short"]))
    XCTAssertNil(DevelopmentConnection.settings(from:[:]))
    XCTAssertNotNil(DevelopmentConnection.settings(from:["ASIDE_PROXY_URL":"http://10.0.0.140:8787", "ASIDE_PROXY_TOKEN":token]))
    XCTAssertNotNil(DevelopmentConnection.settings(from:["ASIDE_PROXY_URL":"http://my-mac.local:8787", "ASIDE_PROXY_TOKEN":token]))
    XCTAssertNil(DevelopmentConnection.settings(from:["ASIDE_PROXY_URL":"http://8.8.8.8:8787", "ASIDE_PROXY_TOKEN":token]))
  }

  func testUnreachableServerStillStartsPhoneCaptureWithoutUploads() async throws {
    let model = SessionModel(people:PeopleStore(fileURL:nil))
    model.captureMode = .phone; model.phoneCameraEnabled = false; model.consent = true
    model.endpoint = "http://127.0.0.1:9" // nothing listens here
    model.start()
    for _ in 0..<50 where model.phase == .starting { try await Task.sleep(for:.milliseconds(100)) }
    XCTAssertTrue(model.offline)
    XCTAssertTrue(model.uploadsDisabled)
    XCTAssertNotEqual(model.notice, "")
    model.stop()
  }
}
