import Foundation
import Observation
import UIKit

@Observable @MainActor
final class SessionModel {
  enum Phase: String { case stopped = "Stopped", starting = "Starting", active = "Listening", paused = "Paused" }
  var phase: Phase = .stopped
  var consent = false
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
  var transcript: [TranscriptEntry] = []
  var captionText: String?
  var captionAtMs: Double = 0
  var phonePreview: UIImage?
  var phoneFramesReceived = 0
  var cue: String?
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

  init() {
    phoneCamera.onFrame = { [weak self] image, time in
      guard let self, self.phase == .active, self.captureMode == .phone else { return }
      self.phonePreview = image; self.phoneFramesReceived += 1; self.sample(image, at:time)
    }
    phoneCamera.onFailure = { [weak self] message in self?.pause(message) }
    microphone.onVoice = { [weak self] timestamp in Task { @MainActor in
      guard let self, self.phase == .active, timestamp >= self.captureStartedAt else { return }
      self.lastVoiceAt = timestamp
      self.invalidateCue()
    } }
    microphone.onChunk = { [weak self] chunk in Task { @MainActor in self?.transcribe(chunk) } }
    microphone.onFailure = { [weak self] message in Task { @MainActor in self?.pause(message) } }
  }
  private func configureGlassesCallbacks() {
    glasses.onFrame = { [weak self] image, time in self?.sample(image, at:time) }
    glasses.onFailure = { [weak self] message in self?.pause(message) }
    glasses.onHelp = { [weak self] in self?.requestCue(manual:true) }
    glasses.onPause = { [weak self] in self?.pause() }
    glasses.onStop = { [weak self] in self?.stop() }
    glasses.onDismiss = { [weak self] in self?.dismiss() }
    glasses.onResume = { [weak self] in self?.start() }
  }
  private var client: APIClient { APIClient(endpoint:endpoint, token:proxyToken) }
  var canStart: Bool { consent && (!captureMode.needsGlasses || !selectedAudioUID.isEmpty) && (phase == .stopped || phase == .paused) }
  var savedNote: String? { contextText.split(separator:"\n").first.map(String.init) }
  private func publishDisplay() {
    guard captureMode.hasGlassesDisplay, phase == .active else { return }
    glasses.show(cue, caption:captionText, note:savedNote)
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
  func start() {
    guard canStart else { return }
    epoch += 1
    let thisEpoch = epoch
    phase = .starting
    captureStartedAt = nowMs()
    invalidateCue()
    notice = simulate ? "SIMULATED INPUT. No camera or microphone recording." : captureMode == .phone ? "Starting the selected iPhone inputs…" : "Opening glasses permissions, then selecting HFP microphone…"
    startTask = Task { [weak self] in
      guard let self else { return }
      await transportTask?.value
      if !simulate {
        if !connectionTestOnly {
        do {
          let health = try await client.health()
          modelMode = health.modelMode ?? "Unknown"
          guard modelMode == "live" else { throw CopilotError(message:"Real transcription needs a live Muse proxy. Configure your server, or enable Capture test only for a no-upload hardware check.") }
        } catch {
          if epoch == thisEpoch, !Task.isCancelled { phase = .paused; notice = error.localizedDescription }
          return
        }
        }
        guard epoch == thisEpoch, !Task.isCancelled else { return }
        if captureMode.needsGlasses { await glasses.stop(); configureGlassesCallbacks() }
        guard epoch == thisEpoch, !Task.isCancelled else { return }
        do {
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
          microphone.stop(); phoneCamera.stop()
          if captureMode.needsGlasses { await glasses.stop() }
          guard epoch == thisEpoch else { return }
          phase = .paused; notice = error.localizedDescription; return
        }
      }
      guard epoch == thisEpoch, !Task.isCancelled else { return }
      phase = .active
      notice = simulate ? "SIMULATED SESSION — add a demo line below." : connectionTestOnly ? "CAPTURE TEST — selected inputs active; no uploads or transcription." : captureMode == .phone ? "iPhone microphone active. Captions appear after each speech chunk; notes stay separate." : "Recording selected glasses HFP microphone. Everyone can ask you to stop."
      publishDisplay()
      loopTask?.cancel()
      loopTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for:.seconds(1))
          guard let self, !Task.isCancelled, self.phase == .active else { return }
          self.trimTranscript()
          self.expireCaption()
          self.requestCue(manual:false)
        }
      }
    }
  }
  func pause(_ reason: String = "Paused. Camera, microphone and uploads stopped.") {
    guard phase == .active || phase == .starting else { return }
    epoch += 1
    phase = .paused
    startTask?.cancel(); asrTask?.cancel(); asrTask = nil; isTranscribing = false
    loopTask?.cancel(); invalidateCue()
    microphone.stop(); phoneCamera.stop(); phonePreview = nil
    latestFrame = nil; latestSampleAt = 0; transcript.removeAll(); lastVoiceAt = 0; captionText = nil; captionAtMs = 0
    if captureMode.needsGlasses { glasses.pauseCapture() }
    notice = reason
  }
  func stop() {
    epoch += 1
    phase = .stopped
    startTask?.cancel(); asrTask?.cancel(); asrTask = nil; isTranscribing = false
    loopTask?.cancel(); invalidateCue()
    microphone.stop(); phoneCamera.stop(); phonePreview = nil
    transcript.removeAll(); latestFrame = nil; contextText = ""; latestSampleAt = 0
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
    if cue != nil { cue = nil; publishDisplay() }
  }
  private func sample(_ image: UIImage, at time: Double) {
    guard phase == .active, time - latestSampleAt >= sampleInterval * 1000 else { return }
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
          transcript.removeAll(); captionText = nil; invalidateCue(); publishDisplay(); notice = "Speech was unclear; waiting for fresh speech."; return
        }
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
    guard phase == .active, cueTask == nil, !isTranscribing, let last = transcript.last else { return }
    let timestamp = nowMs()
    guard timestamp - lastVoiceAt >= 1500, timestamp - last.endMs <= 15000, last.endMs + 100 >= lastVoiceAt else {
      if manual { notice = "Wait for a quiet moment and fresh speech before requesting help." }; return
    }
    guard manual || (timestamp-lastCueAt >= 30000 && lastRequestedGeneration != generation) else { return }
    let revision = generation, thisEpoch = epoch
    let frame = latestFrame.flatMap { timestamp-$0.capturedAtMs <= 10000 ? $0 : nil }
    let context = contextText.split(separator:"\n").prefix(5).map { String($0.prefix(160)) }
    let request = CueRequest(transcript:transcript, frame:frame, context:context, manual:manual)
    let connection = client
    lastRequestedGeneration = revision; isThinking = true; requests += 1
    cueTask = Task { [weak self] in
      guard let self else { return }
      do {
        let response: CueResponse
        if simulate && localMock {
          try await Task.sleep(for:.milliseconds(400))
          let lower = last.text.lowercased()
          let message = lower.contains("friday") ? "Ask what they meant by Friday." : lower.contains("robot") ? "Ask how their robotics project is going." : lower.contains("hot or iced") ? "They asked whether you want it hot or iced." : ""
          response = CueResponse(result:CueResult(cue:message,reason:"Local scripted demo fixture",confidence:message.isEmpty ? 0 : 0.95,type:"clarify",should_display:!message.isEmpty),metrics:nil)
          modelMode = "LOCAL SCRIPTED MOCK"
        } else {
          let result: (CueResponse, Int) = try await connection.post("api/cue", request)
          response = result.0; uploadedBytes += result.1
        }
        guard epoch == thisEpoch, generation == revision, phase == .active, !Task.isCancelled,
              nowMs()-timestamp <= 10000, nowMs()-last.endMs <= 15000, nowMs()-lastVoiceAt >= 1500 else { staleDrops += 1; return }
        apiMs = response.metrics?.apiMs ?? 0; recordCost(response.metrics?.estimatedCostUsd ?? (simulate && localMock ? 0 : nil))
        let result = response.result
        let text = result.cue.trimmingCharacters(in:.whitespacesAndNewlines)
        let normalized = text.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        guard result.should_display, result.confidence.isFinite, result.confidence >= 0.8, result.confidence <= 1,
              ["clarify", "follow_up", "reminder", "respond"].contains(result.type),
              !text.isEmpty, text.count <= 90, text.split(whereSeparator: { $0.isWhitespace }).count <= 14,
              !recentCues.contains(normalized) else { notice = "No cue warranted."; return }
        cue = text; shown += 1; lastCueAt = nowMs(); contextToDisplayMs = lastCueAt-last.endMs
        recentCues = Array((recentCues + [normalized]).suffix(20))
        publishDisplay()
        notice = simulate ? "SIMULATED suggestion." : captureMode.hasGlassesDisplay ? "Cue sent to glasses." : "Suggestion ready on the phone."
        ttlTask = Task { [weak self] in
          try? await Task.sleep(for:.seconds(8))
          guard let self, !Task.isCancelled, self.generation == revision else { return }
          self.dismiss()
        }
      } catch {
        if epoch == thisEpoch, generation == revision, !Task.isCancelled { notice = "Cue request failed: \(error.localizedDescription)" }
      }
      if epoch == thisEpoch, generation == revision { cueTask = nil; isThinking = false }
    }
    // The task also uses defer-like cleanup through a completion watcher for abstentions.
    let pending = cueTask
    Task { [weak self] in
      await pending?.value
      guard let self, self.epoch == thisEpoch, self.generation == revision else { return }
      self.cueTask = nil; self.isThinking = false
    }
  }
  private func recordCost(_ value: Double?) {
    if let value { knownCostTotal += value } else { missingCost = true }
    estimatedCost = missingCost ? nil : knownCostTotal
  }
  func contextChanged() { invalidateCue(); publishDisplay() }
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
