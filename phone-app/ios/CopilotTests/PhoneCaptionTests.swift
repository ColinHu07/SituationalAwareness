import XCTest
import AVFoundation
import os
@testable import Copilot

@MainActor
final class PhoneCaptionTests: XCTestCase {
  func testSeparateSpeakersStayVisibleAndKeepTheirOrder() {
    var roster = PhoneCaptionRoster()
    roster.consume(event(1, "P1", "Hello"), at:1_000)
    roster.consume(event(2, "P2", "Hi there"), at:2_000)
    roster.consume(event(1, "P1", "Hello everyone"), at:3_000)
    XCTAssertEqual(roster.rows.map(\.speakerName), ["P1", "P2"])
    XCTAssertEqual(roster.rows.map(\.text), ["Hello everyone", "Hi there"])
    roster.consume(event(1, "P1", String(repeating:"earlier words ", count:30) + "Newest words"), at:4_000)
    XCTAssertTrue(roster.rows[0].text.hasSuffix("Newest words"))
    XCTAssertEqual(roster.rows[0].text.count, 240)
  }

  func testUnknownTurnDoesNotBorrowThePreviousSpeaker() {
    var roster = PhoneCaptionRoster()
    roster.consume(event(1, "P1", "First person"), at:1_000)
    roster.consume(event(2, nil, "Another voice"), at:2_000)
    XCTAssertEqual(roster.rows.map(\.speakerName), ["P1", "Speaker…"])
    roster.consume(RealtimeASREvent(type:"speaker.updated", turnId:2, speaker:"P2"), at:2_100)
    XCTAssertEqual(roster.rows.map(\.speakerName), ["P1", "P2"])
    XCTAssertEqual(roster.rows.map(\.text), ["First person", "Another voice"])
  }

  func testSpeakerLabelArrivingBeforeTextIsPreserved() {
    var roster = PhoneCaptionRoster()
    roster.consume(RealtimeASREvent(type:"speaker.updated", turnId:1, speaker:"P2"), at:1_000)
    XCTAssertTrue(roster.rows.isEmpty)
    roster.consume(event(1, nil, "Hello"), at:1_100)
    XCTAssertEqual(roster.rows.first?.speakerName, "P2")
  }

  func testDelayedFinalDoesNotReplaceNewerTurnOfSameSpeaker() {
    var roster = PhoneCaptionRoster()
    roster.consume(event(1, "P1", "Old turn"), at:1_000)
    roster.consume(event(2, "P1", "New turn"), at:2_000)
    roster.consume(event(1, "P1", "Old finalized turn", final:true), at:3_000)
    XCTAssertEqual(roster.rows.map(\.text), ["New turn"])
    roster.consume(event(2, "P1", "New finalized turn", final:true), at:3_100)
    XCTAssertEqual(roster.rows.map(\.text), ["New finalized turn"])
  }

  func testUnseenDelayedFinalUsesAudioTimeToProtectNewerCaption() {
    var roster = PhoneCaptionRoster()
    roster.consume(RealtimeASREvent(type:"transcript.partial", turnId:2, speaker:"P1", text:"New", audioProcessedMs:2_000), at:1_000)
    roster.consume(RealtimeASREvent(type:"transcript.final", turnId:1, speaker:"P1", text:"Old", endAudioMs:1_000), at:1_100)
    XCTAssertEqual(roster.rows.map(\.text), ["New"])
  }

  func testLateAttributionMergesOnlyItsOwnPendingRow() {
    var roster = PhoneCaptionRoster()
    roster.consume(event(1, nil, "Old pending"), at:1_000)
    roster.consume(event(2, "P1", "New speech"), at:2_000)
    roster.consume(RealtimeASREvent(type:"speaker.updated", turnId:1, speaker:"P1"), at:3_000)
    XCTAssertEqual(roster.rows.map(\.speakerName), ["P1"])
    XCTAssertEqual(roster.rows.map(\.text), ["New speech"])
  }

