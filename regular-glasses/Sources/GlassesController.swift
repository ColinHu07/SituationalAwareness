import Foundation
import os
import Observation
import UIKit
import MWDATCore
import MWDATCamera
import MWDATDisplay

// At most one decoded frame can wait on the UI actor; all other arrivals are dropped.
private final class FrameDeliveryGate: Sendable {
  private let pending = OSAllocatedUnfairLock(initialState:false)
  func begin() -> Bool { pending.withLock { value in if value { return false }; value = true; return true } }
  func finish() { pending.withLock { $0 = false } }
}

@Observable @MainActor
final class GlassesController {
  var registration = "Not registered"
  var devices = "No Meta glasses connected"
  var cameraState = "Stopped"
  var displayState = "Stopped"
  var preview: UIImage?
  var previewAtMs: Double = 0
  var framesReceived = 0
  var lastError: String?
  var onFrame: ((UIImage, Double) -> Void)?
  var onFailure: ((String) -> Void)?
  var onHelp: (() -> Void)?
  var onPause: (() -> Void)?
  var onStop: (() -> Void)?
  var onDismiss: (() -> Void)?
  var onResume: (() -> Void)?
  @ObservationIgnored private var wearables: WearablesInterface?
  @ObservationIgnored private var selector: AutoDeviceSelector?
  @ObservationIgnored private var session: DeviceSession?
  @ObservationIgnored private var camera: MWDATCamera.Camera?
  @ObservationIgnored var display: Display?
  @ObservationIgnored private var tokens: [AnyListenerToken] = []
  @ObservationIgnored private var observers: [Task<Void, Never>] = []
  @ObservationIgnored private let decoder = VideoFrameDecoder()
  @ObservationIgnored private let frameGate = FrameDeliveryGate()
  @ObservationIgnored private var stopping = false
  @ObservationIgnored var operation: Task<Void, Never>?
  @ObservationIgnored var displayRevision = 0
  @ObservationIgnored private var sessionRevision = 0
  @ObservationIgnored var displayReady = false
  @ObservationIgnored private var lastPreviewAt: Double = 0
  @ObservationIgnored private var sessionHasStarted = false
  @ObservationIgnored private var cameraHasStreamed = false
  @ObservationIgnored private var displayHasStarted = false

  init() {
    #if targetEnvironment(simulator)
    lastError = "DAT hardware is unavailable in Simulator. Use simulated input."
    return
    #else
    do { try Wearables.configure() } catch { lastError = "DAT configuration: \(error.localizedDescription)"; return }
    let wearables = Wearables.shared
    self.wearables = wearables
    observers.append(Task { [weak self] in
      guard let self else { return }
      for await state in wearables.registrationStateStream() { registration = String(describing:state) }
    })
    observers.append(Task { [weak self] in
      guard let self else { return }
      for await ids in wearables.devicesStream() {
        devices = ids.compactMap { wearables.deviceForIdentifier($0)?.nameOrId() }.joined(separator:", ")
        if devices.isEmpty { devices = "No Meta glasses connected" }
      }
    })
    #endif
  }
  func register() async {
    guard let wearables else { fail(lastError ?? "DAT not configured."); return }
    do { try await wearables.startRegistration() } catch { fail(error.localizedDescription) }
  }
  func handle(_ url: URL) async {
    guard let wearables else { return }
    guard URLComponents(url:url, resolvingAgainstBaseURL:false)?.queryItems?.contains(where:{ $0.name == "metaWearablesAction" }) == true else { return }
    do { _ = try await wearables.handleUrl(url) } catch { fail(error.localizedDescription) }
  }

