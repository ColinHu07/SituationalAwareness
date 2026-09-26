import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct RealtimeASREvent: Decodable, Sendable {
  let type: String
  let sessionId: String?
  let turnId: Int?
  let speaker: String?
  let text: String?
  let startAudioMs: Double?
  let endAudioMs: Double?

  init(type: String, sessionId: String? = nil, turnId: Int? = nil, speaker: String? = nil,
       text: String? = nil, startAudioMs: Double? = nil, endAudioMs: Double? = nil) {
    self.type = type; self.sessionId = sessionId; self.turnId = turnId; self.speaker = speaker
    self.text = text; self.startAudioMs = startAudioMs; self.endAudioMs = endAudioMs
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

  func range(startAudioMs: Double?, endAudioMs: Double?, fallbackEndMs: Double) -> RealtimeSpeechRange {
    let mappedEnd = originMs.flatMap { origin in endAudioMs.map { origin + $0 } }
    let end = min(mappedEnd ?? fallbackEndMs, fallbackEndMs)
    let mappedStart = originMs.flatMap { origin in startAudioMs.map { origin + $0 } }
    let start = min(mappedStart ?? max(originMs ?? end, end - 1000), end)
    return RealtimeSpeechRange(startMs:start, endMs:end)
  }

  mutating func reset() { originMs = nil }
}

@MainActor
final class RealtimeASRClient {
  private static let maxFrameBytes = 64 * 1024
  private static let maxQueuedBytes = 512 * 1024

  private let endpoint: String
  private let token: String
  private let session: URLSession
  private var socket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var pendingPCM: [Data] = []
  private var pendingBytes = 0
  private var sending = false
  private var stopped = true
  private(set) var ready = false

  var onEvent: ((RealtimeASREvent) -> Void)?
  var onFailure: ((String) -> Void)?

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
    case "http" where ["localhost", "127.0.0.1", "::1"].contains(host): components.scheme = "ws"
    default: throw CopilotError(message:"Realtime transcription requires HTTPS, except simulator localhost.")
    }
    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }
    components.path = path + "/api/asr/realtime"
    guard let url = components.url else { throw CopilotError(message:"Invalid realtime proxy URL.") }
    return url
  }

  func start(languageBias: [String]) async throws {
    guard socket == nil else { throw CopilotError(message:"Realtime transcription is already running.") }
    let url = try Self.webSocketURL(endpoint:endpoint)
    var request = URLRequest(url:url)
    request.setValue("Bearer \(token)", forHTTPHeaderField:"Authorization")
    let task = session.webSocketTask(with:request)
    socket = task; stopped = false; ready = false
    task.resume()
    do {
      let payload = try JSONSerialization.data(withJSONObject:["type":"start", "languageBias":languageBias])
      guard let text = String(data:payload, encoding:.utf8) else {
        throw CopilotError(message:"Could not encode realtime ASR settings.")
      }
      try await task.send(.string(text))
      let first = try await task.receive()
      let event = try Self.decode(first)
      guard event.type == "ready", event.sessionId?.isEmpty == false else {
        throw CopilotError(message:"Realtime ASR did not acknowledge the session.")
      }
      ready = true
      onEvent?(event)
      receiveTask = Task { [weak self, task] in await self?.receiveForever(task) }
    } catch {
      stop()
      throw CopilotError(message:"Realtime transcription unavailable: \(error.localizedDescription)")
    }
  }

  func sendPCM(_ data: Data) {
    guard ready, !stopped, !data.isEmpty, data.count <= Self.maxFrameBytes else { return }
    pendingPCM.append(data); pendingBytes += data.count
    guard pendingBytes <= Self.maxQueuedBytes else {
      fail("Realtime transcription fell behind; switching to fallback.")
      return
    }
    pump()
  }

  func stop() {
    stopped = true; ready = false
    receiveTask?.cancel(); receiveTask = nil
    pendingPCM.removeAll(keepingCapacity:false); pendingBytes = 0; sending = false
    socket?.cancel(with:.normalClosure, reason:nil); socket = nil
  }

  private func pump() {
    guard !sending, ready, !stopped, let task = socket, !pendingPCM.isEmpty else { return }
    let data = pendingPCM.removeFirst()
    pendingBytes -= data.count
    sending = true
    Task { [weak self, task] in
      do {
        try await task.send(.data(data))
        guard let self else { return }
        self.sending = false
        self.pump()
      } catch {
        guard let self else { return }
        self.sending = false
        self.fail("Realtime transcription connection lost; switching to fallback.")
      }
    }
  }

  private func receiveForever(_ task: URLSessionWebSocketTask) async {
    do {
      while !Task.isCancelled && !stopped {
        let message = try await task.receive()
        let event = try Self.decode(message)
        onEvent?(event)
      }
    } catch {
      if !stopped && !Task.isCancelled {
        fail("Realtime transcription connection lost; switching to fallback.")
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