  func testRowsExpireIndependentlyAndFourthSpeakerEvictsLeastRecent() {
    var roster = PhoneCaptionRoster()
    roster.consume(event(1, "P1", "A"), at:0)
    roster.consume(event(2, "P2", "B"), at:5_000)
    roster.expire(at:15_000)
    XCTAssertEqual(roster.rows.map(\.speakerName), ["P2"])
    roster.consume(event(3, "P3", "C"), at:16_000)
    roster.consume(event(4, "P1", "A again"), at:17_000)
    roster.consume(event(5, "P4", "D"), at:18_000)
    XCTAssertEqual(roster.rows.map(\.speakerName), ["P3", "P1", "P4"])
  }

  func testStopClearsRowsAndOldCallbacksCannotAffectRestart() async {
    let microphone = FakeCaptionMicrophone()
    let first = FakeCaptionRelay(), second = FakeCaptionRelay()
    var connections = [first, second]
    let session = PhoneCaptionSession(microphone:microphone, makeRelay:{ _, _ in connections.removeFirst() },
                                     healthCheck:{ _, _ in HealthResponse(modelMode:"live", tokenValid:true) })
    session.start(endpoint:"https://example.com", token:"test")
    await settle()
    XCTAssertEqual(session.phase, .listening)
    first.onEvent?(event(1, "P1", "First session"))
    XCTAssertEqual(session.rows.count, 1)
    let oldEvent = first.onEvent, oldFailure = first.onFailure
    let oldPCM = microphone.onPCM, oldMicrophoneFailure = microphone.onFailure
    session.stop()
    XCTAssertTrue(session.rows.isEmpty)
    XCTAssertEqual(first.stops, 1)
    XCTAssertNil(microphone.onPCM)
    session.start(endpoint:"https://example.com", token:"test")
    await settle()
    second.onEvent?(event(1, "P2", "New session"))
    oldEvent?(event(2, "P1", "Late old speech"))
    oldFailure?("Old network error")
    oldPCM?(Data([0,0]), 1)
    oldMicrophoneFailure?("Old microphone error")
    await settle()
    XCTAssertEqual(session.phase, .listening)
    XCTAssertEqual(session.status, "Listening…")
    XCTAssertEqual(session.rows.map(\.text), ["New session"])
    XCTAssertTrue(second.audio.isEmpty)
    microphone.onPCM?(Data([1,0]), 2)
    await settle()
    XCTAssertEqual(second.audio, [Data([1,0])])
    session.sceneBecameInactive()
    XCTAssertEqual(session.phase, .stopped)
    XCTAssertTrue(session.rows.isEmpty)
  }

  func testStandaloneCaptionUsesConfirmedProfileNameWithoutChangingRawLabel() async {
    let microphone = FakeCaptionMicrophone(), connection = FakeCaptionRelay()
    let people = PeopleStore(fileURL:nil)
    _ = people.addPerson("Sam")
    let session = PhoneCaptionSession(microphone:microphone, makeRelay:{ _, _ in connection },
                                     healthCheck:{ _, _ in HealthResponse(modelMode:"live", tokenValid:true) },
                                     people:people)
    session.start(endpoint:"https://example.com", token:"test")
    await settle()
    connection.onEvent?(event(1, "P1", "I'm Sam.", final:true))
    XCTAssertEqual(session.rows.first?.speakerLabel, "P1")
    XCTAssertEqual(session.displaySpeakerName(for:session.rows.first?.speakerLabel), "Sam")
    session.stop()
  }

  func testStopCancelsAHandshakeBeforeMicrophoneStarts() async {
    let microphone = FakeCaptionMicrophone(), connection = FakeCaptionRelay()
    connection.waitForHandshake = true
    let session = PhoneCaptionSession(microphone:microphone, makeRelay:{ _, _ in connection },
                                     healthCheck:{ _, _ in HealthResponse(modelMode:"live", tokenValid:true) })
    session.start(endpoint:"https://example.com", token:"test")
    await settle()
    XCTAssertEqual(session.phase, .starting)
    XCTAssertNotNil(connection.handshake)
    session.stop()
    await settle()
    XCTAssertEqual(session.phase, .stopped)
    XCTAssertEqual(connection.stops, 1)
    XCTAssertEqual(microphone.starts, 0)
    XCTAssertNil(connection.handshake)
  }

