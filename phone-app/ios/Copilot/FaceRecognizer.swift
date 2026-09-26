import Foundation
import UIKit
import Vision

/// One enrolled face: a Vision feature print of a cropped face plus a small thumbnail for the People editor.
struct FaceSample: Codable, Identifiable, Hashable {
  var id = UUID()
  var print: Data
  var thumbnail: Data
}

/// Enrolled faces decoded once for matching; rebuilt when enrollment changes.
struct FaceGallery: @unchecked Sendable {
  let entries: [(personID: UUID, print: VNFeaturePrintObservation)]
  let key: [UUID]
  init(people: [Person]) {
    var entries: [(UUID, VNFeaturePrintObservation)] = []
    for person in people {
      for sample in person.faces { if let print = FaceRecognizer.decode(sample.print) { entries.append((person.id, print)) } }
    }
    self.entries = entries
    key = people.flatMap { $0.faces.map(\.id) }
  }
  var isEmpty: Bool { entries.isEmpty }
}

struct FaceMatch: Equatable { let personID: UUID; let distance: Float }

/// On-device only. Frames are never uploaded for recognition, and faces that match
/// no enrolled person are discarded after comparison.
enum FaceRecognizer {
  /// Faces smaller than this (pixels, shorter side) are too blurry to compare.
  static let minimumFaceSide: CGFloat = 48
  /// Generic Vision feature prints are not a trained face-identity model. These defaults
  /// need calibration on real enrollment photos; the People screen shows live distances.
  static let defaultThreshold: Float = 0.55
  static let ambiguityMargin: Float = 0.05

  struct DetectedFace: @unchecked Sendable { let print: VNFeaturePrintObservation; let crop: CGImage; let area: CGFloat }

  static func faces(in image: UIImage) throws -> [DetectedFace] {
    guard let cgImage = upright(image) else { return [] }
    let detect = VNDetectFaceRectanglesRequest()
    try VNImageRequestHandler(cgImage:cgImage).perform([detect])
    let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
    return try (detect.results ?? []).compactMap { face in
      // Vision boxes are normalized with a bottom-left origin; widen to include hair and jaw.
      let box = face.boundingBox
      var rect = CGRect(x:box.minX * width, y:(1 - box.maxY) * height, width:box.width * width, height:box.height * height)
      guard min(rect.width, rect.height) >= minimumFaceSide else { return nil }
      rect = rect.insetBy(dx:-rect.width * 0.2, dy:-rect.height * 0.2).intersection(CGRect(x:0, y:0, width:width, height:height))
      guard let crop = cgImage.cropping(to:rect.integral) else { return nil }
      let printRequest = VNGenerateImageFeaturePrintRequest()
      printRequest.imageCropAndScaleOption = .scaleFill
      try VNImageRequestHandler(cgImage:crop).perform([printRequest])
      guard let print = printRequest.results?.first else { return nil }
      return DetectedFace(print:print, crop:crop, area:rect.width * rect.height)
    }
  }

  /// Best enrolled person for each detected face. A face matches only when it is within the
  /// threshold and clearly closer to one person than to anyone else.
  static func match(_ faces: [DetectedFace], gallery: FaceGallery, threshold: Float = defaultThreshold) -> [FaceMatch] {
    faces.compactMap { face in
      let ranked = rank(face, gallery:gallery)
      guard let first = ranked.first, first.distance <= threshold else { return nil }
      if ranked.count > 1, ranked[1].distance - first.distance < ambiguityMargin { return nil }
      return first
    }
  }
  /// Closest distance to each enrolled person, nearest first. Also used to show calibration numbers.
  static func rank(_ face: DetectedFace, gallery: FaceGallery) -> [FaceMatch] {
    var best: [UUID: Float] = [:]
    for entry in gallery.entries {
      var distance: Float = .greatestFiniteMagnitude
      guard (try? face.print.computeDistance(&distance, to:entry.print)) != nil else { continue }
      best[entry.personID] = min(best[entry.personID] ?? .greatestFiniteMagnitude, distance)
    }
    return best.map { FaceMatch(personID:$0.key, distance:$0.value) }.sorted { $0.distance < $1.distance }
  }

  /// Enrollment: the largest face in a photo of this person.
  static func enroll(from image: UIImage) throws -> FaceSample {
    guard let face = try faces(in:image).max(by: { $0.area < $1.area }) else {
      throw CopilotError(message:"No clear face found. Use a well-lit photo where the face is large and facing the camera.")
    }
    guard let sample = sample(from:face) else { throw CopilotError(message:"Couldn't save this face.") }
    return sample
  }
  static func sample(from face: DetectedFace) -> FaceSample? {
    guard let print = encode(face.print) else { return nil }
    let thumb = UIImage(cgImage:face.crop)
    let side: CGFloat = 96
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let small = UIGraphicsImageRenderer(size:CGSize(width:side, height:side), format:format).image { _ in
      thumb.draw(in:CGRect(x:0, y:0, width:side, height:side))
    }
    return FaceSample(print:print, thumbnail:small.jpegData(compressionQuality:0.7) ?? Data())
  }

  static func encode(_ print: VNFeaturePrintObservation) -> Data? {
    try? NSKeyedArchiver.archivedData(withRootObject:print, requiringSecureCoding:true)
  }
  static func decode(_ data: Data) -> VNFeaturePrintObservation? {
    try? NSKeyedUnarchiver.unarchivedObject(ofClass:VNFeaturePrintObservation.self, from:data)
  }

  /// Redraws so pixel data matches the displayed orientation; Vision then needs no orientation hint.
  private static func upright(_ image: UIImage) -> CGImage? {
    if image.imageOrientation == .up, let cgImage = image.cgImage { return cgImage }
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    return UIGraphicsImageRenderer(size:image.size, format:format).image { _ in image.draw(at:.zero) }.cgImage
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
    ids.filter { id in
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
