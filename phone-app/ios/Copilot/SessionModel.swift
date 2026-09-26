import Foundation
import Observation
import UIKit
import Vision

@Observable @MainActor
final class SessionModel {
  enum Phase: String { case stopped = "Stopped", starting = "Starting", active = "Listening", paused = "Paused" }
  var phase: Phase = .stopped
  var consent = false
  var glassesControlsReady = false
  var openingGlassesControls = false
  var captureMode: CaptureMode = .phone
  var simulate: Bool {
    get { captureMode == .simulated }
    set { captureMode = newValue ? .simulated : .displayGlasses }
  }
  var glassesConversationEnabled = false
  var sceneOnly: Bool { captureMode == .displayGlasses && !glassesConversationEnabled }
  var phoneCameraEnabled = true
  var localMock = true
  /// Set when Start could not reach a live server: camera and mic still run, AI features wait.
  var offline = false
  var connectionTestOnly = false
  var uploadsDisabled: Bool { offline || connectionTestOnly }
  static let translationLanguages = ["English", "Hindi"]
  var translationEnabled = UserDefaults.standard.object(forKey:"copilot.translationEnabled") as? Bool ?? true
  var targetLanguage = UserDefaults.standard.string(forKey:"copilot.targetLanguage") ?? "English"
  var endpoint = UserDefaults.standard.string(forKey:"copilot.endpoint") ?? "http://127.0.0.1:8787"
  var proxyToken = TokenStore.read()
  var selectedAudioUID = ""
  var audioPorts: [AudioPort] = []
  var contextText = ""
  var sampleInterval = 8.0
  var simulateSurroundings = false
  var displayCaptions = true
  var analysisFeedback: String?
  var pendingManualAnalysisAt: Double?
  var latestAudioContext: AudioContext?
  var reducedPower = false
  var nextAnalysisAt: Double = 0
  var transcript: [TranscriptEntry] = []
  var captionText: String?
  var captionAtMs: Double = 0
  var phonePreview: UIImage?
  var phoneFramesReceived = 0
  var cue: String?
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
  var realtimeASRReady = false
  var speechMode = "Not started"
  var apiMs: Double = 0
  var transcriptionMs: Double = 0
  var realtimeCaptionLatencyMs: Double = 0
  var localizationMs: Double = 0
  var contextToDisplayMs: Double = 0
  var realtimeFallbacks = 0
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
  struct FaceCandidate { var sample: FaceSample; var print: VNFeaturePrintObservation; var area: CGFloat; var sightings: Int }
  private(set) var faceCandidates: [UUID: FaceCandidate] = [:]
  @ObservationIgnored lazy var glasses = GlassesController()
  @ObservationIgnored private let phoneCamera = PhoneCamera()
  @ObservationIgnored private let microphone: ConversationMicrophone
  @ObservationIgnored private let realtimeASRFactory: @MainActor (String, String) -> any RealtimeASRTransport
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var epoch = 0
  @ObservationIgnored private var lastRequestedGeneration = -1
  @ObservationIgnored private var lastCueAt: Double = 0
  @ObservationIgnored private var lastRequestedSpeechAt: Double = 0
  @ObservationIgnored private var recentCues: [String] = []
  @ObservationIgnored private var cueTask: Task<Void, Never>?
  @ObservationIgnored private var asrTask: Task<Void, Never>?
  @ObservationIgnored private var realtimeASR: (any RealtimeASRTransport)?
  @ObservationIgnored private var localizationTasks: [UUID:Task<Void, Never>] = [:]
  @ObservationIgnored private var realtimeClock = RealtimeSpeechClock()
  @ObservationIgnored private var realtimePartials: [Int:(text:String, speaker:String?)] = [:]
  @ObservationIgnored private var finalizedRealtimeTurnIDs: Set<Int> = []
  @ObservationIgnored private var visibleRealtimeTurnID: Int?
  @ObservationIgnored private let speechLanguageBias = ["English", "Hindi"]
  @ObservationIgnored private var realtimeFallbackNotice: String?
  @ObservationIgnored private var startTask: Task<Void, Never>?
  @ObservationIgnored private var loopTask: Task<Void, Never>?
  @ObservationIgnored private var ttlTask: Task<Void, Never>?
  @ObservationIgnored private var latestSampleAt: Double = 0
  @ObservationIgnored private var transportTask: Task<Void, Never>?
  @ObservationIgnored private var captureStartedAt: Double = 0
  @ObservationIgnored private var captureActiveAtMs: Double = 0
  @ObservationIgnored private var lastAnalysisAt: Double = 0
  @ObservationIgnored private var simulatedScene = ""
  /// The setting Muse last recognized, shown as a chip and sent back as background.
  var currentScene: String?

