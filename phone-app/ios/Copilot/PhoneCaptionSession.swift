import Foundation
import Observation

struct CaptionRow: Identifiable, Equatable {
  let id: String
  /// Raw session-local diarization label. Display names are resolved separately.
  let speakerLabel: String?
  let text: String
  var speakerName: String { speakerLabel ?? "Speaker…" }
}

// A speaker's next turn replaces only that speaker's row. Pending, unattributed
// turns have their own row until Muse supplies a session-local speaker label.
struct PhoneCaptionRoster {
  private struct Turn {
    let order: Int
    var speaker: String?
    var text = ""
    var updatedAt: Double
    var audioMs: Double?
    var finalized = false
  }
  private struct VisibleRow {
    var value: CaptionRow
    var updatedAt: Double
  }
  private struct LatestTurn {
    let id: Int
    let order: Int
    let audioMs: Double?
  }
  private var turns: [Int:Turn] = [:]
  private var latestBySpeaker: [String:LatestTurn] = [:]
  private var visible: [VisibleRow] = []
  private var nextOrder = 0
  var rows: [CaptionRow] { visible.map(\.value) }

  mutating func consume(_ event: RealtimeASREvent, at time: Double) {
    guard ["transcript.partial", "speaker.updated", "transcript.final"].contains(event.type),
          let id = event.turnId else { return }
    expire(at:time)
    var turn: Turn
    if let existing = turns[id] { turn = existing }
    else { nextOrder += 1; turn = Turn(order:nextOrder, updatedAt:time) }
    let pendingID = "turn:\(id)"
    if let speaker = event.speaker, Self.validSpeaker(speaker) { turn.speaker = speaker }
    if event.type != "speaker.updated" {
      guard !turn.finalized, let raw = event.text else { return }
      let text = raw.trimmingCharacters(in:.whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      turn.text = String(text.suffix(240))
      turn.finalized = event.type == "transcript.final"
    }
    turn.updatedAt = time
    if let audioMs = event.endAudioMs ?? event.audioProcessedMs, audioMs.isFinite {
      turn.audioMs = audioMs
    }
    turns[id] = turn
    guard !turn.text.isEmpty else { return }

    if let speaker = turn.speaker {
      if let latest = latestBySpeaker[speaker], latest.id != id,
         turn.order < latest.order || (turn.audioMs != nil && latest.audioMs != nil && turn.audioMs! < latest.audioMs!) {
        // Finalization can lag behind a newer turn. It may identify an older
        // pending row, but must never overwrite this speaker's newer caption.
        visible.removeAll { $0.value.id == pendingID }
        return
      }
      latestBySpeaker[speaker] = LatestTurn(id:id, order:turn.order, audioMs:turn.audioMs)
    }

    let rowID = turn.speaker ?? pendingID
    let row = CaptionRow(id:rowID, speakerLabel:turn.speaker, text:turn.text)
    if let index = visible.firstIndex(where: { $0.value.id == rowID }) {
      visible[index] = VisibleRow(value:row, updatedAt:time)
      if rowID != pendingID { visible.removeAll { $0.value.id == pendingID } }
    } else if let index = visible.firstIndex(where: { $0.value.id == pendingID }) {
      visible[index] = VisibleRow(value:row, updatedAt:time)
    } else {
      if visible.count == 3, let oldest = visible.indices.min(by: { visible[$0].updatedAt < visible[$1].updatedAt }) {
        visible.remove(at:oldest)
      }
      visible.append(VisibleRow(value:row, updatedAt:time))
    }
    // Bound turn bookkeeping independently of the visible three-person view.
    if turns.count > 100, let oldest = turns.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
      turns[oldest] = nil
    }
  }

  mutating func expire(at time: Double) {
    visible.removeAll { time - $0.updatedAt >= 15_000 }
  }

  private static func validSpeaker(_ value: String) -> Bool {
    guard value.hasPrefix("P"), let number = Int(value.dropFirst()), (1...99).contains(number) else { return false }
    return value == "P\(number)"
  }

}

@MainActor
protocol PhoneCaptionMicrophone: AnyObject {
  var onPCM: (@Sendable (Data, Double) -> Void)? { get set }
  var onFailure: (@Sendable (String) -> Void)? { get set }
  func startPhone() async throws
  func stop()
}
extension ConversationMicrophone: PhoneCaptionMicrophone {}

