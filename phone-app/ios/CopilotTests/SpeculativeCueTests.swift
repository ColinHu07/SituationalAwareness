import XCTest
@testable import Copilot

final class SpeculativeCuePolicyTests: XCTestCase {
  func testAPartialThatOpensLikeAQuestionOrEndsInAMarkLooksLikeOne() {
    for text in ["Where do you study", "what do you think about", "How was your weekend then", "Are you coming to dinner",
                 "Do you want some coffee", "Did you see the game", "Have you met my sister", "Can you hear me okay",
                 "Would you like some tea", "Why is the door open", "When does the train leave", "Who is coming with us",
                 "So, where do you study", "Hey, can you help me", "What\u{2019}s your favorite class", "Which one do you want"] {
      XCTAssertTrue(SpeculativeCue.looksLikeQuestion(text), text)
    }
    XCTAssertTrue(SpeculativeCue.looksLikeQuestion("You coming?"), "A question mark is enough on a short partial")
    XCTAssertTrue(SpeculativeCue.looksLikeQuestion("The red one or the blue one?"))
    XCTAssertTrue(SpeculativeCue.looksLikeQuestion("आप कहाँ पढ़ते हैं\u{FF1F}"))
  }

  func testStatementsAndPartialsThatAreTooShortDoNotLookLikeQuestions() {
    for text in ["What", "Where do you", "How are", "Can you", "", "   ", "…", "I went to the store today",
                 "The train leaves at eight", "You know what I think about that", "Whatever you like is fine with me",
                 "Somehow we got home safely", "I asked where do you study", "What?"] {
      XCTAssertFalse(SpeculativeCue.looksLikeQuestion(text), text)
    }
  }

  func testPunctuationCaseAndFillerAreNotAMeaningfulChange() {
    XCTAssertFalse(SpeculativeCue.changedMeaningfully(from:"Where do you study", to:"Where do you study?"))
    XCTAssertFalse(SpeculativeCue.changedMeaningfully(from:"where do you study", to:"Where do you study now?"))
    XCTAssertFalse(SpeculativeCue.changedMeaningfully(from:"So where do you study", to:"Where do you, um, study?"))
    XCTAssertFalse(SpeculativeCue.changedMeaningfully(from:"What\u{2019}s your name", to:"What's your name?"))
    XCTAssertTrue(SpeculativeCue.changedMeaningfully(from:"Can you have that ready", to:"Can you have that ready by Friday?"), "More words")
    XCTAssertTrue(SpeculativeCue.changedMeaningfully(from:"Where do you study", to:"Where did you study?"), "A corrected word")
    XCTAssertTrue(SpeculativeCue.changedMeaningfully(from:"Do you want the red one", to:"Do you want the one?"), "A lost word")
    XCTAssertTrue(SpeculativeCue.changedMeaningfully(from:"Where do you study", to:"Do you study where?"), "A different order")
  }

  func testAFinishedTurnThatEndsASentenceAnotherWayIsNotAQuestion() {
    XCTAssertTrue(SpeculativeCue.isQuestion(final:"Where do you study these days?"))
    XCTAssertTrue(SpeculativeCue.isQuestion(final:"Where do you study these days"), "Unpunctuated finals go by how they open")
    XCTAssertFalse(SpeculativeCue.isQuestion(final:"What a great day that was."))
    XCTAssertFalse(SpeculativeCue.isQuestion(final:"How nice of you to come!"))
    XCTAssertFalse(SpeculativeCue.isQuestion(final:"I went to the store"))
  }

  func testOnlyALabeledVoiceThatIsNotTheWearersIsChecked() {
    var early = SpeculativeCue()
    let text = "Where do you study"
    XCTAssertNil(early.consider(turn:1, text:text, speaker:"P1", wearerLabel:"P1"), "Never the wearer's own turn")
    XCTAssertNil(early.consider(turn:1, text:text, speaker:"wearer", wearerLabel:"P1"))
    XCTAssertNil(early.consider(turn:1, text:text, speaker:nil, wearerLabel:"P1"), "An unlabeled voice could be the wearer")
    XCTAssertNil(early.consider(turn:1, text:text, speaker:"P2", wearerLabel:nil), "Until the wearer's label is known, any voice could be theirs")
    XCTAssertNil(early.consider(turn:1, text:"I study computer science", speaker:"P2", wearerLabel:"P1"))
    XCTAssertEqual(early.consider(turn:1, text:text, speaker:"P2", wearerLabel:"P1"), text)
  }

