import XCTest
import AVFoundation
import os
@testable import Copilot

@MainActor final class CueSpeakerTests: XCTestCase {
  private func makeModel(_ speaker: FakeCueSpeaker) -> SessionModel {
    let model = SessionModel(people:PeopleStore(fileURL:nil),cueSpeaker:speaker)
    model.captureMode = .simulated; model.phase = .active
    model.transcript = [.init(text:"Can you have it ready by Friday?",startMs:nowMs()-2000,endMs:nowMs(),confidence:nil)]
    return model
  }

  func testOnlyAcceptedOrStillCurrentCueReachesSpeechService() async throws {
    let speaker = FakeCueSpeaker()
    let session = makeModel(speaker)
    defer { session.stop() }
    session.setCaption("P1: Caption only",capturedAtMs:nowMs())
    session.applyRealtimeCaption(.init(type:"transcript.partial",turnId:1,speaker:"P2",text:"Another caption"))
    session.lastSceneSummary = "A summary that must stay silent"
    XCTAssertTrue(speaker.spoken.isEmpty)
    session.requestCue(manual:true)
    try await Task.sleep(for:.milliseconds(650))
    XCTAssertEqual(speaker.spoken,["Ask what they meant by Friday."])
    session.refreshDisplay()
    session.requestCue(manual:true)
    try await Task.sleep(for:.milliseconds(650))
    XCTAssertEqual(speaker.spoken.count,2,"The speech service retries failures and suppresses completed cues")
  }

  func testMutePreservesVisualCueWithoutSpeaking() async throws {
    let speaker = FakeCueSpeaker()
    let session = makeModel(speaker)
    defer { session.stop() }
    session.spokenCuesEnabled = false
    session.requestCue(manual:true)
    try await Task.sleep(for:.milliseconds(650))
    XCTAssertNotNil(session.cue)
    XCTAssertTrue(speaker.spoken.isEmpty)
  }

  func testDismissPauseStopAndMuteCancelSpeech() {
    let speaker = FakeCueSpeaker()
    let model = makeModel(speaker)
    model.dismiss(); XCTAssertEqual(speaker.stops,1)
    model.spokenCuesEnabled = false; XCTAssertEqual(speaker.stops,2)
    model.pause(); XCTAssertEqual(speaker.ends,1)
    model.stop(); XCTAssertEqual(speaker.ends,2)
  }

  func testGlassesRequireBluetoothOutputAndSimulatedModeStaysSilent() {
    XCTAssertFalse(CueSpeaker.permitsOutput(mode:.displayGlasses,ports:[.builtInSpeaker]))
    XCTAssertFalse(CueSpeaker.permitsOutput(mode:.regularGlasses,ports:[]))
    XCTAssertFalse(CueSpeaker.permitsOutput(mode:.displayGlasses,ports:[.bluetoothA2DP]),"A2DP can be selected but silenced by camera streaming")
    XCTAssertTrue(CueSpeaker.permitsOutput(mode:.displayGlasses,ports:[.bluetoothHFP]))
    XCTAssertTrue(CueSpeaker.permitsOutput(mode:.regularGlasses,ports:[.bluetoothHFP]))
    XCTAssertTrue(CueSpeaker.permitsOutput(mode:.phone,ports:[.builtInSpeaker]))
    XCTAssertFalse(CueSpeaker.permitsOutput(mode:.simulated,ports:[.builtInSpeaker]))
  }

  func testVoiceRouteMatchesSelectedGlassesWithoutGuessingAnotherHeadset() {
    let selected = [CueAudioOutput(uid:"a2dp-id",name:"Meta RB Display 0036",port:.bluetoothA2DP)]
    let other = CueAudioOutput(uid:"other",name:"AirPods",port:.bluetoothHFP)
    let glasses = CueAudioOutput(uid:"hfp-id",name:"Meta RB Display 0036",port:.bluetoothHFP)
    XCTAssertEqual(CueSpeaker.voiceInputUID(selectedOutputs:selected,availableInputs:[other,glasses]),"hfp-id")
    XCTAssertNil(CueSpeaker.voiceInputUID(selectedOutputs:selected,availableInputs:[other]))
    XCTAssertNil(CueSpeaker.voiceInputUID(selectedOutputs:[],availableInputs:[glasses]))
    XCTAssertNil(CueSpeaker.voiceInputUID(selectedOutputs:selected,availableInputs:[glasses,glasses]))
  }

