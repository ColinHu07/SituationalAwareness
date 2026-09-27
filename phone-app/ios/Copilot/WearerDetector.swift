import Foundation

/// Speech loudness of the audio sent for live captions, addressed by position in that stream.
/// Caption turns carry stream positions, so a turn's level can be read back without relying on clocks.
/// Only one number per 20 ms frame is kept. No audio is retained.
struct SpeechLevelTrack {
  /// 20 ms at 16 kHz, and the same voiced bar, as `ConversationMicrophone.speechLevel`.
  static let frameSamples = 320
  static let voicedRMS = 0.012
  static let frameMs = 20.0
  /// Frames kept: 90 seconds.
  static let capacity = 4_500
  /// Fewer frames than this say nothing reliable about a turn.
  static let minimumFrames = 5
  /// A turn with audio but no voiced frames is at most this loud.
  static let floorDbFS = 20 * log10(voicedRMS)

  private var powers: [Double] = []
  private var firstFrame = 0
  private var pending: [Int16] = []

  /// Adds PCM16 mono 16 kHz audio in the order it is sent.
  mutating func append(_ pcm: Data) {
    let count = pcm.count / 2
    guard count > 0 else { return }
    var samples = [Int16](repeating:0, count:count)
    _ = samples.withUnsafeMutableBytes { pcm.copyBytes(to:$0, count:count * 2) }
    pending.append(contentsOf:samples)
    var index = 0
    while index + Self.frameSamples <= pending.count {
      var energy = 0.0
      for sample in pending[index..<(index + Self.frameSamples)] { let value = Double(sample) / 32768; energy += value * value }
      powers.append(energy / Double(Self.frameSamples))
      index += Self.frameSamples
    }
    pending.removeFirst(index)
    if powers.count > Self.capacity {
      let extra = powers.count - Self.capacity
      powers.removeFirst(extra); firstFrame += extra
    }
  }

  /// Loudness of the voiced frames between two stream positions, in dBFS.
  /// Returns the floor when there was audio but no voice, and nil when the audio is not held.
  func level(fromMs: Double?, toMs: Double?) -> Double? {
    guard let fromMs, let toMs, fromMs.isFinite, toMs.isFinite, toMs > fromMs else { return nil }
    let lower = max(firstFrame, Int((max(0, fromMs) / Self.frameMs).rounded(.down)))
    let upper = min(firstFrame + powers.count, Int((toMs / Self.frameMs).rounded(.up)))
    guard upper - lower >= Self.minimumFrames else { return nil }
    let voiced = powers[(lower - firstFrame)..<(upper - firstFrame)].filter { $0.squareRoot() > Self.voicedRMS }
    guard voiced.count >= Self.minimumFrames else { return Self.floorDbFS }
    return 10 * log10(voiced.reduce(0, +) / Double(voiced.count))
  }
}

/// Finds the wearer among live-caption speaker labels. The glasses microphone sits next to the wearer's
/// mouth, so their turns are the loudest. This is a loudness heuristic, not voice identification.
struct WearerDetector: Equatable {
  /// Turns a voice needs before it can be chosen.
  static let minimumTurns = 2
  /// "Clearly louder": 6 dB is about twice as loud at the microphone.
  static let marginDb = 6.0
  /// Recent turns averaged per voice, so a long session can still be re-evaluated.
  static let recentTurns = 8

  /// The caption label treated as the wearer. Labels are reassigned whenever captions restart.
  private(set) var wearerLabel: String?
  /// The wearer's average level. Kept for the whole session, so the voice is found again after captions restart.
  private(set) var wearerLevelDbFS: Double?
  /// The loudest other voice when the wearer was last evaluated.
  private(set) var otherLevelDbFS: Double?
  /// True after "That was me". Automatic re-evaluation leaves an explicit choice alone until captions restart.
  private(set) var claimed = false
  private var levels: [String: [Double]] = [:]
  private var lastLabel: String?
  private var lastLevelDbFS: Double?

