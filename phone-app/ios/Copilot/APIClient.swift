import Foundation
import Security

struct TranscriptEntry: Codable, Identifiable {
  var id: UUID = UUID()
  let text: String
  let startMs: Double
  let endMs: Double
  let confidence: Double?
  /// "wearer" or "other" once the wearer's voice level is calibrated; nil when unknown.
  var speaker: String? = nil
  /// Loudness of the voiced parts of this chunk at the microphone (dBFS), used to tell the wearer apart.
  var levelDbFS: Double? = nil
  enum CodingKeys: String, CodingKey { case text, startMs, endMs, confidence, speaker }
}
struct SampledFrame: Codable { let dataUrl: String; let capturedAtMs: Double }
struct AudioContext: Encodable, Sendable {
  let capturedAtMs: Double
  let windowMs: Double
  let activityRatio: Double
  let rmsDbFS: Double
  let source: String
}
struct CueRequest: Encodable {
  let transcript: [TranscriptEntry]
  let frame: SampledFrame?
  let context: [String]
  let manual: Bool
  var analysisMode = "conversation"
  var audioContext: AudioContext? = nil
  var people: [PersonContext] = []
  var groups: [GroupContext] = []
  var currentScene = ""
  /// Earlier one-sentence summaries from this session, oldest first: background beyond the recent 10-second window.
  var recentMoments: [Moment] = []
  /// The cue on screen now, so the model can keep it when it's still the best advice.
  var previousCue = ""
}
struct Moment: Codable, Equatable { let atMs: Double; let summary: String }
struct CueResult: Decodable {
  let cue: String; let reason: String; let confidence: Double; let type: String; let should_display: Bool
  /// Where the wearer seems to be ("library", "funeral"), or "" when unclear.
  var scene: String? = nil
  /// One neutral sentence about what is happening now, kept as session memory.
  var summary: String? = nil
}
struct CueResponse: Decodable {
  struct Metrics: Decodable { let apiMs: Double?; let inputTokens: Int?; let outputTokens: Int?; let estimatedCostUsd: Double? }
  let result: CueResult
  let metrics: Metrics?
}
struct AudioChunk: Encodable, Sendable {
  let audioBase64: String
  let mimeType = "audio/wav"
  let sampleRate = 16000
  let startedAtMs: Double
  let endedAtMs: Double
  /// Voiced loudness (dBFS); kept on the phone, not uploaded.
  var speechDbFS: Double = -120
  enum CodingKeys: String, CodingKey { case audioBase64, mimeType, sampleRate, startedAtMs, endedAtMs }
}

// Checks how the wearer's own line may land (POST /api/tone).
struct ToneRequest: Encodable {
  struct Line: Encodable { let text: String; let endMs: Double }
  struct Recent: Encodable { let text: String; let speaker: String? }
  let line: Line
  let recent: [Recent]
  let scene: String
  let speakerKnown: Bool
  let people: [PersonContext]
  let groups: [GroupContext]
}
struct ToneResult: Decodable { let flag: Bool; let severity: String; let issue: String; let recovery: String; let rephrase: String }
struct ToneResponse: Decodable { let result: ToneResult }
struct TranscriptionResponse: Decodable { let text: String; let confidence: Double?; let transcriptionMs: Double?; let estimatedCostUsd: Double? }
struct HealthResponse: Decodable { let modelMode: String?; let tokenValid: Bool? }
struct CopilotError: LocalizedError { let message: String; var errorDescription: String? { message } }
func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
/// Plain HTTP is allowed only to this device or the local network (e.g. a Mac on the same Wi-Fi).
func isLocalNetworkHost(_ host: String) -> Bool {
  if ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".local") { return true }
  let parts = host.split(separator:".").compactMap { Int($0) }
  guard parts.count == 4, host.split(separator:".").count == 4 else { return false }
  return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254)
}

struct APIClient {
  let endpoint: String
  let token: String
  // Ephemeral configuration avoids HTTP caches containing conversation data.
  private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 22
    config.urlCache = nil
    return URLSession(configuration: config)
  }()
  private func url(_ path: String) throws -> URL {
    guard let base = URL(string: endpoint), let host = base.host,
          base.user == nil, base.password == nil,
          base.scheme == "https" || (base.scheme == "http" && isLocalNetworkHost(host))
    else { throw CopilotError(message: "Use an HTTPS server URL, or http:// with a local network address.") }
    return base.appendingPathComponent(path)
  }
  // Learning reads a whole conversation, so it gets a longer overall limit than live cues.
  private static let learnSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 40
    config.timeoutIntervalForResource = 45
    config.urlCache = nil
    return URLSession(configuration: config)
  }()
  func post<Input: Encodable, Output: Decodable>(_ path: String, _ value: Input) async throws -> (Output, Int) {
    var request = URLRequest(url: try url(path))
    if path == "api/cue" { request.timeoutInterval = 20 }
    if path == "api/learn" { request.timeoutInterval = 40 }
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(value)
    let bytes = request.httpBody?.count ?? 0
    let (data, response) = try await (path == "api/learn" ? Self.learnSession : Self.session).data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw CopilotError(message: "Proxy request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Check the server configuration; session remains under your control.")
    }
    return (try JSONDecoder().decode(Output.self, from: data), bytes)
  }
  func health() async throws -> HealthResponse {
    var request = URLRequest(url: try url("api/health"))
    request.timeoutInterval = 4
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await Self.session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CopilotError(message: "Proxy health check failed.") }
    return try JSONDecoder().decode(HealthResponse.self, from: data)
  }
}

enum TokenStore {
  static func read() -> String {
    let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"conversation-copilot", kSecAttrAccount as String:"proxy", kSecReturnData as String:true, kSecMatchLimit as String:kSecMatchLimitOne]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
    return String(data:data, encoding:.utf8) ?? ""
  }
  static func save(_ token: String) throws {
    let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"conversation-copilot", kSecAttrAccount as String:"proxy"]
    SecItemDelete(query as CFDictionary)
    guard !token.isEmpty else { return }
    var record = query
    record[kSecValueData as String] = Data(token.utf8)
    record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard SecItemAdd(record as CFDictionary, nil) == errSecSuccess else { throw CopilotError(message:"Could not save proxy token in Keychain.") }
  }
}