  func testALabelThatArrivesAfterTheWordsUsesTheLatestPartial() {
    var early = SpeculativeCue()
    XCTAssertNil(early.consider(turn:4, text:"Where do you", speaker:nil, wearerLabel:"P1"))
    XCTAssertNil(early.consider(turn:4, text:"Where do you study", speaker:nil, wearerLabel:"P1"))
    XCTAssertEqual(early.consider(turn:4, text:nil, speaker:"P2", wearerLabel:"P1"), "Where do you study")
    XCTAssertNil(early.consider(turn:5, text:nil, speaker:"P2", wearerLabel:"P1"), "Another turn's words are not borrowed")
  }

  func testEachTurnGetsOneEarlyCheck() {
    var early = SpeculativeCue()
    XCTAssertEqual(early.consider(turn:1, text:"Where do you study", speaker:"P2", wearerLabel:"P1"), "Where do you study")
    XCTAssertEqual(early.consider(turn:1, text:"Where do you study now", speaker:"P2", wearerLabel:"P1"), "Where do you study now",
                   "Until a check is actually sent the turn can still have one")
    early.sent(turn:1, text:"Where do you study now", generation:7)
    XCTAssertEqual(early.turn, 1)
    XCTAssertNil(early.consider(turn:1, text:"Where do you study now or", speaker:"P2", wearerLabel:"P1"))
    XCTAssertEqual(early.consider(turn:2, text:"What do you think", speaker:"P3", wearerLabel:"P1"), "What do you think")
    early.sent(turn:2, text:"What do you think", generation:7)
    XCTAssertNil(early.consider(turn:1, text:"Where do you study now or later", speaker:"P2", wearerLabel:"P1"), "An older turn stays used")
    XCTAssertEqual(early.finalize(turn:2, text:"What do you think?", role:"other", generation:7), .keep)
    XCTAssertNil(early.consider(turn:2, text:"What do you think", speaker:"P3", wearerLabel:"P1"), "A finished turn stays used")
  }

  func testTheFinishedTurnDecidesWhatHappensToTheEarlyAnswer() {
    func outcome(_ final: String, role: String = "other", turn: Int? = 3, generation: Int = 2, failed: Bool = false) -> SpeculativeCue.Outcome {
      var early = SpeculativeCue()
      early.sent(turn:3, text:"Can you have that ready", generation:2)
      if failed { early.requestFailed() }
      return early.finalize(turn:turn, text:final, role:role, generation:generation)
    }
    XCTAssertEqual(outcome("Can you have that ready?"), .keep)
    XCTAssertEqual(outcome("Can you have that ready, please?"), .keep)
    XCTAssertEqual(outcome("Can you have that ready by Friday?"), .rerun)
    XCTAssertEqual(outcome("Can you have that ready by Friday"), .rerun)
    XCTAssertEqual(outcome("Can you have that ready by Friday, I wonder."), .withdraw, "No longer a question")
    XCTAssertEqual(outcome("Can you have that ready?", role:"wearer"), .withdraw, "The turn was the wearer's own")
    XCTAssertEqual(outcome("Can you have that ready?", turn:4), .none, "Another turn")
    XCTAssertEqual(outcome("Can you have that ready?", turn:nil), .none, "A turn without live captions")
    XCTAssertEqual(outcome("Can you have that ready?", generation:3), .none, "The early check was dropped or dismissed")
    XCTAssertEqual(outcome("Can you have that ready?", failed:true), .none, "The early check got no answer")
  }

  func testATurnIsFinishedOnce() {
    var early = SpeculativeCue()
    early.sent(turn:3, text:"Where do you study", generation:0)
    XCTAssertEqual(early.finalize(turn:3, text:"Where do you study?", role:"other", generation:0), .keep)
    XCTAssertNil(early.turn)
    XCTAssertEqual(early.finalize(turn:3, text:"Where do you study?", role:"other", generation:0), .none)
  }
}

