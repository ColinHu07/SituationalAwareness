import Foundation
import Observation
import UIKit

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
  var phoneCameraEnabled = true
  var localMock = true
  var connectionTestOnly = false
  var endpoint = UserDefaults.standard.string(forKey:"copilot.endpoint") ?? "http://127.0.0.1:8787"
  var proxyToken = TokenStore.read()
  var selectedAudioUID = ""
  var audioPorts: [AudioPort] = []
  var contextText = ""
  var sampleInterval = 8.0
  var simulateSurroundings = false
  var displayCaptions = false
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
  var notice = "Start only after everyone agrees."
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
  @ObservationIgnored lazy var glasses = GlassesController()
  @ObservationIgnored private let phoneCamera = PhoneCamera()
  @ObservationIgnored private let microphone = ConversationMicrophone()
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var epoch = 0
  @ObservationIgnored private var lastRequestedGeneration = -1
  @ObservationIgnored private var lastCueAt: Double = 0
  @ObservationIgnored private var recentCues: [String] = []
  @ObservationIgnored private var cueTask: Task<Void, Never>?
  @ObservationIgnored private var asrTask: Task<Void, Never>?
  @ObservationIgnored private var startTask: Task<Void, Never>?
  @ObservationIgnored private var loopTask: Task<Void, Never>?
  @ObservationIgnored private var ttlTask: Task<Void, Never>?
  @ObservationIgnored private var latestSampleAt: Double = 0
  @ObservationIgnored private var transportTask: Task<Void, Never>?
  @ObservationIgnored private var captureStartedAt: Double = 0
  @ObservationIgnored private var captureActiveAtMs: Double = 0
  @ObservationIgnored private var lastAnalysisAt: Double = 0
  @ObservationIgnored private var simulatedScene = ""

  init() {
    #if DEBUG
    let launchEnvironment = ProcessInfo.processInfo.environment
    if let settings = DevelopmentConnection.settings(from:launchEnvironment) {
      do {
        try TokenStore.save(settings.token)
        UserDefaults.standard.set(settings.endpoint,forKey:"copilot.endpoint")
        endpoint = settings.endpoint; proxyToken = settings.token
        notice = "Test backend configured. Choose your inputs and start when ready."
      } catch { notice = "Could not save the test connection. Configure it in Settings." }
    }
    if launchEnvironment["ASIDE_CAPTURE_MODE"] == "display_glasses" { captureMode = .displayGlasses }
    #endif
    phoneCamera.onFrame = { [weak self] image, time in
      guard let self, self.phase == .active, self.captureMode == .phone else { return }
      self.phonePreview = image; self.phoneFramesReceived += 1; self.sample(image, at:time)
    }
    phoneCamera.onFailure = { [weak self] message in self?.pause(message) }
    microphone.onVoice = { [weak self] timestamp in Task { @MainActor in
      guard let self, self.phase == .active, timestamp >= self.captureStartedAt else { return }
      // Ambient energy includes fans/music/crowds. Only recognized speech should
      // reset surroundings timing; otherwise steady noise can starve every cue.
      guard !self.analyzesSurroundings else { return }
      self.lastVoiceAt = timestamp
      self.invalidateCue()
    } }
    microphone.onChunk = { [weak self] chunk in Task { @MainActor in self?.transcribe(chunk) } }
    microphone.onContext = { [weak self] context in Task { @MainActor in
      guard let self, self.phase == .active, context.capturedAtMs >= self.captureStartedAt else { return }
      self.latestAudioContext = context
    } }
    microphone.onFailure = { [weak self] message in Task { @MainActor in self?.pause(message) } }
  }
  private func configureGlassesCallbacks() {
    glasses.onFrame = { [weak self] image, time in self?.sample(image, at:time) }
    glasses.onFailure = { [weak self] message in self?.pause(message) }
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
  var canStart: Bool { consent && (captureMode != .regularGlasses || !selectedAudioUID.isEmpty) && (phase == .stopped || phase == .paused) }
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
    if connectionTestOnly { return "Capture test · no uploads" }
    if isThinking { return "Analyzing surroundings…" }
    if isTranscribing { return "Listening to conversation…" }
    return analyzesSurroundings ? "Watching surroundings" : "Listening for context"
  }
  func analysisInterval(at timestamp: Double = nowMs(), reducedPower: Bool) -> Double {
    SurroundingsPolicy.analysisInterval(recentSpeech:lastVoiceAt > 0 && timestamp - lastVoiceAt < 30000, reducedPower:reducedPower)
  }
  private func publishDisplay() {
    guard captureMode.hasGlassesDisplay, phase == .active else { return }
    glasses.show(cue, caption:captionText, note:savedNote, captionsEnabled:displayCaptions, testOnly:connectionTestOnly)
  }
  func saveConnection() {
    do { try TokenStore.save(proxyToken); UserDefaults.standard.set(endpoint, forKey:"copilot.endpoint"); notice = "Proxy settings saved. Model keys stay on the server." }
    catch { notice = error.localizedDescription }
  }
  func checkBackend() async {
    do { let health = try await client.health(); modelMode = health.modelMode ?? "Unknown"; notice = "Proxy reachable: \(modelMode)" }
    catch { notice = error.localizedDescription }
  }
  func refreshAudioPorts() {
    guard phase == .stopped || phase == .paused else { return }
    do { audioPorts = try microphone.availablePorts(); notice = audioPorts.isEmpty ? "No Bluetooth HFP inputs found. Pair glasses in iOS / Meta AI, then refresh." : "Select the glasses microphone by its Bluetooth name." }
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
    let previousStart = startTask
    openingGlassesControls = displayOnly
    glassesControlsReady = false
    epoch += 1
    let thisEpoch = epoch
    phase = .starting
    captureStartedAt = nowMs()
    lastAnalysisAt = 0; nextAnalysisAt = 0
    invalidateCue()
    notice = displayOnly ? "Opening controls on glasses. Camera and microphone stay off." : simulate ? "SIMULATED INPUT. No camera or microphone recording." : captureMode == .phone ? "Starting the selected iPhone inputs…" : captureMode.hasGlassesDisplay ? "Opening glasses camera and ambient microphone permissions…" : "Opening glasses permissions, then selecting HFP microphone…"
    startTask = Task { [weak self] in
      guard let self else { return }
      await previousStart?.value
      await transportTask?.value
      guard epoch == thisEpoch, !Task.isCancelled else { return }
      if !simulate {
        if !connectionTestOnly && !displayOnly {
        do {
          let health = try await client.health()
          modelMode = health.modelMode ?? "Unknown"
          guard modelMode == "live" else { throw CopilotError(message:"Real transcription needs a live Muse proxy. Configure your server, or enable Capture test only for a no-upload hardware check.") }
        } catch {
          if epoch == thisEpoch, !Task.isCancelled { phase = .paused; openingGlassesControls = false; notice = error.localizedDescription }
          return
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
          microphone.stop(); phoneCamera.stop()
          if captureMode.needsGlasses { await glasses.stop() }
          guard epoch == thisEpoch else { return }
          phase = .paused; openingGlassesControls = false
          if needsGlassesUpdate { glasses.report(error) }
          notice = needsGlassesUpdate ? GlassesController.updateInstructions : error.localizedDescription
          return
        }
      }
      guard epoch == thisEpoch, !Task.isCancelled else { return }
      openingGlassesControls = false
      phase = .active
      captureActiveAtMs = nowMs()
      notice = simulate ? "SIMULATED SESSION — choose a scene or add a demo line below." : connectionTestOnly ? "CAPTURE TEST — selected inputs active; no uploads or transcription." : analyzesSurroundings ? "Analyzing started. Camera and microphone are active; Muse checks samples periodically. Pause or Stop any time." : captureMode == .phone ? "iPhone microphone active. Captions appear after each speech chunk; notes stay separate." : "Recording selected glasses HFP microphone. Everyone can ask you to stop."
      publishDisplay()
      loopTask?.cancel()
      loopTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for:.seconds(1))
          guard let self, !Task.isCancelled, self.phase == .active else { return }
          self.trimTranscript()
          self.expireCaption()
          self.checkCaptureHealth()
          guard self.phase == .active else { return }
          if self.analyzesSurroundings && ProcessInfo.processInfo.thermalState == .critical {
            self.pause("Phone needs to cool down. Analysis paused; resume when ready."); return
          }
          self.reducedPower = ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState == .serious
          self.requestCue(manual:false)
        }
      }
    }
  }
  func pause(_ reason: String = "Paused. Camera, microphone and uploads stopped.") {
    guard phase == .active || phase == .starting else { return }
    epoch += 1
    phase = .paused
    openingGlassesControls = false; glassesControlsReady = false
    startTask?.cancel(); asrTask?.cancel(); asrTask = nil; isTranscribing = false
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
    contextText = ""; recentCues = []; lastCueAt = 0
    glassesControlsReady = true
    glasses.pauseCapture(ready:true)
    notice = "Streaming stopped and session context cleared. Select Start on glasses, or Stop on the phone to disconnect."
  }
  func stop() {
    epoch += 1
    phase = .stopped
    openingGlassesControls = false; glassesControlsReady = false
    startTask?.cancel(); asrTask?.cancel(); asrTask = nil; isTranscribing = false
    loopTask?.cancel(); invalidateCue()
    microphone.stop(); phoneCamera.stop(); phonePreview = nil
    transcript.removeAll(); latestFrame = nil; latestAudioContext = nil; contextText = ""; latestSampleAt = 0
    nextAnalysisAt = 0; simulatedScene = ""
    consent = false; lastVoiceAt = 0; recentCues = []; lastCueAt = 0
    captionText = nil; captionAtMs = 0
    if captureMode.needsGlasses { transportTask = Task { await glasses.stop() } }
    notice = "Stopped. Session transcript, sampled image and context cleared from memory."
  }
  func dismiss() {
    invalidateCue()
    lastCueAt = nowMs() // dismissal also buys a quiet interval
    publishDisplay()
    notice = "Cue dismissed."
  }
  func markDistracting() { distracting += 1; dismiss() }
  private func invalidateCue() {
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
  private func transcribe(_ chunk: AudioChunk) {
    guard !connectionTestOnly, phase == .active, chunk.startedAtMs >= captureStartedAt - 200 else { return }
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
        guard !text.isEmpty else {
          if analyzesSurroundings { return } // Ambient noise is not a new conversation.
          transcript.removeAll(); captionText = nil; invalidateCue(); publishDisplay(); notice = "Speech was unclear; waiting for fresh speech."; return
        }
        if analyzesSurroundings { lastVoiceAt = chunk.endedAtMs }
        transcript.append(TranscriptEntry(text:String(text.prefix(500)), startMs:chunk.startedAtMs, endMs:chunk.endedAtMs, confidence:result.confidence))
        setCaption(text, capturedAtMs:chunk.endedAtMs)
        trimTranscript(); invalidateCue()
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
    invalidateCue()
    let timestamp = nowMs()
    lastVoiceAt = timestamp
    transcript.append(TranscriptEntry(text:String(value.prefix(500)), startMs:timestamp-2500, endMs:timestamp, confidence:nil))
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
    guard simulate, phase == .active, ["library", "group"].contains(scene) else { return }
    simulateSurroundings = true; simulatedScene = scene
    invalidateCue(); transcript.removeAll(); captionText = nil; captionAtMs = 0; lastVoiceAt = 0
    lastAnalysisAt = 0; latestSampleAt = 0
    let image = UIGraphicsImageRenderer(size:CGSize(width:480, height:270)).image { context in
      UIColor.darkGray.setFill(); context.fill(CGRect(x:0, y:0, width:480, height:270))
      "SIMULATED SCENE: \(scene)\nFixture, not a real camera image".draw(in:CGRect(x:25, y:80, width:430, height:120),
        withAttributes:[.font:UIFont.systemFont(ofSize:24), .foregroundColor:UIColor.white])
    }
    sample(image, at:nowMs())
    notice = "SIMULATED \(scene) scene. No real camera or microphone input."
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
    guard !connectionTestOnly else { if manual { notice = "Connection test makes no API requests. Use Manual display test." }; return }
    guard phase == .active, cueTask == nil, !isTranscribing else { return }
    let timestamp = nowMs()
    if let issue = liveInputIssue(at:timestamp) { if manual { notice = issue }; return }
    let surroundings = analyzesSurroundings
    let last = transcript.last
    let freshSpeech = last.flatMap { timestamp - $0.endMs <= 15000 && $0.endMs + 100 >= lastVoiceAt ? $0 : nil }
    let frame = latestFrame.flatMap { timestamp - $0.capturedAtMs <= SurroundingsPolicy.frameFreshnessMs && $0.capturedAtMs <= timestamp ? $0 : nil }
    // Silence does not imply missing context: a fresh library image can support a cue.
    guard timestamp - max(lastVoiceAt, captureStartedAt) >= 1500,
          surroundings ? (frame != nil || freshSpeech != nil) : freshSpeech != nil,
          lastVoiceAt == 0 || (timestamp - lastVoiceAt >= 15000 || freshSpeech != nil) else {
      if manual { notice = surroundings ? "Waiting for a fresh camera view and a quiet moment after speech." : "Wait for a quiet moment and fresh speech before requesting help." }
      return
    }
    if surroundings {
      nextAnalysisAt = max(lastAnalysisAt + analysisInterval(at:timestamp, reducedPower:reducedPower) * 1000,
                           lastCueAt + SurroundingsPolicy.cueCooldownMs)
      guard manual || timestamp >= nextAnalysisAt else { return }
    } else {
      guard manual || (timestamp - lastCueAt >= 30000 && lastRequestedGeneration != generation) else { return }
    }
    let revision = generation, thisEpoch = epoch
    let context = contextText.split(separator:"\n").prefix(5).map { String($0.prefix(160)) }
    // When speech has aged out, don't let it dominate the current visual setting.
    let entries = surroundings && freshSpeech == nil ? [] : transcript
    let audio = surroundings ? latestAudioContext.flatMap { timestamp - $0.capturedAtMs <= 10000 ? $0 : nil } : nil
    let request = CueRequest(transcript:entries, frame:frame, context:context, manual:manual,
                             analysisMode:surroundings ? "surroundings" : "conversation", audioContext:audio)
    let connection = client
    let fixtureScene = simulatedScene
    let evidenceAt = freshSpeech?.endMs ?? frame?.capturedAtMs ?? timestamp
    lastRequestedGeneration = revision; lastAnalysisAt = timestamp
    nextAnalysisAt = timestamp + analysisInterval(at:timestamp, reducedPower:reducedPower) * 1000
    isThinking = true; requests += 1; publishDisplay()
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
          let message: String
          if surroundings && (lower.contains("rough day") || lower.contains("overwhelmed")) {
            message = "They mentioned a hard day. Listen and give them space."
          } else if surroundings && fixtureScene == "library" {
            message = "This looks like a library. Keep your voice low."
          } else if surroundings && fixtureScene == "group" {
            message = "People are talking. Wait for a pause before joining in."
          } else {
            message = lower.contains("friday") ? "Ask what they meant by Friday." : lower.contains("robot") ? "Ask how their robotics project is going." : lower.contains("hot or iced") ? "They asked whether you want it hot or iced." : ""
          }
          response = CueResponse(result:CueResult(cue:message, reason:"Local scripted demo fixture", confidence:message.isEmpty ? 0 : 0.95, type:surroundings ? "reminder" : "clarify", should_display:!message.isEmpty), metrics:nil)
          modelMode = "LOCAL SCRIPTED MOCK"
        } else {
          let result: (CueResponse, Int) = try await connection.post("api/cue", request)
          response = result.0; uploadedBytes += result.1
        }
        let completedAt = nowMs()
        let speechStillFresh = freshSpeech.map { completedAt - $0.endMs <= 15000 } ?? false
        let frameStillFresh = frame.map { completedAt - $0.capturedAtMs <= SurroundingsPolicy.deliveryFreshnessMs } ?? false
        let evidenceStillFresh = surroundings ? (speechStillFresh || frameStillFresh) : speechStillFresh
        guard epoch == thisEpoch, generation == revision, phase == .active, !Task.isCancelled,
              completedAt - timestamp <= (surroundings ? SurroundingsPolicy.deliveryFreshnessMs : 10000),
              evidenceStillFresh, completedAt - lastVoiceAt >= 1500 else { staleDrops += 1; return }
        apiMs = response.metrics?.apiMs ?? 0; recordCost(response.metrics?.estimatedCostUsd ?? (simulate && localMock ? 0 : nil))
        let result = response.result
        lastSceneSummary = String(result.reason.prefix(400))
        lastAnalysisOutcome = "No new social cue needed."
        lastAnalysisAtMs = completedAt
        let text = result.cue.trimmingCharacters(in:.whitespacesAndNewlines)
        let normalized = text.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        guard result.should_display, result.confidence.isFinite, result.confidence >= 0.8, result.confidence <= 1,
              ["clarify", "follow_up", "reminder", "respond"].contains(result.type),
              !text.isEmpty, text.count <= 90, text.split(whereSeparator: { $0.isWhitespace }).count <= 14,
              !recentCues.contains(normalized) else { notice = "No new cue needed. Still watching for context."; return }
        cue = text; shown += 1; lastCueAt = nowMs(); contextToDisplayMs = lastCueAt - evidenceAt
        lastAnalysisOutcome = "Social cue ready."
        recentCues = Array((recentCues + [normalized]).suffix(20))
        publishDisplay()
        notice = simulate ? "SIMULATED social cue." : captureMode.hasGlassesDisplay ? "Social cue sent to glasses." : "Suggestion ready on the phone."
        ttlTask = Task { [weak self] in
          try? await Task.sleep(for:.seconds(8))
          guard let self, !Task.isCancelled, self.generation == revision else { return }
          // Expiry clears the cue without extending the automatic cooldown.
          self.cue = nil; self.publishDisplay()
        }
      } catch {
        if epoch == thisEpoch, generation == revision, !Task.isCancelled { notice = "Cue request failed: \(error.localizedDescription). Tap Analyze now to retry." }
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
    notice = "Manual display test. This is not a model suggestion."
    let revision = generation
    ttlTask = Task { [weak self] in
      try? await Task.sleep(for:.seconds(8))
      guard let self, !Task.isCancelled, self.generation == revision else { return }
      self.dismiss()
    }
  }
}
