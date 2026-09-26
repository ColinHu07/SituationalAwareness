import Foundation
import UIKit
import Vision

/// Legacy prints are retained for decoding old profiles only; they are never used as identity embeddings.
struct FaceSample: Codable, Identifiable, Hashable {
  var id = UUID()
  var print: Data = Data()
  var thumbnail: Data
  var embedding: [Float]? = nil
  var modelID: String? = nil
  /// Set when saved automatically from live video; nil for photos the wearer added.
  var capturedAt: Date? = nil
  var fromVideo: Bool { capturedAt != nil }
  var isCompatible: Bool { modelID == FaceEmbedding.modelID && embedding.flatMap(FaceEmbedding.normalized) != nil }
}

struct FaceGallery: Sendable {
  struct Key: Equatable, Sendable { let personID: UUID; let samples: [FaceSample] }
  let entries: [(personID: UUID, embedding: [Float])]
  let key: [Key]
  static func key(for people: [Person]) -> [Key] { people.map { Key(personID:$0.id, samples:$0.faces) } }
  init(people: [Person]) {
    entries = people.flatMap { person in
      person.faces.compactMap { sample in
        guard sample.isCompatible, let vector = sample.embedding.flatMap(FaceEmbedding.normalized) else { return nil }
        return (person.id, vector)
      }
    }
    key = Self.key(for:people)
  }
  var isEmpty: Bool { entries.isEmpty }
}

struct FaceMatch: Equatable { let personID: UUID; let distance: Float }

/// Frames and identity embeddings stay on device. Uncertain faces remain unknown.
enum FaceRecognizer {
  static let minimumFaceSide: CGFloat = 80
  /// Provisional unit-embedding L2 thresholds; calibrate with held-out camera images.
  static let defaultThreshold: Float = 0.85
  static let ambiguityMargin: Float = 0.12
  struct DetectedFace: @unchecked Sendable { let embedding: [Float]; let crop: CGImage; let area: CGFloat }

  static func faces(in image: UIImage, enrollment: Bool = false) throws -> [DetectedFace] {
    guard let cgImage = upright(image) else { return [] }
    let detect = VNDetectFaceLandmarksRequest()
    try VNImageRequestHandler(cgImage:cgImage).perform([detect])
    let observations = detect.results ?? []
    if enrollment && observations.count > 1 {
      throw CopilotError(message:"More than one face found. Crop the photo to just this person and try again.")
    }
    let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
    return try observations.prefix(6).compactMap { face in
      let box = face.boundingBox
      let w = box.width * width, h = box.height * height
      guard min(w, h) >= minimumFaceSide, face.confidence >= 0.8,
            abs(face.yaw?.doubleValue ?? 0) < 0.65,
            let crop = aligned(cgImage, face:face) else { return nil }
      return DetectedFace(embedding:try FaceNetEncoder.shared.embedding(for:crop), crop:crop, area:w * h)
    }
  }

  static func match(_ faces: [DetectedFace], gallery: FaceGallery, threshold: Float = defaultThreshold) -> [FaceMatch] {
    guard threshold.isFinite, threshold > 0, threshold <= 2 else { return [] }
    let candidates = faces.compactMap { face -> FaceMatch? in
      let ranked = rank(face, gallery:gallery)
      guard let first = ranked.first, first.distance <= threshold else { return nil }
      if ranked.count > 1, ranked[1].distance - first.distance < ambiguityMargin { return nil }
      return first
    }
    // Two different faces claiming the same profile in one frame are ambiguous.
    let counts = Dictionary(candidates.map { ($0.personID, 1) }, uniquingKeysWith:+)
    return candidates.filter { counts[$0.personID] == 1 }
  }

  static func rank(_ face: DetectedFace, gallery: FaceGallery) -> [FaceMatch] {
    var distances: [UUID: [Float]] = [:]
    for entry in gallery.entries {
      if let distance = FaceEmbedding.distance(face.embedding, entry.embedding) {
        distances[entry.personID, default:[]].append(distance)
      }
    }
    // With multiple photos, require support from the closest two, not one lucky outlier.
    return distances.map { id, values in
      let best = values.sorted().prefix(2)
      return FaceMatch(personID:id, distance:best.reduce(0, +) / Float(best.count))
    }.sorted { $0.distance == $1.distance ? $0.personID.uuidString < $1.personID.uuidString : $0.distance < $1.distance }
  }

  static func enroll(from image: UIImage) throws -> FaceSample {
    guard let face = try faces(in:image, enrollment:true).first else {
      throw CopilotError(message:"No clear face found. Use a well-lit photo of one person looking toward the camera, with both eyes visible.")
    }
    guard let sample = sample(from:face) else { throw CopilotError(message:"Couldn't save this face.") }
    return sample
  }