  func testCueEchoIsReplacedWithSilenceAndCaptureResumes() throws {
    let microphone = ConversationMicrophone()
    microphone.prepareStreamPCM()
    defer { microphone.stop() }
    let output = OSAllocatedUnfairLock(initialState:Data())
    let contexts = OSAllocatedUnfairLock(initialState:0)
    microphone.onPCM = { data,_ in output.withLock { $0 = data } }
    microphone.onContext = { _ in contexts.withLock { $0 += 1 } }
    let format = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false)!
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16000))
    buffer.frameLength = 16000
    for i in 0..<16000 { buffer.floatChannelData![0][i] = 0.2 }
    let time = nowMs()
    microphone.receiveStreamPCM(buffer,at:time)
    XCTAssertTrue(output.withLock { $0.contains { $0 != 0 } })
    let before = contexts.withLock { $0 }
    microphone.setCuePlaybackActive(true)
    microphone.receiveStreamPCM(buffer,at:time+1000)
    XCTAssertEqual(output.withLock { $0 },Data(repeating:0,count:32000),"Keep the ASR clock moving without uploading the cue")
    XCTAssertEqual(contexts.withLock { $0 },before,"Do not mistake muted capture for a quiet environment")
    microphone.setCuePlaybackActive(false)
    microphone.receiveStreamPCM(buffer,at:nowMs())
    XCTAssertTrue(output.withLock { $0.allSatisfy { $0 == 0 } },"Suppress the playback echo tail")
    microphone.receiveStreamPCM(buffer,at:nowMs()+1000)
    XCTAssertTrue(output.withLock { $0.contains { $0 != 0 } })
  }
}

@MainActor private final class FakeCueSpeaker: CueSpeaking {
  var onPlaybackChanged: ((Bool) -> Void)?
  var onStatus: ((String?) -> Void)?
  var onDiagnostic: ((String) -> Void)?
  var spoken: [String] = []
  var stops = 0
  var ends = 0
  func prepare(for mode: CaptureMode) throws {}
  func speak(_ cue: String,mode:CaptureMode) { spoken.append(cue) }
  func stop() { stops += 1 }
  func endSession() { ends += 1 }
}

@MainActor final class CuePlaybackTests: XCTestCase {
  private func settle() async throws { try await Task.sleep(for:.milliseconds(300)) }

  func testBenignRouteNotificationsDoNotCancelSpeechAndCompletionDeduplicates() async throws {
    let audio = FakeCueAudioRouting(), synth = RecordingCueSynthesizer(), center = NotificationCenter()
    let speaker = CueSpeaker(synthesizer:synth,audio:audio,notifications:center)
    defer { speaker.endSession() }
    var statuses: [String] = []
    speaker.onStatus = { if let value = $0 { statuses.append(value) } }
    speaker.speak("Ask about the next step.",mode:.displayGlasses)
    try await settle()
    let utterance = try XCTUnwrap(synth.utterances.last)
    center.post(name:AVAudioSession.routeChangeNotification,object:nil,
                userInfo:[AVAudioSessionRouteChangeReasonKey:AVAudioSession.RouteChangeReason.categoryChange.rawValue])
    try await settle()
    XCTAssertEqual(synth.stops,0,"Session activation/category events must not cancel valid Bluetooth playback")
    XCTAssertFalse(statuses.contains { $0.hasPrefix("Speaking cue") },"Submitting speech is not a start confirmation")
    speaker.speechSynthesizer(synth,didStart:utterance)
    try await settle()
    XCTAssertTrue(statuses.last?.hasPrefix("Speaking cue") == true)
    speaker.speechSynthesizer(synth,didFinish:utterance)
    try await settle()
    speaker.speak("Ask about the next step!",mode:.displayGlasses)
    try await settle()
    XCTAssertEqual(synth.utterances.count,1)
    XCTAssertEqual(audio.activations,1)
  }

