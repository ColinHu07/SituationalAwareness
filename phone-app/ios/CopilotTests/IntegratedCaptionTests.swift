import XCTest
@testable import Copilot

@MainActor
final class IntegratedCaptionTests: XCTestCase {
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

  func testConfirmedProfileNameChangesDisplayWithoutChangingRawSpeaker() async {
    let relay = IntegratedRelay()
    let store = PeopleStore(fileURL:nil)
    let sam = store.addPerson("Sam")!
    let model = SessionModel(people:store, makeRealtimeRelay:{ _,_ in relay })
    model.phase = .active
    let time = nowMs()
    model.applyFaceMatches([sam], at:time)
    model.applyFaceMatches([sam], at:time + 1)
    await model.startRealtimeCaptions()
    relay.onEvent?(.init(type:"transcript.final", turnId:1, speaker:"P1", text:"I'm Sam."))
    XCTAssertEqual(model.captionText, "Sam: I'm Sam.")
    XCTAssertEqual(model.captionRows.first?.speakerLabel, "P1")
    XCTAssertEqual(model.transcript.first?.speaker, "P1")
    XCTAssertEqual(model.speakerIdentityContexts, [
      SpeakerIdentityContext(label:"P1", personId:sam.uuidString, name:"Sam"),
    ])
    model.stop()
    XCTAssertTrue(model.speakerIdentityContexts.isEmpty)
    XCTAssertEqual(model.displaySpeakerName(for:"P1"), "P1")
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