  init(people: PeopleStore? = nil,
       microphone: ConversationMicrophone = ConversationMicrophone(),
       realtimeASRFactory: @escaping @MainActor (String, String) -> any RealtimeASRTransport = { RealtimeASRClient(endpoint:$0, token:$1) }) {
    self.people = people ?? PeopleStore()
    self.microphone = microphone
    self.realtimeASRFactory = realtimeASRFactory
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
    phoneCamera.onFrame = { [weak self] image, time in
      guard let self, self.phase == .active, self.captureMode == .phone else { return }
      self.phonePreview = image; self.phoneFramesReceived += 1; self.sample(image, at:time); self.checkFaces(image, at:time)
    }
    phoneCamera.onFailure = { [weak self] message in self?.captureFailed(message) }
    microphone.onVoice = { [weak self] timestamp in Task { @MainActor in
      guard let self, self.phase == .active, timestamp >= self.captureStartedAt else { return }
      // Ambient energy includes fans/music/crowds. Only recognized speech should
      // reset surroundings timing; otherwise steady noise can starve every cue.
      guard !self.analyzesSurroundings else { return }
      self.lastVoiceAt = timestamp
      self.invalidateCue()
    } }
    microphone.onPCM = { [weak self] data, timestamp in Task { @MainActor in
      self?.sendRealtimePCM(data, endedAtMs:timestamp)
    } }
    microphone.onChunk = { [weak self] chunk in Task { @MainActor in self?.transcribe(chunk) } }
    microphone.onContext = { [weak self] context in Task { @MainActor in
      guard let self, self.phase == .active, context.capturedAtMs >= self.captureStartedAt else { return }
      self.latestAudioContext = context
    } }
    microphone.onFailure = { [weak self] message in Task { @MainActor in self?.captureFailed(message) } }
  }
  private func configureGlassesCallbacks() {
    glasses.onFrame = { [weak self] image, time in self?.sample(image, at:time); self?.checkFaces(image, at:time) }
    glasses.onFailure = { [weak self] message in self?.captureFailed(message) }
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
  var requiresCamera: Bool { captureMode.needsGlasses || (captureMode == .phone && phoneCameraEnabled) }
  func liveInputIssue(at timestamp: Double = nowMs()) -> String? {
    guard !simulate else { return nil }
    let freshFrame = latestFrame.map { timestamp - $0.capturedAtMs <= 10000 && $0.capturedAtMs <= timestamp + 1000 } ?? false
    if requiresCamera && !freshFrame {
      return "Waiting for fresh \(captureMode.needsGlasses ? "glasses" : "phone") camera frames."
    }
    if sceneOnly { return nil } // A fresh image is sufficient; missing audio is reported separately.
    let expectedSource = captureMode == .displayGlasses ? "glasses_pcm" : captureMode == .regularGlasses ? "glasses_hfp" : "phone"
    guard let audio = latestAudioContext, timestamp - audio.capturedAtMs <= 10000,
          audio.capturedAtMs <= timestamp + 1000, audio.source == expectedSource else {
      return "Waiting for live \(captureMode.hasGlassesDisplay ? "glasses ambient" : "microphone") audio."
    }
    return nil
  }
  func checkCaptureHealth(at timestamp: Double = nowMs()) {
    guard phase == .active, !simulate, timestamp - captureActiveAtMs >= 12000,
          let issue = liveInputIssue(at:timestamp) else { return }
    pause("Capture stopped receiving data. \(issue) Resume after checking the connection.")
  }
  var analysisStatus: String {
    if offline { return "Server offline" }
    if isThinking { return "Analyzing surroundings…" }
    if isTranscribing { return "Listening to conversation…" }
    return analyzesSurroundings ? "Watching surroundings" : "Listening for context"
  }
  func analysisInterval(at timestamp: Double = nowMs(), reducedPower: Bool) -> Double {
    if sceneOnly { return reducedPower ? 30 : 10 }
    return SurroundingsPolicy.analysisInterval(recentSpeech:lastVoiceAt > 0 && timestamp - lastVoiceAt < 30000, reducedPower:reducedPower)
  }
  private func publishDisplay() {
    guard captureMode.hasGlassesDisplay, phase == .active else { return }
    glasses.show(cue, caption:sceneOnly ? nil : captionText, note:sceneOnly ? nil : savedNote, captionsEnabled:displayCaptions && !sceneOnly, testOnly:connectionTestOnly, feedback:analysisFeedback, sceneOnly:sceneOnly)
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
    lastAnalysisAt = 0; nextAnalysisAt = 0
    realtimeCaptionLatencyMs = 0; localizationMs = 0
    realtimeFallbackNotice = nil
    speechMode = sceneOnly ? "Scene only" : simulate ? "Simulated" : connectionTestOnly ? "No uploads" : displayOnly ? "Not started" : "Starting"
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
        if !connectionTestOnly && !displayOnly && !offline && !sceneOnly {
          do { try await startRealtimeASR() }
          catch { useChunkedFallback("Realtime transcription unavailable; using chunked fallback.") }
        } else if offline && !sceneOnly {
          speechMode = "Unavailable offline"
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
          if captureMode.hasGlassesDisplay { glasses.show(nil, starting:true) }
          if captureMode == .phone {
            try await microphone.startPhone()
            guard epoch == thisEpoch, !Task.isCancelled else { microphone.stop(); return }
            if phoneCameraEnabled { try await phoneCamera.start() }
          } else {
            try await glasses.start(microphone:microphone, audioUID:selectedAudioUID, withDisplay:captureMode.hasGlassesDisplay)
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
      if let realtimeFallbackNotice { notice = realtimeFallbackNotice }
      else if !offline { notice = "" }
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
    epoch += 1
    phase = .paused
    openingGlassesControls = false; glassesControlsReady = false
    analysisFeedback = nil; pendingManualAnalysisAt = nil
    startTask?.cancel(); asrTask?.cancel(); asrTask = nil; isTranscribing = false
    stopRealtimeASR()
    cancelLocalization()
    speechMode = "Paused"
    loopTask?.cancel(); invalidateCue()
    microphone.stop(); phoneCamera.stop(); phonePreview = nil
    latestFrame = nil; latestAudioContext = nil; latestSampleAt = 0; transcript.removeAll(); lastVoiceAt = 0; captionText = nil; captionAtMs = 0
    nextAnalysisAt = 0; simulatedScene = ""
    if captureMode.needsGlasses { glasses.pauseCapture() }
    notice = reason
  }
  // Stop capture and clear session context, retaining the consented control connection.
  func stopStreaming() {
    guard captureMode.hasGlassesDisplay, consent, phase != .stopped else { return }
    pause()
    contextText = ""; recentCues = []; lastCueAt = 0; currentScene = nil
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
    stopRealtimeASR()
    cancelLocalization()
    speechMode = "Stopped"
    loopTask?.cancel(); invalidateCue()
    microphone.stop(); phoneCamera.stop(); phonePreview = nil
    transcript.removeAll(); latestFrame = nil; latestAudioContext = nil; contextText = ""; latestSampleAt = 0
    nextAnalysisAt = 0; simulatedScene = ""; currentScene = nil
    consent = false
    lastVoiceAt = 0; recentCues = []; lastCueAt = 0; lastRequestedSpeechAt = 0
    captionText = nil; captionAtMs = 0
    if captureMode.needsGlasses { transportTask = Task { await glasses.stop() } }
    notice = ""
    finishConversation()
  }
  private func finishConversation() {
    let log = sessionLog; sessionLog = []
    learn(from:log)
    // Who's here is per conversation; the next session starts from scratch.
    faceTask?.cancel(); faceTask = nil; faceReadout = nil; faceCandidates = [:]
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
    let enrolled = people.people.filter { !$0.faces.isEmpty }
    if faceGallery.key != enrolled.flatMap({ $0.faces.map(\.id) }) { faceGallery = FaceGallery(people:enrolled) }
    guard !faceGallery.isEmpty else { return }
    lastFaceCheckAt = time
    let gallery = faceGallery, thisEpoch = epoch, threshold = Float(faceThreshold)
    faceTask = Task { [weak self] in
      let result = await Task.detached(priority:.utility) { () -> (matches: [FaceMatch], nearest: [FaceMatch], unmatched: [FaceRecognizer.DetectedFace]) in
        guard let faces = try? FaceRecognizer.faces(in:image) else { return ([], [], []) }
        var matches: [FaceMatch] = [], unmatched: [FaceRecognizer.DetectedFace] = []
        for face in faces {
          if let match = FaceRecognizer.match([face], gallery:gallery, threshold:threshold).first { matches.append(match) } else { unmatched.append(face) }
        }
        return (matches, faces.compactMap { FaceRecognizer.rank($0, gallery:gallery).first }, unmatched)
      }.value
      guard let self else { return }
      faceTask = nil
      guard epoch == thisEpoch, phase == .active else { return }
      faceReadout = result.nearest.isEmpty ? "No faces in view" : result.nearest.map { match in
        let name = people.people.first { $0.id == match.personID }?.name ?? "?"
        return "\(name) \(String(format:"%.2f", match.distance))\(result.matches.contains(match) ? " ✓" : "")"
      }.joined(separator:" · ")
      applyFaceMatches(result.matches.map(\.personID), at:time)
      considerFaceCandidate(result.unmatched, at:time)
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
    var distance: Float = .greatestFiniteMagnitude
    if var existing = faceCandidates[id], (try? face.print.computeDistance(&distance, to:existing.print)) != nil, distance <= Float(faceThreshold) {
      existing.sightings += 1
      if face.area > existing.area, let sample = FaceRecognizer.sample(from:face) { existing.sample = sample; existing.print = face.print; existing.area = face.area }
      faceCandidates[id] = existing
    } else if let sample = FaceRecognizer.sample(from:face) {
      faceCandidates[id] = FaceCandidate(sample:sample, print:face.print, area:face.area, sightings:1)
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
    syncPresence()
  }
  func dismiss() {
    invalidateCue()
    lastCueAt = nowMs() // dismissal also buys a quiet interval
    publishDisplay()
    notice = ""
  }
  func markDistracting() { distracting += 1; dismiss() }
  private func invalidateCue() {
    if isThinking && phase == .active {
      analysisFeedback = "New speech. Analyze after a pause."
    } else if cue != nil { analysisFeedback = "Streaming" }
    generation += 1
    cueTask?.cancel(); cueTask = nil; isThinking = false
    ttlTask?.cancel()
    lastSceneSummary = nil; lastAnalysisOutcome = nil; lastAnalysisAtMs = 0
    if cue != nil { cue = nil; publishDisplay() }
  }
  private func sample(_ image: UIImage, at time: Double) {
    // Keep a fresh image locally even when inference backs off to 20–30 seconds.
    let interval = analyzesSurroundings ? 2.0 : sampleInterval
    guard phase == .active, time >= captureStartedAt, time - latestSampleAt >= interval * 1000 else { return }
    let scale = min(1, 640 / max(image.size.width, image.size.height))
    let target = CGSize(width:image.size.width * scale, height:image.size.height * scale)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let reduced = UIGraphicsImageRenderer(size:target, format:format).image { _ in image.draw(in:CGRect(origin:.zero, size:target)) }
    guard let data = reduced.jpegData(compressionQuality:0.6) else { return }
    latestFrame = SampledFrame(dataUrl:"data:image/jpeg;base64," + data.base64EncodedString(), capturedAtMs:time)
    latestSampleAt = time
  }
  func startRealtimeASR() async throws {
    stopRealtimeASR()
    let relay = realtimeASRFactory(endpoint, proxyToken)
    relay.onEvent = { [weak self] event in self?.applyRealtimeEvent(event) }
    relay.onFailure = { [weak self] message in
      guard let self else { return }
      self.useChunkedFallback(message)
    }
    try await relay.start(languageBias:speechLanguageBias)
    realtimeASR = relay
    realtimeASRReady = true
    speechMode = "Realtime diarization"
    resetRealtimeSessionState()
  }
  func useChunkedFallback(_ message: String) {
    realtimeASR?.onEvent = nil; realtimeASR?.onFailure = nil; realtimeASR?.stop()
    realtimeASR = nil; realtimeASRReady = false
    resetRealtimeSessionState()
    if speechMode != "Chunked fallback" { realtimeFallbacks += 1 }
    speechMode = "Chunked fallback"
    realtimeFallbackNotice = message
    if phase == .active { notice = message }
  }
  private func stopRealtimeASR() {
    realtimeASR?.onEvent = nil
    realtimeASR?.onFailure = nil
    realtimeASR?.stop()
    realtimeASR = nil
    realtimeASRReady = false
    resetRealtimeSessionState()
  }
  private func resetRealtimeSessionState() {
    realtimeClock.reset()
    realtimePartials.removeAll()
    finalizedRealtimeTurnIDs.removeAll()
    visibleRealtimeTurnID = nil
  }
  func sendRealtimePCM(_ data: Data, endedAtMs: Double) {
    guard !sceneOnly, !uploadsDisabled, let relay = realtimeASR, realtimeASRReady,
          phase == .starting || phase == .active else { return }
    realtimeClock.notePCM(byteCount:data.count, endedAtMs:endedAtMs)
    relay.sendPCM(data)
  }
  private func updateRealtimeLatency(_ event: RealtimeASREvent, receivedAtMs: Double) {
    guard let capturedAt = realtimeClock.captureTime(audioProcessedMs:event.audioProcessedMs) else { return }
    realtimeCaptionLatencyMs = max(0, receivedAtMs - capturedAt)
  }
  func applyRealtimeEvent(_ event: RealtimeASREvent, receivedAtMs: Double = nowMs()) {
    guard phase == .active else { return }
    switch event.type {
    case "transcript.partial":
      updateRealtimeLatency(event, receivedAtMs:receivedAtMs)
      guard let turnID = event.turnId, let raw = event.text else { return }
      let text = raw.trimmingCharacters(in:.whitespacesAndNewlines)
      guard !text.isEmpty, !finalizedRealtimeTurnIDs.contains(turnID) else { return }
      let speaker = validatedSpeakerAlias(event.speaker) ?? realtimePartials[turnID]?.speaker
      realtimePartials[turnID] = (String(text.prefix(500)), speaker)
      if visibleRealtimeTurnID == nil || turnID >= visibleRealtimeTurnID! {
        visibleRealtimeTurnID = turnID
        setCaption(Self.speakerCaption(speaker, text), capturedAtMs:receivedAtMs)
      }
    case "speaker.updated":
      guard let turnID = event.turnId, let speaker = validatedSpeakerAlias(event.speaker),
            var partial = realtimePartials[turnID], !finalizedRealtimeTurnIDs.contains(turnID) else { return }
      partial.speaker = speaker
      realtimePartials[turnID] = partial
      if visibleRealtimeTurnID == turnID {
        setCaption(Self.speakerCaption(speaker, partial.text), capturedAtMs:receivedAtMs)
      }
    case "transcript.final":
      updateRealtimeLatency(event, receivedAtMs:receivedAtMs)
      guard let turnID = event.turnId, !finalizedRealtimeTurnIDs.contains(turnID), let raw = event.text else { return }
      finalizedRealtimeTurnIDs.insert(turnID)
      let text = raw.trimmingCharacters(in:.whitespacesAndNewlines)
      let prior = realtimePartials.removeValue(forKey:turnID)
      guard !text.isEmpty else {
        if visibleRealtimeTurnID == turnID {
          visibleRealtimeTurnID = nil; captionText = nil; captionAtMs = 0; publishDisplay()
        }
        return
      }
      let speaker = validatedSpeakerAlias(event.speaker) ?? prior?.speaker
      let timing = realtimeClock.range(startAudioMs:event.startAudioMs, endAudioMs:event.endAudioMs, fallbackEndMs:receivedAtMs)
      lastVoiceAt = timing.endMs
      let entry = TranscriptEntry(text:String(text.prefix(500)), startMs:timing.startMs, endMs:timing.endMs,
                                  confidence:nil, speaker:speaker)
      transcript.append(entry)
      transcript.sort { $0.endMs < $1.endMs }
      logSpeech(entry); noteNames(in:entry)
      trimTranscript()
      if visibleRealtimeTurnID == nil || turnID >= visibleRealtimeTurnID! {
        visibleRealtimeTurnID = turnID
        setCaption(Self.speakerCaption(speaker, text), capturedAtMs:receivedAtMs)
      }
      localize(entry.id)
    default: break
    }
  }
  private static func speakerCaption(_ speaker: String?, _ text: String) -> String {
    speaker.map { "\($0): \(text)" } ?? text
  }
  private func localize(_ entryID: UUID) {
    guard translationEnabled, !simulate, !uploadsDisabled, localizationTasks[entryID] == nil,
          let index = transcript.firstIndex(where: { $0.id == entryID }) else { return }
    let entry = transcript[index]
    let context = transcript[..<index].suffix(2).map {
      LocalizationContextTurn(text:$0.text, speaker:$0.speaker)
    }
    let request = LocalizationRequest(text:entry.text, speaker:entry.speaker,
                                      targetLanguage:targetLanguage, context:Array(context))
    let thisEpoch = epoch
    let requestedAt = nowMs()
    let connection = client
    localizationTasks[entryID] = Task { [weak self] in
      guard let self else { return }
      defer { if self.epoch == thisEpoch { self.localizationTasks[entryID] = nil } }
      do {
        let (response, bytes): (LocalizationResponse, Int) = try await connection.post("api/localize", request)
        guard self.epoch == thisEpoch, self.phase == .active, !Task.isCancelled else { return }
        self.uploadedBytes += bytes
        self.localizationMs = response.metrics?.apiMs ?? max(0, nowMs() - requestedAt)
        self.recordCost(response.metrics?.estimatedCostUsd)
        self.applyLocalization(response.result, to:entryID)
      } catch {
        guard self.epoch == thisEpoch, self.phase == .active, !Task.isCancelled else { return }
        if self.transcript.last?.id == entryID { self.notice = "Translation unavailable; showing original speech." }
      }
    }
  }
  private func cancelLocalization() {
    localizationTasks.values.forEach { $0.cancel() }
    localizationTasks.removeAll()
  }
  func applyLocalization(_ result: LocalizationResult, to entryID: UUID, completedAtMs: Double = nowMs()) {
    guard phase == .active, result.targetLanguage == targetLanguage,
          let index = transcript.firstIndex(where: { $0.id == entryID }) else { return }
    guard result.confidence >= 0.65 else {
      if transcript.last?.id == entryID { notice = "Translation uncertain; showing original speech." }
      return
    }
    transcript[index].localization = result
    guard transcript.last?.id == entryID, realtimePartials.isEmpty else { return }
    let entry = transcript[index]
    setCaption(Self.speakerCaption(entry.speaker, result.translation), capturedAtMs:completedAtMs)
  }
  func translationSettingsChanged() {
    guard phase == .stopped else { return }
    if !Self.translationLanguages.contains(targetLanguage) { targetLanguage = "English" }
    UserDefaults.standard.set(translationEnabled, forKey:"copilot.translationEnabled")
    UserDefaults.standard.set(targetLanguage, forKey:"copilot.targetLanguage")
  }
  func transcribe(_ chunk: AudioChunk) {
    // WAV transcription is an explicit fallback, not a duplicate stream while realtime is healthy.
    guard realtimeASR == nil, !sceneOnly, !uploadsDisabled, phase == .active,
          chunk.startedAtMs >= captureStartedAt - 200 else { return }
    guard asrTask == nil else { audioDrops += 1; return }
    speechMode = "Chunked fallback"
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
        let entry = TranscriptEntry(text:String(text.prefix(500)), startMs:chunk.startedAtMs, endMs:chunk.endedAtMs, confidence:result.confidence)
        transcript.append(entry); logSpeech(entry); noteNames(in:entry)
        // New speech updates captions but leaves a pending or displayed cue alone:
        // cues take longer than the gap between sentences in a real conversation.
        setCaption(text, capturedAtMs:chunk.endedAtMs)
        trimTranscript()
        localize(entry.id)
      } catch {
        guard epoch == thisEpoch, !Task.isCancelled else { return }
        // Fail closed: missing transcription cannot be quietly replaced by a fixture.
        pause("Transcription failed: \(error.localizedDescription)")
      }
    }
  }
  func addSimulationLine(_ line: String? = nil) {
    guard simulate, phase == .active else { return }
    let value = (line ?? simulationText).trimmingCharacters(in:.whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    let timestamp = nowMs()
    lastVoiceAt = timestamp
    let entry = TranscriptEntry(text:String(value.prefix(500)), startMs:timestamp-2500, endMs:timestamp, confidence:nil)
    transcript.append(entry); logSpeech(entry); noteNames(in:entry)
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
    publishDisplay()
  }
  func expireCaption(at timestamp: Double = nowMs()) {
    if captionText != nil, timestamp-captionAtMs > 15000 { captionText = nil; publishDisplay() }
  }
  func sceneBecameInactive() {
    // Phone camera is a foreground experience. Do not claim pocket camera support.
    if captureMode == .phone { pause("Phone session paused when the app left the foreground. Resume deliberately.") }
  }
  func requestCue(manual: Bool) {
    guard !uploadsDisabled else { if manual { notice = "Connection test makes no API requests. Use Manual display test." }; return }
    guard phase == .active else { return }
    guard cueTask == nil else { if manual { feedback("Analyzing…") }; return }
    let timestamp = nowMs()
    guard !isTranscribing else {
      if manual { queueManualAnalysis("Finishing speech, then analyzing…", at:timestamp) }
      return
    }
    if let issue = liveInputIssue(at:timestamp) { if manual { queueManualAnalysis(issue, at:timestamp) }; return }
    let surroundings = analyzesSurroundings
    let last = sceneOnly ? nil : transcript.last
    let freshSpeech = last.flatMap { timestamp - $0.endMs <= 15000 ? $0 : nil }
    let frame = latestFrame.flatMap { timestamp - $0.capturedAtMs <= SurroundingsPolicy.frameFreshnessMs && $0.capturedAtMs <= timestamp ? $0 : nil }
    // Silence does not imply missing context: a fresh library image can support a cue.
    guard timestamp - captureStartedAt >= 1500,
          surroundings ? (frame != nil || freshSpeech != nil) : freshSpeech != nil else {
      if manual { notice = "Not enough context yet." }
      return
    }
    if surroundings {
      nextAnalysisAt = max(lastAnalysisAt + analysisInterval(at:timestamp, reducedPower:reducedPower) * 1000,
                           sceneOnly ? 0 : lastCueAt + SurroundingsPolicy.cueCooldownMs)
      guard manual || timestamp >= nextAnalysisAt else { return }
    } else {
      // Automatic checks need new speech since the last check, plus the usual cooldown.
      guard manual || (timestamp - lastCueAt >= SurroundingsPolicy.cueCooldownMs
                       && timestamp - lastAnalysisAt >= sampleInterval * 1000
                       && (last?.endMs ?? 0) > lastRequestedSpeechAt) else { return }
    }
    let revision = generation, thisEpoch = epoch
    let context = (sceneOnly ? "" : contextText).split(separator:"\n").prefix(5).map { String($0.prefix(160)) }
    // When speech has aged out, don't let it dominate the current visual setting.
    let entries = sceneOnly || (surroundings && freshSpeech == nil) ? [] : transcript
    let audio = surroundings ? latestAudioContext.flatMap { timestamp - $0.capturedAtMs <= 10000 ? $0 : nil } : nil
    let present = presentPeople
    let request = CueRequest(transcript:entries, frame:frame, context:context, manual:manual,
                             analysisMode:surroundings ? "surroundings" : "conversation", audioContext:audio,
                             people:present.prefix(8).map { people.context(for:$0) },
                             groups:people.groups(of:present).prefix(8).map(people.context(for:)),
                             currentScene:currentScene ?? "")
    let connection = client
    let fixtureScene = simulatedScene
    let evidenceAt = freshSpeech?.endMs ?? frame?.capturedAtMs ?? timestamp
    lastRequestedGeneration = revision; lastAnalysisAt = timestamp; lastRequestedSpeechAt = last?.endMs ?? 0
    nextAnalysisAt = timestamp + analysisInterval(at:timestamp, reducedPower:reducedPower) * 1000
    pendingManualAnalysisAt = nil
    isThinking = true; requests += 1; feedback(sceneOnly ? "Muse is checking the scene…" : "Analyzing…")
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
          response = CueResponse(result:CueResult(cue:message, reason:"Local scripted demo fixture", confidence:message.isEmpty ? 0 : 0.95, type:surroundings ? "reminder" : "clarify", should_display:!message.isEmpty,
                                                  scene:["library", "funeral"].contains(fixtureScene) ? fixtureScene : ""), metrics:nil)
          modelMode = "LOCAL SCRIPTED MOCK"
        } else {
          let result: (CueResponse, Int) = try await connection.post("api/cue", request)
          response = result.0; uploadedBytes += result.1
        }
        let completedAt = nowMs()
        let speechStillFresh = freshSpeech.map { completedAt - $0.endMs <= SurroundingsPolicy.deliveryFreshnessMs } ?? false
        let frameStillFresh = frame.map { completedAt - $0.capturedAtMs <= SurroundingsPolicy.deliveryFreshnessMs } ?? false
        let evidenceStillFresh = surroundings ? (speechStillFresh || frameStillFresh) : speechStillFresh
        guard epoch == thisEpoch, generation == revision, phase == .active, !Task.isCancelled,
              completedAt - timestamp <= SurroundingsPolicy.responseMaxAgeMs,
              evidenceStillFresh else { staleDrops += 1; return }
        apiMs = response.metrics?.apiMs ?? 0; recordCost(response.metrics?.estimatedCostUsd ?? (simulate && localMock ? 0 : nil))
        let result = response.result
        if let scene = result.scene?.trimmingCharacters(in:.whitespaces), !scene.isEmpty, scene != currentScene { currentScene = scene }
        lastSceneSummary = String(result.reason.prefix(400))
        lastAnalysisOutcome = "No new social cue needed."
        lastAnalysisAtMs = completedAt
        let text = result.cue.trimmingCharacters(in:.whitespacesAndNewlines)
        let normalized = text.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        guard result.should_display, result.confidence.isFinite, result.confidence >= 0.8, result.confidence <= 1,
              ["clarify", "follow_up", "reminder", "respond"].contains(result.type),
              !text.isEmpty, text.count <= 90, text.split(whereSeparator: { $0.isWhitespace }).count <= 14,
              (sceneOnly || !recentCues.contains(normalized)) else {
          if sceneOnly { cue = nil }
          notice = "No new cue needed. Still watching for context."
          feedback("No new cue needed. See phone for why.")
          return
        }
        cue = text; shown += 1; lastCueAt = nowMs(); contextToDisplayMs = lastCueAt - evidenceAt
        lastAnalysisOutcome = "Social cue ready."
        analysisFeedback = "Social cue"
        recentCues = Array((recentCues + [normalized]).suffix(20))
        publishDisplay()
        notice = simulate ? "SIMULATED social cue." : captureMode.hasGlassesDisplay ? "Social cue sent to glasses." : "Suggestion ready on the phone."
        if !sceneOnly { ttlTask = Task { [weak self] in
          try? await Task.sleep(for:.seconds(8))
          guard let self, !Task.isCancelled, self.generation == revision else { return }
          // Expiry clears the cue without extending the automatic cooldown.
          self.cue = nil; self.analysisFeedback = "Streaming"; self.publishDisplay()
        } }
      } catch {
        if epoch == thisEpoch, generation == revision, !Task.isCancelled {
          if sceneOnly { cue = nil }
          notice = "Cue request failed: \(error.localizedDescription). " + (sceneOnly ? "Will retry automatically." : "Tap Analyze now to retry.")
          feedback("Analysis failed. Check phone for details.")
        }
      }
    }
  }
  private func recordCost(_ value: Double?) {
    if let value { knownCostTotal += value } else { missingCost = true }
    estimatedCost = missingCost ? nil : knownCostTotal
  }
  func contextChanged() { invalidateCue(); publishDisplay() }
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