  /// Reject likely wrong-person uploads and cross-profile duplicates before saving.
  static func validateEnrollment(_ sample: FaceSample, personID: UUID, people: [Person]) throws {
    guard sample.isCompatible, let vector = sample.embedding else { throw CopilotError(message:"Please add a new face photo.") }
    let own = people.first { $0.id == personID }?.faces.filter(\.isCompatible) ?? []
    if !own.isEmpty, !own.contains(where: { FaceEmbedding.distance(vector, $0.embedding!).map { $0 <= 1.05 } ?? false }) {
      throw CopilotError(message:"This photo doesn't closely match this person's saved photos. Check the person and try a clearer photo.")
    }
    for other in people where other.id != personID {
      if other.faces.contains(where: { $0.isCompatible && FaceEmbedding.distance(vector, $0.embedding!).map { $0 < defaultThreshold } == true }) {
        throw CopilotError(message:"This face also matches \(other.name). Check the selected profile before adding it.")
      }
    }
  }

  // MARK: Stills saved from live video

  /// Only confident matches are saved, so a lookalike can't slowly take over a profile.
  static let stillMaxDistance: Float = 0.70
  /// A still must differ this much from every saved photo of the person (new angle or lighting).
  static let stillMinNovelty: Float = 0.30
  static let stillMinArea: CGFloat = 120 * 120
  static let maxUploadedFaces = 8
  static let maxVideoFaces = 12

  /// A still worth adding to this person's photos, or nil when it is too uncertain, too small,
  /// a near-duplicate of a saved photo, or also resembles someone else.
  static func stillWorthKeeping(_ face: DetectedFace, personID: UUID, distance: Float, people: [Person]) -> FaceSample? {
    guard distance <= stillMaxDistance, face.area >= stillMinArea,
          let person = people.first(where: { $0.id == personID }) else { return nil }
    let saved = person.faces.compactMap { $0.isCompatible ? $0.embedding : nil }
    guard saved.allSatisfy({ FaceEmbedding.distance(face.embedding, $0).map { $0 >= stillMinNovelty } ?? false }),
          var sample = sample(from:face) else { return nil }
    sample.capturedAt = Date()
    guard (try? validateEnrollment(sample, personID:personID, people:people)) != nil else { return nil }
    return sample
  }
  /// Uploaded photos (up to 8) are always kept; video stills keep the newest 12.
  static func trimmed(_ faces: [FaceSample]) -> [FaceSample] {
    Array(faces.filter { !$0.fromVideo }.suffix(maxUploadedFaces)) + Array(faces.filter(\.fromVideo).suffix(maxVideoFaces))
  }

  static func sample(from face: DetectedFace) -> FaceSample? {
    guard let vector = FaceEmbedding.normalized(face.embedding),
          let thumbnail = UIImage(cgImage:face.crop).jpegData(compressionQuality:0.85) else { return nil }
    return FaceSample(thumbnail:thumbnail, embedding:vector, modelID:FaceEmbedding.modelID)
  }

  /// Identical eye alignment for enrollment and camera frames, in top-left pixel coordinates.
  private static func aligned(_ image: CGImage, face: VNFaceObservation) -> CGImage? {
    func center(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
      guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
      let x = points.reduce(CGFloat(0)) { $0 + $1.x } / CGFloat(points.count)
      let y = points.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(points.count)
      let box = face.boundingBox
      return CGPoint(x:(box.minX + x * box.width) * CGFloat(image.width),
                     y:(1 - box.minY - y * box.height) * CGFloat(image.height))
    }
    guard let a = center(face.landmarks?.leftEye), let b = center(face.landmarks?.rightEye) else { return nil }
    let left = a.x < b.x ? a : b, right = a.x < b.x ? b : a
    let dx = right.x - left.x, dy = right.y - left.y
    let eyeDistance = hypot(dx, dy)
    guard eyeDistance >= 16 else { return nil }
    let scale = 60 / eyeDistance, angle = atan2(dy, dx)
    let transform = CGAffineTransform(a:scale * cos(angle), b:-scale * sin(angle),
                                     c:scale * sin(angle), d:scale * cos(angle), tx:0, ty:0)
    let mapped = left.applying(transform)
    var final = transform; final.tx = 50 - mapped.x; final.ty = 60 - mapped.y
    // Avoid artificial black borders when a face is partly outside the frame.
    let inverse = final.inverted()
    let bounds = CGRect(x:0, y:0, width:image.width, height:image.height)
    guard [CGPoint(x:0,y:0), CGPoint(x:159,y:0), CGPoint(x:0,y:159), CGPoint(x:159,y:159)]
      .allSatisfy({ bounds.contains($0.applying(inverse)) }) else { return nil }
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
    return UIGraphicsImageRenderer(size:CGSize(width:160, height:160), format:format).image { context in
      context.cgContext.concatenate(final)
      UIImage(cgImage:image).draw(in:bounds)
    }.cgImage
  }

