import Foundation

enum CaptureMode: String, CaseIterable, Identifiable {
  case phone = "iPhone"
  case regularGlasses = "Meta glasses"
  case displayGlasses = "Display glasses"
  case simulated = "Simulated demo"
  var id: String { rawValue }
  var needsGlasses: Bool { self == .regularGlasses || self == .displayGlasses }
  var hasGlassesDisplay: Bool { self == .displayGlasses }
}

/// Arrival time proves transport activity, not freshness of the captured content.
struct CaptureActivity {
  var videoReceivedAtMs = 0.0
  var audioReceivedAtMs = 0.0
  func isReceiving(requiresVideo: Bool, requiresAudio: Bool, at timestamp: Double) -> Bool {
    func recent(_ received: Double) -> Bool {
      received > 0 && received <= timestamp + 1000 && timestamp - received <= 10000
    }
    return (!requiresVideo || recent(videoReceivedAtMs)) && (!requiresAudio || recent(audioReceivedAtMs))
  }
}

// Scene checks run on a backup timer. Conversation checks fire at a moment instead: see ConversationPolicy.
enum SurroundingsPolicy {
  /// Seconds between automatic scene checks. Only one check runs at a time, so model latency also limits the rate.
  static func analysisInterval(recentSpeech: Bool, reducedPower: Bool) -> Double {
    30
  }
  /// Scene cues keep the scene prompt's own confidence bar.
  static let displayConfidence = 0.6
  /// After the wearer dismisses a cue, automatic checks wait this long.
  static let dismissQuietMs = 10_000.0
  static let contextWindowMs = 10_000.0
  /// Session memory: summaries kept and sent with each check.
  static let momentCount = 8
  static let frameFreshnessMs = 10_000.0
  // Live Spark checks took about 10 seconds; preserve a bounded delivery window
  // distinct from the stricter age of the image at request time.
  static let deliveryFreshnessMs = 30_000.0
  /// Live Muse cues take ~13 s, so evidence and responses may be this old when shown.
  static let responseMaxAgeMs = 30_000.0
}
