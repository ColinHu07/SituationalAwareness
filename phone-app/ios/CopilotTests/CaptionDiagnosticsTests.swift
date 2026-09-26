import XCTest
@testable import Copilot

@MainActor
final class CaptionDiagnosticsTests: XCTestCase {
  func testAudioBacklogAndTimingExportExcludeSpeechAndCredentials() {
    let diagnostics = CaptionDiagnostics()
    diagnostics.reset()
    diagnostics.captured(bytes:32000, endedAtMs:nowMs())
    diagnostics.sent(bytes:16000, durationMs:12)
    XCTAssertTrue(diagnostics.summary.contains("Phone send backlog: 500 ms audio"))
    var event = RealtimeASREvent(type:"transcript.partial", turnId:1, speaker:"P1", text:"PRIVATE CONVERSATION", audioProcessedMs:300)
    event.timing = .init(serverElapsedMs:999_999_999, audioReceivedMs:500, audioForwardedMs:500, upstreamQueuedMs:0)
    diagnostics.received(event)
    XCTAssertFalse(diagnostics.exportText.contains("PRIVATE CONVERSATION"))
    XCTAssertTrue(diagnostics.exportText.contains("FIRST transcript.partial"))
    XCTAssertTrue(diagnostics.summary.contains("Muse processed offset: 300 ms audio"))
    XCTAssertFalse(diagnostics.summary.contains("999999999"), "Server-relative clocks must not be subtracted from phone clocks")
  }

  func testLogsAreBoundedAndNextStartResetsPreviousSession() {
    let diagnostics = CaptionDiagnostics()
    diagnostics.reset()
    for index in 0..<250 { diagnostics.record("marker \(index)") }
    XCTAssertEqual(diagnostics.entries.count,200)
    XCTAssertTrue(diagnostics.exportText.contains("marker 249"))
    diagnostics.reset()
    XCTAssertEqual(diagnostics.entries.count,1)
    XCTAssertFalse(diagnostics.exportText.contains("marker"))
  }

  func testOptionalTelemetryDecodesAlongsideOldCaptionEvents() throws {
    let old = try JSONDecoder().decode(RealtimeASREvent.self, from:Data(#"{"type":"transcript.partial","turnId":1,"text":"hello"}"#.utf8))
    XCTAssertNil(old.timing)
    let timed = try JSONDecoder().decode(RealtimeASREvent.self, from:Data(#"{"type":"timing.pong","clientSentMs":10,"timing":{"serverElapsedMs":20,"audioReceivedMs":100,"audioForwardedMs":100,"upstreamQueuedMs":0}}"#.utf8))
    XCTAssertEqual(timed.clientSentMs,10)
    XCTAssertEqual(timed.timing?.audioReceivedMs,100)
  }
}
