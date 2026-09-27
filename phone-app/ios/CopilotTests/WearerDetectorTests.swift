import XCTest
@testable import Copilot

/// A steady tone. Amplitude 8000 is about -15 dBFS and 800 is about -35 dBFS.
private func tone(_ amplitude: Double, ms: Int) -> [Int16] { (0..<(ms * 16)).map { Int16(sin(Double($0) / 5) * amplitude) } }
private func pcm(_ samples: [Int16]) -> Data { samples.withUnsafeBufferPointer { Data(buffer:$0) } }
private let loud = 8000.0, quiet = 800.0

final class SpeechLevelTrackTests: XCTestCase {
  func testMeasuresTheSameSpeechLevelAsAudioChunks() throws {
    let samples = tone(loud, ms:1000) + [Int16](repeating:0, count:8000) + tone(quiet, ms:500)
    var track = SpeechLevelTrack()
    var offset = 0
    for size in [341, 1024, 77, 4000, 9999, 50_000] { // uneven buffers, as a microphone delivers them
      let end = min(samples.count, offset + size)
      track.append(pcm(Array(samples[offset..<end]))); offset = end
    }
    XCTAssertEqual(offset, samples.count)
    XCTAssertEqual(try XCTUnwrap(track.level(fromMs:0, toMs:2000)), ConversationMicrophone.speechLevel(samples), accuracy:1e-9)
  }

  func testReadsEachTurnsOwnLevelByStreamPosition() throws {
    var track = SpeechLevelTrack()
    track.append(pcm(tone(loud, ms:1000) + tone(quiet, ms:1000)))
    let first = try XCTUnwrap(track.level(fromMs:0, toMs:1000)), second = try XCTUnwrap(track.level(fromMs:1000, toMs:2000))
    XCTAssertEqual(first, -15.3, accuracy:0.2)
    XCTAssertEqual(second, -35.3, accuracy:0.2)
    XCTAssertEqual(try XCTUnwrap(track.level(fromMs:1010, toMs:1990)), second, accuracy:0.2, "Positions inside a frame round outward")
  }

  func testSilenceIsTheFloorAndAudioThatIsNotHeldIsUnknown() {
    var track = SpeechLevelTrack()
    XCTAssertNil(track.level(fromMs:0, toMs:1000), "Nothing sent yet")
    track.append(pcm([Int16](repeating:0, count:16_000)))
    XCTAssertEqual(track.level(fromMs:0, toMs:1000), SpeechLevelTrack.floorDbFS, "Audio without a voice is at most the voiced bar")
    XCTAssertEqual(SpeechLevelTrack.floorDbFS, -38.4, accuracy:0.1)
    XCTAssertNil(track.level(fromMs:1000, toMs:2000), "Beyond what was sent")
    XCTAssertNil(track.level(fromMs:0, toMs:60), "Too short to judge")
    XCTAssertNil(track.level(fromMs:nil, toMs:1000))
    XCTAssertNil(track.level(fromMs:500, toMs:500))
    XCTAssertNil(track.level(fromMs:.nan, toMs:1000))
  }

  func testKeepsNinetySecondsOfFramesAndNoAudio() throws {
    var track = SpeechLevelTrack()
    for _ in 0..<100 { track.append(pcm(tone(loud, ms:1000))) }
    XCTAssertNil(track.level(fromMs:0, toMs:1000), "Older frames are dropped")
    XCTAssertNil(track.level(fromMs:9000, toMs:10_000))
    XCTAssertNotNil(track.level(fromMs:10_000, toMs:11_000))
    XCTAssertEqual(try XCTUnwrap(track.level(fromMs:99_000, toMs:100_000)), -15.3, accuracy:0.2)
    XCTAssertLessThanOrEqual(MemoryLayout.size(ofValue:track), 64, "Only frame numbers are stored inline")
  }
}

final class WearerDetectorTests: XCTestCase {
  private func detector(_ turns: [(String?, Double?)]) -> WearerDetector {
    var value = WearerDetector()
    for (label, level) in turns { value.record(label:label, levelDbFS:level) }
    return value
  }

  func testOneVoiceAloneIsNotEnough() {
    let value = detector([("P1", -20), ("P1", -21), ("P1", -19)])
    XCTAssertNil(value.wearerLabel, "Louder than whom? Someone else must have been heard")
    XCTAssertFalse(value.knowsWearer)
  }

