import Foundation
import CoreML
import Vision

/// Version includes weights, image normalization and alignment. Never compare across versions.
enum FaceEmbedding {
  static let modelID = "facenet-vggface2-512-vision-eyes-v1"
  static let dimensions = 512

  static func normalized(_ values: [Float]) -> [Float]? {
    guard values.count == dimensions, values.allSatisfy(\.isFinite) else { return nil }
    let norm = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
    guard norm.isFinite, norm > 0.000001 else { return nil }
    return values.map { $0 / norm }
  }

  /// Euclidean distance of unit embeddings (0…2), not a probability.
  static func distance(_ lhs: [Float], _ rhs: [Float]) -> Float? {
    guard let a = normalized(lhs), let b = normalized(rhs) else { return nil }
    return sqrt(zip(a, b).reduce(Float(0)) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) })
  }
}

/// Serialized inference permits photo enrollment and live matching to share one model safely.
final class FaceNetEncoder: @unchecked Sendable {
  static let shared = FaceNetEncoder()
  private let lock = NSLock()
  private var model: VNCoreMLModel?

  func embedding(for crop: CGImage) throws -> [Float] {
    lock.lock(); defer { lock.unlock() }
    if model == nil {
      guard let url = Bundle.main.url(forResource:"FaceNet", withExtension:"mlmodelc") else {
        throw CopilotError(message:"FaceNet is missing from this build. Rebuild the app with the bundled model.")
      }
      let config = MLModelConfiguration()
      #if targetEnvironment(simulator)
      config.computeUnits = .cpuOnly
      #else
      config.computeUnits = .all
      #endif
      let loaded = try MLModel(contentsOf:url, configuration:config)
      let metadata = loaded.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
      guard metadata?["aside.model_id"] == FaceEmbedding.modelID else {
        throw CopilotError(message:"The face model version is incompatible. Rebuild with the matching FaceNet model.")
      }
      model = try VNCoreMLModel(for:loaded)
    }
    let request = VNCoreMLRequest(model:model!)
    request.imageCropAndScaleOption = .scaleFill
    try VNImageRequestHandler(cgImage:crop).perform([request])
    guard let output = (request.results as? [VNCoreMLFeatureValueObservation])?.first(where: { $0.featureName == "embedding" })?.featureValue.multiArrayValue,
          output.count == FaceEmbedding.dimensions,
          let result = FaceEmbedding.normalized((0..<output.count).map { output[$0].floatValue }) else {
      throw CopilotError(message:"FaceNet returned an invalid face embedding.")
    }
    return result
  }
}
