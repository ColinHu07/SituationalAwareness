@preconcurrency import AVFoundation
import Foundation

@MainActor protocol CueSpeaking: AnyObject {
  var onPlaybackChanged: ((Bool) -> Void)? { get set }
  var onStatus: ((String?) -> Void)? { get set }
  var onDiagnostic: ((String) -> Void)? { get set }
  func prepare(for mode: CaptureMode) async throws
  func speak(_ cue: String, mode: CaptureMode)
  func stop()
  func endSession()
}

struct CueAudioOutput: Equatable {
  let uid: String
  let name: String
  let port: AVAudioSession.Port
}

@MainActor protocol CueAudioRouting: AnyObject {
  var outputs: [CueAudioOutput] { get }
  var volume: Float { get }
  func prepare(for mode: CaptureMode) async throws
  func activate(for mode: CaptureMode) throws
  func endSession()
}

extension CueAudioRouting {
  func prepare(for mode: CaptureMode) async throws { try activate(for:mode) }
}

@MainActor private final class SystemCueAudioRouting: CueAudioRouting {
  private let session = AVAudioSession.sharedInstance()
  private let voiceEngine = AVAudioEngine()
  private var voiceTapInstalled = false
  private var ownsSession = false
  private var voiceInputUID: String?
  var outputs: [CueAudioOutput] {
    session.currentRoute.outputs.map { .init(uid:$0.uid,name:$0.portName,port:$0.portType) }
  }
  var volume: Float { session.outputVolume }
  func prepare(for mode: CaptureMode) async throws {
    guard mode == .displayGlasses else { try activate(for:mode); return }
    // A2DP can remain selected yet be inaudible during DAT camera streaming.
    // Configure the same selected glasses' bidirectional voice route after
    // addCamera and BEFORE stream.start, per Meta's microphone/speaker guide.
    let selectedOutputs = outputs
    try session.setCategory(.playAndRecord, mode:.default, options:[.allowBluetoothHFP])
    try session.setActive(true)
    ownsSession = true
    let inputs = session.availableInputs ?? []
    let candidates = inputs.map { CueAudioOutput(uid:$0.uid,name:$0.portName,port:$0.portType) }
    guard let uid = CueSpeaker.voiceInputUID(selectedOutputs:selectedOutputs,availableInputs:candidates),
          let input = inputs.first(where: { $0.uid == uid }) else {
      throw CopilotError(message:"The selected glasses' Bluetooth voice route is unavailable. Reconnect them, then restart the session.")
    }
    try session.setPreferredInput(input)
    // A selected HFP route alone does not establish the Bluetooth voice link.
    // Start I/O before DAT, as Meta documents. Discard this beamformed input:
    // multi-speaker transcription must keep using the ambient DAT PCM feed.
    let node = voiceEngine.inputNode
    let format = node.outputFormat(forBus:0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw CopilotError(message:"Glasses Bluetooth voice audio has no usable format.")
    }
    node.installTap(onBus:0,bufferSize:1024,format:format) { _, _ in }
    voiceTapInstalled = true
    do {
      voiceEngine.prepare()
      try voiceEngine.start()
      try await Task.sleep(for:.seconds(2))
    } catch {
      stopVoiceLink()
      throw error
    }
    guard session.currentRoute.inputs.contains(where: { $0.uid == uid }),
          CueSpeaker.permitsOutput(mode:mode,ports:outputs.map(\.port)) else {
      stopVoiceLink()
      throw CopilotError(message:"Glasses voice audio did not connect. Reconnect the glasses and restart the session.")
    }
    voiceInputUID = uid
  }
  func activate(for mode: CaptureMode) throws {
    if mode == .displayGlasses {
      // Never switch to HFP for the first time under an already-running camera.
      guard let uid = voiceInputUID, session.category == .playAndRecord,
            session.currentRoute.inputs.contains(where: { $0.uid == uid }) else {
        throw CopilotError(message:"Restart the glasses session to connect voice audio before the camera.")
      }
    }
    // Preserve the phone/HFP capture category and preferred input.
    try session.setActive(true)
  }
  func endSession() {
    stopVoiceLink()
    if ownsSession {
      try? session.setActive(false, options:.notifyOthersOnDeactivation)
      ownsSession = false
    }
    voiceInputUID = nil
  }
  private func stopVoiceLink() {
    voiceEngine.stop()
    if voiceTapInstalled {
      voiceEngine.inputNode.removeTap(onBus:0)
      voiceTapInstalled = false
    }
  }
}