  func testTheLoudestVoiceNeedsTwoTurnsAndAClearMargin() {
    var value = detector([("P1", -20), ("P2", -34)])
    XCTAssertNil(value.wearerLabel, "One turn is not consistent yet")
    value.record(label:"P1", levelDbFS:-22)
    XCTAssertEqual(value.wearerLabel, "P1")
    XCTAssertEqual(value.wearerLevelDbFS ?? 0, -21, accuracy:0.001)
    XCTAssertEqual(value.otherLevelDbFS ?? 0, -34, accuracy:0.001)
    XCTAssertTrue(value.knowsWearer)
    XCTAssertFalse(value.claimed)
  }

  func testVoicesOfSimilarLoudnessAreLeftUndecided() {
    var value = detector([("P1", -20), ("P2", -24), ("P1", -21), ("P2", -25)])
    XCTAssertNil(value.wearerLabel, "4 dB is not clearly louder")
    value.record(label:"P3", levelDbFS:-36)
    XCTAssertNil(value.wearerLabel, "Clearly louder than one voice is not louder than the others")
    value.record(label:"P2", levelDbFS:-40); value.record(label:"P2", levelDbFS:-40)
    XCTAssertEqual(value.wearerLabel, "P1", "P2 now averages 11 dB below")
  }

  func testTheSecondLoudestIsNeverChosenWhileTheLoudestHasOneTurn() {
    let value = detector([("P1", -15), ("P2", -30), ("P2", -31), ("P3", -45)])
    XCTAssertNil(value.wearerLabel, "P2 has two turns and is clearly above P3, but P1 is louder")
  }

  func testWhenOthersSpeakFirstTheWearerTakesOverAfterTwoTurns() {
    var value = detector([("P2", -30), ("P2", -31), ("P3", -45)])
    XCTAssertEqual(value.wearerLabel, "P2", "The loudest voice heard so far")
    value.record(label:"P1", levelDbFS:-15)
    XCTAssertEqual(value.wearerLabel, "P2", "One turn is not consistent yet")
    value.record(label:"P1", levelDbFS:-16)
    XCTAssertEqual(value.wearerLabel, "P1")
  }

  func testTheWearerIsKeptThroughALoudTurnFromSomeoneElse() {
    var value = detector([("P1", -20), ("P2", -34), ("P1", -22)])
    value.record(label:"P2", levelDbFS:-12)
    XCTAssertEqual(value.wearerLabel, "P1", "P2 averages -23: not clearly louder than the wearer")
    value.record(label:"P3", levelDbFS:-5)
    XCTAssertEqual(value.wearerLabel, "P1", "One turn is not consistent")
  }

  func testReevaluatesOnlyWhenAnotherVoiceIsConsistentlyLouder() {
    var value = detector([("P1", -30), ("P2", -44), ("P1", -30)])
    XCTAssertEqual(value.wearerLabel, "P1")
    value.record(label:"P3", levelDbFS:-25); value.record(label:"P3", levelDbFS:-25)
    XCTAssertEqual(value.wearerLabel, "P1", "5 dB louder is not clearly louder")
    value.record(label:"P4", levelDbFS:-15)
    XCTAssertEqual(value.wearerLabel, "P1")
    value.record(label:"P4", levelDbFS:-17)
    XCTAssertEqual(value.wearerLabel, "P4", "Two turns, 14 dB above the old wearer")
    XCTAssertEqual(value.wearerLevelDbFS ?? 0, -16, accuracy:0.001)
    XCTAssertEqual(value.otherLevelDbFS ?? 0, -25, accuracy:0.001)
  }

  func testOnlyRecentTurnsAreAveraged() {
    var value = detector([("P1", -20), ("P2", -34), ("P1", -20)])
    for _ in 0..<WearerDetector.recentTurns { value.record(label:"P1", levelDbFS:-30) }
    XCTAssertEqual(value.wearerLevelDbFS ?? 0, -30, accuracy:0.001)
    XCTAssertNil({ var other = value; other.record(label:"P2", levelDbFS:-34); return other.wearerLabel == "P1" ? nil : other.wearerLabel }(), "Still the wearer at 4 dB above")
  }

  func testTurnsWithoutALabelOrALevelAreNotCounted() {
    var value = detector([(nil, -10), ("P1", nil), ("P1", .nan), ("P1", -20), ("P2", -34)])
    XCTAssertNil(value.wearerLabel)
    value.record(label:nil, levelDbFS:-10)
    XCTAssertNil(value.wearerLabel)
    value.record(label:"P1", levelDbFS:-20)
    XCTAssertEqual(value.wearerLabel, "P1")
  }