  func testConnectionFailureStopsMicrophoneAndClearsCaptions() async {
    let microphone = FakeCaptionMicrophone(), connection = FakeCaptionRelay()
    let session = PhoneCaptionSession(microphone:microphone, makeRelay:{ _, _ in connection },
                                     healthCheck:{ _, _ in HealthResponse(modelMode:"live", tokenValid:true) })
    session.start(endpoint:"https://example.com", token:"test")
    await settle()
    connection.onEvent?(event(1, "P1", "Private speech"))
    connection.onFailure?("Connection lost. Start again.")
    XCTAssertEqual(session.phase, .stopped)
    XCTAssertTrue(session.rows.isEmpty)
    XCTAssertEqual(session.status, "Connection lost. Start again.")
    XCTAssertEqual(microphone.stops, 1)
  }

  func testMockBackendNeverStartsMicrophoneOrInventsSpeakers() async {
    let microphone = FakeCaptionMicrophone()
    let session = PhoneCaptionSession(microphone:microphone, makeRelay:{ _, _ in
      XCTFail("A mock backend cannot create a live caption connection")
      return FakeCaptionRelay()
    }, healthCheck:{ _, _ in HealthResponse(modelMode:"mock", tokenValid:nil) })
    session.start(endpoint:"https://example.com", token:"test")
    await settle()
    XCTAssertEqual(session.phase, .stopped)
    XCTAssertEqual(microphone.starts, 0)
    XCTAssertTrue(session.status.contains("live Muse server"))
    XCTAssertTrue(session.rows.isEmpty)
  }

  func testRealtimeURLMatchesExistingLocalServerSettings() throws {
    XCTAssertEqual(try RealtimeASRClient.webSocketURL(endpoint:"http://192.168.1.5:8787").absoluteString,
                   "ws://192.168.1.5:8787/api/asr/realtime")
    XCTAssertEqual(try RealtimeASRClient.webSocketURL(endpoint:"https://example.com").absoluteString,
                   "wss://example.com/api/asr/realtime")
    XCTAssertThrowsError(try RealtimeASRClient.webSocketURL(endpoint:"http://public.example"))
    XCTAssertThrowsError(try RealtimeASRClient.webSocketURL(endpoint:"https://example.com?token=secret"))
  }

  func testConvertedAudioArrivesBeforeACompletedChunk() throws {
    let microphone = ConversationMicrophone()
    let frames = OSAllocatedUnfairLock(initialState:[Data]())
    microphone.onPCM = { data, _ in frames.withLock { $0.append(data) } }
    microphone.prepareStreamPCM()
    defer { microphone.stop() }
    let format = try XCTUnwrap(AVAudioFormat(commonFormat:.pcmFormatFloat32, sampleRate:16_000, channels:1, interleaved:false))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:format, frameCapacity:1024))
    buffer.frameLength = 1024
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    for index in 0..<1024 { samples[index] = 0.02 }
    microphone.receiveStreamPCM(buffer, at:1_000)
    XCTAssertEqual(frames.withLock { $0.first?.count }, 2048)
    microphone.stop()
    microphone.receiveStreamPCM(buffer, at:2_000)
    XCTAssertEqual(frames.withLock { $0.count }, 1)
  }

  private func event(_ turn: Int, _ speaker: String?, _ text: String, final: Bool = false) -> RealtimeASREvent {
    RealtimeASREvent(type:final ? "transcript.final" : "transcript.partial", turnId:turn, speaker:speaker, text:text)
  }
  private func settle() async { for _ in 0..<25 { await Task.yield() } }
}

@MainActor
private final class FakeCaptionMicrophone: PhoneCaptionMicrophone {
  var onPCM: (@Sendable (Data, Double) -> Void)?
  var onFailure: (@Sendable (String) -> Void)?
  var starts = 0
  var stops = 0
  func startPhone() async throws { starts += 1 }
  func stop() { stops += 1 }
}

@MainActor
private final class FakeCaptionRelay: PhoneCaptionRelay {
  var onEvent: ((RealtimeASREvent) -> Void)?
  var onFailure: ((String) -> Void)?
  var audio: [Data] = []
  var stops = 0
  var waitForHandshake = false
  var handshake: CheckedContinuation<Void, Error>?
  func start(languageBias: [String]) async throws {
    if waitForHandshake {
      try await withCheckedThrowingContinuation { handshake = $0 }
    }
  }
  func sendPCM(_ data: Data) { audio.append(data) }
  func stop() {
    stops += 1
    handshake?.resume(throwing:CancellationError()); handshake = nil
  }
}
