import XCTest
@testable import Copilot

final class ConversationContextTests: XCTestCase {
  func testSentenceEndBypassesSceneIntervalButCoalescesRapidTurns() {
    var schedule = ConversationCueSchedule()
    schedule.observe(changed:true,final:false,at:11000)
    schedule.observe(changed:true,final:true,at:11200)
    XCTAssertEqual(schedule.readyAt(lastRequestAt:8000,reducedPower:false),11450)
    schedule.submitted()
    XCTAssertFalse(schedule.hasPending)
    schedule.observe(changed:true,final:true,at:11800)
    XCTAssertEqual(schedule.readyAt(lastRequestAt:11450,reducedPower:false),13450)
    XCTAssertEqual(schedule.readyAt(lastRequestAt:11450,reducedPower:true),15450)
  }

  func testContinuousPartialsCannotPostponeAnalysisForever() {
    var schedule = ConversationCueSchedule()
    for time in stride(from:10000.0,through:14000.0,by:200) {
      schedule.observe(changed:true,final:false,at:time)
    }
    XCTAssertEqual(schedule.readyAt(lastRequestAt:0,reducedPower:false),13000)
    schedule.submitted()
    schedule.observe(changed:false,final:true,at:15000)
    XCTAssertFalse(schedule.hasPending,"Finalizing an already submitted snapshot does not need another request")
    schedule.observe(changed:true,final:true,at:15100)
    XCTAssertTrue(schedule.hasPending,"Corrected text must trigger a fresh snapshot")
  }

  func testDuplicateAndSpeakerUpdatesDoNotTriggerInference() {
    var window = ConversationWindow()
    XCTAssertTrue(window.consume(.init(type:"transcript.partial",turnId:1,text:"What happens next?"),at:1000))
    XCTAssertFalse(window.consume(.init(type:"transcript.partial",turnId:1,text:"What happens next?"),at:1500))
    XCTAssertFalse(window.consume(.init(type:"speaker.updated",turnId:1,speaker:"P2"),at:1800))
    XCTAssertTrue(window.consume(.init(type:"transcript.final",turnId:1,text:"What happens after that?"),at:2000))
  }

  func testLateFinalCannotMarkNewerPartialAsFinished() {
    var schedule = ConversationCueSchedule()
    schedule.observe(changed:true,final:false,turnId:2,at:11000)
    schedule.observe(changed:false,final:true,turnId:1,at:11100)
    XCTAssertEqual(schedule.readyAt(lastRequestAt:0,reducedPower:false),11750)
    schedule.observe(changed:false,final:true,turnId:2,at:11200)
    XCTAssertEqual(schedule.readyAt(lastRequestAt:0,reducedPower:false),11450)
  }

  func testRecentWindowIncludesPartialsAndSeparateSpeakers() {
    var window = ConversationWindow()
    window.consume(.init(type:"transcript.partial",turnId:1,speaker:"P1",text:"Let's review the plan"),at:1000)
    window.consume(.init(type:"transcript.partial",turnId:2,speaker:"P2",text:"What about the cost?"),at:2000)
    XCTAssertEqual(window.entries(at:3000).map(\.speaker),["P1","P2"])
    XCTAssertEqual(window.entries(at:3000).map(\.text),["Let's review the plan","What about the cost?"])
  }

  func testLongCumulativeTurnDoesNotReviveEarlierWordsOrDuplicateFinal() {
    var window = ConversationWindow()
    window.consume(.init(type:"transcript.partial",turnId:1,text:"Old topic."),at:1000)
    window.consume(.init(type:"transcript.partial",turnId:1,text:"Old topic. New proposal"),at:12000)
    window.consume(.init(type:"speaker.updated",turnId:1,speaker:"P2"),at:13000)
    window.consume(.init(type:"transcript.final",turnId:1,text:"Old topic. New proposal"),at:14000)
    XCTAssertEqual(window.entries(at:15000).map(\.text),["New proposal"])
    XCTAssertEqual(window.entries(at:15000).first?.speaker,"P2")
    XCTAssertEqual(window.entries(at:15000).first?.endMs,12000)
    XCTAssertTrue(window.entries(at:22001).isEmpty)
    window.consume(.init(type:"transcript.final",turnId:1,text:"Old topic. New proposal"),at:23000)
    XCTAssertTrue(window.entries(at:23000).isEmpty)
  }