  func testTheWearerIsKeptForTheSessionWhenCaptionsRestart() {
    var value = detector([("P1", -20), ("P2", -34), ("P1", -22)])
    value.captionsRestarted()
    XCTAssertNil(value.wearerLabel, "Caption labels are numbered afresh")
    XCTAssertTrue(value.knowsWearer)
    XCTAssertEqual(value.wearerBarDbFS ?? 0, -27, accuracy:0.001, "6 dB below the wearer; halfway to the other voice is lower")
    value.record(label:"P1", levelDbFS:-33) // someone else speaks first and gets the first label
    XCTAssertNil(value.wearerLabel)
    value.record(label:"P2", levelDbFS:-19)
    XCTAssertEqual(value.wearerLabel, "P2", "Found again on the wearer's first turn")
    XCTAssertEqual(value.wearerLevelDbFS ?? 0, -19, accuracy:0.001)
    XCTAssertEqual(value.otherLevelDbFS ?? 0, -33, accuracy:0.001)
  }

  func testACloseMarginRaisesTheBarAfterARestart() {
    var value = detector([("P1", -20), ("P2", -26), ("P1", -20)])
    XCTAssertEqual(value.wearerLabel, "P1")
    value.captionsRestarted()
    XCTAssertEqual(value.wearerBarDbFS ?? 0, -23, accuracy:0.001, "Halfway between the two voices")
    value.record(label:"P1", levelDbFS:-24)
    XCTAssertNil(value.wearerLabel)
  }

  func testThatWasMeOverridesAndIsLeftAlone() {
    var value = detector([("P1", -30), ("P2", -12), ("P2", -12), ("P1", -30)])
    XCTAssertEqual(value.wearerLabel, "P2", "Loudness alone picks P2")
    XCTAssertTrue(value.claimLastTurn(), "The wearer says the last turn, from P1, was theirs")
    XCTAssertEqual(value.wearerLabel, "P1")
    XCTAssertTrue(value.claimed)
    value.record(label:"P2", levelDbFS:-12); value.record(label:"P2", levelDbFS:-12)
    XCTAssertEqual(value.wearerLabel, "P1", "An explicit choice is not re-evaluated")
    XCTAssertEqual(value.wearerLevelDbFS ?? 0, -30, accuracy:0.001)
  }

  func testThatWasMeWorksWhileCaptionsAreStopped() {
    var value = detector([("P1", -18)])
    XCTAssertTrue(value.canClaim)
    value.captionsRestarted()
    XCTAssertTrue(value.canClaim, "The last turn's level is remembered")
    XCTAssertTrue(value.claimLastTurn())
    XCTAssertNil(value.wearerLabel)
    XCTAssertTrue(value.knowsWearer)
    XCTAssertEqual(value.wearerBarDbFS ?? 0, -24, accuracy:0.001)
    value.record(label:"P1", levelDbFS:-31)
    XCTAssertNil(value.wearerLabel)
    value.record(label:"P2", levelDbFS:-19)
    XCTAssertEqual(value.wearerLabel, "P2")
  }

  func testNothingToClaimAndReset() {
    var value = WearerDetector()
    XCTAssertFalse(value.canClaim)
    XCTAssertFalse(value.claimLastTurn())
    value.record(label:"P1", levelDbFS:nil)
    XCTAssertTrue(value.claimLastTurn(), "A labeled turn can be claimed even when its level could not be read")
    XCTAssertEqual(value.wearerLabel, "P1")
    value.reset()
    XCTAssertEqual(value, WearerDetector())
  }
}

@MainActor
final class WearerSessionTests: XCTestCase {
  override func setUp() { for key in ["copilot.wearerVoiceDbFS", "copilot.skipWearerWait"] { UserDefaults.standard.removeObject(forKey:key) } }
  override func tearDown() { UserDefaults.standard.removeObject(forKey:"copilot.skipWearerWait") }