  func start(microphone: ConversationMicrophone, audioUID: String, withDisplay: Bool = true) async throws {
    guard let wearables else { throw CopilotError(message:lastError ?? "DAT configuration missing.") }
    let selector = AutoDeviceSelector(wearables:wearables, filter:{ withDisplay ? $0.supportsDisplay() : !$0.supportsDisplay() })
    self.selector = selector
    stopping = false
    sessionRevision += 1
    let revision = sessionRevision
    sessionHasStarted = false; cameraHasStreamed = false; displayHasStarted = false
    let permission = try await wearables.requestPermission(.camera)
    guard permission == .granted else { throw CopilotError(message:"Glasses camera permission denied in Meta AI.") }
    try Task.checkCancellation()
    let deviceSession = try wearables.createSession(deviceSelector:selector)
    session = deviceSession
    tokens.append(deviceSession.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        guard let self, self.sessionRevision == revision else { return }
        if state == .started { self.sessionHasStarted = true }
        if (state == .paused || state == .stopped) && self.sessionHasStarted && !self.stopping { self.fail("Glasses session \(state). Resume deliberately after reconnecting.") }
      }
    })
    tokens.append(deviceSession.errorPublisher.listen { [weak self] error in
      Task { @MainActor in guard self?.sessionRevision == revision else { return }; self?.fail(error.localizedDescription) }
    })
    try deviceSession.start()
    let deadline = Date().addingTimeInterval(15)
    while deviceSession.state != .started {
      try await Task.sleep(for:.milliseconds(100))
      guard Date() < deadline, sessionRevision == revision else { throw CopilotError(message:"Glasses session did not start. Check pairing, DAT glasses app and firmware.") }
    }
    // Strict order from official HFP guide: add camera, settle HFP, then start video.
    guard let camera = try deviceSession.addCamera(config:StreamConfiguration(videoCodec:.hvc1, resolution:.low, frameRate:15)) else { throw CopilotError(message:"Could not attach camera.") }
    self.camera = camera
    tokens.append(camera.stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        guard let self, self.sessionRevision == revision else { return }
        self.cameraState = String(describing:state)
        if state == .streaming { self.cameraHasStreamed = true }
        if (state == .paused || state == .stopped) && self.cameraHasStreamed && !self.stopping { self.fail("Camera \(state); cues paused. Resume creates a fresh supported stream.") }
      }
    })
    tokens.append(camera.stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in guard self?.sessionRevision == revision else { return }; self?.fail(error.localizedDescription) }
    })
    let decoder = self.decoder
    let frameGate = self.frameGate
    tokens.append(camera.stream.videoFramePublisher.listen { [weak self] frame in
      let captured = nowMs()
      // Decode every HEVC dependency but publish at most 2 Hz to the UI/sampler.
      guard let image = decoder.decode(frame.sampleBuffer), frameGate.begin() else { return }
      Task { @MainActor in
        defer { frameGate.finish() }
        guard let self, self.sessionRevision == revision, !self.stopping else { return }
        self.framesReceived += 1
        guard captured - self.lastPreviewAt >= 500 else { return }
        self.lastPreviewAt = captured
        self.preview = image; self.previewAtMs = captured
        self.onFrame?(image, captured)
      }
    })
    if withDisplay {
    let cap = try deviceSession.addDisplay()
    display = cap
    tokens.append(cap.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        guard let self, self.sessionRevision == revision else { return }
        self.displayState = String(describing:state)
        self.displayReady = state == .started
        if state == .started { self.displayHasStarted = true }
        if state == .stopped && self.displayHasStarted && !self.stopping { self.fail("Display control ended; recording and cues paused.") }
      }
    })
    cap.start()
    } else { displayState = "Phone output (no glasses display)" }
    try await microphone.start(uid:audioUID)
    try Task.checkCancellation()
    guard sessionRevision == revision else { throw CancellationError() }
    camera.stream.start()
    let streamDeadline = Date().addingTimeInterval(12)
    while (withDisplay && !displayReady) || camera.stream.state != .streaming {
      try await Task.sleep(for:.milliseconds(100))
      guard Date() < streamDeadline, sessionRevision == revision else { throw CopilotError(message:"Camera or display not ready. No conversation data has been sent.") }
    }
  }

  func pauseCapture() {
    stopping = true
    camera?.stop(); camera = nil
    preview = nil; previewAtMs = 0
    show(nil, paused:true)
  }

  func stop() async {
    stopping = true
    sessionRevision += 1
    camera?.stop(); camera = nil
    preview = nil; previewAtMs = 0
    clear()
    await operation?.value
    camera?.stop(); display?.stop(); session?.stop()
    camera = nil; display = nil; session = nil
    for token in tokens { await token.cancel() }
    tokens.removeAll()
    displayReady = false; cameraState = "Stopped"; displayState = "Stopped"
    preview = nil; previewAtMs = 0
  }
  func fail(_ message: String) { lastError = message; if !stopping { onFailure?(message) } }
}
