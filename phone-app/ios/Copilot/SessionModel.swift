import Foundation
import Observation
import UIKit
import Vision

@Observable @MainActor
final class SessionModel {
  enum Phase: String { case stopped = "Stopped", starting = "Starting", active = "Listening", paused = "Paused" }
  var phase: Phase = .stopped
  var consent = false
  /// Coach the wearer when something they said may come across too blunt.
  var toneCheckEnabled = true
  /// The wearer's calibrated voice level at the mic (dBFS); nil until they tap "That was me".
  var wearerVoiceDbFS: Double? = UserDefaults.standard.object(forKey:"copilot.wearerVoiceDbFS") as? Double
  /// Finds the wearer's voice among live-caption labels by loudness, for the whole session. "That was me" overrides it.
  private(set) var wearerDetector = WearerDetector()
  @ObservationIgnored private var levelTrack = SpeechLevelTrack()
  var wearerLabel: String? { wearerDetector.wearerLabel }
  /// A few facts the wearer chose to share, sent with conversation checks so a suggested answer can be specific.
  var aboutMe = UserDefaults.standard.string(forKey:"copilot.aboutMe") ?? "" {
    didSet { UserDefaults.standard.set(aboutMe, forKey:"copilot.aboutMe") }
  }
  var toneFeedback: ToneFeedback?
  @ObservationIgnored private var toneTask: Task<Void, Never>?
  @ObservationIgnored private var pendingToneEntry: TranscriptEntry?
  @ObservationIgnored private var toneTTLTask: Task<Void, Never>?
  var glassesControlsReady = false
  var openingGlassesControls = false
  var captureMode: CaptureMode = .phone
  var simulate: Bool {
    get { captureMode == .simulated }
    set { captureMode = newValue ? .simulated : .displayGlasses }
  }
  var glassesConversationEnabled = true
  var sceneOnly: Bool { captureMode == .displayGlasses && !glassesConversationEnabled }
  var phoneCameraEnabled = true
  var localMock = true
  /// Set when Start could not reach a live server: camera and mic still run, AI features wait.
  var offline = false
  var connectionTestOnly = false
  var uploadsDisabled: Bool { offline || connectionTestOnly }
  var endpoint = UserDefaults.standard.string(forKey:"copilot.endpoint") ?? "http://127.0.0.1:8787"
  var proxyToken = TokenStore.read()
  var selectedAudioUID = ""
  var audioPorts: [AudioPort] = []
  var contextText = ""
  var sampleInterval = 8.0
  var simulateSurroundings = false
  var analysisFeedback: String?
  var pendingManualAnalysisAt: Double?
  var latestAudioContext: AudioContext?
  @ObservationIgnored private var lastAudioCaptureAtMs = 0.0
  @ObservationIgnored var captureActivity = CaptureActivity()
  @ObservationIgnored private var ambientWindow = AmbientWindow()
  @ObservationIgnored private var conversationWindow = ConversationWindow()
  var reducedPower = false
  var nextAnalysisAt: Double = 0
  var transcript: [TranscriptEntry] = []
  var captionRows: [CaptionRow] = []
  let captionDiagnostics = CaptionDiagnostics()
  var speechMode = "Not started"
  @ObservationIgnored private var realtimeRelay: (any PhoneCaptionRelay)?
  @ObservationIgnored private var realtimeRoster = PhoneCaptionRoster()
  @ObservationIgnored private var realtimeClock = RealtimeSpeechClock()
  @ObservationIgnored private var finalizedTurns: Set<Int> = []
  @ObservationIgnored private var realtimeSpeakers: [Int:String] = [:]
  @ObservationIgnored private let makeRealtimeRelay: @MainActor (String, String) -> any PhoneCaptionRelay
  var captionText: String?
  var captionAtMs: Double = 0
  var phonePreview: UIImage?
  var phoneFramesReceived = 0
  var cue: String?
  var spokenCuesEnabled = true {
    didSet {
      if !spokenCuesEnabled { cueSpeaker.stop(); cueAudioStatus = nil }
      else if !oldValue, phase == .active, let cue { cueSpeaker.speak(cue, mode:captureMode) }
    }
  }
  var cueAudioStatus: String?
  @ObservationIgnored private let cueSpeaker: any CueSpeaking
  var lastSceneSummary: String?
  var lastAnalysisOutcome: String?
  var lastAnalysisAtMs: Double = 0
  var notice = ""
  var modelMode = "Not checked"
  var audioRate: Double = 0
  var lastVoiceAt: Double = 0
  var latestFrame: SampledFrame?
  var isThinking = false
  var isTranscribing = false
  var apiMs: Double = 0
  var transcriptionMs: Double = 0
  var contextToDisplayMs: Double = 0
  var uploadedBytes = 0
  var estimatedCost: Double?
  @ObservationIgnored private var knownCostTotal: Double = 0
  @ObservationIgnored private var missingCost = false
  var requests = 0
  var staleDrops = 0
  var audioDrops = 0
  var shown = 0
  var distracting = 0
  var simulationText = "Can you have it ready by Friday?"
  let people: PeopleStore
  var presentIDs: Set<UUID> = []
  var presentPeople: [Person] { people.people.filter { presentIDs.contains($0.id) } }
  var learnReview: LearnReview?
  /// Recognize enrolled friends on-device from camera frames.
  var recognizeFaces = true
  /// Maximum feature-print distance that counts as a match; lower is stricter.
  var faceThreshold = Double(FaceRecognizer.defaultThreshold)
  var presence = PresenceTracker()
  /// Latest per-face distances ("Sam 0.41"), for calibrating the match threshold.
  var faceReadout: String?
  var isLearning = false
  // Whole-conversation speech kept until Stop so profiles can learn from it.
  @ObservationIgnored private(set) var sessionLog: [TranscriptEntry] = []
  @ObservationIgnored private var learnTask: Task<Void, Never>?
  @ObservationIgnored private var faceTask: Task<Void, Never>?
  @ObservationIgnored private var faceGallery = FaceGallery(people:[])
  @ObservationIgnored private var lastFaceCheckAt: Double = 0
  /// In-memory face seen while a just-introduced person had no enrolled face. Proposed at Stop; never saved unless approved.
  struct FaceCandidate { var sample: FaceSample; var embedding: [Float]; var area: CGFloat; var sightings: Int }
  private(set) var faceCandidates: [UUID: FaceCandidate] = [:]
  /// Save new stills of recognized friends from live video to improve matching.
  var saveFaceStills = true
  /// Stills saved during this conversation, shown on the live screen.
  private(set) var stillsSaved = 0
  @ObservationIgnored private var lastStillAt: [UUID: Double] = [:]
  @ObservationIgnored private var stillsThisSession: [UUID: Int] = [:]
  static let stillIntervalMs = 20_000.0
  /// An unrecognized face seen during this conversation. Held in memory only; saved only once linked to a name.
  struct UnknownFace { var embedding: [Float]; var sample: FaceSample; var area: CGFloat; var sightings: Int; var lastSeen: Double }
  @ObservationIgnored private var unknownFaces: [UnknownFace] = []
  /// Names said to someone who isn't saved yet, waiting for an unambiguous face.
  @ObservationIgnored private var pendingNames: [(name: String, at: Double)] = []
  static let unknownFaceMemoryMs = 60_000.0
  static let nameFaceWindowMs = 15_000.0
  static let maxStillsPerSession = 3
  @ObservationIgnored lazy var glasses = GlassesController()
  @ObservationIgnored private let phoneCamera = PhoneCamera()
  @ObservationIgnored private let microphone = ConversationMicrophone()
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var epoch = 0
  @ObservationIgnored private var lastRequestedGeneration = -1
  @ObservationIgnored private var lastCueAt: Double = 0
  @ObservationIgnored private var lastRequestedSpeechAt: Double = 0
  /// Rolling memory of earlier moments in this session, from the model's own summaries.
  private(set) var moments: [Moment] = []
  @ObservationIgnored private var dismissedAt: Double = 0
  @ObservationIgnored private var ttlTask: Task<Void, Never>?
  @ObservationIgnored private var cueTask: Task<Void, Never>?
  @ObservationIgnored private var stuckTask: Task<Void, Never>?
  /// The moment behind the check in flight; nil for a scene check.
  @ObservationIgnored private var activeTrigger: CueTrigger?
  @ObservationIgnored private var speculation = SpeculativeCue()
  @ObservationIgnored private var speculationTask: Task<Void, Never>?
  @ObservationIgnored private var asrTask: Task<Void, Never>?
  @ObservationIgnored private var startTask: Task<Void, Never>?
  @ObservationIgnored private var loopTask: Task<Void, Never>?
  @ObservationIgnored private var latestSampleAt: Double = 0
  @ObservationIgnored private var transportTask: Task<Void, Never>?
  @ObservationIgnored private var captureStartedAt: Double = 0
  @ObservationIgnored private var captureActiveAtMs: Double = 0
  @ObservationIgnored private var lastAnalysisAt: Double = 0
  @ObservationIgnored private var simulatedScene = ""
  /// The setting Muse last recognized, shown as a chip and sent back as background.
  var currentScene: String?