  /// Live captions from a scripted relay. Requests fail at the invalid endpoint, so nothing leaves the test.
  /// These sessions wait for the wearer to be detected, which is what the detector is for.
  private func captioningModel(_ relay: LevelRelay) async -> SessionModel {
    let model = SessionModel(people:PeopleStore(fileURL:nil), makeRealtimeRelay:{ _,_ in relay })
    model.skipWearerWait = false
    model.phoneCameraEnabled = false
    model.endpoint = "invalid-endpoint"
    await resume(model)
    return model
  }
  private func resume(_ model: SessionModel) async {
    model.phase = .active
    model.latestAudioContext = AudioContext(capturedAtMs:nowMs(),windowMs:1000,activityRatio:1,rmsDbFS:-20,source:"phone")
    await model.startRealtimeCaptions()
  }
  /// Sends two-second turns of scripted loudness as a microphone would, 100 ms at a time, ending now.
  private func speak(_ model: SessionModel, _ amplitudes: [Double]) {
    let began = nowMs() - Double(amplitudes.count) * 2000
    for (turn, amplitude) in amplitudes.enumerated() {
      let samples = tone(amplitude, ms:2000)
      for part in 0..<20 {
        model.sendRealtimePCM(pcm(Array(samples[(part * 1600)..<((part + 1) * 1600)])), endedAtMs:began + Double(turn) * 2000 + Double(part + 1) * 100)
      }
    }
  }
  /// The finished caption for the scripted two-second turn at `index`.
  private func final(_ id: Int, _ speaker: String?, _ text: String, turn index: Int) -> RealtimeASREvent {
    .init(type:"transcript.final", turnId:id, speaker:speaker, text:text, startAudioMs:Double(index) * 2000 + 100, endAudioMs:Double(index) * 2000 + 1900)
  }

  func testTheWearerIsFoundFromLoudnessWithoutATap() async throws {
    let relay = LevelRelay()
    let model = await captioningModel(relay)
    defer { model.stop() }
    speak(model, [loud, quiet, loud, quiet, loud])
    relay.onEvent?(final(1, "P1", "I started a new job this week.", turn:0))
    relay.onEvent?(final(2, "P2", "Where do you work now?", turn:1))
    XCTAssertNil(model.wearerLabel)
    XCTAssertFalse(model.wearerKnown)
    XCTAssertEqual(model.requests,0,"Until the wearer is found, no question prompts a check")
    relay.onEvent?(final(3, "P1", "At the hospital downtown.", turn:2))
    XCTAssertEqual(model.wearerLabel,"P1","Two loud turns, clearly above the other voice")
    XCTAssertTrue(model.wearerKnown)
    XCTAssertFalse(model.wearerDetector.claimed)
    XCTAssertEqual(try XCTUnwrap(model.transcript[0].levelDbFS), -15.3, accuracy:0.3)
    XCTAssertEqual(try XCTUnwrap(model.transcript[1].levelDbFS), -35.3, accuracy:0.3)
    XCTAssertEqual(model.requests,0,"A statement from the wearer is not a moment")
    relay.onEvent?(final(4, "P2", "Do you like it there?", turn:3))
    XCTAssertEqual(model.requests,1,"Someone else's question now prompts a check")
    relay.onEvent?(final(5, "P1", "Do you want to visit?", turn:4))
    XCTAssertEqual(model.requests,1,"The wearer's own question never does")
    XCTAssertEqual(ConversationPolicy.turns(from:model.transcript, wearerLabel:model.wearerLabel).map(\.speaker), ["wearer", "other", "wearer", "other", "wearer"])
  }

  func testBeforeTheWearerIsFoundOnlyAPhrasePromptsACheck() async throws {
    let relay = LevelRelay()
    let model = await captioningModel(relay)
    defer { model.stop() }
    relay.onEvent?(.init(type:"transcript.final",turnId:1,speaker:"P1",text:"Are you coming tonight?"))
    relay.onEvent?(.init(type:"transcript.final",turnId:2,speaker:"P2",text:"I went to the store."))
    XCTAssertEqual(model.requests,0)
    try await Task.sleep(for:.milliseconds(3300))
    XCTAssertEqual(model.requests,0,"No stuck check either")
    relay.onEvent?(.init(type:"transcript.final",turnId:3,speaker:"P2",text:"It\u{2019}s getting late, should we go?"))
    XCTAssertEqual(model.requests,1,"Explaining a phrase does not depend on who said it")
    XCTAssertTrue(model.isThinking)
  }

  func testAnUnlabeledTurnAtTheWearersLevelIsTheWearers() async {
    let relay = LevelRelay()
    let model = await captioningModel(relay)
    defer { model.stop() }
    speak(model, [loud, quiet, loud, loud, quiet])
    relay.onEvent?(final(1, "P1", "I started a new job this week.", turn:0))
    relay.onEvent?(final(2, "P2", "That is good news.", turn:1))
    relay.onEvent?(final(3, "P1", "At the hospital downtown.", turn:2))
    relay.onEvent?(final(4, nil, "Do you want to visit?", turn:3))
    XCTAssertEqual(model.transcript.last?.speaker,"wearer","The provider gave no label, but the level is the wearer's")
    XCTAssertEqual(model.requests,0)
    relay.onEvent?(final(5, nil, "Is it far from here?", turn:4))
    XCTAssertEqual(model.transcript.last?.speaker,"other")
    XCTAssertEqual(model.requests,1)
  }