  private static func upright(_ image: UIImage) -> CGImage? {
    // Bound work for large photo-library images while preserving orientation.
    let longest = max(image.size.width, image.size.height)
    guard longest > 0 else { return nil }
    let scale = min(1, 1600 / longest)
    let size = CGSize(width:image.size.width * scale, height:image.size.height * scale)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    return UIGraphicsImageRenderer(size:size, format:format).image { _ in image.draw(in:CGRect(origin:.zero, size:size)) }.cgImage
  }
}

/// Combines face matches and spoken names into "who's here", fully automatically.
/// - Two face matches within 10 seconds add a person.
/// - Hearing their name adds them right away (a face match nearby also counts as seen).
/// - An introduction ("this is my friend Sam") adds them.
/// - People drop off after 5 minutes without being seen or named; someone only ever
///   named (never seen) drops off after 2 minutes, since people talk about absent friends.
struct PresenceTracker {
  enum Source: String { case face, name, introduction }
  static let faceWindowMs: Double = 10_000
  static let fusionWindowMs: Double = 30_000
  static let expiryMs: Double = 300_000
  static let nameOnlyExpiryMs: Double = 120_000
  static let minimumSpeechConfidence = 0.65

  private(set) var faceHits: [UUID: [Double]] = [:]
  private(set) var sources: [UUID: Set<Source>] = [:]
  private(set) var confirmed: Set<UUID> = []
  /// Everyone who was here at any point this session (for learning on Stop).
  private(set) var everConfirmed: Set<UUID> = []
  /// When each person's name was last heard, including after they were confirmed.
  private(set) var lastHeard: [UUID: Double] = [:]
  private(set) var lastEvidence: [UUID: Double] = [:]
  /// People the wearer marked "Not here" stay out until they introduce themselves again.
  private(set) var dismissed: Set<UUID> = []

  /// Returns people newly added by this evidence.
  mutating func recordFaces(_ ids: [UUID], at time: Double) -> [UUID] {
    var seen: Set<UUID> = []
    return ids.filter { id in
      guard seen.insert(id).inserted, faceHits[id]?.last != time else { return false }
      faceHits[id] = (faceHits[id] ?? []).filter { time - $0 <= Self.faceWindowMs } + [time]
      guard !dismissed.contains(id) else { return false }
      if confirmed.contains(id) { sources[id, default:[]].insert(.face); lastEvidence[id] = time; return false }
      let seenTwice = faceHits[id]!.count >= 2
      let heardNearby = lastHeard[id].map { abs(time - $0) <= Self.fusionWindowMs } ?? false
      guard seenTwice || heardNearby else { return false }
      return add(id, [.face] + (heardNearby ? [.name] : []), at:time)
    }
  }
  mutating func recordNames(_ ids: [UUID], at time: Double) -> [UUID] {
    ids.filter { id in
      lastHeard[id] = time
      guard !dismissed.contains(id) else { return false }
      if confirmed.contains(id) { sources[id, default:[]].insert(.name); lastEvidence[id] = time; return false }
      let seenNearby = (faceHits[id] ?? []).contains { abs(time - $0) <= Self.fusionWindowMs }
      return add(id, [.name] + (seenNearby ? [.face] : []), at:time)
    }
  }
  /// Someone introduced by name in conversation.
  mutating func introduce(_ id: UUID, at time: Double) {
    dismissed.remove(id); lastHeard[id] = time
    _ = add(id, [.introduction], at:time)
  }
  mutating func dismiss(_ id: UUID) {
    dismissed.insert(id); confirmed.remove(id); sources[id] = nil
  }
  /// Removes people with no recent evidence; returns who left.
  mutating func expire(at time: Double) -> [UUID] {
    let gone = confirmed.filter { id in
      let seen = sources[id].map { $0.contains(.face) || $0.contains(.introduction) } ?? false
      return time - (lastEvidence[id] ?? time) > (seen ? Self.expiryMs : Self.nameOnlyExpiryMs)
    }
    for id in gone { confirmed.remove(id); sources[id] = nil; faceHits[id] = nil }
    return Array(gone)
  }
  mutating func reset() { self = PresenceTracker() }

  private mutating func add(_ id: UUID, _ found: [Source], at time: Double) -> Bool {
    let isNew = confirmed.insert(id).inserted
    everConfirmed.insert(id)
    sources[id, default:[]].formUnion(found)
    lastEvidence[id] = time
    return isNew
  }

