import Foundation
import Observation
import OSLog

/// All clocks/durations are local or explicitly labelled server-relative.
/// Audio progress is a stream offset, not the timestamp of a spoken word.
@Observable @MainActor
final class CaptionDiagnostics {
  struct Entry: Identifiable {
    let id = UUID()
    let line: String
  }
  private(set) var entries: [Entry] = []
  private(set) var summary = "Start listening to collect timing."
  @ObservationIgnored private var began = 0.0
  @ObservationIgnored private var audioOrigin: Double?
  @ObservationIgnored private var capturedBytes = 0
  @ObservationIgnored private var sentBytes = 0
  @ObservationIgnored private var captureDispatchMs = 0.0
  @ObservationIgnored private var sendMs = 0.0
  @ObservationIgnored private var networkRTT: Double?
  @ObservationIgnored private var progressMs: Double?
  @ObservationIgnored private var progressAgeMs: Double?
  @ObservationIgnored private var server: RealtimeASREvent.Timing?
  @ObservationIgnored private var lastCaptureLog = -Double.infinity
  @ObservationIgnored private var lastSendLog = -Double.infinity
  @ObservationIgnored private var firstPartial = false
  @ObservationIgnored private var firstSpeaker = false
  @ObservationIgnored private var firstFinal = false
  @ObservationIgnored private var partials = 0
  @ObservationIgnored private var finals = 0
  @ObservationIgnored private var speakers = 0
  private static let logger = Logger(subsystem:"com.colinhu07.situationalawareness", category:"CaptionTiming")
  private static let formatter: DateFormatter = {
    let value = DateFormatter(); value.dateFormat = "HH:mm:ss.SSS"; return value
  }()
  private var uptimeMs: Double { ProcessInfo.processInfo.systemUptime * 1000 }

  var exportText: String {
    "Caption timing — audio/text content excluded\nTime: phone local HH:mm:ss.SSS; +seconds since Start.\nServer timestamps use a separate session-relative clock.\n\n\(summary)\n\n" + entries.map(\.line).joined(separator:"\n")
  }

  func reset() {
    began = uptimeMs; audioOrigin = nil; capturedBytes = 0; sentBytes = 0
    captureDispatchMs = 0; sendMs = 0; networkRTT = nil; progressMs = nil; progressAgeMs = nil; server = nil
    lastCaptureLog = -.infinity; lastSendLog = -.infinity
    firstPartial = false; firstSpeaker = false; firstFinal = false
    partials = 0; finals = 0; speakers = 0; entries = []
    record("Start tapped")
    updateSummary()
  }

  func record(_ message: String) {
    if began == 0 { began = uptimeMs }
    let line = "\(Self.formatter.string(from:Date()))  +\(String(format:"%.3f", max(0, uptimeMs - began) / 1000))s  \(message)"
    entries.append(Entry(line:line))
    if entries.count > 200 { entries.removeFirst(entries.count - 200) }
    Self.logger.info("\(line, privacy:.public)")
  }

  func captured(bytes: Int, endedAtMs: Double, receivedAtMs: Double = nowMs()) {
    let elapsed = uptimeMs
    captureDispatchMs = max(0, receivedAtMs - endedAtMs)
    if audioOrigin == nil { audioOrigin = elapsed - captureDispatchMs - Double(bytes) / 32 }
    capturedBytes += bytes
    if elapsed - lastCaptureLog >= 1000 {
      lastCaptureLog = elapsed
      record("Audio captured: offset \(Int(Double(capturedBytes)/32))ms; callback \(Self.formatter.string(from:Date(timeIntervalSince1970:endedAtMs/1000))); dispatch \(ms(captureDispatchMs)); frame \(bytes) bytes")
      updateSummary()
    }
  }

  func sent(bytes: Int, durationMs: Double) {
    sentBytes += bytes; sendMs = durationMs
    if uptimeMs - lastSendLog >= 1000 {
      lastSendLog = uptimeMs
      record("Socket send completed: offset \(Int(Double(sentBytes)/32))ms; send call \(ms(durationMs)); phone backlog \(ms(Double(max(0,capturedBytes-sentBytes))/32))")
      updateSummary()
    }
  }

  func received(_ event: RealtimeASREvent) {
    if let timing = event.timing { server = timing }
    if let progress = event.audioProcessedMs, progress.isFinite, progress >= 0 {
      progressMs = max(progressMs ?? 0, progress)
      if let audioOrigin { progressAgeMs = max(0, uptimeMs - audioOrigin - progress) }
    }
    if event.type == "timing.pong", let sentAt = event.clientSentMs, sentAt.isFinite {
      networkRTT = max(0, uptimeMs - sentAt)
      record("Phone ↔ proxy round trip \(ms(networkRTT))")
    } else {
      var first = ""
      switch event.type {
      case "transcript.partial":
        partials += 1; if !firstPartial { first = "FIRST "; firstPartial = true }
      case "speaker.updated":
        speakers += 1; if !firstSpeaker { first = "FIRST "; firstSpeaker = true }
      case "transcript.final":
        finals += 1; if !firstFinal { first = "FIRST "; firstFinal = true }
      default: break
      }
      let turn = event.turnId.map { " turn=\($0)" } ?? ""
      let audio = event.audioProcessedMs.map { " audio=\(Int($0))ms" } ?? ""
      let age = event.audioProcessedMs != nil ? " estimated age=\(ms(progressAgeMs))" : ""
      let relay = event.timing.map { " server+\(Int($0.serverElapsedMs))ms received=\(Int($0.audioReceivedMs))ms forwarded=\(Int($0.audioForwardedMs))ms" } ?? ""
      record("\(first)\(event.type)\(turn)\(audio)\(age)\(relay)")
    }
    updateSummary()
  }

  func applied(event: RealtimeASREvent, durationMs: Double, changed: Bool) {
    guard ["transcript.partial", "transcript.final", "speaker.updated"].contains(event.type) else { return }
    record("Caption state \(changed ? "updated" : "unchanged") turn=\(event.turnId ?? -1); receive → state \(ms(durationMs))")
  }

  private func updateSummary() {
    summary = """
    Captured / socket-sent: \(ms(Double(capturedBytes)/32)) / \(ms(Double(sentBytes)/32)) audio
    Phone send backlog: \(ms(Double(max(0,capturedBytes-sentBytes))/32)) audio
    Capture → main thread: \(ms(captureDispatchMs))
    Last socket send call: \(ms(sendMs))
    Phone ↔ proxy RTT: \(ms(networkRTT))
    Proxy received / forwarded: \(ms(server?.audioReceivedMs)) / \(ms(server?.audioForwardedMs)) audio
    Proxy send backlog: \(ms(server?.upstreamQueuedMs)) audio
    Muse processed offset: \(ms(progressMs)) audio
    Latest event age (estimate): \(ms(progressAgeMs))
    Partials / speaker events / finals: \(partials) / \(speakers) / \(finals)
    """
  }

  private func ms(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format:"%.0f ms", value)
  }
}
