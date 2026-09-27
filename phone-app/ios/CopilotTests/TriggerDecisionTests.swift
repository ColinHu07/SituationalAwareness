import XCTest
@testable import Copilot

final class TriggerDecisionTests: XCTestCase {
  private func decide(_ text: String, role: String = "other", wearerKnown: Bool = true, sceneChecks: Bool = false, active: Bool = true,
                      newest: Bool = true, early: SpeculativeCue.Outcome = .none) -> TriggerDecision {
    .forTurn(text:text, role:role, wearerKnown:wearerKnown, sceneChecks:sceneChecks, active:active, newest:newest, early:early)
  }

  func testAQuestionOrAPhraseIsSentAndSilenceIsWaitedFor() {
    XCTAssertEqual(decide("Where do you study?"), .init(trigger:.question, stuck:true, note:"question: the turn ends in a question mark"))
    XCTAssertEqual(decide("Well, it\u{2019}s getting late."), .init(trigger:.indirect, stuck:true, note:"indirect: the turn has an indirect phrase"))
    XCTAssertEqual(decide("I went to the store."), .init(trigger:nil, stuck:true, note:"none: not a question or an indirect phrase; stuck check after 3 s of silence"))
  }

  func testEveryReasonForNotAskingIsNamed() {
    XCTAssertEqual(decide("Where do you study?", role:"wearer"), .init(trigger:nil, stuck:false, note:"none: turn was the wearer's"))
    XCTAssertEqual(decide("Where do you study?", sceneChecks:true), .init(trigger:nil, stuck:false, note:"none: scene checks are on, which run on a timer"))
    XCTAssertEqual(decide("Where do you study?", active:false), .init(trigger:nil, stuck:false, note:"none: the session is not active"))
    XCTAssertEqual(decide("Where do you study?", newest:false), .init(trigger:nil, stuck:false, note:"none: a newer turn was already heard"))
    XCTAssertEqual(decide("Where do you study?", wearerKnown:false),
                   .init(trigger:nil, stuck:false, note:"question skipped: wearer not detected yet; stuck skipped: wearer not detected yet"))
    XCTAssertEqual(decide("I went to the store.", wearerKnown:false),
                   .init(trigger:nil, stuck:false, note:"none: not a question or an indirect phrase; stuck skipped: wearer not detected yet"))
    XCTAssertEqual(decide("Well, it\u{2019}s getting late.", wearerKnown:false), .init(trigger:.indirect, stuck:false, note:"indirect: the turn has an indirect phrase"),
                   "A phrase is explained whoever said it")
    XCTAssertEqual(decide("It\u{2019}s getting late, should we go?", wearerKnown:false).trigger, .indirect)
  }

  func testAnEarlyCheckChangesWhatTheFinishedTurnAsks() {
    XCTAssertEqual(decide("Where do you study?", early:.keep),
                   .init(trigger:nil, stuck:true, note:"question skipped: already checked early with the same words; stuck check after 3 s of silence"))
    XCTAssertEqual(decide("Where do you study these days", early:.rerun), .init(trigger:.question, stuck:true, note:"question: the words changed since the early check"))
    XCTAssertEqual(decide("What a day that was.", early:.withdraw).trigger, nil)
    XCTAssertEqual(decide("Where do you study?", role:"wearer", early:.withdraw).note, "none: turn was the wearer's")
  }

  func testTheGateNamesWhatStopsACheckInTheOrderItIsTested() {
    XCTAssertNil(CueGate().skip(for:.question))
    XCTAssertNil(CueGate(sinceStartMs:1500, sinceDismissMs:10_000).skip(for:.question))
    XCTAssertEqual(CueGate(uploadsDisabled:true, active:false).skip(for:.question), "uploads are off (offline or capture test)")
    XCTAssertEqual(CueGate(active:false, checkInFlight:true).skip(for:.question), "the session is not active")
    XCTAssertEqual(CueGate(checkInFlight:true, inputIssue:"Waiting for live microphone audio.").skip(for:.question), "check in flight")
    XCTAssertEqual(CueGate(inputIssue:"Waiting for fresh phone camera frames.", hasSpeech:false).skip(for:.indirect), "input not live: Waiting for fresh phone camera frames.")
    XCTAssertEqual(CueGate(hasSpeech:false, sinceStartMs:100).skip(for:.question), "no clear speech to send")
    XCTAssertEqual(CueGate(sinceStartMs:1499, sinceDismissMs:0).skip(for:.question), "session started under 1.5 s ago")
    XCTAssertEqual(CueGate(sinceDismissMs:3_800).skip(for:.question), "dismiss quiet period, 6.2 s left")
  }

