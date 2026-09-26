import Foundation

// Debug launch convenience: provision the existing proxy credential into Keychain,
// never into source, Info.plist, a URL, or an automatic capture session.
enum DevelopmentConnection {
  struct Settings { let endpoint: String; let token: String }
  static func settings(from environment: [String: String]) -> Settings? {
    guard let endpoint = environment["ASIDE_PROXY_URL"],
          let token = environment["ASIDE_PROXY_TOKEN"], token.count >= 32,
          let url = URL(string:endpoint), let host = url.host, !host.isEmpty,
          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
          url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { return nil }
    return Settings(endpoint:endpoint,token:token)
  }
}
