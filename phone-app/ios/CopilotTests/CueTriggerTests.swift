import XCTest
@testable import Copilot

final class IndirectPhraseTests: XCTestCase {
  func testListStartsWithAboutTwentyCommonPhrasesInMatchingForm() {
    XCTAssertTrue((18...30).contains(IndirectPhrases.all.count))
    for phrase in ["it's getting late", "we should hang out sometime", "no worries"] {
      XCTAssertTrue(IndirectPhrases.all.contains(phrase), phrase)
    }
    XCTAssertEqual(Set(IndirectPhrases.all).count, IndirectPhrases.all.count, "No duplicates")
    for phrase in IndirectPhrases.all { XCTAssertEqual(IndirectPhrases.normalize(phrase), phrase, "Stored the way it is matched") }
  }

  func testMatchingIgnoresCasePunctuationAndCurlyApostrophes() {
    XCTAssertEqual(IndirectPhrases.match(in:"Well, it\u{2019}s getting late!"), "it's getting late")
    XCTAssertEqual(IndirectPhrases.match(in:"NO WORRIES."), "no worries")
    XCTAssertEqual(IndirectPhrases.match(in:"Yeah \u{2014} we should hang out   sometime, okay"), "we should hang out sometime")
    XCTAssertEqual(IndirectPhrases.match(in:"Would you mind closing the door"), "would you mind")
  }

  func testMatchingNeedsWholeWords() {
    XCTAssertNil(IndirectPhrases.match(in:"It's getting later every year"))
    XCTAssertNil(IndirectPhrases.match(in:"Snow worries me"))
    XCTAssertNil(IndirectPhrases.match(in:"The train leaves at eight."))
    XCTAssertNil(IndirectPhrases.match(in:""))
  }
}

final class ConversationPolicyTests: XCTestCase {
  private func result(_ cue: String, confidence: Double = 0.9, type: String = "respond", display: Bool = true) -> CueResult {
    CueResult(cue:cue, reason:"They asked where you study.", confidence:confidence, type:type, should_display:display)
  }

  func testAQuestionComesBeforeAnIndirectPhraseAndStatementsWait() {
    XCTAssertEqual(ConversationPolicy.trigger(for:"Where do you study?"), .question)
    XCTAssertEqual(ConversationPolicy.trigger(for:"She asked, \u{201C}are you coming?\u{201D} "), .question)
    XCTAssertEqual(ConversationPolicy.trigger(for:"आप कहाँ पढ़ते हैं\u{FF1F}"), .question)
    XCTAssertEqual(ConversationPolicy.trigger(for:"It's getting late, should we go?"), .question)
    XCTAssertEqual(ConversationPolicy.trigger(for:"Well, it's getting late."), .indirect)
    XCTAssertNil(ConversationPolicy.trigger(for:"Is it? I think so."), "Only the end of the turn counts")
    XCTAssertNil(ConversationPolicy.trigger(for:"I went to the store."))
  }

  func testUntilTheWearerIsKnownOnlyAPhraseCounts() {
    XCTAssertNil(ConversationPolicy.trigger(for:"Where do you study?", wearerKnown:false), "A question could be the wearer's own")
    XCTAssertEqual(ConversationPolicy.trigger(for:"Well, it's getting late.", wearerKnown:false), .indirect)
    XCTAssertEqual(ConversationPolicy.trigger(for:"It's getting late, should we go?", wearerKnown:false), .indirect)
    XCTAssertEqual(ConversationPolicy.trigger(for:"It's getting late, should we go?", wearerKnown:true), .question)
  }

  func testLiveCaptionLabelsBecomeWearerOrOther() {
    XCTAssertEqual(ConversationPolicy.role("P2", wearerLabel:"P2"), "wearer")
    XCTAssertEqual(ConversationPolicy.role("P1", wearerLabel:"P2"), "other")
    XCTAssertEqual(ConversationPolicy.role("wearer", wearerLabel:nil), "wearer", "Voice-level labels are kept")
    XCTAssertEqual(ConversationPolicy.role("P1", wearerLabel:nil), "other", "Until the wearer says which voice is theirs")
    XCTAssertEqual(ConversationPolicy.role(nil, wearerLabel:"P2"), "other")
  }