  func testCancellationCanRetrySameCueAndLateCallbackDoesNotCancelNewPlayback() async throws {
    let audio = FakeCueAudioRouting(), synth = RecordingCueSynthesizer()
    let speaker = CueSpeaker(synthesizer:synth,audio:audio,notifications:NotificationCenter())
    defer { speaker.endSession() }
    var playing = false
    speaker.onPlaybackChanged = { playing = $0 }
    speaker.speak("Ask about the next step.",mode:.displayGlasses)
    try await settle()
    let first = try XCTUnwrap(synth.utterances.last)
    speaker.speechSynthesizer(synth,didCancel:first)
    try await settle()
    XCTAssertFalse(playing)
    speaker.speak("Ask about the next step.",mode:.displayGlasses)
    try await settle()
    XCTAssertEqual(synth.utterances.count,2,"Cancelled speech was never delivered")
    XCTAssertEqual(audio.activations,2,"Reassert the audio session before retrying")
    speaker.speechSynthesizer(synth,didCancel:first)
    try await settle()
    XCTAssertTrue(playing)
  }

  func testWaitsForBluetoothThenStopsOnActualDisconnect() async throws {
    let audio = FakeCueAudioRouting(), synth = RecordingCueSynthesizer(), center = NotificationCenter()
    audio.outputs = [.init(uid:"phone",name:"iPhone",port:.builtInSpeaker)]
    let speaker = CueSpeaker(synthesizer:synth,audio:audio,notifications:center)
    defer { speaker.endSession() }
    var playing = false
    speaker.onPlaybackChanged = { playing = $0 }
    speaker.speak("Ask about the next step.",mode:.displayGlasses)
    try await settle()
    XCTAssertTrue(synth.utterances.isEmpty)
    XCTAssertFalse(playing,"Waiting for Bluetooth must not mask conversation audio")
    audio.outputs = FakeCueAudioRouting.glasses
    try await settle()
    XCTAssertEqual(synth.utterances.count,1)
    audio.outputs = [.init(uid:"phone",name:"iPhone",port:.builtInSpeaker)]
    center.post(name:AVAudioSession.routeChangeNotification,object:nil)
    try await settle()
    XCTAssertEqual(synth.stops,1)
    XCTAssertFalse(playing)
  }

  func testStopCancelsPendingPlaybackAndInterruptionEndDoesNotCancelSpeech() async throws {
    let audio = FakeCueAudioRouting(), synth = RecordingCueSynthesizer(), center = NotificationCenter()
    audio.outputs = []
    let speaker = CueSpeaker(synthesizer:synth,audio:audio,notifications:center)
    defer { speaker.endSession() }
    speaker.speak("Ask about the next step.",mode:.displayGlasses)
    try await settle()
    speaker.stop()
    audio.outputs = FakeCueAudioRouting.glasses
    try await settle()
    XCTAssertTrue(synth.utterances.isEmpty)
    speaker.speak("Ask about the next step.",mode:.displayGlasses)
    try await settle()
    center.post(name:AVAudioSession.interruptionNotification,object:nil,
                userInfo:[AVAudioSessionInterruptionTypeKey:AVAudioSession.InterruptionType.ended.rawValue])
    try await settle()
    XCTAssertEqual(synth.stops,0)
    center.post(name:AVAudioSession.interruptionNotification,object:nil,
                userInfo:[AVAudioSessionInterruptionTypeKey:AVAudioSession.InterruptionType.began.rawValue])
    try await settle()
    XCTAssertEqual(synth.stops,1)
  }

  func testZeroVolumeDoesNotConsumeCueAndNewestPendingCueWins() async throws {
    let audio = FakeCueAudioRouting(), synth = RecordingCueSynthesizer()
    let speaker = CueSpeaker(synthesizer:synth,audio:audio,notifications:NotificationCenter())
    defer { speaker.endSession() }
    audio.volume = 0
    speaker.speak("Ask about the old topic.",mode:.displayGlasses)
    try await settle()
    XCTAssertTrue(synth.utterances.isEmpty)
    speaker.speak("Ask about the new topic.",mode:.displayGlasses)
    audio.volume = 0.5
    try await settle()
    XCTAssertEqual(synth.utterances.map(\.speechString),["Ask about the new topic."])
  }
}

@MainActor private final class FakeCueAudioRouting: CueAudioRouting {
  static let glasses = [CueAudioOutput(uid:"glasses",name:"Meta glasses",port:.bluetoothHFP)]
  var outputs = glasses
  var volume: Float = 0.5
  var activations = 0
  func activate(for mode: CaptureMode) throws { activations += 1 }
  func endSession() {}
}

private final class RecordingCueSynthesizer: AVSpeechSynthesizer {
  var utterances: [AVSpeechUtterance] = []
  var stops = 0
  override func speak(_ utterance: AVSpeechUtterance) { utterances.append(utterance) }
  override func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { stops += 1; return true }
}