  func testOnlySilenceIsStoppedByACueThatIsAlreadyShowing() {
    XCTAssertEqual(CueGate(cueShowing:true).skip(for:.stuck), "cue already showing")
    XCTAssertEqual(CueGate(checkInFlight:true, cueShowing:true).skip(for:.stuck), "cue already showing")
    XCTAssertEqual(CueGate(checkInFlight:true).skip(for:.stuck), "check in flight")
    XCTAssertNil(CueGate(cueShowing:true).skip(for:.question), "A new question replaces the cue on screen")
    XCTAssertNil(CueGate(cueShowing:true).skip(for:.indirect))
  }

  func testVoiceLevelsAreListedWithoutAnyWords() {
    var detector = WearerDetector()
    XCTAssertEqual(detector.levelsNote, "no labeled voice with a level yet")
    detector.record(label:"P2", levelDbFS:-35.2)
    detector.record(label:"P1", levelDbFS:-15)
    detector.record(label:nil, levelDbFS:-20)
    detector.record(label:"P3", levelDbFS:nil)
    XCTAssertEqual(detector.levelsNote, "P1 -15 dBFS ×1, P2 -35 dBFS ×1")
    XCTAssertNil(detector.wearerLabel, "One loud turn is not enough")
    detector.record(label:"P1", levelDbFS:-17)
    XCTAssertEqual(detector.levelsNote, "P1 -16 dBFS ×2, P2 -35 dBFS ×1")
    XCTAssertEqual(detector.wearerLabel, "P1")
  }

  @MainActor func testTriggerDecisionsAreInTheLogAndTheSummary() {
    let diagnostics = CaptionDiagnostics()
    diagnostics.reset()
    XCTAssertTrue(diagnostics.summary.contains("Last trigger: —"))
    diagnostics.trigger("question skipped: wearer not detected yet", turn:4)
    XCTAssertTrue(diagnostics.summary.contains("Last trigger: question skipped: wearer not detected yet (turn=4)"), diagnostics.summary)
    XCTAssertTrue(diagnostics.exportText.contains("Trigger turn=4: question skipped: wearer not detected yet"))
    diagnostics.trigger("stuck sent", turn:nil)
    XCTAssertTrue(diagnostics.summary.contains("Last trigger: stuck sent\n"), diagnostics.summary)
    XCTAssertTrue(diagnostics.exportText.contains("  Trigger: stuck sent"))
    diagnostics.reset()
    XCTAssertTrue(diagnostics.summary.contains("Last trigger: —"))
  }
}

@MainActor
final class TriggerSessionTests: XCTestCase {
  override func setUp() { for key in ["copilot.wearerVoiceDbFS", "copilot.skipWearerWait"] { UserDefaults.standard.removeObject(forKey:key) } }
  override func tearDown() { UserDefaults.standard.removeObject(forKey:"copilot.skipWearerWait") }

  /// Live captions from a scripted relay. Requests fail at the invalid endpoint, so nothing leaves the test.
  private func liveModel(_ relay: DecisionRelay, waitForWearer: Bool? = nil) async -> SessionModel {
    let model = SessionModel(people:PeopleStore(fileURL:nil), makeRealtimeRelay:{ _,_ in relay })
    if let waitForWearer { model.skipWearerWait = !waitForWearer }
    model.phoneCameraEnabled = false
    model.endpoint = "invalid-endpoint"
    model.phase = .active
    model.latestAudioContext = AudioContext(capturedAtMs:nowMs(),windowMs:1000,activityRatio:1,rmsDbFS:-20,source:"phone")
    await model.startRealtimeCaptions()
    return model
  }
  /// The same captions answered by the local scripted model, so cues reach the screen.
  private func scriptedModel(_ relay: DecisionRelay) async -> SessionModel {
    let model = SessionModel(people:PeopleStore(fileURL:nil), makeRealtimeRelay:{ _,_ in relay })
    model.simulate = true; model.localMock = true
    model.phase = .active
    await model.startRealtimeCaptions()
    return model
  }
  private func final(_ turn: Int, _ speaker: String?, _ text: String) -> RealtimeASREvent { .init(type:"transcript.final",turnId:turn,speaker:speaker,text:text) }
  private func log(_ model: SessionModel) -> [String] {
    model.captionDiagnostics.entries.map(\.line).filter { $0.contains("  Trigger") }.map { String($0[$0.range(of:"Trigger")!.lowerBound...]) }
  }

