import XCTest
@testable import Copilot

@MainActor
final class IntegratedCaptionTests: XCTestCase {
  func testNewSentenceDuringInferenceTriggersLatestSnapshotWithoutTenSecondWait() async throws {
    let relay = IntegratedRelay()
    let model = SessionModel(people:PeopleStore(fileURL:nil),makeRealtimeRelay:{ _,_ in relay })
    model.simulate = true
    model.phase = .active
    defer { model.stop() }
    await model.startRealtimeCaptions()
    relay.onEvent?(.init(type:"transcript.partial",turnId:1,text:"Can you have it ready by Friday?"))
    model.requestCue(manual:true)
    XCTAssertEqual(model.requests,1)
    relay.onEvent?(.init(type:"transcript.partial",turnId:2,text:"How is your robotics"))
    relay.onEvent?(.init(type:"transcript.final",turnId:2,text:"How is your robotics project going?"))
    XCTAssertEqual(model.requests,1,"New speech must coalesce while the first request runs")
    try await Task.sleep(for:.milliseconds(2700))
    XCTAssertEqual(model.requests,2,"A pending sentence must not wait for the ten-second scene poll")
    XCTAssertTrue(model.lastSceneSummary?.contains("robotics project going") == true,"The follow-up snapshot must include the complete latest sentence")
    relay.onEvent?(.init(type:"transcript.final",turnId:2,text:"How is your robotics project going?"))
    XCTAssertEqual(model.requests,2,"Duplicate finals must not create extra requests")
    model.pause()
    try await Task.sleep(for:.milliseconds(300))
    XCTAssertNil(model.cue,"Pause must cancel a response waiting for reading time")
  }

  func testPauseCancelsSentenceDebounce() async throws {
    let relay = IntegratedRelay()
    let model = SessionModel(people:PeopleStore(fileURL:nil),makeRealtimeRelay:{ _,_ in relay })
    model.simulate = true
    model.phase = .active
    defer { model.stop() }
    await model.startRealtimeCaptions()
    relay.onEvent?(.init(type:"transcript.final",turnId:1,text:"What should happen next?"))
    model.pause()
    try await Task.sleep(for:.milliseconds(500))
    XCTAssertEqual(model.requests,0)
    XCTAssertNil(model.cue)
  }

  func testPartialsUpdateSeparateRowsBeforeFinalAndAvoidChunkRequests() async {
    let relay = IntegratedRelay()
    let model = SessionModel(people:PeopleStore(fileURL:nil), makeRealtimeRelay:{ _,_ in relay })
    model.phase = .active
    defer { model.stop() }
    await model.startRealtimeCaptions()
    model.sendRealtimePCM(Data(repeating:0,count:3200),endedAtMs:nowMs())
    XCTAssertEqual(relay.bytes,3200)
    relay.onEvent?(.init(type:"transcript.partial",turnId:1,speaker:"P1",text:"Hello"))
    relay.onEvent?(.init(type:"transcript.partial",turnId:2,speaker:"P2",text:"Hi"))
    relay.onEvent?(.init(type:"transcript.partial",turnId:2,speaker:"P2",text:"Hi there"))
    XCTAssertEqual(model.captionText,"P1: Hello\nP2: Hi there")
    XCTAssertEqual(model.recentCueTranscript().count,2,"Cue context must include both unfinished speaker turns")
    XCTAssertTrue(model.transcript.isEmpty,"Partial captions must show before final transcription")
    model.transcribe(.init(audioBase64:"unused",startedAtMs:nowMs()-1000,endedAtMs:nowMs()))
    XCTAssertFalse(model.isTranscribing,"Healthy realtime must not send duplicate chunk requests")
    relay.onEvent?(.init(type:"transcript.final",turnId:1,speaker:"P1",text:"Hello"))
    relay.onEvent?(.init(type:"transcript.final",turnId:1,speaker:"P1",text:"Hello"))
    XCTAssertEqual(model.transcript.count,1)
    XCTAssertEqual(model.recentCueTranscript().count,2,"Finalization must not duplicate partial context")
    XCTAssertEqual(model.transcript.first?.speaker,"P1")
    XCTAssertTrue(model.captionText?.contains("P2: Hi there") == true)
    let lateEvent = relay.onEvent
    model.pause()
    lateEvent?(.init(type:"transcript.partial",turnId:3,speaker:"P1",text:"Late"))
    XCTAssertTrue(model.captionRows.isEmpty)
    XCTAssertNil(model.captionText)
  }

  func testFailureMakesFallbackVisible() async {
    let relay = IntegratedRelay()
    let model = SessionModel(people:PeopleStore(fileURL:nil), makeRealtimeRelay:{ _,_ in relay })
    model.phase = .active
    await model.startRealtimeCaptions()
    relay.onFailure?("Disconnected")
    XCTAssertTrue(model.speechMode.contains("Chunked fallback"))
    XCTAssertGreaterThan(relay.stops,0)
    model.stop()
  }

  func testStopCancelsPendingHandshake() async {
    let relay = IntegratedRelay(); relay.wait = true
    let model = SessionModel(people:PeopleStore(fileURL:nil), makeRealtimeRelay:{ _,_ in relay })
    model.phase = .starting
    let pending = Task { await model.startRealtimeCaptions() }
    for _ in 0..<20 { await Task.yield() }
    model.stop()
    await pending.value
    XCTAssertEqual(model.phase,.stopped)
    XCTAssertEqual(model.speechMode,"Not started")
  }

  func testGlassesOmitBothSpeakerCaptions() {
    let screen = GlassesScreen(cue:"A cue",caption:"P1: Hello\nP2: Hi there",note:nil,paused:false,captionsEnabled:true,ready:false,starting:false,testOnly:false)
    XCTAssertNil(screen.detail)
    XCTAssertEqual(screen.cue,"A cue")
  }
}

@MainActor private final class IntegratedRelay: PhoneCaptionRelay {
  var onEvent: ((RealtimeASREvent) -> Void)?
  var onFailure: ((String) -> Void)?
  var bytes = 0
  var stops = 0
  var wait = false
  var continuation: CheckedContinuation<Void,Error>?
  func start(languageBias: [String]) async throws {
    if wait { try await withCheckedThrowingContinuation { continuation = $0 } }
  }
  func sendPCM(_ data: Data) { bytes += data.count }
  func stop() { stops += 1; continuation?.resume(throwing:CancellationError()); continuation = nil }
}