final class CueTimingTests: XCTestCase {
  func testStepsAreMeasuredFromTheEndOfSpeech() {
    var log = CueTimingLog()
    XCTAssertNil(log.turnFinal(turn:7, speechEndMs:10_000, at:10_640))
    log.requested(trigger:"question", early:false, speechEndMs:10_000, at:10_650)
    XCTAssertEqual(log.current?.turn, 7)
    XCTAssertEqual(log.current?.finalReceivedMs, 10_640)
    log.answered(at:11_500)
    XCTAssertNil(log.lastShown)
    let timing = log.shown(at:11_510)
    XCTAssertEqual(timing, log.lastShown)
    XCTAssertEqual(timing?.label, "question")
    XCTAssertEqual(timing?.steps, "final received +640 ms; request sent +650 ms; response received +1500 ms; cue shown +1510 ms")
    XCTAssertNil(log.shown(at:12_000), "A cue is shown once")
  }

  func testAnEarlyCheckWaitsForItsTurnAndCanFinishBeforeTheSpeechDoes() {
    var log = CueTimingLog()
    log.requested(trigger:"question", early:true, speechEndMs:9_700, at:9_690)
    XCTAssertNil(log.current?.speechEndMs, "A partial's end is not the end of the turn")
    log.sentEarly(for:7)
    log.answered(at:10_520)
    XCTAssertNil(log.shown(at:10_525), "The turn has not finished, so its speech end is unknown")
    XCTAssertNil(log.turnFinal(turn:6, speechEndMs:9_000, at:10_600), "Another turn's final is not this one's")
    let timing = log.turnFinal(turn:7, speechEndMs:10_800, at:11_440)
    XCTAssertEqual(timing?.label, "question, early")
    XCTAssertEqual(timing?.steps, "final received +640 ms; request sent \u{2212}1110 ms; response received \u{2212}280 ms; cue shown \u{2212}275 ms")
    XCTAssertEqual(log.lastShown, timing)
  }

  func testAnEarlyCheckThatShowsAfterItsTurnFinishedIsCompleteWhenShown() {
    var log = CueTimingLog()
    log.requested(trigger:"question", early:true, speechEndMs:nil, at:1_000)
    log.sentEarly(for:2)
    XCTAssertNil(log.turnFinal(turn:2, speechEndMs:1_200, at:1_700))
    log.answered(at:1_900)
    XCTAssertEqual(log.shown(at:1_905)?.steps, "final received +500 ms; request sent \u{2212}200 ms; response received +700 ms; cue shown +705 ms")
  }

  func testAnAnswerWithNoCueLeavesTheLastShownCueInPlace() {
    var log = CueTimingLog()
    _ = log.turnFinal(turn:1, speechEndMs:1_000, at:1_500)
    log.requested(trigger:"question", early:false, speechEndMs:1_000, at:1_510)
    log.answered(at:2_300)
    let first = log.shown(at:2_310)
    _ = log.turnFinal(turn:2, speechEndMs:9_000, at:9_500)
    log.requested(trigger:"stuck", early:false, speechEndMs:9_000, at:12_500)
    log.answered(at:13_300)
    XCTAssertEqual(log.lastShown, first)
    XCTAssertEqual(log.current?.trigger, "stuck")
    XCTAssertEqual(log.current?.offset(log.current?.requestSentMs), "+3500 ms")
  }

  func testASceneCheckIsMeasuredFromItsRequest() {
    var log = CueTimingLog()
    log.requested(trigger:"scene", early:false, speechEndMs:nil, at:5_000)
    log.answered(at:7_000)
    XCTAssertEqual(log.shown(at:7_020)?.steps, "final received —; request sent +0 ms; response received +2000 ms; cue shown +2020 ms")
  }