  func testNotWaitingIsTheDefaultAndTheChoiceIsKept() {
    XCTAssertTrue(SessionModel(people:PeopleStore(fileURL:nil)).skipWearerWait)
    let model = SessionModel(people:PeopleStore(fileURL:nil))
    model.skipWearerWait = false
    XCTAssertFalse(SessionModel(people:PeopleStore(fileURL:nil)).skipWearerWait, "Kept for the next launch")
    model.skipWearerWait = true
    XCTAssertTrue(SessionModel(people:PeopleStore(fileURL:nil)).skipWearerWait)
  }

  func testWithoutWaitingEveryMomentPromptsACheckBeforeTheWearerIsFound() async throws {
    let relay = DecisionRelay(), model = await liveModel(relay)
    defer { model.stop() }
    XCTAssertFalse(model.wearerKnown)
    XCTAssertEqual(model.voiceLine, "Your voice: learning")
    relay.onEvent?(final(1,"P2","Where do you study?"))
    XCTAssertEqual(model.requests,1,"A question, with nobody detected yet")
    relay.onEvent?(final(2,"P1","I went to the store."))
    XCTAssertEqual(model.requests,1)
    try await Task.sleep(for:.milliseconds(3300))
    XCTAssertEqual(model.requests,2,"Silence after a statement")
    relay.onEvent?(final(3,nil,"Well, it\u{2019}s getting late."))
    XCTAssertEqual(model.requests,3,"A phrase from an unlabeled voice")
    XCTAssertFalse(model.wearerKnown,"Nothing here detected the wearer")
    let lines = log(model)
    XCTAssertEqual(lines.filter { $0.hasSuffix("sent") }, ["Trigger turn=1: question sent", "Trigger turn=2: stuck sent", "Trigger turn=3: indirect sent"], lines.joined(separator:"\n"))
    XCTAssertTrue(lines.contains { $0.hasPrefix("Trigger turn=2: none: not a question or an indirect phrase; stuck check after 3 s of silence; voices: ") }, lines.joined(separator:"\n"))
    XCTAssertTrue(model.captionDiagnostics.summary.contains("Last trigger: indirect sent (turn=3)"))
  }

  func testWaitingSkipsQuestionsAndSilenceAndSaysWhy() async throws {
    let relay = DecisionRelay(), model = await liveModel(relay, waitForWearer:true)
    defer { model.stop() }
    relay.onEvent?(final(1,"P2","Where do you study?"))
    relay.onEvent?(final(2,"P1","I went to the store."))
    try await Task.sleep(for:.milliseconds(3300))
    XCTAssertEqual(model.requests,0)
    let lines = log(model)
    XCTAssertEqual(lines.count,2)
    XCTAssertTrue(lines[0].hasPrefix("Trigger turn=1: question skipped: wearer not detected yet; stuck skipped: wearer not detected yet; voices: "), lines[0])
    XCTAssertTrue(lines[1].hasPrefix("Trigger turn=2: none: not a question or an indirect phrase; stuck skipped: wearer not detected yet; voices: "), lines[1])
    XCTAssertTrue(model.captionDiagnostics.summary.contains("Last trigger: none: not a question or an indirect phrase; stuck skipped: wearer not detected yet"))
  }

  func testATurnMatchedToTheWearerNeverPromptsACheckEitherWay() async throws {
    for waitForWearer in [false, true] {
      let relay = DecisionRelay(), model = await liveModel(relay, waitForWearer:waitForWearer)
      defer { model.stop() }
      relay.onEvent?(final(1,"P1","Hello there."))
      model.markLastLineAsMine()
      XCTAssertEqual(model.voiceLine, "Your voice: learned")
      relay.onEvent?(final(2,"P1","What do you think?"))
      try await Task.sleep(for:.milliseconds(3300))
      XCTAssertEqual(model.requests,0,"waitForWearer \(waitForWearer)")
      XCTAssertTrue(log(model).contains("Trigger turn=2: none: turn was the wearer's"), log(model).joined(separator:"\n"))
      if !waitForWearer { XCTAssertTrue(log(model).contains("Trigger turn=1: stuck skipped: cancelled by new speech, a dismissal or That was me")) }
      relay.onEvent?(final(3,"P2","Sure, where should we go?"))
      XCTAssertEqual(model.requests,1)
      XCTAssertEqual(log(model).last, "Trigger turn=3: question sent")
    }
  }