  init(people: PeopleStore? = nil, cueSpeaker: (any CueSpeaking)? = nil, makeRealtimeRelay: @escaping @MainActor (String, String) -> any PhoneCaptionRelay = { RealtimeASRClient(endpoint:$0, token:$1) }) {
    self.cueSpeaker = cueSpeaker ?? CueSpeaker()
    self.makeRealtimeRelay = makeRealtimeRelay
    self.people = people ?? PeopleStore()
    #if DEBUG
    let launchEnvironment = ProcessInfo.processInfo.environment
    if let settings = DevelopmentConnection.settings(from:launchEnvironment) {
      do {
        try TokenStore.save(settings.token)
        UserDefaults.standard.set(settings.endpoint,forKey:"copilot.endpoint")
        endpoint = settings.endpoint; proxyToken = settings.token
        notice = ""
      } catch { notice = "Could not save the test connection. Configure it in Settings." }
    }
    if launchEnvironment["ASIDE_CAPTURE_MODE"] == "display_glasses" { captureMode = .displayGlasses }
    #endif
    self.cueSpeaker.onPlaybackChanged = { [weak self] active in self?.microphone.setCuePlaybackActive(active) }
    self.cueSpeaker.onStatus = { [weak self] status in self?.cueAudioStatus = status }
    self.cueSpeaker.onDiagnostic = { [weak self] message in self?.captionDiagnostics.record(message) }
    phoneCamera.onFrame = { [weak self] image, time in
      guard let self, self.phase == .active, self.captureMode == .phone else { return }
      self.phonePreview = image; self.phoneFramesReceived += 1; self.sample(image, at:time); self.checkFaces(image, at:time)
    }
    phoneCamera.onFailure = { [weak self] message in self?.captureFailed(message) }
    // Raw voice energy (fans, music, crowds, ongoing talk) never cancels cues; only recognized speech updates timing.
    microphone.onVoice = nil
    microphone.onPCM = { [weak self] data, time in Task { @MainActor in
      guard let self, self.phase == .starting || self.phase == .active, time >= self.captureStartedAt else { return }
      self.lastAudioCaptureAtMs = time
      self.captureActivity.audioReceivedAtMs = nowMs()
      self.sendRealtimePCM(data, endedAtMs:time)
    } }
    microphone.onChunk = { [weak self] chunk in Task { @MainActor in self?.transcribe(chunk) } }
    microphone.onContext = { [weak self] context in Task { @MainActor in
      guard let self, self.phase == .active, context.capturedAtMs >= self.captureStartedAt else { return }
      self.latestAudioContext = context
      self.ambientWindow.append(context)
    } }
    microphone.onFailure = { [weak self] message in Task { @MainActor in self?.captureFailed(message) } }
  }
  private func configureGlassesCallbacks() {
    glasses.onFrame = { [weak self] image, time in self?.sample(image, at:time); self?.checkFaces(image, at:time) }
    glasses.onFailure = { [weak self] message in self?.captureFailed(message) }
    glasses.onDiagnostic = { [weak self] message in self?.captionDiagnostics.record(message) }
    glasses.onHelp = { [weak self] in
      guard let self else { return }
      if self.connectionTestOnly { self.manualDisplayTest() }
      else { self.requestCue(manual:true) }
    }
    glasses.onPause = { [weak self] in self?.pause() }
    glasses.onStop = { [weak self] in self?.stopStreaming() }
    glasses.onDisconnect = { [weak self] in self?.stop() }
    glasses.onDismiss = { [weak self] in self?.dismiss() }
    glasses.onResume = { [weak self] in self?.start() }
  }
  private var client: APIClient { APIClient(endpoint:endpoint, token:proxyToken) }
  var canStart: Bool { (captureMode != .regularGlasses || !selectedAudioUID.isEmpty) && (phase == .stopped || phase == .paused) }
  var savedNote: String? { contextText.split(separator:"\n").first.map(String.init) }
  var analyzesSurroundings: Bool {
    captureMode.needsGlasses || (captureMode == .phone && phoneCameraEnabled) || (simulate && simulateSurroundings)
  }
  /// Timer-driven checks that read the camera image: scene-only glasses and the simulated scene fixtures.
  /// Every other mode runs conversation checks, which fire at a moment and send text only.
  var sceneChecks: Bool { sceneOnly || (simulate && simulateSurroundings) }
  var requiresCamera: Bool { captureMode.needsGlasses || (captureMode == .phone && phoneCameraEnabled) }
  func liveInputIssue(at timestamp: Double = nowMs()) -> String? {
    guard !simulate else { return nil }
    let freshFrame = latestFrame.map { timestamp - $0.capturedAtMs <= 10000 && $0.capturedAtMs <= timestamp + 1000 } ?? false
    if requiresCamera && !freshFrame {
      return "Waiting for fresh \(captureMode.needsGlasses ? "glasses" : "phone") camera frames."
    }
    if sceneOnly { return nil } // A fresh image is sufficient; missing audio is reported separately.
    let expectedSource = captureMode == .displayGlasses ? "glasses_pcm" : captureMode == .regularGlasses ? "glasses_hfp" : "phone"
    guard let audio = latestAudioContext, timestamp - max(audio.capturedAtMs,lastAudioCaptureAtMs) <= 10000,
          audio.capturedAtMs <= timestamp + 1000, audio.source == expectedSource else {
      return "Waiting for live \(captureMode.hasGlassesDisplay ? "glasses ambient" : "microphone") audio."
    }
    return nil
  }
  func checkCaptureHealth(at timestamp: Double = nowMs()) {
    guard phase == .active, !simulate, timestamp - captureActiveAtMs >= 12000 else { return }
    let delayed = "Glasses stream is delayed. Waiting for fresh camera and audio."
    guard let issue = liveInputIssue(at:timestamp) else {
      if notice == delayed {
        notice = ""
        captionDiagnostics.record("Capture current again")
      }
      return
    }
    if captureMode == .displayGlasses,
       captureActivity.isReceiving(requiresVideo:requiresCamera,requiresAudio:!sceneOnly,at:timestamp) {
      // HFP can briefly delay the shared DAT link. Keep receiving so it can
      // catch up; requestCue still rejects stale capture timestamps. Never
      // relabel old frames/audio as fresh or bypass a real SDK disconnect.
      if notice != delayed { captionDiagnostics.record("Capture delayed: \(issue)") }
      if cue != nil {
        cueSpeaker.stop(); cue = nil; lastSceneSummary = nil
        lastAnalysisOutcome = "Waiting for fresh input."
        feedback("Stream delayed · waiting for fresh input")
      }
      notice = delayed
      return
    }
    pause("Capture stopped receiving data. \(issue) Resume after checking the connection.")
  }
  var analysisStatus: String {
    if offline { return "Server offline" }
    if isThinking { return sceneChecks ? "Analyzing surroundings…" : "Analyzing…" }
    if isTranscribing { return "Listening to conversation…" }
    return sceneChecks ? "Watching surroundings" : "Listening for context"
  }
  func analysisInterval(at timestamp: Double = nowMs(), reducedPower: Bool) -> Double {
    return SurroundingsPolicy.analysisInterval(recentSpeech:lastVoiceAt > 0 && timestamp - lastVoiceAt < 30000, reducedPower:reducedPower)
  }
  private func publishDisplay() {
    guard captureMode.hasGlassesDisplay, phase == .active else { return }
    glasses.show(cue, testOnly:connectionTestOnly, feedback:cue == nil ? analysisFeedback : "Social cue", sceneOnly:sceneOnly)
  }
  private func feedback(_ message: String) {
    analysisFeedback = message
    publishDisplay()
  }
  private func queueManualAnalysis(_ message: String, at timestamp: Double) {
    if pendingManualAnalysisAt == nil { pendingManualAnalysisAt = timestamp }
    notice = message
    feedback(message)
  }
  enum ConnectionStatus: Equatable { case unknown, checking, connected, failed(String) }
  var connectionStatus: ConnectionStatus = .unknown
  /// Save the server URL and token, then verify the server is reachable, live, and accepts the token.
  func connect() async {
    endpoint = endpoint.trimmingCharacters(in:.whitespacesAndNewlines)
    while endpoint.hasSuffix("/") { endpoint.removeLast() }
    if !endpoint.isEmpty && !endpoint.contains("://") { endpoint = "http://" + endpoint }
    proxyToken = proxyToken.trimmingCharacters(in:.whitespacesAndNewlines)
    connectionStatus = .checking
    guard !proxyToken.isEmpty else { connectionStatus = .failed("Paste the token."); return }
    do { try TokenStore.save(proxyToken) } catch { connectionStatus = .failed("Couldn't save the token."); return }
    var candidates = [endpoint]
    if endpoint.isEmpty || endpoint.contains("127.0.0.1") || endpoint.contains("localhost") {
      #if targetEnvironment(simulator)
      candidates = ["http://127.0.0.1:8787"]
      #else
      // On a real phone, localhost is the phone itself: look for the Mac's server instead.
      candidates = await ServerDiscovery.candidates()
      guard !candidates.isEmpty else {
        connectionStatus = .failed("No server found on this Wi-Fi. Is it running? Allow Local Network access, or enter the URL."); return
      }
      #endif
    }
    var health: HealthResponse?
    var lastError: Error?
    for candidate in candidates {
      endpoint = candidate
      do { health = try await client.health(); break } catch { lastError = error }
    }
    UserDefaults.standard.set(endpoint, forKey:"copilot.endpoint")
    do {
      guard let health else { throw lastError ?? CopilotError(message:"No server found.") }
      modelMode = health.modelMode ?? "Unknown"
      if health.tokenValid == false { connectionStatus = .failed("Wrong token."); return }
      guard modelMode == "live" else { connectionStatus = .failed("Server is in \(modelMode) mode, not live."); return }
      connectionStatus = .connected
      // A camera-only session picks up Muse without restarting.
      if offline { offline = false; notice = "" }
    } catch {
      connectionStatus = .failed(Self.describe(error, endpoint:endpoint))
    }
  }
  static func describe(_ error: Error, endpoint: String) -> String {
    guard let error = error as? URLError else { return error.localizedDescription }
    switch error.code {
    case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
      return "Can't reach \(URL(string:endpoint)?.host ?? endpoint). Check same Wi-Fi, server running, and Local Network access for this app."
    default: return error.localizedDescription
    }
  }
  func refreshAudioPorts() {
    guard phase == .stopped || phase == .paused else { return }
    do { audioPorts = try microphone.availablePorts(); notice = audioPorts.isEmpty ? "No Bluetooth microphones found." : "" }
    catch { notice = error.localizedDescription }
  }
  func openGlassesControls() {
    guard captureMode.hasGlassesDisplay else { return }
    start(displayOnly:true)
  }
  func startFromPhone() {
    if captureMode.hasGlassesDisplay { openGlassesControls() }
    else { start() }
  }
  func start(displayOnly: Bool = false) {
    guard canStart, !displayOnly || captureMode.hasGlassesDisplay else { return }
    consent = true
    let previousStart = startTask
    openingGlassesControls = displayOnly
    glassesControlsReady = false
    analysisFeedback = nil; pendingManualAnalysisAt = nil
    epoch += 1
    let thisEpoch = epoch
    phase = .starting
    captureStartedAt = nowMs()
    captureActivity = CaptureActivity()
    lastAnalysisAt = 0; nextAnalysisAt = 0
    invalidateCue()
    notice = displayOnly ? "Opening controls on glasses. Camera and microphone stay off." : simulate ? "SIMULATED INPUT. No camera or microphone recording." : captureMode == .phone ? "Starting the selected iPhone inputs…" : captureMode.hasGlassesDisplay ? "Opening glasses camera and ambient microphone permissions…" : "Opening glasses permissions, then selecting HFP microphone…"
    startTask = Task { [weak self] in
      guard let self else { return }
      await previousStart?.value
      await transportTask?.value
      guard epoch == thisEpoch, !Task.isCancelled else { return }
      if !simulate {
        offline = false
        if !connectionTestOnly && !displayOnly {
        do {
          let health = try await client.health()
          modelMode = health.modelMode ?? "Unknown"
          if modelMode != "live" { offline = true; notice = "Server isn't in live mode. Camera only." }
        } catch {
          guard epoch == thisEpoch, !Task.isCancelled else { return }
          offline = true; modelMode = "Offline"; notice = "Cannot reach Muse. Camera only."
        }
        }
        guard epoch == thisEpoch, !Task.isCancelled else { return }
        if captureMode.needsGlasses { configureGlassesCallbacks() }
        guard epoch == thisEpoch, !Task.isCancelled else { return }
        do {
          if displayOnly {
            try await glasses.connectDisplayOnly()
            guard epoch == thisEpoch, !Task.isCancelled else { return }
            phase = .paused; openingGlassesControls = false; glassesControlsReady = true
            notice = "Controls ready on glasses. Select Start with your wristband. Camera and microphone are off."
            glasses.show(nil, paused:true, ready:true)
            return
          }
          if captureMode.hasGlassesDisplay {
            glasses.show(nil, starting:true)
          }
          if captureMode == .phone {
            try await microphone.startPhone()
            guard epoch == thisEpoch, !Task.isCancelled else { microphone.stop(); return }
            if phoneCameraEnabled { try await phoneCamera.start() }
          } else {
            try await glasses.start(microphone:microphone, audioUID:selectedAudioUID, withDisplay:captureMode.hasGlassesDisplay, voiceAudioEnabled:spokenCuesEnabled) { [weak self] in
              guard let self, self.spokenCuesEnabled else { return }
              do { try await self.cueSpeaker.prepare(for:self.captureMode) }
              catch is CancellationError { throw CancellationError() }
              catch {
                self.cueAudioStatus = "Cue audio: \(error.localizedDescription)"
                self.captionDiagnostics.record("Cue audio setup failed: \(error.localizedDescription)")
              }
            }
          }
          // Muse closes idle streams before slow glasses permission/startup can
          // finish. Connect only after the capture sources are running.
          if !connectionTestOnly && !offline && !sceneOnly {
            await startRealtimeCaptions()
            guard epoch == thisEpoch, !Task.isCancelled else { return }
          }
          audioRate = microphone.actualSampleRate
        } catch {
          guard epoch == thisEpoch else { return }
          let needsGlassesUpdate = captureMode.needsGlasses && GlassesController.requiresGlassesAppUpdate(error)
          captureFailed(needsGlassesUpdate ? GlassesController.updateInstructions : error.localizedDescription)
          if needsGlassesUpdate { glasses.report(error) }
          return
        }
      }
      guard epoch == thisEpoch, !Task.isCancelled else { return }
      openingGlassesControls = false
      phase = .active
      captureActiveAtMs = nowMs()
      if !offline { notice = "" }
      publishDisplay()
      loopTask?.cancel()
      loopTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for:.seconds(1))
          guard let self, !Task.isCancelled, self.phase == .active else { return }
          self.trimTranscript()
          self.expireCaption()
          self.expirePresence()
          self.checkCaptureHealth()
          guard self.phase == .active else { return }
          if self.analyzesSurroundings && ProcessInfo.processInfo.thermalState == .critical {
            self.pause("Phone needs to cool down. Analysis paused; resume when ready."); return
          }
          self.reducedPower = ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState == .serious
          if let pending = self.pendingManualAnalysisAt, nowMs() - pending > 15000 {
            self.pendingManualAnalysisAt = nil
            self.feedback("Pause speech, then tap Analyze again.")
          } else { self.requestCue(manual:self.pendingManualAnalysisAt != nil) }
        }
      }
    }
  }
  // Capture failure must not close a healthy display/device session. Only the
  // explicit Close/phone Stop action tears down the control connection.
  func captureFailed(_ message: String) {
    guard phase == .starting || phase == .active else { return }
    pause(message)
    if captureMode.hasGlassesDisplay {
      glasses.show(nil, paused:true, status:"Capture paused. Check phone, then Resume.")
    }
  }
  func pause(_ reason: String = "Paused. Camera, microphone and uploads stopped.") {
    guard phase == .active || phase == .starting else { return }
    captionDiagnostics.record("Capture paused: \(reason)")
    epoch += 1
    phase = .paused
    openingGlassesControls = false; glassesControlsReady = false
    analysisFeedback = nil; pendingManualAnalysisAt = nil
    startTask?.cancel(); asrTask?.cancel(); asrTask = nil; isTranscribing = false
    stopRealtimeCaptions()
    ambientWindow = AmbientWindow(); lastAudioCaptureAtMs = 0
    captureActivity = CaptureActivity()
    loopTask?.cancel(); invalidateCue()
    cueSpeaker.endSession()
    microphone.stop(); phoneCamera.stop(); phonePreview = nil
    latestFrame = nil; latestAudioContext = nil; latestSampleAt = 0; transcript.removeAll(); lastVoiceAt = 0; captionText = nil; captionAtMs = 0
    clearTone()
    nextAnalysisAt = 0; simulatedScene = ""
    if captureMode.needsGlasses { glasses.pauseCapture() }
    notice = reason
  }
  // Stop capture and clear session context, retaining the consented control connection.
  func stopStreaming() {
    guard captureMode.hasGlassesDisplay, consent, phase != .stopped else { return }
    pause()
    contextText = ""; moments = []; lastCueAt = 0; dismissedAt = 0; currentScene = nil
    finishConversation()
    glassesControlsReady = true
    glasses.pauseCapture(ready:true)
    notice = "Streaming stopped and session context cleared. Select Start on glasses, or Stop on the phone to disconnect."
  }
  func stop() {
    epoch += 1
    phase = .stopped
    openingGlassesControls = false; glassesControlsReady = false
    analysisFeedback = nil; pendingManualAnalysisAt = nil
    startTask?.cancel(); asrTask?.cancel(); asrTask = nil; isTranscribing = false
    stopRealtimeCaptions()
    ambientWindow = AmbientWindow(); lastAudioCaptureAtMs = 0
    captureActivity = CaptureActivity()
    loopTask?.cancel(); invalidateCue()
    cueSpeaker.endSession()
    microphone.stop(); phoneCamera.stop(); phonePreview = nil
    transcript.removeAll(); latestFrame = nil; latestAudioContext = nil; contextText = ""; latestSampleAt = 0
    nextAnalysisAt = 0; simulatedScene = ""; currentScene = nil
    consent = false; lastVoiceAt = 0; moments = []; lastCueAt = 0; dismissedAt = 0; lastRequestedSpeechAt = 0
    clearTone()
    captionText = nil; captionAtMs = 0
    if captureMode.needsGlasses { transportTask = Task { await glasses.stop() } }
    notice = ""
    finishConversation()
  }
  private func finishConversation() {
    let log = sessionLog; sessionLog = []
    learn(from:log)
    // Who's here is per conversation; the next session starts from scratch.
    wearerDetector.reset()
    faceTask?.cancel(); faceTask = nil; faceReadout = nil; faceCandidates = [:]
    lastStillAt = [:]; stillsThisSession = [:]; stillsSaved = 0; unknownFaces = []; pendingNames = []
    presence.reset(); presentIDs = []
  }
  private func learn(from log: [TranscriptEntry]) {
    guard !uploadsDisabled else { return }
    // Everyone detected during the session, including people who already left.
    let attended = presence.everConfirmed
    let present = people.people.filter { attended.contains($0.id) }
    guard !present.isEmpty else { return }
    let faceItems = faceCandidates.filter { $0.value.sightings >= 2 && attended.contains($0.key) }.map { id, candidate in
      LearnItem(target:.person(id), field:.face, value:"Recognize this face as \(people.label(for:.person(id)))", face:candidate.sample)
    }
    people.markSeen(attended)
    guard !log.isEmpty else { return }
    let presentGroups = people.groups(of:present)
    let request = LearnRequest(transcript:log, people:present.prefix(8).map { people.context(for:$0, includeID:true) },
                               groups:presentGroups.prefix(8).map(people.context(for:)),
                               otherGroupNames:people.groups.filter { !presentGroups.contains($0) }.prefix(40).map { String($0.name.prefix(40)) },
                               wordsPerMinute:Self.wordsPerMinute(log))
    let offline = simulate && localMock
    let connection = client
    learnTask?.cancel()
    isLearning = true
    learnTask = Task { [weak self] in
      do {
        let result = offline ? PeopleStore.mockLearn(request) : try await (connection.post("api/learn", request) as (LearnResponse, Int)).0.result
        guard let self, !Task.isCancelled else { return }
        isLearning = false
        let items = faceItems + people.reviewItems(for:result)
        if !items.isEmpty { learnReview = LearnReview(items:items) }
      } catch {
        guard let self, !Task.isCancelled else { return }
        isLearning = false; notice = "Couldn't update profiles."
        if !faceItems.isEmpty { learnReview = LearnReview(items:faceItems) }
      }
    }
  }
  /// Speech rate over recognized chunks; nil when there is too little speech to judge.
  static func wordsPerMinute(_ log: [TranscriptEntry]) -> Double? {
    let words = log.reduce(0) { $0 + $1.text.split(whereSeparator:\.isWhitespace).count }
    let minutes = log.reduce(0) { $0 + max(0, $1.endMs - $1.startMs) } / 60000
    guard words >= 20, minutes >= 10.0 / 60 else { return nil }
    return min(400, Double(words) / minutes)
  }
  private func logSpeech(_ entry: TranscriptEntry) { sessionLog = Array((sessionLog + [entry]).suffix(400)) }
  /// Correct a wrong match: out for the rest of this conversation unless they introduce themselves.
  func markNotHere(_ id: UUID) { presence.dismiss(id); syncPresence() }
  /// Presence changes feed the next cue request; they don't cancel one already in flight.
  private func syncPresence() { if presentIDs != presence.confirmed { presentIDs = presence.confirmed } }
  func expirePresence(at time: Double = nowMs()) { if !presence.expire(at:time).isEmpty { syncPresence() } }
  /// Throttled on-device face check. Frames that arrive while one is running are skipped.
  private func checkFaces(_ image: UIImage, at time: Double) {
    guard recognizeFaces, phase == .active, faceTask == nil, time - lastFaceCheckAt >= 1000 else { return }
    let enrolled = people.people
    if faceGallery.key != FaceGallery.key(for:enrolled) { faceGallery = FaceGallery(people:enrolled) }
    // Runs even with no saved faces: unknown faces can become new friends when named.
    lastFaceCheckAt = time
    let gallery = faceGallery, thisEpoch = epoch, threshold = Float(faceThreshold)
    faceTask = Task { [weak self] in
      let result = await Task.detached(priority:.utility) { () -> (matches: [FaceMatch], unmatched: [FaceRecognizer.DetectedFace], matched: [(FaceMatch, FaceRecognizer.DetectedFace)], error: String?) in
        do {
          let faces = try FaceRecognizer.faces(in:image)
          let matches = FaceRecognizer.match(faces, gallery:gallery, threshold:threshold)
          // Pair each unambiguous match with its face so confident ones can be saved as stills.
          let matched = faces.compactMap { face in
            FaceRecognizer.match([face], gallery:gallery, threshold:threshold).first.flatMap { matches.contains($0) ? ($0, face) : nil }
          }
          // Ambiguous near-matches must never become new enrollment candidates.
          let unmatched = faces.filter { face in
            FaceRecognizer.rank(face, gallery:gallery).first.map { $0.distance > threshold + FaceRecognizer.ambiguityMargin } ?? true
          }
          return (matches, unmatched, matched, nil)
        } catch { return ([], [], [], error.localizedDescription) }
      }.value
      guard let self, !Task.isCancelled else { return }
      faceTask = nil
      guard epoch == thisEpoch, phase == .active, recognizeFaces, Float(faceThreshold) == threshold,
            gallery.key == FaceGallery.key(for:people.people) else { return }
      if let error = result.error { faceReadout = error; return }
      faceReadout = result.matches.isEmpty ? "No confident friend match" : result.matches.map { match in
        let name = people.people.first { $0.id == match.personID }?.name ?? "?"
        return "\(name) · distance \(String(format:"%.2f", match.distance))"
      }.joined(separator:" · ")
      applyFaceMatches(result.matches.map(\.personID), at:time)
      saveStills(result.matched, at:time)
      considerFaceCandidate(result.unmatched, at:time)
      trackUnknownFaces(result.unmatched, at:time)
    }
  }
  /// Adds confident, new-looking stills of friends who are confirmed here to their photos.
  func saveStills(_ matched: [(FaceMatch, FaceRecognizer.DetectedFace)], at time: Double) {
    guard saveFaceStills else { return }
    for (match, face) in matched where presentIDs.contains(match.personID) {
      let id = match.personID
      guard time - (lastStillAt[id] ?? -.infinity) >= Self.stillIntervalMs,
            (stillsThisSession[id] ?? 0) < Self.maxStillsPerSession,
            let sample = FaceRecognizer.stillWorthKeeping(face, personID:id, distance:match.distance, people:people.people) else { continue }
      people.addFace(sample, to:id)
      lastStillAt[id] = time; stillsThisSession[id, default:0] += 1; stillsSaved += 1
    }
  }
  /// Links an unrecognized face to someone only when it is unambiguous: exactly one unmatched face
  /// in view, and exactly one present person without an enrolled face whose name was heard in the
  /// last 20 seconds. Needs two consistent sightings before it is proposed.
  func considerFaceCandidate(_ unmatched: [FaceRecognizer.DetectedFace], at time: Double) {
    guard unmatched.count == 1, let face = unmatched.first else { return }
    let waiting = presentPeople.filter { person in
      person.faces.isEmpty && presence.lastHeard[person.id].map { time - $0 <= 20_000 && $0 <= time + 1000 } == true
    }
    guard waiting.count == 1, let id = waiting.first?.id else { return }
    if var existing = faceCandidates[id], let distance = FaceEmbedding.distance(face.embedding, existing.embedding), distance <= Float(faceThreshold) {
      existing.sightings += 1
      if face.area > existing.area, let sample = FaceRecognizer.sample(from:face) { existing.sample = sample; existing.embedding = face.embedding; existing.area = face.area }
      faceCandidates[id] = existing
    } else if let sample = FaceRecognizer.sample(from:face) {
      faceCandidates[id] = FaceCandidate(sample:sample, embedding:face.embedding, area:face.area, sightings:1)
    }
    // Two consistent sightings: save right away so they're recognized later in this conversation.
    if saveFaceStills, var candidate = faceCandidates[id], candidate.sightings >= 2 {
      candidate.sample.capturedAt = Date()
      guard (try? FaceRecognizer.validateEnrollment(candidate.sample, personID:id, people:people.people)) != nil else { return }
      people.addFace(candidate.sample, to:id)
      faceCandidates[id] = nil; lastStillAt[id] = time; stillsThisSession[id, default:0] += 1; stillsSaved += 1
    }
  }
  func applyFaceMatches(_ ids: [UUID], at time: Double) { _ = presence.recordFaces(ids, at:time); syncPresence() }
  func noteNames(in entry: TranscriptEntry) {
    guard (entry.confidence ?? 1) >= PresenceTracker.minimumSpeechConfidence else { return }
    for name in PresenceTracker.introducedNames(in:entry.text) {
      let existing = people.people.first { person in
        person.name.caseInsensitiveCompare(name) == .orderedSame
          || person.name.split(separator:" ").first.map { $0.caseInsensitiveCompare(name) == .orderedSame } == true
      }
      guard let id = existing?.id ?? people.addPerson(name) else { continue }
      if existing == nil { notice = "Met \(name). Added to People." }
      presence.introduce(id, at:entry.endMs)
    }
    let ids = PresenceTracker.mentionedPeople(in:entry.text, people:people.people)
    _ = presence.recordNames(ids, at:entry.endMs)
    // A name said to someone new: wait for the one unknown face it belongs to.
    for name in PresenceTracker.addressedNames(in:entry.text) where person(named:name) == nil {
      pendingNames.removeAll { $0.name == name }
      pendingNames.append((name, entry.endMs))
    }
    linkNamesToFaces(at:entry.endMs)
    syncPresence()
  }
  private func person(named name: String) -> Person? {
    people.people.first { person in
      person.name.caseInsensitiveCompare(name) == .orderedSame
        || person.name.split(separator:" ").first.map { $0.caseInsensitiveCompare(name) == .orderedSame } == true
    }
  }
  /// Groups unrecognized faces across frames so one stranger counts as one face.
  func trackUnknownFaces(_ unmatched: [FaceRecognizer.DetectedFace], at time: Double) {
    unknownFaces.removeAll { time - $0.lastSeen > Self.unknownFaceMemoryMs }
    for face in unmatched {
      if let index = unknownFaces.firstIndex(where: { FaceEmbedding.distance(face.embedding, $0.embedding).map { $0 <= Float(faceThreshold) } ?? false }) {
        unknownFaces[index].sightings += 1; unknownFaces[index].lastSeen = time
        if face.area > unknownFaces[index].area, let sample = FaceRecognizer.sample(from:face) {
          unknownFaces[index].sample = sample; unknownFaces[index].embedding = face.embedding; unknownFaces[index].area = face.area
        }
      } else if let sample = FaceRecognizer.sample(from:face) {
        unknownFaces.append(UnknownFace(embedding:face.embedding, sample:sample, area:face.area, sightings:1, lastSeen:time))
      }
    }
    linkNamesToFaces(at:time)
  }
  /// Creates a new friend when a name said to someone new lines up with exactly one unknown face
  /// (seen at least twice) within 15 seconds, and no other unknown face or new name competes.
  private func linkNamesToFaces(at time: Double) {
    guard saveFaceStills, phase == .active else { return }
    pendingNames.removeAll { time - $0.at > Self.nameFaceWindowMs }
    guard pendingNames.count == 1, let pending = pendingNames.first else { return }
    let nearby = unknownFaces.filter { abs($0.lastSeen - pending.at) <= Self.nameFaceWindowMs }
    guard nearby.count == 1, let face = nearby.first, face.sightings >= 2, person(named:pending.name) == nil else { return }
    var sample = face.sample
    sample.capturedAt = Date()
    guard let id = people.addPerson(pending.name) else { return }
    guard (try? FaceRecognizer.validateEnrollment(sample, personID:id, people:people.people)) != nil else {
      people.people.removeAll { $0.id == id }; pendingNames = []; return // looks like someone already saved
    }
    people.addFace(sample, to:id)
    pendingNames = []
    unknownFaces.removeAll { $0.embedding == face.embedding }
    presence.introduce(id, at:time)
    notice = "Met \(pending.name)."
    syncPresence()
  }
  // MARK: Tone check — coaching on the wearer's own words

  struct ToneFeedback: Identifiable, Equatable {
    let id = UUID()
    let said: String
    let recovery: String
    let rephrase: String
    let strong: Bool
  }
  /// Speech this loud relative to the wearer's calibrated level counts as the wearer (6 dB ≈ half as loud).
  static let wearerLevelMarginDb = 6.0
  func speaker(forLevel level: Double?) -> String? {
    // The level found in this session comes first; the saved level is from an earlier "That was me".
    guard let level, level > -120,
          let bar = wearerDetector.wearerBarDbFS ?? wearerVoiceDbFS.map({ $0 - Self.wearerLevelMarginDb }) else { return nil }
    return level >= bar ? "wearer" : "other"
  }
  /// Whether the wearer's turns can be told from everyone else's. Simulated lines are scripted.
  var wearerKnown: Bool { simulate || wearerDetector.knowsWearer || (realtimeRelay == nil && wearerVoiceDbFS != nil) }
  /// Whether "That was me" has something to learn from: a caption turn, or a measured voice level.
  var canClaimLastLine: Bool { wearerDetector.canClaim || transcript.last?.levelDbFS != nil }
  /// "That was me", an optional override: the most recent caption turn was the wearer's.
  /// Without live captions it learns the wearer's voice level from the most recent caption, then relabels speech.
  func markLastLineAsMine() {
    if realtimeRelay != nil || transcript.isEmpty, wearerDetector.claimLastTurn() {
      // Help that was being prepared for the wearer's own line no longer applies.
      if ConversationPolicy.role(transcript.last?.speaker, wearerLabel:wearerLabel) == "wearer" { dropConversationCheck(); clearCue() }
      return
    }
    guard let level = transcript.last(where: { $0.levelDbFS.map { $0 > -120 } ?? false })?.levelDbFS else { return }
    let updated = wearerVoiceDbFS.map { ($0 + level) / 2 } ?? level
    wearerVoiceDbFS = updated
    UserDefaults.standard.set(updated, forKey:"copilot.wearerVoiceDbFS")
    transcript = transcript.map { entry in var entry = entry; entry.speaker = speaker(forLevel:entry.levelDbFS); return entry }
  }
  func resetWearerVoice() {
    wearerDetector.reset()
    wearerVoiceDbFS = nil
    UserDefaults.standard.removeObject(forKey:"copilot.wearerVoiceDbFS")
  }
  /// Checks one line the wearer said. Until the voice is calibrated every line is treated as possibly theirs.
  func checkTone(_ entry: TranscriptEntry) {
    guard toneCheckEnabled, phase == .active, entry.speaker != "other",
          entry.text.split(whereSeparator:\.isWhitespace).count >= 3 else { return }
    let offline = simulate && localMock
    guard offline || !uploadsDisabled else { return }
    guard toneTask == nil else { pendingToneEntry = entry; return }
    let recent = transcript.suffix(6).map { ToneRequest.Recent(text:$0.text, speaker:$0.speaker) }
    let present = presentPeople
    let request = ToneRequest(line:.init(text:entry.text, endMs:entry.endMs), recent:recent, scene:currentScene ?? "",
                              speakerKnown:entry.speaker == "wearer", people:present.prefix(8).map { people.context(for:$0) },
                              groups:people.groups(of:present).prefix(8).map(people.context(for:)))
    let connection = client, thisEpoch = epoch
    toneTask = Task { [weak self] in
      let result: ToneResult?
      if offline {
        try? await Task.sleep(for:.milliseconds(300))
        result = Self.mockTone(entry.text)
      } else {
        result = try? await (connection.post("api/tone", request) as (ToneResponse, Int)).0.result
      }
      guard let self, epoch == thisEpoch else { return }
      toneTask = nil
      if let result, result.flag, phase == .active {
        showTone(ToneFeedback(said:entry.text, recovery:result.recovery, rephrase:result.rephrase, strong:result.severity == "strong"))
      }
      if let next = pendingToneEntry { pendingToneEntry = nil; checkTone(next) }
    }
  }
  private func showTone(_ feedback: ToneFeedback) {
    toneFeedback = feedback
    toneTTLTask?.cancel()
    toneTTLTask = Task { [weak self] in
      try? await Task.sleep(for:.seconds(25))
      guard let self, !Task.isCancelled, self.toneFeedback?.id == feedback.id else { return }
      self.toneFeedback = nil
    }
  }
  func dismissTone() { toneTTLTask?.cancel(); toneFeedback = nil }
  private func clearTone() {
    toneTask?.cancel(); toneTask = nil; pendingToneEntry = nil
    dismissTone()
  }
  /// Offline demo fixture mirroring the server's mockTone.
  static func mockTone(_ text: String) -> ToneResult {
    let blunt = text.range(of:#"\b(stupid|dumb|idiotic|pointless|terrible|useless|makes no sense|waste of time|you're wrong|that's wrong|shut up|whatever|not listening|ridiculous|awful)\b"#,
                           options:[.regularExpression, .caseInsensitive]) != nil
    return blunt ? ToneResult(flag:true, severity:"strong", issue:"Blunt wording", recovery:"Sorry, that came out harsh. Let me explain my concern.",
                              rephrase:"I'm not sure this works yet. Could we talk through the risks?")
                 : ToneResult(flag:false, severity:"none", issue:"", recovery:"", rephrase:"")
  }

  func dismiss() {
    invalidateCue()
    dismissedAt = nowMs() // dismissal also buys a quiet interval
    publishDisplay()
    notice = ""
  }
  func markDistracting() { distracting += 1; dismiss() }
  private func invalidateCue() {
    cueSpeaker.stop()
    if isThinking && phase == .active {
      analysisFeedback = "New speech. Analyze after a pause."
    } else if cue != nil { analysisFeedback = "Streaming" }
    generation += 1
    cueTask?.cancel(); cueTask = nil; isThinking = false
    ttlTask?.cancel(); stuckTask?.cancel()
    lastSceneSummary = nil; lastAnalysisOutcome = nil; lastAnalysisAtMs = 0
    if cue != nil { cue = nil; publishDisplay() }
  }
  /// New words make a conversation answer in flight out of date, and mean nobody is stuck. The cue on screen stays.
  private func dropConversationCheck() {
    stuckTask?.cancel()
    guard cueTask != nil, let trigger = activeTrigger else { return }
    generation += 1
    cueTask?.cancel(); cueTask = nil; isThinking = false; staleDrops += 1
    if trigger == .manual { feedback("New speech. Analyze after a pause.") }
  }
  /// A question gets its check before its turn is finalized, once its words have settled. See SpeculativeCue.
  private func speculate(turn: Int, text: String?) {
    guard !sceneChecks, let wait = speculation.heard(turn:turn, text:text, at:nowMs()) else { return }
    speculationTask?.cancel()
    speculationTask = Task { [weak self] in
      try? await Task.sleep(for:.milliseconds(Int(wait.rounded(.up))))
      guard let self, !Task.isCancelled, phase == .active, !sceneChecks,
            let early = speculation.consider(turn:turn, speaker:realtimeSpeakers[turn], wearerLabel:wearerLabel, at:nowMs()) else { return }
      let sent = requests
      requestCue(manual:false, trigger:.question, partial:TranscriptEntry(text:String(early.text.prefix(500)), startMs:early.heardAt - 1000, endMs:early.heardAt, confidence:nil, speaker:realtimeSpeakers[turn]))
      guard requests > sent else { return }
      speculation.sent(turn:turn, text:early.text, generation:generation); captionDiagnostics.cueSentEarly(for:turn)
    }
  }
  /// A finished turn from someone else is a moment to help. The wearer's own turns never are.
  private func turnFinalized(_ entry: TranscriptEntry, turn: Int? = nil) {
    captionDiagnostics.turnFinal(turn:turn, speechEndMs:entry.endMs)
    let role = ConversationPolicy.role(entry.speaker, wearerLabel:wearerLabel)
    let early = speculation.finalize(turn:turn, text:entry.text, role:role, generation:generation)
    // Different words make the early answer out of date. Its cue stays until the new answer replaces it,
    // unless the turn was the wearer's own or no question after all.
    if early == .rerun || early == .withdraw { dropConversationCheck() }
    if early == .withdraw { cueSpeaker.stop(); clearCue() }
    guard !sceneChecks, phase == .active, transcript.last?.id == entry.id, role == "other" else { return }
    // Until the wearer's voice is found, this turn could be their own: no question or stuck check.
    let known = wearerKnown
    if early != .keep, let trigger = early == .rerun ? .question : ConversationPolicy.trigger(for:entry.text, wearerKnown:known) { requestCue(manual:false, trigger:trigger) }
    guard known else { return }
    stuckTask = Task { [weak self] in
      try? await Task.sleep(for:.milliseconds(Int(ConversationPolicy.stuckDelayMs)))
      // Any speech cancels this wait. A cue on screen or a check in flight already covers the moment.
      guard let self, !Task.isCancelled, cue == nil, cueTask == nil else { return }
      requestCue(manual:false, trigger:.stuck)
    }
  }
  /// Expiry is not a dismissal: no quiet interval follows.
  private func clearCue() {
    ttlTask?.cancel()
    if cue != nil { analysisFeedback = "Streaming"; cue = nil; publishDisplay() }
  }
  /// Conversation cues clear themselves. Scene cues stay until the next check replaces them.
  private func expireCue() {
    ttlTask?.cancel()
    ttlTask = Task { [weak self] in
      try? await Task.sleep(for:.milliseconds(Int(ConversationPolicy.cueLifetimeMs)))
      guard let self, !Task.isCancelled else { return }
      clearCue()
    }
  }
  private func sample(_ image: UIImage, at time: Double) {
    guard phase == .active, time >= captureStartedAt else { return }
    captureActivity.videoReceivedAtMs = nowMs()
    // Keep a fresh image locally even when inference backs off to 20–30 seconds.
    let interval = analyzesSurroundings ? 2.0 : sampleInterval
    guard time - latestSampleAt >= interval * 1000 else { return }
    let scale = min(1, 640 / max(image.size.width, image.size.height))
    let target = CGSize(width:image.size.width * scale, height:image.size.height * scale)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let reduced = UIGraphicsImageRenderer(size:target, format:format).image { _ in image.draw(in:CGRect(origin:.zero, size:target)) }
    guard let data = reduced.jpegData(compressionQuality:0.6) else { return }
    latestFrame = SampledFrame(dataUrl:"data:image/jpeg;base64," + data.base64EncodedString(), capturedAtMs:time)
    latestSampleAt = time
  }
  func startRealtimeCaptions() async {
    stopRealtimeCaptions()
    captionDiagnostics.reset()
    captionDiagnostics.record("Capture running; opening realtime connection")
    let run = epoch
    let relay = makeRealtimeRelay(endpoint, proxyToken)
    realtimeRelay = relay
    speechMode = "Connecting realtime captions…"
    relay.onEvent = { [weak self] event in
      guard let self, self.epoch == run else { return }
      self.captionDiagnostics.received(event)
      self.applyRealtimeCaption(event)
    }
    relay.onSend = { [weak self] bytes, duration in
      guard let self, self.epoch == run else { return }
      self.captionDiagnostics.sent(bytes:bytes, durationMs:duration)
    }
    relay.onFailure = { [weak self] message in
      guard let self, self.epoch == run else { return }
      self.captionDiagnostics.record("Realtime failed: \(message)")
      self.stopRealtimeCaptions()
      self.speechMode = "Chunked fallback — \(message)"
    }
    do {
      try await relay.start(languageBias:["English", "Hindi"])
      guard epoch == run, !Task.isCancelled, realtimeRelay != nil else { relay.stop(); return }
      speechMode = "Live streaming captions"
    } catch {
      guard epoch == run, !Task.isCancelled else { relay.stop(); return }
      captionDiagnostics.record("Realtime startup failed: \(error.localizedDescription)")
      stopRealtimeCaptions()
      speechMode = "Chunked fallback — \(error.localizedDescription)"
    }
  }

  private func stopRealtimeCaptions() {
    realtimeRelay?.onEvent = nil; realtimeRelay?.onFailure = nil; realtimeRelay?.onSend = nil
    realtimeRelay?.stop(); realtimeRelay = nil
    realtimeRoster = PhoneCaptionRoster(); realtimeClock.reset()
    conversationWindow = ConversationWindow()
    finalizedTurns.removeAll(); realtimeSpeakers.removeAll(); captionRows = []; speculation = SpeculativeCue()
    wearerDetector.captionsRestarted(); levelTrack = SpeechLevelTrack()
    speechMode = "Not started"
  }

  func sendRealtimePCM(_ data: Data, endedAtMs: Double) {
    guard !sceneOnly, !uploadsDisabled, phase == .starting || phase == .active,
          let relay = realtimeRelay else { return }
    captionDiagnostics.captured(bytes:data.count, endedAtMs:endedAtMs)
    realtimeClock.notePCM(byteCount:data.count, endedAtMs:endedAtMs)
    if relay.acceptsPCM { levelTrack.append(data) }
    relay.sendPCM(data)
  }

  func applyRealtimeCaption(_ event: RealtimeASREvent) {
    guard phase == .active, let id = event.turnId,
          ["transcript.partial", "speaker.updated", "transcript.final"].contains(event.type) else { return }
    let time = nowMs()
    if let speaker = event.speaker { realtimeSpeakers[id] = speaker }
    let range = realtimeClock.range(startAudioMs:event.startAudioMs, endAudioMs:event.endAudioMs, fallbackEndMs:time)
    conversationWindow.consume(event, at:min(time, realtimeClock.captureTime(audioProcessedMs:event.audioProcessedMs) ?? range.endMs))
    realtimeRoster.consume(event, at:time)
    captionRows = realtimeRoster.rows
    captionText = captionRows.isEmpty ? nil : captionRows.map { "\($0.id.hasPrefix("P") ? $0.id : "Speaker…"): \($0.text)" }.joined(separator:"\n")
    captionAtMs = time
    if event.type != "speaker.updated", !finalizedTurns.contains(id),
       event.text?.contains(where: { $0.isLetter || $0.isNumber }) == true, speculation.turn != id { dropConversationCheck() }
    if event.type != "transcript.final", !finalizedTurns.contains(id) { speculate(turn:id, text:event.text) }
    guard event.type == "transcript.final", !finalizedTurns.contains(id) else { return }
    finalizedTurns.insert(id)
    // Bound deduplication bookkeeping during long sessions.
    if finalizedTurns.count > 256, let oldest = finalizedTurns.min() {
      finalizedTurns.remove(oldest); realtimeSpeakers[oldest] = nil
    }
    guard let text = event.text?.trimmingCharacters(in:.whitespacesAndNewlines), !text.isEmpty else { return }
    // The turn's own loudness, read back from the audio that was sent for it.
    let level = levelTrack.level(fromMs:event.startAudioMs, toMs:event.endAudioMs)
    wearerDetector.record(label:realtimeSpeakers[id], levelDbFS:level)
    let entry = TranscriptEntry(text:String(text.prefix(500)), startMs:range.startMs, endMs:range.endMs,
                                confidence:nil, speaker:realtimeSpeakers[id] ?? speaker(forLevel:level), levelDbFS:level)
    transcript.append(entry); transcript.sort { $0.endMs < $1.endMs }
    lastVoiceAt = max(lastVoiceAt, range.endMs)
    logSpeech(entry); noteNames(in:entry); trimTranscript()
    turnFinalized(entry, turn:id)
  }

  func transcribe(_ chunk: AudioChunk) {
    guard realtimeRelay == nil else { return }
    guard !sceneOnly, !uploadsDisabled, phase == .active, chunk.startedAtMs >= captureStartedAt - 200 else { return }
    guard asrTask == nil else { audioDrops += 1; return }
    let thisEpoch = epoch
    let connection = client
    isTranscribing = true
    asrTask = Task { [weak self] in
      guard let self else { return }
      defer { if epoch == thisEpoch { asrTask = nil; isTranscribing = false } }
      do {
        let (result, bytes): (TranscriptionResponse, Int) = try await connection.post("api/transcribe", chunk)
        guard epoch == thisEpoch, phase == .active, !Task.isCancelled else { return }
        uploadedBytes += bytes; transcriptionMs = result.transcriptionMs ?? 0; recordCost(result.estimatedCostUsd)
        let text = result.text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else { return } // Noise or unclear audio is not new conversation.
        lastVoiceAt = chunk.endedAtMs
        let entry = TranscriptEntry(text:String(text.prefix(500)), startMs:chunk.startedAtMs, endMs:chunk.endedAtMs, confidence:result.confidence,
                                    speaker:speaker(forLevel:chunk.speechDbFS), levelDbFS:chunk.speechDbFS)
        transcript.append(entry); logSpeech(entry); noteNames(in:entry); checkTone(entry)
        // New speech updates captions and leaves a displayed cue alone until it expires.
        setCaption(text, capturedAtMs:chunk.endedAtMs)
        trimTranscript()
        dropConversationCheck(); turnFinalized(entry)
      } catch {
        guard epoch == thisEpoch, !Task.isCancelled else { return }
        // Fail closed: missing transcription cannot be quietly replaced by a fixture.
        pause("Transcription failed: \(error.localizedDescription)")
      }
    }
  }
  func addSimulationLine(_ line: String? = nil, speaker: String? = nil) {
    guard simulate, phase == .active else { return }
    let value = (line ?? simulationText).trimmingCharacters(in:.whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    let timestamp = nowMs()
    lastVoiceAt = timestamp
    let entry = TranscriptEntry(text:String(value.prefix(500)), startMs:timestamp-2500, endMs:timestamp, confidence:nil, speaker:speaker)
    transcript.append(entry); logSpeech(entry); noteNames(in:entry); checkTone(entry)
    setCaption(value, capturedAtMs:timestamp)
    trimTranscript()
    // Render an original synthetic scene, clearly labeled, to exercise image serialization in proxy mode.
    let renderer = UIGraphicsImageRenderer(size:CGSize(width:480,height:270))
    let image = renderer.image { context in
      UIColor(red:0.09,green:0.16,blue:0.18,alpha:1).setFill(); context.fill(CGRect(x:0,y:0,width:480,height:270))
      let label = "SIMULATED CAMERA\nNo participant image"
      label.draw(in:CGRect(x:32,y:95,width:416,height:90), withAttributes:[.font:UIFont.systemFont(ofSize:24),.foregroundColor:UIColor.white])
    }
    latestSampleAt = 0; sample(image, at:timestamp)
    dropConversationCheck(); turnFinalized(entry)
  }
  func addSimulationScene(_ scene: String) {
    guard simulate, phase == .active, ["library", "group", "funeral"].contains(scene) else { return }
    simulateSurroundings = true; simulatedScene = scene
    invalidateCue(); transcript.removeAll(); captionText = nil; captionAtMs = 0; lastVoiceAt = 0
    lastAnalysisAt = 0; latestSampleAt = 0
    let image = UIGraphicsImageRenderer(size:CGSize(width:480, height:270)).image { context in
      UIColor.darkGray.setFill(); context.fill(CGRect(x:0, y:0, width:480, height:270))
      "SIMULATED SCENE: \(scene)\nFixture, not a real camera image".draw(in:CGRect(x:25, y:80, width:430, height:120),
        withAttributes:[.font:UIFont.systemFont(ofSize:24), .foregroundColor:UIColor.white])
    }
    sample(image, at:nowMs())
    notice = ""
    requestCue(manual:true) // A fixture selection is an explicit scene check.
  }
  private func trimTranscript() {
    let cutoff = nowMs() - 60000
    transcript = Array(transcript.filter { $0.endMs >= cutoff }.suffix(12))
  }
  func setCaption(_ text: String, capturedAtMs: Double) {
    guard phase == .active, capturedAtMs >= captionAtMs, nowMs()-capturedAtMs <= 15000, capturedAtMs <= nowMs()+1000 else { return }
    captionText = String(text.suffix(240)); captionAtMs = capturedAtMs
  }
  func expireCaption(at timestamp: Double = nowMs()) {
    if realtimeRelay != nil {
      realtimeRoster.expire(at:timestamp)
      let updated = realtimeRoster.rows
      if updated != captionRows {
        captionRows = updated
        captionText = updated.isEmpty ? nil : updated.map { "\($0.id.hasPrefix("P") ? $0.id : "Speaker…"): \($0.text)" }.joined(separator:"\n")
      }
      return
    }
    if captionText != nil, timestamp-captionAtMs > 15000 { captionText = nil }
  }
  func sceneBecameInactive() {
    // Phone camera is a foreground experience. Do not claim pocket camera support.
    if captureMode == .phone { pause("Phone session paused when the app left the foreground. Resume deliberately.") }
  }
  func recentCueTranscript(at timestamp: Double = nowMs()) -> [TranscriptEntry] {
    guard !sceneOnly else { return [] }
    if realtimeRelay != nil { return conversationWindow.entries(at:timestamp) }
    return transcript.filter { timestamp - $0.endMs <= SurroundingsPolicy.contextWindowMs && $0.endMs <= timestamp + 1000 && ($0.confidence ?? 1) >= 0.65 }
  }
  func requestCue(manual: Bool, trigger: CueTrigger? = nil, partial: TranscriptEntry? = nil) {
    guard !uploadsDisabled else { if manual { notice = "Connection test makes no API requests. Use Manual display test." }; return }
    guard phase == .active else { return }
    let timestamp = nowMs()
    let surroundings = sceneChecks
    guard cueTask == nil else {
      // An explicit request waits for an automatic check instead of being lost with it.
      if manual { if surroundings || activeTrigger == .manual { feedback("Analyzing…") } else { queueManualAnalysis("Analyzing…", at:timestamp) } }
      return
    }
    // A conversation check answers a moment: someone's finished turn, or the wearer asking. It never runs on a timer.
    let trigger = surroundings ? nil : trigger ?? (manual ? .manual : nil)
    guard surroundings || trigger != nil else { return }
    // An explicit request waits for speech still being transcribed. A finished turn is already complete.
    guard surroundings || !manual || !isTranscribing else {
      queueManualAnalysis("Finishing speech, then analyzing…", at:timestamp)
      return
    }
    if let issue = liveInputIssue(at:timestamp) { if manual { queueManualAnalysis(issue, at:timestamp) }; return }
    // Conversation checks send text only: the last few turns, labeled wearer or other.
    let entries = surroundings ? recentCueTranscript(at:timestamp) : ConversationPolicy.turns(from:transcript + [partial].compactMap { $0 }, wearerLabel:wearerLabel)
    let last = entries.last
    let freshSpeech = last
    let frame = !surroundings ? nil : latestFrame.flatMap { timestamp - $0.capturedAtMs <= SurroundingsPolicy.frameFreshnessMs && $0.capturedAtMs <= timestamp ? $0 : nil }
    // Silence does not imply missing context: a fresh library image can support a cue.
    guard timestamp - captureStartedAt >= 1500,
          surroundings ? (frame != nil || freshSpeech != nil) : freshSpeech != nil else {
      if manual { notice = "Not enough context yet." }
      return
    }
    if surroundings {
      nextAnalysisAt = max(lastAnalysisAt + analysisInterval(at:timestamp, reducedPower:reducedPower) * 1000,
                           dismissedAt + SurroundingsPolicy.dismissQuietMs)
      guard manual || timestamp >= nextAnalysisAt else { return }
    } else {
      // Moments are not rate limited, but a dismissal still buys a quiet interval.
      guard manual || timestamp - dismissedAt >= SurroundingsPolicy.dismissQuietMs else { return }
    }
    let revision = generation, thisEpoch = epoch
    let context = (sceneOnly ? "" : contextText).split(separator:"\n").prefix(5).map { String($0.prefix(160)) }
    let audio = surroundings ? (ambientWindow.context(at:timestamp) ?? latestAudioContext.flatMap { timestamp - $0.capturedAtMs <= 10000 ? $0 : nil }) : nil
    let present = presentPeople
    let request = CueRequest(transcript:entries, frame:frame, context:context, manual:manual,
                             analysisMode:surroundings ? "surroundings" : "conversation", audioContext:audio,
                             people:present.prefix(8).map { people.context(for:$0) },
                             groups:people.groups(of:present).prefix(8).map(people.context(for:)),
                             currentScene:surroundings ? currentScene ?? "" : "", recentMoments:surroundings ? moments : ConversationPolicy.summary(from:moments, at:timestamp),
                             previousCue:surroundings ? cue ?? "" : "",
                             trigger:trigger?.rawValue, aboutMe:ConversationPolicy.aboutMe(aboutMe, for:trigger))
    let connection = client
    let fixtureScene = simulatedScene
    let evidenceAt = freshSpeech?.endMs ?? frame?.capturedAtMs ?? timestamp
    lastRequestedGeneration = revision; lastAnalysisAt = timestamp; lastRequestedSpeechAt = last?.endMs ?? 0
    nextAnalysisAt = timestamp + analysisInterval(at:timestamp, reducedPower:reducedPower) * 1000
    pendingManualAnalysisAt = nil
    activeTrigger = trigger
    isThinking = true; requests += 1
    captionDiagnostics.cueRequested(trigger:trigger?.rawValue ?? "scene", early:partial != nil, speechEndMs:last?.endMs, at:timestamp)
    // An automatic conversation check stays quiet on the lens unless it has something to show.
    if surroundings || manual { feedback(sceneOnly ? "Muse is checking the scene…" : "Analyzing…") }
    cueTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if epoch == thisEpoch, generation == revision { cueTask = nil; isThinking = false; publishDisplay() }
      }
      do {
        let response: CueResponse
        if simulate && localMock {
          try await Task.sleep(for:.milliseconds(400))
          let lower = freshSpeech?.text.lowercased() ?? ""
          var message: String
          var type = surroundings ? "reminder" : "clarify"
          if surroundings && (lower.contains("rough day") || lower.contains("overwhelmed")) {
            message = "They mentioned a hard day. Listen and give them space."
          } else if surroundings && fixtureScene == "library" {
            message = "This looks like a library. Keep your voice low."
          } else if surroundings && fixtureScene == "funeral" && currentScene != "funeral" {
            message = "Looks like a funeral. Stay quiet and somber."
          } else if surroundings && fixtureScene == "group" {
            message = "People are talking. Wait for a pause before joining in."
          } else {
            message = lower.contains("friday") ? "Ask what they meant by Friday." : lower.contains("robot") ? "Ask how their robotics project is going." : lower.contains("hot or iced") ? "They asked whether you want it hot or iced." : ""
          }
          if message.isEmpty, manual, let person = present.first(where: { !$0.topics.isEmpty }), let topic = person.topics.last {
            let suggestion = "Ask \(person.name) about \(topic)."
            if suggestion.count <= 90 && suggestion.split(separator:" ").count <= 14 { message = suggestion }
          }
          if message.isEmpty, !surroundings, let meaning = ConversationPolicy.demoMeaning(for:lower) { message = meaning; type = "meaning" }
          // Ordinary speech gets no filler advice: the fixture abstains, as the live prompt does.
          response = CueResponse(result:CueResult(cue:message, reason:"Local scripted demo fixture", confidence:message.isEmpty ? 0 : 0.95, type:message.isEmpty ? "abstain" : type, should_display:!message.isEmpty,
                                                  scene:["library", "funeral"].contains(fixtureScene) ? fixtureScene : "",
                                                  summary:!surroundings ? nil : freshSpeech.map { "SIMULATED: conversation mentioning \"\($0.text.prefix(60))\"." }), metrics:nil)
          modelMode = "LOCAL SCRIPTED MOCK"
        } else {
          let result: (CueResponse, Int) = try await connection.post("api/cue", request)
          response = result.0; uploadedBytes += result.1
        }
        let completedAt = nowMs()
        captionDiagnostics.cueAnswered(at:completedAt)
        let speechStillFresh = freshSpeech.map { completedAt - $0.endMs <= SurroundingsPolicy.deliveryFreshnessMs } ?? false
        let frameStillFresh = frame.map { completedAt - $0.capturedAtMs <= SurroundingsPolicy.deliveryFreshnessMs } ?? false
        let evidenceStillFresh = surroundings ? (speechStillFresh || frameStillFresh) : (manual || speechStillFresh)
        guard epoch == thisEpoch, generation == revision, phase == .active, !Task.isCancelled,
              completedAt - timestamp <= SurroundingsPolicy.responseMaxAgeMs,
              evidenceStillFresh, liveInputIssue(at:completedAt) == nil else {
          staleDrops += 1
          // The current cue stays up; the next check replaces it.
          if epoch == thisEpoch && generation == revision { feedback(cue == nil && surroundings ? "Checking again shortly…" : "Streaming") }
          return
        }
        apiMs = response.metrics?.apiMs ?? 0; recordCost(response.metrics?.estimatedCostUsd ?? (simulate && localMock ? 0 : nil))
        let result = response.result
        if let scene = result.scene?.trimmingCharacters(in:.whitespaces), !scene.isEmpty, scene != currentScene { currentScene = scene }
        let summary = result.summary?.trimmingCharacters(in:.whitespacesAndNewlines)
        lastSceneSummary = summary.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        remember(result.summary, at:evidenceAt)
        lastAnalysisOutcome = "No new social cue needed."
        lastAnalysisAtMs = completedAt
        if surroundings, !result.should_display && result.type == "abstain" {
          // No supported current context: do not leave an earlier conversation's advice on the lens.
          cueSpeaker.stop()
          cue = nil
          lastAnalysisOutcome = "Waiting for clearer context."
          feedback("Listening for context…")
          notice = ""
          return
        }
        guard let text = ConversationPolicy.displayText(for:result, trigger:trigger) else {
          // Abstaining keeps whatever is on screen rather than blanking it.
          lastAnalysisOutcome = cue == nil ? "No cue yet." : "Keeping the current cue."
          notice = ""
          feedback(cue == nil && surroundings ? "Listening…" : "Streaming")
          return
        }
        let normalized = text.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        let current = cue.map { $0.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace } }
        if surroundings { ttlTask?.cancel() } else { expireCue() }
        // The same advice, or nothing better than what is already showing, keeps the cue on screen.
        if normalized == current || (cue != nil && ConversationPolicy.isNothingToAdd(text)) {
          lastAnalysisOutcome = "Current cue still fits."
          // A failed/route-blocked utterance may now be playable. CueSpeaker
          // suppresses cues that are pending, playing, or already completed.
          if spokenCuesEnabled { cueSpeaker.speak(text, mode:captureMode) }
          return
        }
        pendingManualAnalysisAt = nil // A cue answers a request that was waiting behind this check.
        cue = text; shown += 1; lastCueAt = nowMs(); contextToDisplayMs = lastCueAt - evidenceAt
        lastAnalysisOutcome = "Social cue ready."
        analysisFeedback = "Social cue"
        publishDisplay()
        captionDiagnostics.cueShown(at:lastCueAt)
        if spokenCuesEnabled { cueSpeaker.speak(text, mode:captureMode) }
        notice = ""
      } catch {
        if epoch == thisEpoch, generation == revision, !Task.isCancelled {
          if partial != nil { speculation.requestFailed() }
          notice = surroundings ? "Cue check failed. Retrying automatically." : "Cue check failed. Check the server connection."
          feedback("Analysis failed. Check phone for details.")
        }
      }
    }
  }
  /// Adds the model's summary of this moment to session memory, skipping repeats.
  func remember(_ summary: String?, at time: Double) {
    guard let summary = summary?.trimmingCharacters(in:.whitespacesAndNewlines), !summary.isEmpty,
          summary.caseInsensitiveCompare(moments.last?.summary ?? "") != .orderedSame else { return }
    moments = Array((moments + [Moment(atMs:time, summary:String(summary.prefix(200)))]).suffix(SurroundingsPolicy.momentCount))
  }
  private func recordCost(_ value: Double?) {
    if let value { knownCostTotal += value } else { missingCost = true }
    estimatedCost = missingCost ? nil : knownCostTotal
  }
  /// Notes or people changed: drop the in-flight check and re-check soon, but keep the cue on screen.
  func contextChanged() {
    generation += 1
    cueTask?.cancel(); cueTask = nil; isThinking = false
    lastAnalysisAt = 0; lastRequestedSpeechAt = 0
    publishDisplay()
  }
  func refreshDisplay() { publishDisplay() }
  func manualDisplayTest() {
    guard phase == .active else { return }
    invalidateCue(); cue = "Test cue — check the selected output."
    publishDisplay()
    notice = ""
    let revision = generation
    ttlTask = Task { [weak self] in
      try? await Task.sleep(for:.seconds(8))
      guard let self, !Task.isCancelled, self.generation == revision else { return }
      self.dismiss()
    }
  }
}