  func testTheWearerIsKeptWhenCaptionsRestartAfterAPause() async {
    let relay = LevelRelay()
    let model = await captioningModel(relay)
    defer { model.stop() }
    speak(model, [loud, quiet, loud])
    relay.onEvent?(final(1, "P1", "I started a new job this week.", turn:0))
    relay.onEvent?(final(2, "P2", "That is good news.", turn:1))
    relay.onEvent?(final(3, "P1", "At the hospital downtown.", turn:2))
    XCTAssertEqual(model.wearerLabel,"P1")
    model.pause()
    XCTAssertNil(model.wearerLabel,"Caption labels are numbered afresh after a pause")
    XCTAssertTrue(model.wearerKnown,"The wearer's level is kept for the session")
    await resume(model)
    XCTAssertTrue(model.wearerKnown)
    speak(model, [quiet, loud])
    relay.onEvent?(final(1, "P1", "Are you ready to order?", turn:0)) // the other person speaks first this time
    XCTAssertNil(model.wearerLabel)
    XCTAssertEqual(model.requests,1,"Their question prompts a check at once, with no second detection")
    relay.onEvent?(final(2, "P2", "Yes, are you?", turn:1))
    XCTAssertEqual(model.wearerLabel,"P2","Found again on the wearer's first turn")
    XCTAssertEqual(model.requests,1)
    model.stop()
    XCTAssertFalse(model.wearerKnown,"Stop ends the session")
    XCTAssertEqual(model.wearerDetector, WearerDetector())
  }

  func testThatWasMeCanBeUsedFromSettingsWhilePaused() async {
    let relay = LevelRelay()
    let model = await captioningModel(relay)
    defer { model.stop() }
    speak(model, [loud])
    relay.onEvent?(final(1, "P1", "I started a new job this week.", turn:0))
    XCTAssertFalse(model.wearerKnown,"One voice alone is not enough")
    model.pause()
    XCTAssertTrue(model.canClaimLastLine)
    model.markLastLineAsMine()
    XCTAssertTrue(model.wearerKnown)
    XCTAssertNil(model.wearerLabel)
    await resume(model)
    speak(model, [quiet, loud])
    relay.onEvent?(final(1, "P1", "Are you ready to order?", turn:0))
    XCTAssertEqual(model.requests,1)
    relay.onEvent?(final(2, "P2", "Yes, are you?", turn:1))
    XCTAssertEqual(model.wearerLabel,"P2")
    XCTAssertEqual(model.requests,1)
  }

  func testAudioOfferedBeforeTheCaptionStreamIsReadyIsNotMeasured() async {
    let relay = LevelRelay()
    let model = await captioningModel(relay)
    defer { model.stop() }
    relay.acceptsPCM = false
    speak(model, [loud]) // dropped during the handshake, so it must not shift later positions
    relay.acceptsPCM = true
    speak(model, [quiet, loud])
    relay.onEvent?(final(1, "P2", "That is good news.", turn:0))
    relay.onEvent?(final(2, "P1", "At the hospital downtown.", turn:1))
    XCTAssertEqual(model.transcript.map { ($0.levelDbFS ?? 0).rounded() }, [-35, -15])
  }

  func testTheFoundLevelAlsoSortsFallbackCaptions() async {
    let relay = LevelRelay()
    let model = await captioningModel(relay)
    defer { model.stop() }
    XCTAssertNil(model.speaker(forLevel:-16),"Unknown until the wearer is found")
    speak(model, [loud, quiet, loud])
    relay.onEvent?(final(1, "P1", "I started a new job this week.", turn:0))
    relay.onEvent?(final(2, "P2", "That is good news.", turn:1))
    relay.onEvent?(final(3, "P1", "At the hospital downtown.", turn:2))
    relay.onFailure?("Disconnected")
    XCTAssertTrue(model.speechMode.contains("Chunked fallback"))
    XCTAssertTrue(model.wearerKnown)
    XCTAssertEqual(model.speaker(forLevel:-16),"wearer")
    XCTAssertEqual(model.speaker(forLevel:-36),"other")
  }
}

@MainActor private final class LevelRelay: PhoneCaptionRelay {
  var onEvent: ((RealtimeASREvent) -> Void)?
  var onFailure: ((String) -> Void)?
  var acceptsPCM = true
  func start(languageBias: [String]) async throws {}
  func sendPCM(_ data: Data) {}
  func stop() {}
}