@MainActor
protocol PhoneCaptionRelay: AnyObject {
  var onEvent: ((RealtimeASREvent) -> Void)? { get set }
  var onFailure: ((String) -> Void)? { get set }
  var onSend: ((Int, Double) -> Void)? { get set }
  func start(languageBias: [String]) async throws
  func sendPCM(_ data: Data)
  func stop()
}
extension PhoneCaptionRelay {
  var onSend: ((Int, Double) -> Void)? { get { nil } set {} }
}
extension RealtimeASRClient: PhoneCaptionRelay {}

@Observable @MainActor
final class PhoneCaptionSession {
  enum Phase { case stopped, starting, listening }
  private(set) var phase: Phase = .stopped
  private(set) var status = ""
  private(set) var rows: [CaptionRow] = []
  let diagnostics = CaptionDiagnostics()
  @ObservationIgnored private let microphone: any PhoneCaptionMicrophone
  @ObservationIgnored private let makeRelay: (String, String) -> any PhoneCaptionRelay
  @ObservationIgnored private let healthCheck: (String, String) async throws -> HealthResponse
  @ObservationIgnored private var relay: (any PhoneCaptionRelay)?
  @ObservationIgnored private var startTask: Task<Void, Never>?
  @ObservationIgnored private var expiryTask: Task<Void, Never>?
  @ObservationIgnored private var epoch = 0
  @ObservationIgnored private var roster = PhoneCaptionRoster()
  @ObservationIgnored private var identityResolver = SpeakerIdentityResolver()
  @ObservationIgnored private var identityPresence = PresenceTracker()
  private struct FinalizedTurnRecord {
    let text: String
    var speakerAlias: String?
    var identityResolved: Bool
  }
  @ObservationIgnored private var realtimeSpeakers: [Int: String] = [:]
  @ObservationIgnored private var finalizedTurnRecords: [Int: FinalizedTurnRecord] = [:]
  @ObservationIgnored private var finalizedTurns: Set<Int> = []
  @ObservationIgnored private var peopleStore: PeopleStore?

  convenience init() {
    self.init(microphone:ConversationMicrophone(),
              makeRelay:{ RealtimeASRClient(endpoint:$0, token:$1) },
              healthCheck:{ try await APIClient(endpoint:$0, token:$1).health() })
  }

  init(microphone: any PhoneCaptionMicrophone,
       makeRelay: @escaping (String, String) -> any PhoneCaptionRelay,
       healthCheck: @escaping (String, String) async throws -> HealthResponse,
       people: PeopleStore? = nil) {
    self.microphone = microphone
    self.makeRelay = makeRelay
    self.healthCheck = healthCheck
    self.peopleStore = people
  }

  func attachPeople(_ people: PeopleStore) { peopleStore = people }

  func displaySpeakerName(for label: String?) -> String {
    guard let label else { return "Speaker…" }
    return identityResolver.displayName(for:label, people:peopleStore?.people ?? [])
  }

  func start(endpoint: String, token: String) {
    guard phase == .stopped else { return }
    epoch += 1
    let run = epoch
    diagnostics.reset()
    roster = PhoneCaptionRoster(); rows = []
    identityResolver.resetSession(); identityPresence.reset(); finalizedTurns = []
    realtimeSpeakers = [:]; finalizedTurnRecords = [:]
    phase = .starting; status = "Connecting…"
    microphone.onPCM = { [weak self] data, capturedAt in
      Task { @MainActor in
        guard let self, self.epoch == run, self.phase == .listening else { return }
        self.diagnostics.captured(bytes:data.count, endedAtMs:capturedAt)
        self.relay?.sendPCM(data)
      }
    }
    microphone.onFailure = { [weak self] message in
      Task { @MainActor in self?.fail(message, run:run) }
    }
    startTask = Task { [weak self] in
      guard let self else { return }
      do {
        let health = try await healthCheck(endpoint, token)
        guard epoch == run, !Task.isCancelled else { return }
        guard health.modelMode == "live" else {
          throw CopilotError(message:"Live captions need a live Muse server. Check your server settings and try again.")
        }
        guard health.tokenValid != false else {
          throw CopilotError(message:"The server token was rejected. Check your token in Settings and try again.")
        }
        diagnostics.record("Proxy health checked; connecting to Muse")
        let connection = makeRelay(endpoint, token)
        relay = connection // Retain before awaiting so Stop cancels the handshake.
        connection.onEvent = { [weak self] event in self?.receive(event, run:run) }
        connection.onFailure = { [weak self] message in self?.fail(message, run:run) }
        connection.onSend = { [weak self] bytes, duration in
          guard let self, self.epoch == run, self.phase == .listening else { return }
          self.diagnostics.sent(bytes:bytes, durationMs:duration)
        }
        try await connection.start(languageBias:["English", "Hindi"])
        guard epoch == run, !Task.isCancelled else { return }
        status = "Starting microphone…"
        diagnostics.record("Muse ready; requesting microphone")
        try await microphone.startPhone()
        guard epoch == run, !Task.isCancelled else { return }
        phase = .listening; status = "Listening…"
        diagnostics.record("Microphone started; listening")
        startTask = nil
        expiryTask = Task { [weak self] in
          while !Task.isCancelled {
            do { try await Task.sleep(for:.seconds(1)) } catch { return }
            guard let self, self.epoch == run, self.phase == .listening else { return }
            self.roster.expire(at:nowMs())
            self.rows = self.roster.rows
          }
        }
      } catch {
        guard epoch == run, !Task.isCancelled else { return }
        fail(error.localizedDescription, run:run)
      }
    }
  }

