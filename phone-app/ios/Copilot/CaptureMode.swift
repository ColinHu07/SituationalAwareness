import Foundation

enum CaptureMode: String, CaseIterable, Identifiable {
  case phone = "iPhone"
  case regularGlasses = "Meta glasses"
  case displayGlasses = "Display glasses"
  case simulated = "Simulated demo"
  var id: String { rawValue }
  var needsGlasses: Bool { self == .regularGlasses || self == .displayGlasses }
  var hasGlassesDisplay: Bool { self == .displayGlasses }
  var description: String {
    switch self {
    case .phone: return "iPhone camera and microphone. Captions, saved notes and suggestions appear here."
    case .regularGlasses: return "Glasses camera and selected HFP microphone. Captions and notes appear on the phone; these glasses have no display."
    case .displayGlasses: return "Glasses camera and ambient audio help Muse understand the setting and conversation. Brief social cues appear on the glasses."
    case .simulated: return "Typed speech and a synthetic image. No camera or microphone capture."
    }
  }
}

// Inference cadence is independent of camera transport and cue display cooldown.
enum SurroundingsPolicy {
  static func analysisInterval(recentSpeech: Bool, reducedPower: Bool) -> Double {
    reducedPower ? 30 : recentSpeech ? 8 : 20
  }
  static let cueCooldownMs = 30_000.0
  static let frameFreshnessMs = 10_000.0
  // Live Spark checks took about 10 seconds; preserve a bounded delivery window
  // distinct from the stricter age of the image at request time.
  static let deliveryFreshnessMs = 20_000.0
}