  func testOnlyTheLastEightReliableTurnsAreSentOldestFirst() throws {
    XCTAssertEqual(ConversationPolicy.turnCount, 8)
    var lines: [TranscriptEntry] = (1...7).map { .init(text:"Line \($0)", startMs:Double($0), endMs:Double($0) + 0.5, confidence:nil, speaker:$0 % 2 == 0 ? "P2" : "P1") }
    lines += [
      .init(text:"Mumble", startMs:8, endMs:8.5, confidence:0.2, speaker:"P1"),
      .init(text:"Eight", startMs:9, endMs:9.5, confidence:nil, speaker:nil),
      .init(text:"Nine?", startMs:10, endMs:10.5, confidence:0.9, speaker:"P1"),
    ]
    let turns = ConversationPolicy.turns(from:lines, wearerLabel:"P2")
    XCTAssertEqual(turns.map(\.text), ["Line 2", "Line 3", "Line 4", "Line 5", "Line 6", "Line 7", "Eight", "Nine?"], "The oldest line and the unclear one are left out")
    XCTAssertEqual(turns.map(\.speaker), ["wearer", "other", "wearer", "other", "wearer", "other", "other", "other"])
    XCTAssertEqual(turns.last?.id, lines.last?.id, "The newest turn is last, and relabeling keeps its identity")
    XCTAssertEqual(ConversationPolicy.turns(from:Array(lines.prefix(2)), wearerLabel:"P2").map(\.text), ["Line 1", "Line 2"], "A short conversation is sent whole")
    let request = CueRequest(transcript:turns, frame:nil, context:[], manual:false, analysisMode:"conversation",
                             recentMoments:ConversationPolicy.summary(from:[Moment(atMs:1_000, summary:"Ordering coffee."), Moment(atMs:50_000, summary:"Catching up about school.")], at:60_000),
                             trigger:CueTrigger.question.rawValue, aboutMe:ConversationPolicy.aboutMe("  I study CS at Tech. ", for:.question))
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(request)) as? [String:Any])
    XCTAssertEqual(body["trigger"] as? String, "question")
    XCTAssertEqual(body["aboutMe"] as? String, "I study CS at Tech.")
    XCTAssertNil(body["frame"], "Conversation checks send text only")
    let speakers = try XCTUnwrap(body["transcript"] as? [[String:Any]]).map { $0["speaker"] as? String }
    XCTAssertEqual(speakers, turns.map(\.speaker), "No live-caption labels reach the server")
    XCTAssertEqual(try XCTUnwrap(body["recentMoments"] as? [[String:Any]]).map { $0["summary"] as? String }, ["Catching up about school."])
  }

  func testOnlyTheMostRecentSummaryIsSentAndOnlyWhileItIsRecent() {
    let moments = [Moment(atMs:100_000, summary:"Ordering coffee."), Moment(atMs:400_000, summary:"Catching up about school.")]
    XCTAssertEqual(ConversationPolicy.summary(from:moments, at:410_000), [moments[1]])
    XCTAssertEqual(ConversationPolicy.summary(from:moments, at:700_000), [moments[1]], "Five minutes old")
    XCTAssertEqual(ConversationPolicy.summary(from:moments, at:700_001), [], "Too old to say what the talk is about now")
    XCTAssertEqual(ConversationPolicy.summary(from:moments, at:390_000), [], "Not from the future")
    XCTAssertEqual(ConversationPolicy.summary(from:[], at:410_000), [])
  }

  func testSceneRequestsCarryNoTriggerOrAboutMe() throws {
    XCTAssertNil(ConversationPolicy.aboutMe("I study CS at Tech.", for:nil))
    XCTAssertNil(ConversationPolicy.aboutMe("   ", for:.manual))
    XCTAssertEqual(ConversationPolicy.aboutMe(String(repeating:"x", count:900), for:.stuck)?.count, 500)
    let hindi = ConversationPolicy.aboutMe(String(repeating:"क्षि", count:400), for:.stuck)
    XCTAssertEqual(hindi?.utf16.count, 500, "Clipped by the server's measure, on a whole character")
    XCTAssertEqual(hindi?.count, 125)
    let request = CueRequest(transcript:[], frame:nil, context:[], manual:false, analysisMode:"surroundings")
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(request)) as? [String:Any])
    XCTAssertNil(body["trigger"]); XCTAssertNil(body["aboutMe"])
  }

  func testConversationCuesNeedConfidenceOfPointEight() {
    XCTAssertEqual(ConversationPolicy.displayText(for:result(" Say you study CS at Tech. ", confidence:0.8), trigger:.question), "Say you study CS at Tech.")
    XCTAssertNil(ConversationPolicy.displayText(for:result("Say you study CS at Tech.", confidence:0.79), trigger:.question))
    XCTAssertNil(ConversationPolicy.displayText(for:result("Say you study CS at Tech.", confidence:0.79), trigger:.stuck))
    XCTAssertEqual(ConversationPolicy.displayText(for:result("This looks like a library.", confidence:0.6, type:"reminder"), trigger:nil),
                   "This looks like a library.", "Scene cues keep their own bar")
    XCTAssertNil(ConversationPolicy.displayText(for:result("This looks like a library.", confidence:0.59, type:"reminder"), trigger:nil))
  }

  func testMeaningIsAKnownTypeAndMalformedCuesAreNotShown() {
    XCTAssertEqual(ConversationPolicy.displayText(for:result("Often means: they may want to wrap up.", type:"meaning"), trigger:.indirect),
                   "Often means: they may want to wrap up.")
    XCTAssertNil(ConversationPolicy.displayText(for:result("Be yourself.", type:"advice"), trigger:.stuck))
    XCTAssertNil(ConversationPolicy.displayText(for:result("", type:"abstain", display:false), trigger:.question))
    XCTAssertNil(ConversationPolicy.displayText(for:result(String(repeating:"word ", count:15)), trigger:.question))
    XCTAssertNil(ConversationPolicy.displayText(for:result(String(repeating:"x", count:91)), trigger:.question))
    XCTAssertNil(ConversationPolicy.displayText(for:result("Say hello.", confidence:.nan), trigger:.question))
  }

  func testAnExplicitRequestAlwaysGetsAnAnswer() {
    XCTAssertEqual(ConversationPolicy.displayText(for:result("", confidence:0, type:"abstain", display:false), trigger:.manual), "Nothing to add")
    XCTAssertEqual(ConversationPolicy.displayText(for:result("nothing to add.", confidence:0.3, type:"abstain"), trigger:.manual), "Nothing to add")
    XCTAssertEqual(ConversationPolicy.displayText(for:result("Ask about the trip.", confidence:0.5), trigger:.manual), "Nothing to add",
                   "A low-confidence line is not shown, even when asked")
    XCTAssertEqual(ConversationPolicy.displayText(for:result("Ask about the trip."), trigger:.manual), "Ask about the trip.")
    XCTAssertNil(ConversationPolicy.displayText(for:result("Nothing to add"), trigger:.stuck), "Unasked, there is nothing to show")
  }
}

