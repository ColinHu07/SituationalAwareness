import Foundation
import Network

/// Finds an Aside server announced on the local network (`_aside._tcp`).
/// Returns candidate http:// URLs, best first: the addresses the server lists in its
/// announcement, then the address reached by resolving the service.
enum ServerDiscovery {
  static func candidates(timeout: Duration = .seconds(5)) async -> [String] {
    await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
      let queue = DispatchQueue(label:"aside.discovery")
      let browser = NWBrowser(for:.bonjourWithTXTRecord(type:"_aside._tcp", domain:nil), using:.tcp)
      var connection: NWConnection?
      var urls: [String] = []
      var finished = false
      // All callbacks run on `queue`, so this state is only touched serially.
      func finish() {
        guard !finished else { return }
        finished = true
        browser.cancel(); connection?.cancel()
        var seen = Set<String>()
        continuation.resume(returning:urls.filter { seen.insert($0).inserted })
      }
      browser.browseResultsChangedHandler = { results, _ in
        guard connection == nil, let result = results.first else { return }
        var port = "8787"
        if case .service(_, _, _, _) = result.endpoint, case .bonjour(let txt) = result.metadata,
           let ips = txt["ips"] {
          if case .hostPort(_, let p) = result.endpoint { port = "\(p.rawValue)" }
          urls += ips.split(separator:",").map { "http://\($0):\(port)" }
        }
        // Resolve over IPv4 to learn the real port (and an address to fall back on).
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let candidate = NWConnection(to:result.endpoint, using:parameters)
        connection = candidate
        candidate.stateUpdateHandler = { state in
          switch state {
          case .ready:
            if case .hostPort(let host, let resolved)? = candidate.currentPath?.remoteEndpoint {
              urls = urls.map { $0.replacingOccurrences(of:":\(port)", with:":\(resolved.rawValue)") }
              let address = "\(host)".split(separator:"%").first.map(String.init) ?? "\(host)"
              urls.append("http://\(address):\(resolved.rawValue)")
            }
            finish()
          case .failed, .cancelled: finish()
          default: break
          }
        }
        candidate.start(queue:queue)
      }
      browser.stateUpdateHandler = { state in
        if case .failed = state { finish() }
      }
      browser.start(queue:queue)
      queue.asyncAfter(deadline:.now() + Double(timeout.components.seconds)) { finish() }
    }
  }
}