  func stop() {
    if phase != .stopped { diagnostics.record("Stopped; audio capture and connection closed") }
    epoch += 1
    startTask?.cancel(); startTask = nil
    expiryTask?.cancel(); expiryTask = nil
    relay?.onEvent = nil; relay?.onFailure = nil
    relay?.onSend = nil
    relay?.stop(); relay = nil
    microphone.onPCM = nil; microphone.onFailure = nil
    microphone.stop()
    roster = PhoneCaptionRoster(); rows = []
    identityResolver.resetSession(); identityPresence.reset(); finalizedTurns = []
    realtimeSpeakers = [:]; finalizedTurnRecords = [:]
    phase = .stopped; status = "Stopped. Captions cleared."
  }

  func sceneBecameInactive() { stop() }

  private func receive(_ event: RealtimeASREvent, run: Int) {
    guard epoch == run, phase != .stopped else { return }
    let receivedAt = ProcessInfo.processInfo.systemUptime
    diagnostics.received(event)
    guard phase == .listening,
          ["transcript.partial", "transcript.final", "speaker.updated"].contains(event.type),
          let id = event.turnId else { return }
    let previousRows = rows
    if let speaker = event.speaker, SpeakerIdentityResolver.validLabel(speaker) {
      realtimeSpeakers[id] = speaker
    }
    roster.consume(event, at:nowMs())

    if event.type == "speaker.updated",
       let speakerAlias = realtimeSpeakers[id],
       var record = finalizedTurnRecords[id] {
      if !record.identityResolved {
        record.speakerAlias = speakerAlias
        record.identityResolved = true
        finalizedTurnRecords[id] = record
        let profiles = peopleStore?.people ?? []
        if let person = SpeakerIdentityResolver.selfIdentifiedPerson(in:record.text, people:profiles) {
          identityPresence.introduce(person.id, at:nowMs())
        }
        _ = identityResolver.observeFinalTurn(label:speakerAlias, text:record.text, people:profiles,
                                              presentPersonIDs:identityPresence.confirmed)
      }
    }

    if event.type == "transcript.final", finalizedTurns.insert(id).inserted {
      if finalizedTurns.count > 256, let oldest = finalizedTurns.min() {
        finalizedTurns.remove(oldest)
        realtimeSpeakers[oldest] = nil
        finalizedTurnRecords[oldest] = nil
      }
      if let text = event.text?.trimmingCharacters(in:.whitespacesAndNewlines), !text.isEmpty {
        let speakerAlias = (event.speaker.flatMap { SpeakerIdentityResolver.validLabel($0) ? $0 : nil }) ?? realtimeSpeakers[id]
        let profiles = peopleStore?.people ?? []
        if let person = SpeakerIdentityResolver.selfIdentifiedPerson(in:text, people:profiles) {
          identityPresence.introduce(person.id, at:nowMs())
        }
        var identityResolved = false
        if let speakerAlias {
          _ = identityResolver.observeFinalTurn(label:speakerAlias, text:text, people:profiles,
                                                presentPersonIDs:identityPresence.confirmed)
          identityResolved = true
        }
        finalizedTurnRecords[id] = FinalizedTurnRecord(text:text, speakerAlias:speakerAlias, identityResolved:identityResolved)
      }
    }

    rows = roster.rows
    diagnostics.applied(event:event, durationMs:(ProcessInfo.processInfo.systemUptime-receivedAt)*1000, changed:rows != previousRows)
  }

  private func fail(_ message: String, run: Int) {
    guard epoch == run, phase != .stopped else { return }
    stop()
    status = message
  }
}