  @MainActor func testDiagnosticsShowTheStepsWithoutAnyWords() {
    let diagnostics = CaptionDiagnostics()
    diagnostics.reset()
    XCTAssertTrue(diagnostics.summary.contains("Last cue: —"))
    diagnostics.cueRequested(trigger:"question", early:true, speechEndMs:nil, at:9_690)
    diagnostics.cueSentEarly(for:7)
    diagnostics.cueAnswered(at:10_520)
    diagnostics.cueShown(at:10_525)
    XCTAssertTrue(diagnostics.summary.contains("Last cue: —"), "Not complete until the turn is finalized")
    diagnostics.turnFinal(turn:7, speechEndMs:10_800, at:11_440)
    let summary = diagnostics.summary
    XCTAssertTrue(summary.contains("Last cue: question, early, speech end "), summary)
    XCTAssertTrue(summary.contains("Final received: +640 ms"), summary)
    XCTAssertTrue(summary.contains("Request sent: \u{2212}1110 ms"), summary)
    XCTAssertTrue(summary.contains("Response received: \u{2212}280 ms"), summary)
    XCTAssertTrue(summary.contains("Cue shown: \u{2212}275 ms"), summary)
    let export = diagnostics.exportText
    for line in ["Cue request sent (question, early)", "Cue response received: request → response 830 ms", "Cue shown: response → screen 5 ms",
                 "Turn final turn=7: speech end ", "final received +640 ms", "Cue timing (question, early) turn=7: speech end "] {
      XCTAssertTrue(export.contains(line), line)
    }
    diagnostics.reset()
    XCTAssertTrue(diagnostics.summary.contains("Last cue: —"), "A new session starts clean")
  }
}

@MainActor
final class SpeculativeCueSessionTests: XCTestCase {
  override func setUp() { UserDefaults.standard.removeObject(forKey:"copilot.wearerVoiceDbFS") }

  private let hotOrIced = "They asked whether you want it hot or iced."
  private let friday = "Ask what they meant by Friday."

  /// Live captions from a scripted relay, answered by the local scripted model. P1 is the wearer.
  private func model(_ relay: EarlyRelay) async -> SessionModel {
    let model = SessionModel(people:PeopleStore(fileURL:nil), makeRealtimeRelay:{ _,_ in relay })
    model.simulate = true; model.localMock = true
    model.phase = .active
    await model.startRealtimeCaptions()
    relay.onEvent?(.init(type:"transcript.final",turnId:1,speaker:"P1",text:"Hello there."))
    model.markLastLineAsMine()
    XCTAssertEqual(model.wearerLabel,"P1")
    XCTAssertEqual(model.requests,0)
    return model
  }
  private func partial(_ turn: Int, _ speaker: String?, _ text: String) -> RealtimeASREvent { .init(type:"transcript.partial",turnId:turn,speaker:speaker,text:text) }
  private func final(_ turn: Int, _ speaker: String?, _ text: String) -> RealtimeASREvent { .init(type:"transcript.final",turnId:turn,speaker:speaker,text:text) }