/// Only accepted social cues enter this service; transcripts never do.
@MainActor final class CueSpeaker: NSObject, CueSpeaking, AVSpeechSynthesizerDelegate {
  var onPlaybackChanged: ((Bool) -> Void)?
  var onStatus: ((String?) -> Void)?
  var onDiagnostic: ((String) -> Void)?
  private let synthesizer: AVSpeechSynthesizer
  private let audio: any CueAudioRouting
  private let notifications: NotificationCenter
  private var current: AVSpeechUtterance?
  private var currentMode: CaptureMode = .simulated
  private var playbackOutputs: [CueAudioOutput] = []
  private var lastCompleted = ""
  private var pendingKey = ""
  private var routeWait: Task<Void, Never>?
  private var playbackTimeout: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  private var requestID = 0

  init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer(), audio: (any CueAudioRouting)? = nil,
       notifications: NotificationCenter = .default) {
    self.synthesizer = synthesizer
    self.audio = audio ?? SystemCueAudioRouting()
    self.notifications = notifications
    super.init()
    synthesizer.delegate = self
    synthesizer.usesApplicationAudioSession = true
    observers.append(notifications.addObserver(forName:AVAudioSession.routeChangeNotification,object:nil,queue:.main) { [weak self] notification in
      let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
      Task { @MainActor in self?.routeChanged(reason:reason) }
    })
    observers.append(notifications.addObserver(forName:AVAudioSession.interruptionNotification,object:nil,queue:.main) { [weak self] notification in
      let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
      Task { @MainActor in
        guard let self, type == AVAudioSession.InterruptionType.began.rawValue else { return }
        guard self.current != nil || !self.pendingKey.isEmpty else { return }
        self.stop()
        self.status("Cue audio interrupted; waiting for the next cue.")
      }
    })
  }

  deinit { observers.forEach(notifications.removeObserver) }

  func prepare(for mode: CaptureMode) async throws {
    guard mode != .simulated else { return }
    try await audio.prepare(for:mode)
    onDiagnostic?("Cue audio prepared; \(routeDescription)")
  }

  static func voiceInputUID(selectedOutputs: [CueAudioOutput], availableInputs: [CueAudioOutput]) -> String? {
    let selected = selectedOutputs.filter { [.bluetoothA2DP,.bluetoothHFP,.bluetoothLE].contains($0.port) }
    let matches = availableInputs.filter { input in
      input.port == .bluetoothHFP && selected.contains { output in
        input.uid == output.uid || input.name.caseInsensitiveCompare(output.name) == .orderedSame
      }
    }
    // Do not guess between unrelated headsets or select the phone microphone.
    return matches.count == 1 ? matches[0].uid : nil
  }

  static func key(_ text: String) -> String {
    text.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
      .split(whereSeparator: { $0.isWhitespace }).joined(separator:" ")
  }

  static func permitsOutput(mode: CaptureMode, ports: [AVAudioSession.Port]) -> Bool {
    if mode == .simulated { return false }
    if mode == .displayGlasses { return !ports.isEmpty && ports.allSatisfy { $0 == .bluetoothHFP } }
    if mode.needsGlasses { return !ports.isEmpty && ports.allSatisfy { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0) } }
    return !ports.isEmpty
  }

  private var routeDescription: String {
    audio.outputs.map { "\($0.name) [\($0.port.rawValue)]" }.joined(separator:", ") + "; volume \(Int(audio.volume * 100))%"
  }
  private func status(_ text: String) {
    onStatus?(text)
    onDiagnostic?(text + "; " + routeDescription)
  }

  func speak(_ cue: String, mode: CaptureMode) {
    let text = cue.trimmingCharacters(in:.whitespacesAndNewlines), key = Self.key(cue)
    guard mode != .simulated, !key.isEmpty, key != lastCompleted, key != pendingKey,
          text.count <= 90, text.split(whereSeparator: { $0.isWhitespace }).count <= 14 else { return }
    stop() // Latest cue replaces any pending/playing advice.
    currentMode = mode; pendingKey = key
    let revision = requestID
    status("Preparing cue audio…")
    routeWait = Task { [weak self] in
      guard let self else { return }
      do {
        try self.audio.activate(for:mode)
        // Activation and Bluetooth routing settle asynchronously. Do not drop
        // the cue just because the first route snapshot still names the phone.
        for _ in 0..<25 {
          try await Task.sleep(for:.milliseconds(200))
          guard self.requestID == revision else { return }
          if Self.permitsOutput(mode:mode, ports:self.audio.outputs.map(\.port)), self.audio.volume > 0 {
            self.begin(text, revision:revision)
            return
          }
        }
        self.pendingKey = ""; self.routeWait = nil
        self.status(self.audio.volume == 0 ? "Cue audio is muted. Turn up the glasses volume." : "Waiting for glasses audio. Select the glasses in Control Center.")
      } catch is CancellationError {
        return
      } catch {
        guard self.requestID == revision else { return }
        self.pendingKey = ""; self.routeWait = nil
        self.status("Cue audio: \(error.localizedDescription)")
        self.onDiagnostic?("Cue audio activation failed: \(error.localizedDescription)")
      }
    }
  }

  private func begin(_ text: String, revision: Int) {
    routeWait = nil
    let utterance = AVSpeechUtterance(string:text)
    utterance.voice = AVSpeechSynthesisVoice(language:"en-US")
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    utterance.volume = 1
    current = utterance; playbackOutputs = audio.outputs
    onPlaybackChanged?(true)
    status("Starting cue audio · " + playbackOutputs.map(\.name).joined(separator:", "))
    synthesizer.speak(utterance)
    // Also releases the echo mask if synthesis never starts or never completes.
    playbackTimeout = Task { [weak self] in
      do { try await Task.sleep(for:.seconds(8)) } catch { return }
      guard let self, self.requestID == revision, self.current != nil else { return }
      self.stop()
      self.status("Cue audio timed out. The cue can retry on the next check.")
    }
  }

  private func routeChanged(reason: UInt) {
    guard current != nil || !pendingKey.isEmpty else { return }
    onDiagnostic?("Cue audio route event \(reason); \(routeDescription)")
    guard current != nil else { return } // Pending playback waits for a usable route.
    // Category/activation notifications often arrive just as synthesis starts.
    // They are not disconnects. Only stop if the actual output disappeared/changed.
    guard audio.outputs != playbackOutputs || !Self.permitsOutput(mode:currentMode,ports:audio.outputs.map(\.port)) else { return }
    stop()
    status("Cue audio output changed; waiting for the next cue.")
  }

  func stop() {
    requestID += 1
    routeWait?.cancel(); routeWait = nil; pendingKey = ""
    playbackTimeout?.cancel(); playbackTimeout = nil
    guard current != nil else { return }
    current = nil
    synthesizer.stopSpeaking(at:.immediate)
    onPlaybackChanged?(false)
  }

  func endSession() {
    stop(); lastCompleted = ""; onStatus?(nil)
    audio.endSession()
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    Task { @MainActor [weak self] in
      guard let self, self.current === utterance else { return }
      self.status("Speaking cue · " + self.audio.outputs.map(\.name).joined(separator:", "))
    }
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor [weak self] in self?.finished(utterance,completed:true) }
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor [weak self] in self?.finished(utterance,completed:false) }
  }
  private func finished(_ utterance: AVSpeechUtterance, completed: Bool) {
    guard current === utterance else { return }
    // A request or cancellation does not establish playback success. Only a
    // completion suppresses the same cue on a later successful Muse check.
    if completed { lastCompleted = Self.key(utterance.speechString) }
    playbackTimeout?.cancel(); playbackTimeout = nil
    current = nil; pendingKey = ""; onPlaybackChanged?(false)
    status(completed ? "Cue audio finished · " + audio.outputs.map(\.name).joined(separator:", ") : "Cue audio cancelled; waiting for the next cue.")
  }
}
