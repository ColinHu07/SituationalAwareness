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

// Inference cadence is independent of camera transport and cue display cooldown.
enum SurroundingsPolicy {
  /// Seconds between automatic checks. Only one check runs at a time, so model latency also limits the rate.
  static func analysisInterval(recentSpeech: Bool, reducedPower: Bool) -> Double {
    reducedPower ? 15 : recentSpeech ? 3 : 5
  }
  /// A cue stays on screen at least this long before a different one replaces it, so it can be read.
  static let minimumDwellMs = 5_000.0
  /// After the wearer dismisses a cue, automatic checks wait this long.
  static let dismissQuietMs = 10_000.0
  /// Session memory: summaries kept and sent with each check.
  static let momentCount = 8
  static let frameFreshnessMs = 10_000.0
  // Live Spark checks took about 10 seconds; preserve a bounded delivery window
  // distinct from the stricter age of the image at request time.
  static let deliveryFreshnessMs = 30_000.0
  /// Live Muse cues take ~13 s, so evidence and responses may be this old when shown.
  static let responseMaxAgeMs = 30_000.0
}
