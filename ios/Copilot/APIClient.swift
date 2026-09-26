import Foundation
import Security

struct TranscriptEntry: Codable, Identifiable {
  var id: UUID = UUID()
  let text: String
  let startMs: Double
  let endMs: Double
  let confidence: Double?
  enum CodingKeys: String, CodingKey { case text, startMs, endMs, confidence }
}
struct SampledFrame: Codable { let dataUrl: String; let capturedAtMs: Double }
struct CueRequest: Encodable { let transcript: [TranscriptEntry]; let frame: SampledFrame?; let context: [String]; let manual: Bool }
struct CueResult: Decodable { let cue: String; let reason: String; let confidence: Double; let type: String; let should_display: Bool }
struct CueResponse: Decodable {
  struct Metrics: Decodable { let apiMs: Double?; let inputTokens: Int?; let outputTokens: Int?; let estimatedCostUsd: Double? }
  let result: CueResult
  let metrics: Metrics?
}
struct AudioChunk: Encodable {
  let audioBase64: String
  let mimeType = "audio/wav"
  let sampleRate = 16000
  let startedAtMs: Double
  let endedAtMs: Double
}
struct TranscriptionResponse: Decodable { let text: String; let confidence: Double?; let transcriptionMs: Double?; let estimatedCostUsd: Double? }
struct HealthResponse: Decodable { let modelMode: String? }
struct CopilotError: LocalizedError { let message: String; var errorDescription: String? { message } }
func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

struct APIClient {
  let endpoint: String
  let token: String
  // Ephemeral configuration avoids HTTP caches containing conversation data.
  private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 12
    config.urlCache = nil
    return URLSession(configuration: config)
  }()
  private func url(_ path: String) throws -> URL {
    guard let base = URL(string: endpoint), let host = base.host,
          base.user == nil, base.password == nil,
          base.scheme == "https" || (base.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    else { throw CopilotError(message: "Use your trusted HTTPS proxy URL. HTTP is allowed only on simulator localhost.") }
    return base.appendingPathComponent(path)
  }
  func post<Input: Encodable, Output: Decodable>(_ path: String, _ value: Input) async throws -> (Output, Int) {
    var request = URLRequest(url: try url(path))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONEncoder().encode(value)
    let bytes = request.httpBody?.count ?? 0
    let (data, response) = try await Self.session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw CopilotError(message: "Proxy request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Check the server configuration; session remains under your control.")
    }
    return (try JSONDecoder().decode(Output.self, from: data), bytes)
  }
  func health() async throws -> HealthResponse {
    var request = URLRequest(url: try url("api/health"))
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
