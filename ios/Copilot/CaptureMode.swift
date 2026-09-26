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
    case .displayGlasses: return "Glasses camera and selected HFP microphone. Captions and suggestions also appear on the glasses."
    case .simulated: return "Typed speech and a synthetic image. No camera or microphone capture."
    }
  }
}