@MainActor
final class CueTriggerTests: XCTestCase {
  override func setUp() { UserDefaults.standard.removeObject(forKey:"copilot.wearerVoiceDbFS") }

  /// A simulated session that is already past the 1.5 s start-up wait, so moments can fire.
  private func activeModel() async throws -> SessionModel {
    let model = SessionModel(people:PeopleStore(fileURL:nil))
    model.simulate = true; model.localMock = true; model.consent = true
    model.start()
    try await Task.sleep(for:.milliseconds(1700))
    XCTAssertEqual(model.phase,.active)
    return model
  }

  /// Live captions from a scripted relay. Requests fail at the invalid endpoint, so nothing leaves the test.
  private func captioningModel(_ relay: TriggerRelay) async -> SessionModel {
    let model = SessionModel(people:PeopleStore(fileURL:nil), makeRealtimeRelay:{ _,_ in relay })
    model.phoneCameraEnabled = false
    model.endpoint = "invalid-endpoint"
    model.phase = .active
    model.latestAudioContext = AudioContext(capturedAtMs:nowMs(),windowMs:1000,activityRatio:1,rmsDbFS:-20,source:"phone")
    await model.startRealtimeCaptions()
    return model
  }

  func testAQuestionFromSomeoneElseIsAnsweredAtOnce() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.addSimulationLine("Would you like that hot or iced?")
    XCTAssertEqual(model.requests,1,"No timer: the finished question is the moment")
    XCTAssertTrue(model.isThinking)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"They asked whether you want it hot or iced.")
    try await Task.sleep(for:.milliseconds(3000))
    XCTAssertEqual(model.requests,1,"With a cue on screen, silence does not ask again")
  }

  func testAnIndirectPhraseGetsItsUsualMeaning() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.addSimulationLine("Well, it\u{2019}s getting late.")
    XCTAssertEqual(model.requests,1)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"Often means: they may want to wrap up.")
  }

  func testSilenceAfterSomeoneElseSpeaksAsksAfterThreeSeconds() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.addSimulationLine("My robotics project is going well.")
    XCTAssertEqual(model.requests,0,"A statement waits")
    try await Task.sleep(for:.milliseconds(2500))
    XCTAssertEqual(model.requests,0,"Not before 3 seconds")
    try await Task.sleep(for:.milliseconds(800))
    XCTAssertEqual(model.requests,1)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"Ask how their robotics project is going.")
  }

  func testTheWearerAnsweringMeansNobodyIsStuck() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.addSimulationLine("My robotics project is going well.")
    try await Task.sleep(for:.milliseconds(1500))
    model.addSimulationLine("That sounds fun.", speaker:"wearer")
    try await Task.sleep(for:.milliseconds(3500))
    XCTAssertEqual(model.requests,0)
    XCTAssertNil(model.cue)
  }

  func testTheWearersOwnTurnsNeverPromptACheck() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.addSimulationLine("Can you have it ready by Friday?", speaker:"wearer")
    model.addSimulationLine("Honestly, it\u{2019}s getting late.", speaker:"wearer")
    XCTAssertEqual(model.requests,0)
    try await Task.sleep(for:.milliseconds(3500))
    XCTAssertEqual(model.requests,0,"Not a question, not a phrase, and not silence after the wearer")
    XCTAssertNil(model.cue)
  }

  func testConversationChecksNeverRunOnATimer() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.transcript = [TranscriptEntry(text:"The train leaves at eight.", startMs:nowMs()-2000, endMs:nowMs()-1000, confidence:nil)]
    model.requestCue(manual:false)
    try await Task.sleep(for:.milliseconds(2300)) // two passes of the one-second session loop
    XCTAssertEqual(model.requests,0)
  }

  func testAnExplicitRequestIsDroppedByNewSpeechAndSaysSo() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.transcript = [TranscriptEntry(text:"The train leaves at eight.", startMs:nowMs()-2000, endMs:nowMs()-1000, confidence:nil)]
    model.requestCue(manual:true)
    XCTAssertTrue(model.isThinking)
    model.addSimulationLine("Anyway, lunch was good.")
    XCTAssertFalse(model.isThinking)
    XCTAssertEqual(model.analysisFeedback,"New speech. Analyze after a pause.")
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertNil(model.cue)
  }

  func testNothingToAddNeverReplacesACueThatIsShowing() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.addSimulationLine("Would you like that hot or iced?")
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"They asked whether you want it hot or iced.")
    model.addSimulationLine("Let me think.", speaker:"wearer")
    model.requestCue(manual:true)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"They asked whether you want it hot or iced.")
    XCTAssertEqual(model.shown,1)
    XCTAssertEqual(model.requests,2)
  }

  func testAnExplicitRequestWaitsBehindAnAutomaticCheckAndIsAnsweredByItsCue() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.addSimulationLine("Would you like that hot or iced?")
    model.requestCue(manual:true)
    XCTAssertNotNil(model.pendingManualAnalysisAt,"Not lost while the automatic check is in flight")
    XCTAssertEqual(model.requests,1)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"They asked whether you want it hot or iced.")
    XCTAssertNil(model.pendingManualAnalysisAt)
    try await Task.sleep(for:.milliseconds(1500))
    XCTAssertEqual(model.requests,1,"The cue already answered the request")
  }

  func testAnExplicitRequestMayLookBackOverTheRollingTranscript() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.transcript = [TranscriptEntry(text:"Tell me about your robotics project.", startMs:nowMs()-42000, endMs:nowMs()-40000, confidence:nil)]
    model.requestCue(manual:true)
    XCTAssertEqual(model.requests,1)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"Ask how their robotics project is going.")
  }

  func testThatWasMeIsAnOverrideForLiveCaptions() async {
    let relay = TriggerRelay()
    let model = await captioningModel(relay)
    defer { model.stop() }
    let voiceLevel = model.wearerVoiceDbFS
    XCTAssertFalse(model.canClaimLastLine)
    relay.onEvent?(.init(type:"transcript.partial",turnId:1,speaker:"P1",text:"Well, it is"))
    XCTAssertFalse(model.canClaimLastLine,"Only a finished turn can be claimed")
    relay.onEvent?(.init(type:"transcript.final",turnId:1,speaker:"P1",text:"Well, it\u{2019}s getting late."))
    XCTAssertEqual(model.requests,1,"A phrase is explained before the wearer's voice is known")
    XCTAssertTrue(model.isThinking)
    XCTAssertTrue(model.canClaimLastLine)
    model.markLastLineAsMine()
    XCTAssertEqual(model.wearerLabel,"P1")
    XCTAssertTrue(model.wearerDetector.claimed)
    XCTAssertTrue(model.wearerKnown)
    XCTAssertEqual(model.wearerVoiceDbFS,voiceLevel,"Claiming a caption label leaves the saved voice level alone")
    XCTAssertFalse(model.isThinking,"Help being prepared for the wearer's own line is dropped")
    relay.onEvent?(.init(type:"transcript.final",turnId:2,speaker:"P1",text:"What do you think?"))
    XCTAssertEqual(model.requests,1,"The wearer's own question never prompts a check")
    relay.onEvent?(.init(type:"transcript.final",turnId:3,speaker:"P2",text:"Sure, where should we go?"))
    XCTAssertEqual(model.requests,2)
    XCTAssertEqual(ConversationPolicy.turns(from:model.transcript, wearerLabel:model.wearerLabel).map(\.speaker), ["wearer", "wearer", "other"])
    XCTAssertEqual(model.transcript.map(\.speaker), ["P1", "P1", "P2"], "Captions keep their own labels on the phone")
    model.resetWearerVoice()
    XCTAssertNil(model.wearerLabel)
    XCTAssertFalse(model.wearerKnown)
  }

  func testLiveWordsDropTheAnswerInFlight() async {
    let relay = TriggerRelay()
    let model = await captioningModel(relay)
    defer { model.stop() }
    relay.onEvent?(.init(type:"transcript.final",turnId:1,speaker:"P1",text:"Hello there."))
    model.markLastLineAsMine()
    relay.onEvent?(.init(type:"transcript.final",turnId:2,speaker:"P2",text:"Where do you study?"))
    XCTAssertEqual(model.requests,1)
    XCTAssertTrue(model.isThinking)
    relay.onEvent?(.init(type:"speaker.updated",turnId:2,speaker:"P2"))
    relay.onEvent?(.init(type:"transcript.final",turnId:2,speaker:"P2",text:"Where do you study?"))
    relay.onEvent?(.init(type:"transcript.partial",turnId:3,speaker:"P2",text:"…"))
    XCTAssertTrue(model.isThinking,"Labels, repeats and punctuation are not new speech")
    relay.onEvent?(.init(type:"transcript.partial",turnId:3,speaker:"P2",text:"I mean"))
    XCTAssertFalse(model.isThinking,"Someone is talking again")
    XCTAssertEqual(model.staleDrops,1)
    relay.onEvent?(.init(type:"transcript.final",turnId:3,speaker:"P2",text:"I mean which school?"))
    XCTAssertEqual(model.requests,2)
  }

  func testALateFinalForAnOlderTurnDoesNotPromptACheck() async {
    let relay = TriggerRelay()
    let model = await captioningModel(relay)
    defer { model.stop() }
    model.sendRealtimePCM(Data(repeating:0,count:32_000),endedAtMs:nowMs()) // one second of audio anchors the caption clock
    relay.onEvent?(.init(type:"transcript.partial",turnId:1,speaker:"P2",text:"Where do you"))
    relay.onEvent?(.init(type:"transcript.final",turnId:2,speaker:"P1",text:"I study computer science.",startAudioMs:600,endAudioMs:900))
    model.markLastLineAsMine()
    XCTAssertEqual(model.wearerLabel,"P1")
    relay.onEvent?(.init(type:"transcript.final",turnId:1,speaker:"P2",text:"Where do you study?",startAudioMs:100,endAudioMs:500))
    XCTAssertEqual(model.transcript.map(\.text),["Where do you study?","I study computer science."])
    XCTAssertEqual(model.requests,0,"The wearer had already answered when this question was finalized")
  }

  func testSceneChecksIgnoreConversationMoments() async throws {
    let model = try await activeModel()
    defer { model.stop() }
    model.simulateSurroundings = true
    XCTAssertTrue(model.sceneChecks)
    model.addSimulationLine("Would you like that hot or iced?")
    XCTAssertEqual(model.requests,0,"Scene checks keep their timer; a question is not their moment")
  }
}

@MainActor private final class TriggerRelay: PhoneCaptionRelay {
  var onEvent: ((RealtimeASREvent) -> Void)?
  var onFailure: ((String) -> Void)?
  func start(languageBias: [String]) async throws {}
  func sendPCM(_ data: Data) {}
  func stop() {}
}