  func testCorrectionKeepsOriginalTimeAndRemovesSupersededText() {
    var window = ConversationWindow()
    window.consume(.init(type:"transcript.partial",turnId:1,text:"Tuesday works"),at:1000)
    window.consume(.init(type:"transcript.final",turnId:1,text:"Thursday works"),at:6000)
    XCTAssertEqual(window.entries(at:7000).map(\.text),["Thursday works"])
    XCTAssertTrue(window.entries(at:11001).isEmpty)
  }

  func testNonWhitespaceLanguagesAndPunctuationOnlyFinal() {
    var window = ConversationWindow()
    window.consume(.init(type:"transcript.partial",turnId:1,text:"你好"),at:1000)
    window.consume(.init(type:"transcript.partial",turnId:1,text:"你好我们开始吧"),at:12000)
    XCTAssertEqual(window.entries(at:13000).map(\.text),["我们开始吧"])
    window.consume(.init(type:"transcript.final",turnId:1,text:"你好我们开始吧。"),at:24000)
    XCTAssertTrue(window.entries(at:24000).isEmpty)
  }

  func testAudioWindowUsesEnergyAverageAndExpiresInSilence() {
    var window = AmbientWindow()
    window.append(.init(capturedAtMs:1000,windowMs:1000,activityRatio:0,rmsDbFS:-60,source:"glasses_pcm"))
    window.append(.init(capturedAtMs:2000,windowMs:1000,activityRatio:1,rmsDbFS:-20,source:"glasses_pcm"))
    let context = window.context(at:2000)
    XCTAssertEqual(context?.windowMs,2000)
    XCTAssertEqual(context?.activityRatio,0.5)
    XCTAssertEqual(context?.rmsDbFS ?? 0,-23.0099,accuracy:0.001)
    XCTAssertNil(window.context(at:12001))
  }

  func testAudioWindowDropsOldSamplesAndKeepsSourcesSeparate() {
    var window = AmbientWindow()
    for i in 1...12 {
      window.append(.init(capturedAtMs:Double(i*1000),windowMs:1000,activityRatio:0.1,rmsDbFS:-50,source:"phone"))
    }
    XCTAssertEqual(window.context(at:12000)?.windowMs,10000)
    window.append(.init(capturedAtMs:13000,windowMs:1000,activityRatio:0.9,rmsDbFS:-20,source:"glasses_pcm"))
    XCTAssertEqual(window.context(at:13000)?.windowMs,1000)
    XCTAssertEqual(window.context(at:13000)?.source,"glasses_pcm")
  }

  @MainActor func testCaptionChangesCannotRedrawGlasses() {
    let controller = GlassesController()
    controller.displayReady = true
    controller.show("Could we review the timeline?",caption:"P1: First",captionsEnabled:true)
    let revision = controller.displayRevision
    controller.show("Could we review the timeline?",caption:"P1: First second\nP2: Hello",captionsEnabled:true)
    XCTAssertEqual(controller.displayRevision,revision)
    XCTAssertNil(controller.requestedScreen?.detail)
  }

  @MainActor func testFallbackWindowExcludesOldAndUnclearSpeech() {
    let model = SessionModel(people:PeopleStore(fileURL:nil))
    model.transcript = [
      .init(text:"Old topic",startMs:0,endMs:1000,confidence:nil),
      .init(text:"Unclear",startMs:10000,endMs:11000,confidence:0.2),
      .init(text:"New proposal",startMs:12000,endMs:13000,confidence:0.9)
    ]
    XCTAssertEqual(model.recentCueTranscript(at:15000).map(\.text),["New proposal"])
  }

  @MainActor func testUnsupportedSceneClearsEarlierConversationCue() async throws {
    let model = SessionModel(people:PeopleStore(fileURL:nil))
    model.captureMode = .simulated
    model.simulateSurroundings = true
    model.phase = .active
    model.cue = "Could we review the budget?"
    model.latestFrame = .init(dataUrl:"synthetic fixture",capturedAtMs:nowMs())
    defer { model.stop() }
    model.requestCue(manual:true)
    try await Task.sleep(for:.milliseconds(600))
    XCTAssertNil(model.cue,"An unsupported new scene must not keep stale business advice")
    XCTAssertEqual(model.lastAnalysisOutcome,"Waiting for clearer context.")
  }
}