  /// Names someone introduces in speech ("my name is Priya", "this is my friend Dev", "nice to meet you, Sam").
  /// ASR capitalizes proper nouns, so a capitalized word is required to avoid "I'm tired".
  static func introducedNames(in text: String) -> [String] {
    // (?i:…) makes only the trigger phrase case-insensitive; the captured name must be capitalized.
    let name = #"(\p{Lu}[\p{L}'-]{1,20})"#
    let relation = #"(?: my (?:friend|roommate|coworker|colleague|classmate|cousin|brother|sister|partner|boss|teammate|neighbor))?"#
    let patterns = [
      #"(?i:\bmy name(?: is|'s)\s+)"# + name,
      #"(?i:\bcall me\s+)"# + name,
      #"(?i:\b(?:this is|meet|say hi to|say hello to)"# + relation + #"\s+)"# + name,
      #"(?i:\bnice to meet you,?\s+)"# + name,
      #"(?i:^(?:hi|hey|hello)[,!]?\s+(?:i'm|i am)\s+)"# + name,
      #"(?i:\b(?:i'm|i am)\s+)"# + name + #"(?i:\s*[,.!]?\s*(?:nice|pleasure|good) to meet)"#,
    ]
    var found: [String] = []
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern:pattern) else { continue }
      for match in regex.matches(in:text, range:NSRange(text.startIndex..., in:text)) {
        guard let range = Range(match.range(at:1), in:text) else { continue }
        let candidate = String(text[range])
        if !notNames.contains(candidate.lowercased()), !found.contains(candidate) { found.append(candidate) }
      }
    }
    return found
  }
  private static let notNames: Set<String> = ["i", "the", "here", "there", "so", "just", "really", "sorry", "fine", "good", "great", "not",
    "going", "glad", "happy", "sure", "okay", "ok", "back", "done", "ready", "home", "right", "well", "actually", "very", "what", "that",
    "it", "is", "a", "an", "my", "your", "our", "his", "her", "their", "everyone", "everybody", "you", "all", "also", "still"]

  /// Names said *to* someone: "Hey Marcus", "Marcus, did you…", "Thanks, Marcus", "See you later, Lena".
  /// A name only talked about ("Did Marcus text you?") is not included: that person may not be here.
  static func addressedNames(in text: String) -> [String] {
    let name = #"(\p{Lu}[\p{Ll}'-]{1,20})"#
    let greeting = #"(?i:hey|hi|hello|yo|sup|thanks|thank you|bye|morning|good morning|good to see you|see you|see ya|what's up|how are you)"#
    let patterns = [
      #"\b"# + greeting + #",?\s+"# + name + #"\b"#,                              // (oh) hey Marcus / Thanks, Marcus
      #"(?:^|[.!?]\s+)"# + name + #"\s*,"#,                                       // Marcus, did you finish?
      #",\s*"# + name + #"\s*[.!?]?\s*$"#,                                       // …see you later, Lena.
    ]
    var found: [String] = []
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern:pattern) else { continue }
      for match in regex.matches(in:text, range:NSRange(text.startIndex..., in:text)) {
        guard let range = Range(match.range(at:1), in:text) else { continue }
        let candidate = String(text[range])
        if !notNames.contains(candidate.lowercased()), !notAddressees.contains(candidate.lowercased()), !found.contains(candidate) { found.append(candidate) }
      }
    }
    return found
  }
  /// Capitalized words people use to address someone that are not names.
  private static let notAddressees: Set<String> = ["guys", "man", "dude", "bro", "bud", "buddy", "team", "folks", "sir", "ma'am", "madam",
    "babe", "honey", "mom", "dad", "mum", "god", "siri", "alexa", "google", "yes", "no", "yeah", "yep", "nope", "well", "okay", "anyway",
    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow", "tonight", "and", "but", "or",
    "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december", "then",
    "look", "listen", "wait", "please", "hey", "hi", "hello", "thanks", "bye", "oh", "um", "uh", "like", "because", "if", "when", "which"]

  /// Saved people whose first or full name appears as a whole, capitalized word in this speech.
  /// Capitalization is required (ASR capitalizes names) so "will" or "mark my words" don't add Will or Mark.
  static func mentionedPeople(in text: String, people: [Person]) -> [UUID] {
    people.filter { person in
      let full = person.name.trimmingCharacters(in:.whitespaces)
      let names = Set([full, full.split(separator:" ").first.map(String.init) ?? full]).filter { $0.count >= 2 }
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      return names.contains { name in
        text.range(of:"\\b\(NSRegularExpression.escapedPattern(for:name))\\b", options:[.regularExpression]) != nil
      }
    }.map(\.id)
  }
}