  /// Whether turns can be told apart: a label is chosen, or the wearer's level is remembered.
  var knowsWearer: Bool { wearerLabel != nil || wearerLevelDbFS != nil }
  /// Every labeled voice heard, in label order, with its recent turns and their average level.
  var voiceLevels: [(label: String, turns: Int, levelDbFS: Double)] {
    levels.keys.sorted().compactMap { label in average(label).map { (label, levels[label]?.count ?? 0, $0) } }
  }
  /// Whether "That was me" has a turn to learn from.
  var canClaim: Bool { lastLabel != nil || lastLevelDbFS != nil }

  /// One finished caption turn. Turns without a label or a level are remembered only for "That was me".
  mutating func record(label: String?, levelDbFS: Double?) {
    let level = levelDbFS.flatMap { $0.isFinite ? $0 : nil }
    lastLabel = label; lastLevelDbFS = level
    guard let label, let level else { return }
    levels[label] = Array((levels[label, default:[]] + [level]).suffix(Self.recentTurns))
    evaluate(latest:label)
  }

  /// Level at or above which a voice counts as the wearer's, once the wearer's level is known.
  var wearerBarDbFS: Double? {
    wearerLevelDbFS.map { wearer in max(wearer - Self.marginDb, otherLevelDbFS.map { ($0 + wearer) / 2 } ?? -.infinity) }
  }

  /// "That was me": the most recent turn was the wearer's. Returns false when there is nothing to learn from.
  @discardableResult mutating func claimLastTurn() -> Bool {
    if let label = lastLabel {
      wearerLabel = label; claimed = true
      wearerLevelDbFS = average(label) ?? lastLevelDbFS ?? wearerLevelDbFS
      otherLevelDbFS = loudest(except:label)
      return true
    }
    // Captions are stopped, so there is no label to keep. The voice is found again by its level.
    guard let level = lastLevelDbFS else { return false }
    wearerLabel = nil; claimed = false; wearerLevelDbFS = level; otherLevelDbFS = nil
    return true
  }

  /// Captions stopped. The next caption session numbers its voices afresh, so labels and their
  /// averages are dropped. The wearer's level stays.
  mutating func captionsRestarted() {
    levels = [:]; wearerLabel = nil; claimed = false; lastLabel = nil
  }

  /// The session ended.
  mutating func reset() { self = WearerDetector() }

  private func average(_ label: String) -> Double? {
    guard let values = levels[label], !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
  }
  private func loudest(except label: String) -> Double? {
    levels.keys.filter { $0 != label }.compactMap(average).max()
  }

  private mutating func evaluate(latest: String) {
    if let current = wearerLabel {
      // Keep the wearer. Re-evaluate only when another voice is consistently and clearly louder.
      let challenger = levels.keys.filter { $0 != current && (levels[$0]?.count ?? 0) >= Self.minimumTurns }
        .compactMap { label in average(label).map { (label, $0) } }.max { $0.1 < $1.1 }
      if !claimed, let challenger, challenger.1 >= (average(current) ?? wearerLevelDbFS ?? -.infinity) + Self.marginDb {
        wearerLabel = challenger.0
      }
    } else if let bar = wearerBarDbFS, let level = average(latest), level >= bar, level >= loudest(except:latest) ?? -.infinity {
      // Captions restarted: the first voice at the wearer's remembered level is the wearer again.
      wearerLabel = latest
    } else if let candidate = levels.keys.compactMap({ label in average(label).map { (label, $0) } }).max(by: { $0.1 < $1.1 }),
              (levels[candidate.0]?.count ?? 0) >= Self.minimumTurns,
              let other = loudest(except:candidate.0), candidate.1 >= other + Self.marginDb {
      // The consistently loudest voice, clearly louder than every other voice heard so far.
      wearerLabel = candidate.0
    }
    guard let current = wearerLabel else { return }
    wearerLevelDbFS = average(current) ?? wearerLevelDbFS
    otherLevelDbFS = loudest(except:current) ?? otherLevelDbFS
  }
}
