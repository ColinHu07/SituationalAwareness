import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct RealtimeASREvent: Decodable, Sendable {
  struct Timing: Decodable, Sendable {
    let serverElapsedMs: Double
    let audioReceivedMs: Double
    let audioForwardedMs: Double
    let upstreamQueuedMs: Double
  }
  let type: String
  let sessionId: String?
  let turnId: Int?
  let speaker: String?
  let text: String?
  let startAudioMs: Double?
  let endAudioMs: Double?
  let audioProcessedMs: Double?
  var timing: Timing? = nil
  var clientSentMs: Double? = nil

  init(type: String, sessionId: String? = nil, turnId: Int? = nil, speaker: String? = nil,
       text: String? = nil, startAudioMs: Double? = nil, endAudioMs: Double? = nil,
       audioProcessedMs: Double? = nil) {
    self.type = type; self.sessionId = sessionId; self.turnId = turnId; self.speaker = speaker
    self.text = text; self.startAudioMs = startAudioMs; self.endAudioMs = endAudioMs
    self.audioProcessedMs = audioProcessedMs
  }
}

struct RealtimeSpeechRange: Equatable, Sendable {
  let startMs: Double
  let endMs: Double
}

struct RealtimeSpeechClock: Sendable {
  private(set) var originMs: Double?

  mutating func notePCM(byteCount: Int, endedAtMs: Double) {
    guard originMs == nil, byteCount > 0 else { return }
    let durationMs = Double(byteCount) / 32.0 // PCM16 mono at 16 kHz = 32 bytes/ms.
    originMs = endedAtMs - durationMs
  }

  func captureTime(audioProcessedMs: Double?) -> Double? {
    guard let originMs, let audioProcessedMs, audioProcessedMs >= 0 else { return nil }
    return originMs + audioProcessedMs
  }

  func range(startAudioMs: Double?, endAudioMs: Double?, fallbackEndMs: Double) -> RealtimeSpeechRange {
    let mappedEnd = captureTime(audioProcessedMs:endAudioMs)
    let end = min(mappedEnd ?? fallbackEndMs, fallbackEndMs)
    let mappedStart = captureTime(audioProcessedMs:startAudioMs)
    let start = min(mappedStart ?? max(originMs ?? end, end - 1000), end)
    return RealtimeSpeechRange(startMs:start, endMs:end)
  }

  mutating func reset() { originMs = nil }
}

@MainActor
final class RealtimeASRClient {
  nonisolated static let maxFrameBytes = 64 * 1024
  private static let maxQueuedBytes = 512 * 1024

  private let endpoint: String
  private let token: String
  private let session: URLSession
  private var socket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var sendTask: Task<Void, Never>?
  private var pingTask: Task<Void, Never>?
  private var pendingPCM: [Data] = []
  private var pendingBytes = 0
  private var sending = false
  private var stopped = true
  private(set) var ready = false
  var acceptsPCM: Bool { ready && !stopped }

  var onEvent: ((RealtimeASREvent) -> Void)?
  var onFailure: ((String) -> Void)?
  var onSend: ((Int, Double) -> Void)?

  init(endpoint: String, token: String) {
    self.endpoint = endpoint
    self.token = token
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 0
    configuration.urlCache = nil
    session = URLSession(configuration:configuration)
  }