  func testAQuestionIsCheckedWhileItIsStillBeingAskedAndItsCueShowsAtOnce() async throws {
    let relay = EarlyRelay(), model = await model(relay)
    defer { model.stop() }
    relay.onEvent?(partial(2,"P2","Would you"))
    XCTAssertEqual(model.requests,0,"Two words are not yet a question")
    relay.onEvent?(partial(2,"P2","Would you like that hot or iced"))
    XCTAssertEqual(model.requests,1,"Sent on the partial, before the turn is finalized")
    XCTAssertTrue(model.isThinking)
    XCTAssertEqual(model.transcript.map(\.text),["Hello there."],"A partial is sent with the check but is not yet a transcript turn")
    relay.onEvent?(partial(2,"P2","Would you like that hot or iced please"))
    relay.onEvent?(.init(type:"speaker.updated",turnId:2,speaker:"P2"))
    XCTAssertEqual(model.requests,1,"One early check per turn")
    XCTAssertTrue(model.isThinking,"More words in the same turn do not drop its early check")
    XCTAssertEqual(model.staleDrops,0)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,hotOrIced,"Shown as soon as it returns, with the turn still unfinished")
    XCTAssertEqual(model.shown,1)
    relay.onEvent?(final(2,"P2","Would you like that hot or iced, please?"))
    XCTAssertEqual(model.requests,1,"The same words are not checked twice")
    XCTAssertFalse(model.isThinking)
    XCTAssertEqual(model.cue,hotOrIced)
    XCTAssertEqual(model.transcript.map(\.text),["Hello there.","Would you like that hot or iced, please?"])
    try await Task.sleep(for:.milliseconds(3300))
    XCTAssertEqual(model.requests,1,"With the cue on screen, silence does not ask again")
  }

  func testAFinalThatArrivesWhileTheEarlyCheckIsInFlightLeavesItAlone() async throws {
    let relay = EarlyRelay(), model = await model(relay)
    defer { model.stop() }
    relay.onEvent?(partial(2,"P2","Would you like that hot or iced"))
    relay.onEvent?(final(2,"P2","Would you like that hot or iced?"))
    XCTAssertEqual(model.requests,1)
    XCTAssertTrue(model.isThinking,"The check in flight already has these words")
    XCTAssertEqual(model.staleDrops,0)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,hotOrIced)
  }

  func testChangedWordsAreCheckedAgainAndTheNewCueReplacesTheEarlyOne() async throws {
    let relay = EarlyRelay(), model = await model(relay)
    defer { model.stop() }
    relay.onEvent?(partial(2,"P2","Would you like that hot or iced"))
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,hotOrIced)
    relay.onEvent?(final(2,"P2","Would you like that hot or iced on Friday?"))
    XCTAssertEqual(model.requests,2,"The words changed, so the check runs again")
    XCTAssertTrue(model.isThinking)
    XCTAssertEqual(model.cue,hotOrIced,"The early cue stays until the new answer arrives")
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,friday)
    XCTAssertEqual(model.shown,2)
  }

  func testChangedWordsDropAnEarlyCheckStillInFlight() async throws {
    let relay = EarlyRelay(), model = await model(relay)
    defer { model.stop() }
    relay.onEvent?(partial(2,"P2","Can you have that ready"))
    XCTAssertEqual(model.requests,1)
    relay.onEvent?(final(2,"P2","Can you have that ready by Friday?"))
    XCTAssertEqual(model.requests,2)
    XCTAssertEqual(model.staleDrops,1,"The early answer would be about the wrong words")
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,friday)
    XCTAssertEqual(model.shown,1)
  }

  func testTheWearersOwnTurnsAndUnlabeledVoicesAreNeverCheckedEarly() async throws {
    let relay = EarlyRelay(), model = await model(relay)
    defer { model.stop() }
    relay.onEvent?(partial(2,"P1","What do you think about Friday"))
    relay.onEvent?(final(2,"P1","What do you think about Friday?"))
    XCTAssertEqual(model.requests,0,"The wearer's own question")
    relay.onEvent?(partial(3,nil,"Would you like that hot or iced"))
    XCTAssertEqual(model.requests,0,"No label yet: this could be the wearer")
    relay.onEvent?(.init(type:"speaker.updated",turnId:3,speaker:"P2"))
    XCTAssertEqual(model.requests,1,"Checked as soon as the voice is known to be someone else's")
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,hotOrIced)
  }

  func testAnEarlyCueForATurnThatTurnsOutToBeTheWearersIsTakenBack() async throws {
    let relay = EarlyRelay(), model = await model(relay)
    defer { model.stop() }
    relay.onEvent?(partial(2,"P2","Would you like that hot or iced"))
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,hotOrIced)
    relay.onEvent?(final(2,"P1","Would you like that hot or iced?"))
    XCTAssertNil(model.cue)
    XCTAssertEqual(model.requests,1)
    XCTAssertFalse(model.isThinking)
  }

  func testAnEarlyCueForWordsThatWereNotAQuestionIsTakenBack() async throws {
    let relay = EarlyRelay(), model = await model(relay)
    defer { model.stop() }
    relay.onEvent?(partial(2,"P2","What a great robot that"))
    XCTAssertEqual(model.requests,1)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,"Ask how their robotics project is going.")
    relay.onEvent?(final(2,"P2","What a great robot that turned out to be."))
    XCTAssertNil(model.cue)
    XCTAssertEqual(model.requests,1,"A statement is not checked as a question")
  }

  func testAnEarlyCheckDroppedByAnotherVoiceLeavesTheFinishedTurnToBeCheckedAsUsual() async throws {
    let relay = EarlyRelay(), model = await model(relay)
    defer { model.stop() }
    relay.onEvent?(partial(2,"P2","Would you like that hot or iced"))
    XCTAssertTrue(model.isThinking)
    relay.onEvent?(partial(3,"P3","I mean"))
    XCTAssertFalse(model.isThinking,"Someone else is talking")
    XCTAssertEqual(model.staleDrops,1)
    relay.onEvent?(partial(2,"P2","Would you like that hot or iced today"))
    XCTAssertEqual(model.requests,1,"The turn has had its early check")
    relay.onEvent?(final(2,"P2","Would you like that hot or iced?"))
    XCTAssertEqual(model.requests,2,"Nothing was kept from the dropped check, so the finished question is checked")
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,hotOrIced)
  }

  func testADismissedEarlyCueIsNotBroughtBackByItsOwnTurn() async throws {
    let relay = EarlyRelay(), model = await model(relay)
    defer { model.stop() }
    relay.onEvent?(partial(2,"P2","Would you like that hot or iced"))
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,hotOrIced)
    model.dismiss()
    relay.onEvent?(final(2,"P2","Would you like that hot or iced on Friday?"))
    XCTAssertEqual(model.requests,1,"A dismissal buys a quiet interval")
    XCTAssertNil(model.cue)
  }

  func testStatementsAndSceneChecksAreNeverCheckedEarly() async throws {
    let relay = EarlyRelay(), model = await model(relay)
    defer { model.stop() }
    relay.onEvent?(partial(2,"P2","I went to the store on Friday"))
    XCTAssertEqual(model.requests,0)
    model.simulateSurroundings = true
    XCTAssertTrue(model.sceneChecks)
    relay.onEvent?(partial(3,"P2","Would you like that hot or iced"))
    XCTAssertEqual(model.requests,0)
  }

  func testEachStepOfAnEarlyCueIsInTheCaptionTimingLog() async throws {
    let relay = EarlyRelay(), model = await model(relay)
    defer { model.stop() }
    relay.onEvent?(partial(2,"P2","Would you like that hot or iced"))
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertTrue(model.captionDiagnostics.summary.contains("Last cue: —"),"The turn has not finished")
    relay.onEvent?(final(2,"P2","Would you like that hot or iced?"))
    let summary = model.captionDiagnostics.summary, export = model.captionDiagnostics.exportText
    XCTAssertTrue(summary.contains("Last cue: question, early, speech end "), summary)
    XCTAssertTrue(summary.contains("Final received: +"), summary)
    XCTAssertTrue(summary.contains("Request sent: \u{2212}"), "Sent before the speech ended: \(summary)")
    XCTAssertTrue(summary.contains("Cue shown: \u{2212}"), "Shown before the speech ended: \(summary)")
    for line in ["Cue request sent (question, early)", "Cue response received: request → response ", "Cue shown: response → screen ",
                 "Turn final turn=2: speech end ", "Cue timing (question, early) turn=2: speech end "] {
      XCTAssertTrue(export.contains(line), line)
    }
    XCTAssertFalse(export.lowercased().contains("iced"), "Timing never includes what was said or shown")
  }

  func testACueForAFinishedTurnIsTimedFromTheEndOfItsSpeech() async throws {
    let relay = EarlyRelay(), model = await model(relay)
    defer { model.stop() }
    relay.onEvent?(final(2,"P2","Hot or iced?"))
    XCTAssertEqual(model.requests,1)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertEqual(model.cue,hotOrIced)
    let summary = model.captionDiagnostics.summary, export = model.captionDiagnostics.exportText
    XCTAssertTrue(summary.contains("Last cue: question, speech end "), summary)
    for step in ["Final received: +", "Request sent: +", "Response received: +", "Cue shown: +"] { XCTAssertTrue(summary.contains(step), summary) }
    XCTAssertTrue(export.contains("Cue request sent (question) turn=2"), export)
    XCTAssertTrue(export.contains("Cue timing (question) turn=2: speech end "), export)
  }
}

@MainActor private final class EarlyRelay: PhoneCaptionRelay {
  var onEvent: ((RealtimeASREvent) -> Void)?
  var onFailure: ((String) -> Void)?
  func start(languageBias: [String]) async throws {}
  func sendPCM(_ data: Data) {}
  func stop() {}
}