  func testACheckStoppedByTheGateSaysWhich() async throws {
    let relay = DecisionRelay(), model = await liveModel(relay)
    defer { model.stop() }
    model.dismiss()
    relay.onEvent?(final(1,"P2","Where do you study?"))
    XCTAssertEqual(model.requests,0)
    XCTAssertTrue(log(model).last?.hasPrefix("Trigger turn=1: question skipped: dismiss quiet period, ") == true, log(model).joined(separator:"\n"))
    model.latestAudioContext = nil
    relay.onEvent?(final(2,"P2","Are you coming tonight?"))
    XCTAssertEqual(model.requests,0)
    XCTAssertEqual(log(model).last, "Trigger turn=2: question skipped: input not live: Waiting for live microphone audio.")
    model.connectionTestOnly = true
    relay.onEvent?(final(3,"P2","Did you eat yet?"))
    XCTAssertEqual(log(model).last, "Trigger turn=3: question skipped: uploads are off (offline or capture test)")
  }

  func testSilenceSaysWhenACueOrNewSpeechMadeItUnnecessary() async throws {
    let relay = DecisionRelay(), model = await scriptedModel(relay)
    defer { model.stop() }
    relay.onEvent?(final(1,"P2","Would you like that hot or iced?"))
    XCTAssertEqual(log(model), ["Trigger turn=1: question sent"])
    try await Task.sleep(for:.milliseconds(3300))
    XCTAssertEqual(model.requests,1)
    XCTAssertEqual(log(model).last, "Trigger turn=1: stuck skipped: cue already showing")
    relay.onEvent?(final(2,"P2","The sky is blue."))
    try await Task.sleep(for:.milliseconds(500))
    relay.onEvent?(.init(type:"transcript.partial",turnId:3,speaker:"P3",text:"I mean"))
    try await Task.sleep(for:.milliseconds(100))
    XCTAssertEqual(log(model).last, "Trigger turn=2: stuck skipped: cancelled by new speech, a dismissal or That was me")
    XCTAssertEqual(model.requests,1)
  }

  func testWithoutWaitingALabeledQuestionIsCheckedEarly() async throws {
    let relay = DecisionRelay(), model = await scriptedModel(relay)
    defer { model.stop() }
    XCTAssertNil(model.wearerLabel)
    relay.onEvent?(.init(type:"transcript.partial",turnId:1,speaker:nil,text:"Would you like that hot or iced"))
    try await Task.sleep(for:.milliseconds(380))
    XCTAssertEqual(model.requests,0,"An unlabeled partial still waits for its label")
    relay.onEvent?(.init(type:"speaker.updated",turnId:1,speaker:"P2"))
    try await Task.sleep(for:.milliseconds(50))
    XCTAssertEqual(model.requests,1)
    model.skipWearerWait = false
    relay.onEvent?(.init(type:"transcript.partial",turnId:2,speaker:"P2",text:"Can you have that ready by Friday"))
    try await Task.sleep(for:.milliseconds(380))
    XCTAssertEqual(model.requests,1,"Waiting for the wearer: no early check until their label is known")
  }

  func testLogsNeverIncludeWhatWasSaid() async throws {
    let relay = DecisionRelay(), model = await liveModel(relay)
    defer { model.stop() }
    relay.onEvent?(final(1,"P2","Where do you study?"))
    relay.onEvent?(final(2,"P2","I went to the PRIVATE store."))
    let export = model.captionDiagnostics.exportText
    XCTAssertFalse(export.contains("study") || export.contains("PRIVATE"))
  }
}

@MainActor private final class DecisionRelay: PhoneCaptionRelay {
  var onEvent: ((RealtimeASREvent) -> Void)?
  var onFailure: ((String) -> Void)?
  func start(languageBias: [String]) async throws {}
  func sendPCM(_ data: Data) {}
  func stop() {}
}