  nonisolated static func webSocketURL(endpoint: String) throws -> URL {
    guard var components = URLComponents(string:endpoint), let scheme = components.scheme?.lowercased(),
          let host = components.host, components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil else {
      throw CopilotError(message:"Use a trusted proxy URL without embedded credentials, query parameters or fragments.")
    }
    switch scheme {
    case "https": components.scheme = "wss"
    case "http" where isLocalNetworkHost(host): components.scheme = "ws"
    default: throw CopilotError(message:"Use an HTTPS server URL, or http:// with a local network address.")
    }
    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }
    components.path = path + "/api/asr/realtime"
    guard let url = components.url else { throw CopilotError(message:"Invalid realtime proxy URL.") }
    return url
  }

  nonisolated static func pcmFrames(_ data: Data) -> [Data] {
    guard !data.isEmpty else { return [] }
    var frames: [Data] = []
    frames.reserveCapacity((data.count + maxFrameBytes - 1) / maxFrameBytes)
    var offset = 0
    while offset < data.count {
      let end = min(offset + maxFrameBytes, data.count)
      frames.append(data.subdata(in:offset..<end))
      offset = end
    }
    return frames
  }

  func start(languageBias: [String]) async throws {
    try Task.checkCancellation()
    guard socket == nil else { throw CopilotError(message:"Realtime transcription is already running.") }
    let url = try Self.webSocketURL(endpoint:endpoint)
    var request = URLRequest(url:url)
    request.setValue("Bearer \(token)", forHTTPHeaderField:"Authorization")
    let task = session.webSocketTask(with:request)
    socket = task; stopped = false; ready = false
    task.resume()
    var timedOut = false
    let timeout = Task { [weak self, task] in
      do { try await Task.sleep(for:.seconds(10)) } catch { return }
      guard let self, self.socket === task, !self.stopped, !self.ready else { return }
      timedOut = true
      task.cancel(with:.goingAway, reason:nil)
    }
    defer { timeout.cancel() }
    do {
      try await withTaskCancellationHandler {
      let payload = try JSONSerialization.data(withJSONObject:["type":"start", "languageBias":languageBias, "diagnostics":true])
      guard let text = String(data:payload, encoding:.utf8) else {
        throw CopilotError(message:"Could not encode realtime ASR settings.")
      }
      try await task.send(.string(text))
      let event = try Self.decode(await task.receive())
      try Task.checkCancellation()
      guard socket === task, !stopped else { throw CancellationError() }
      guard event.type == "ready", event.sessionId?.isEmpty == false else {
        throw CopilotError(message:"Realtime ASR did not acknowledge the session.")
      }
      ready = true
      onEvent?(event)
      receiveTask = Task { [weak self, task] in await self?.receiveForever(task) }
      if event.timing != nil { pingTask = Task { [weak self, task] in
        while !Task.isCancelled {
          guard let self, self.socket === task, !self.stopped else { return }
          do {
            let payload = try JSONSerialization.data(withJSONObject:["type":"timing.ping", "clientSentMs":ProcessInfo.processInfo.systemUptime * 1000])
            try await task.send(.string(String(decoding:payload, as:UTF8.self)))
            try await Task.sleep(for:.seconds(2))
          } catch { return }
        }
      } }
      } onCancel: {
        task.cancel(with:.goingAway, reason:nil)
      }
    } catch {
      if socket === task { stop() }
      if Task.isCancelled { throw CancellationError() }
      if timedOut { throw CopilotError(message:"Connection timed out. Check the server and try again.") }
      throw CopilotError(message:"Realtime transcription unavailable: \(error.localizedDescription)")
    }
  }

  func sendPCM(_ data: Data) {
    guard ready, !stopped, !data.isEmpty else { return }
    for frame in Self.pcmFrames(data) {
      pendingPCM.append(frame); pendingBytes += frame.count
      guard pendingBytes <= Self.maxQueuedBytes else {
        fail("The connection fell behind. Check your network and start again.")
        return
      }
    }
    pump()
  }

  func stop() {
    stopped = true; ready = false
    receiveTask?.cancel(); receiveTask = nil
    sendTask?.cancel(); sendTask = nil
    pingTask?.cancel(); pingTask = nil
    pendingPCM.removeAll(keepingCapacity:false); pendingBytes = 0; sending = false
    socket?.cancel(with:.normalClosure, reason:nil); socket = nil
  }

  private func pump() {
    guard !sending, ready, !stopped, let task = socket, !pendingPCM.isEmpty else { return }
    let data = pendingPCM.removeFirst()
    pendingBytes -= data.count
    sending = true
    sendTask = Task { [weak self, task] in
      do {
        let began = ProcessInfo.processInfo.systemUptime
        try await task.send(.data(data))
        guard let self, self.socket === task, !self.stopped else { return }
        self.onSend?(data.count, (ProcessInfo.processInfo.systemUptime - began) * 1000)
        self.sending = false
        self.pump()
      } catch {
        guard let self, self.socket === task, !self.stopped else { return }
        self.sending = false
        self.fail("The caption connection was lost. Check your network and start again.")
      }
    }
  }

  private func receiveForever(_ task: URLSessionWebSocketTask) async {
    do {
      while !Task.isCancelled && !stopped {
        let message = try await task.receive()
        guard socket === task, !stopped, !Task.isCancelled else { return }
        let event = try Self.decode(message)
        onEvent?(event)
      }
    } catch {
      if socket === task && !stopped && !Task.isCancelled {
        fail("Caption connection closed (WebSocket \(task.closeCode.rawValue), network \((error as NSError).code)). Start again to reconnect.")
      }
    }
  }

  private func fail(_ message: String) {
    guard !stopped else { return }
    stop()
    onFailure?(message)
  }

  private nonisolated static func decode(_ message: URLSessionWebSocketTask.Message) throws -> RealtimeASREvent {
    let data: Data
    switch message {
    case .string(let text): data = Data(text.utf8)
    case .data(let bytes): data = bytes
    @unknown default: throw CopilotError(message:"Unsupported realtime ASR message.")
    }
    return try JSONDecoder().decode(RealtimeASREvent.self, from:data)
  }
}
