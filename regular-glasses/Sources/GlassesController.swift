import Foundation
import os
import Observation
import UIKit
import CoreMedia
import MWDATCore
import MWDATCamera
import MWDATDisplay

// At most one decoded frame can wait on the UI actor; all other arrivals are dropped.
private final class FrameDeliveryGate: Sendable {
  private let pending = OSAllocatedUnfairLock(initialState:false)
  func begin() -> Bool { pending.withLock { value in if value { return false }; value = true; return true } }
  func finish() { pending.withLock { $0 = false } }
}

// Camera audio and video share a presentation clock. Anchor it once per session;
// the local epoch includes link latency, so this is not a sensor-clock calibration.
final class GlassesStreamClock: Sendable {
  private struct State {
    var active = true
    var anchorPTS: Double?
    var anchorEpoch: Double = 0
    var lastVideo: Double = -.infinity
    var lastAudio: Double = -.infinity
    var hasAudio = false
  }
  private let state = OSAllocatedUnfairLock(initialState:State())
  var hasAudio: Bool { state.withLock { $0.hasAudio } }
  var hasVideo: Bool { state.withLock { $0.lastVideo.isFinite } }
  func stop() { state.withLock { $0.active = false } }
  func timestamp(for presentationTime: CMTime, audio: Bool, arrival: Double = nowMs()) -> Double? {
    let milliseconds = CMTimeGetSeconds(presentationTime) * 1000
    guard milliseconds.isFinite, arrival.isFinite else { return nil }
    return state.withLock { value in
      guard value.active else { return nil }
      if value.anchorPTS == nil { value.anchorPTS = milliseconds; value.anchorEpoch = arrival }
      guard let anchor = value.anchorPTS else { return nil }
      let mapped = value.anchorEpoch + milliseconds - anchor
      // Reject a reset clock, delayed backlog, or out-of-order frames instead of
      // relabeling their arrival as newly captured data.
      guard mapped <= arrival + 1000, arrival - mapped <= 15000,
            mapped > (audio ? value.lastAudio : value.lastVideo) else { return nil }
      if audio { value.lastAudio = mapped; value.hasAudio = true }
      else { value.lastVideo = mapped }
      return mapped
    }
  }
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
  var updateRequired = false
  static let updateInstructions = "Open Meta’s glasses app updater below. In Developer Mode, also check Meta AI → Settings → App Info and install or update the package beside your glasses. Return here after installation and retry."
  func openGlassesAppUpdate() async {
    guard let wearables else { fail(lastError ?? "DAT not configured."); return }
    do { try await wearables.openDATGlassesAppUpdate() }
    catch { lastError = "Could not open Meta’s updater: \(error.localizedDescription). Check Meta AI → Settings → App Info." }
  }
  static func requiresGlassesAppUpdate(_ error: Error) -> Bool {
    (error as? DeviceSessionError) == .datAppOnTheGlassesUpdateRequired
  }
  func report(_ error: Error) {
    updateRequired = Self.requiresGlassesAppUpdate(error)
    fail(updateRequired ? Self.updateInstructions : error.localizedDescription)
  }
  var onFrame: ((UIImage, Double) -> Void)?
  var onFailure: ((String) -> Void)?
  var onHelp: (() -> Void)?
  var onPause: (() -> Void)?
  var onStop: (() -> Void)?
  var onDismiss: (() -> Void)?
  var onResume: (() -> Void)?
  var onDisconnect: (() -> Void)?
  @ObservationIgnored private var wearables: WearablesInterface?
  @ObservationIgnored private var selector: AutoDeviceSelector?
  @ObservationIgnored private var session: DeviceSession?
  @ObservationIgnored private var camera: MWDATCamera.Camera?
  @ObservationIgnored var display: Display?
  @ObservationIgnored private var tokens: [AnyListenerToken] = []
  @ObservationIgnored private var audioToken: AnyListenerToken?
  @ObservationIgnored private var streamClock: GlassesStreamClock?
  @ObservationIgnored private var captureStopTask: Task<Bool, Never>?
  @ObservationIgnored private var cameraTokens: [AnyListenerToken] = []
  @ObservationIgnored private var cameraRevision = 0
  @ObservationIgnored private var sessionUsesDisplay = false
  @ObservationIgnored private var observers: [Task<Void, Never>] = []
  @ObservationIgnored private let frameGate = FrameDeliveryGate()
  @ObservationIgnored private var stopping = false
  @ObservationIgnored var operation: Task<Void, Never>?
  @ObservationIgnored var displayRevision = 0
  @ObservationIgnored var requestedScreen: GlassesScreen?
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

  // Display stays connected while camera capture is stopped or restarted.
  func connectDisplayOnly() async throws {
    _ = try await connect(withDisplay:true)
  }

  private func connect(withDisplay: Bool) async throws -> DeviceSession {
    if let session, session.state == .started, sessionUsesDisplay == withDisplay,
       !withDisplay || displayReady { return session }
    await stop()
    try Task.checkCancellation()
    guard session == nil else { throw CopilotError(message:"Previous glasses connection is still closing. Retry shortly.") }
    guard let wearables else { throw CopilotError(message:lastError ?? "DAT configuration missing.") }
    let selector = AutoDeviceSelector(wearables:wearables, filter:{ withDisplay ? $0.supportsDisplay() : !$0.supportsDisplay() })
    self.selector = selector
    stopping = false
    sessionRevision += 1
    let revision = sessionRevision
    sessionUsesDisplay = withDisplay
    lastError = nil; updateRequired = false
    sessionHasStarted = false; displayHasStarted = false
    // AutoDeviceSelector resolves asynchronously. Poll its public snapshot so a
    // quiet discovery stream cannot leave Start or its cancellation hanging.
    let selectionDeadline = ContinuousClock.now.advanced(by:.seconds(15))
    while true {
      try Task.checkCancellation()
      guard sessionRevision == revision, !stopping else { throw CancellationError() }
      if let identifier = selector.activeDevice,
         let device = wearables.deviceForIdentifier(identifier) {
        let compatibility = device.compatibility()
        if compatibility == .deviceUpdateRequired {
          throw CopilotError(message:"Glasses firmware needs an update in Meta AI before this session can start.")
        }
        if compatibility == .sdkUpdateRequired {
          throw CopilotError(message:"These glasses need a newer DAT SDK. Update the companion app before starting.")
        }
        if device.linkState == .connected, compatibility == .compatible { break }
      }
      guard ContinuousClock.now < selectionDeadline else {
        throw CopilotError(message:withDisplay
          ? "No connected, compatible Display glasses became available. Check Meta AI pairing, registration and firmware, then try again."
          : "No connected, compatible Meta glasses became available. Check Meta AI pairing, registration and firmware, then try again.")
      }
      try await Task.sleep(for:.milliseconds(100))
    }
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
      Task { @MainActor in guard self?.sessionRevision == revision else { return }; self?.report(error) }
    })
    try deviceSession.start()
    let deadline = Date().addingTimeInterval(15)
    while deviceSession.state != .started {
      try await Task.sleep(for:.milliseconds(100))
      guard Date() < deadline, sessionRevision == revision else { throw CopilotError(message:"Glasses session did not start. Check pairing, DAT glasses app and firmware.") }
    }
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
    let displayDeadline = ContinuousClock.now.advanced(by:.seconds(12))
    while withDisplay && !displayReady {
      try await Task.sleep(for:.milliseconds(100))
      guard sessionRevision == revision, ContinuousClock.now < displayDeadline else {
        throw CopilotError(message:"Glasses display did not become ready. Check the connection and retry.")
      }
    }
    return deviceSession
  }

  func start(microphone: ConversationMicrophone, audioUID: String, withDisplay: Bool = true) async throws {
    guard let wearables else { throw CopilotError(message:"DAT configuration missing.") }
    let permissions: [Permission] = withDisplay ? [.camera, .microphone] : [.camera]
    for permission in permissions {
      if try await wearables.checkPermissionStatus(permission) != .granted {
        guard try await wearables.requestPermission(permission) == .granted else {
          throw CopilotError(message:"Glasses \(permission) permission denied in Meta AI.")
        }
      }
      try Task.checkCancellation()
    }
    let deviceSession = try await connect(withDisplay:withDisplay)
    let revision = sessionRevision
    let stopped = await captureStopTask?.value ?? true
    try Task.checkCancellation()
    guard stopped else { throw CopilotError(message:"Previous camera is still stopping. Close the glasses controls and reconnect.") }
    captureStopTask = nil
    guard sessionRevision == revision else { throw CancellationError() }
    stopping = false
    cameraRevision += 1
    let captureRevision = cameraRevision
    lastPreviewAt = 0; framesReceived = 0; lastError = nil; updateRequired = false
    preview = nil; previewAtMs = 0; cameraHasStreamed = false
    // Display uses DAT 1.0 ambient PCM alongside low-rate video. Regular glasses
    // retain their existing HFP path: add camera, settle HFP, then start video.
    let configuration = withDisplay
      ? StreamConfiguration(videoCodec:.hvc1, audioCodec:.pcm(sampleRate:.rate16000, numberOfChannels:1), resolution:.low, frameRate:2)
      : StreamConfiguration(videoCodec:.hvc1, resolution:.low, frameRate:15)
    guard let camera = try deviceSession.addCamera(config:configuration) else { throw CopilotError(message:"Could not attach camera.") }
    self.camera = camera
    let clock = GlassesStreamClock()
    streamClock = clock
    cameraTokens.append(camera.stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in
        guard let self, self.sessionRevision == revision, self.cameraRevision == captureRevision else { return }
        self.cameraState = String(describing:state)
        if state == .streaming { self.cameraHasStreamed = true }
        if (state == .paused || state == .stopped) && self.cameraHasStreamed && !self.stopping { self.fail("Camera \(state); cues paused. Resume creates a fresh supported stream.") }
      }
    })
    cameraTokens.append(camera.stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in guard self?.sessionRevision == revision, self?.cameraRevision == captureRevision else { return }; self?.fail("Camera error: \(String(describing:error)). \(error.localizedDescription)") }
    })
    let decoder = VideoFrameDecoder()
    let frameGate = self.frameGate
    cameraTokens.append(camera.stream.videoFramePublisher.listen { [weak self] frame in
      // Decode every HEVC dependency but publish at most 2 Hz to the UI/sampler.
      guard let image = decoder.decode(frame.sampleBuffer),
            let captured = clock.timestamp(for:CMSampleBufferGetPresentationTimeStamp(frame.sampleBuffer), audio:false),
            frameGate.begin() else { return }
      Task { @MainActor in
        defer { frameGate.finish() }
        guard let self, self.sessionRevision == revision, self.cameraRevision == captureRevision, !self.stopping else { return }
        self.framesReceived += 1
        guard captured - self.lastPreviewAt >= 500 else { return }
        self.lastPreviewAt = captured
        self.preview = image; self.previewAtMs = captured
        self.onFrame?(image, captured)
      }
    })
    if withDisplay {
      audioToken = camera.stream.audioFramePublisher.listen { frame in
        let buffer = frame.pcmBuffer
        guard buffer.format.sampleRate > 0, buffer.frameLength > 0 else { return }
        // The shared microphone pipeline expects a buffer-end timestamp.
        let duration = CMTime(seconds:Double(buffer.frameLength) / buffer.format.sampleRate, preferredTimescale:1_000_000)
        guard let captured = clock.timestamp(for:CMTimeAdd(frame.presentationTimeStamp, duration), audio:true) else { return }
        microphone.receiveStreamPCM(buffer, at:captured)
      }
    }
    if withDisplay { try await microphone.startStreamPCM() }
    else { try await microphone.start(uid:audioUID) }
    try Task.checkCancellation()
    guard sessionRevision == revision, cameraRevision == captureRevision else { throw CancellationError() }
    camera.stream.start()
    let streamDeadline = Date().addingTimeInterval(12)
    while !clock.hasVideo || (withDisplay && (!displayReady || !clock.hasAudio)) || camera.stream.state != .streaming {
      try await Task.sleep(for:.milliseconds(100))
      guard Date() < streamDeadline, sessionRevision == revision, cameraRevision == captureRevision else {
        var missing: [String] = []
        if !clock.hasVideo { missing.append("decoded camera frames") }
        if withDisplay && !clock.hasAudio { missing.append("ambient audio") }
        if withDisplay && !displayReady { missing.append("display connection") }
        if camera.stream.state != .streaming { missing.append("camera streaming (\(camera.stream.state))") }
        throw CopilotError(message:"Capture timed out waiting for \(missing.joined(separator:", ")). Check Meta AI permissions and the glasses connection, then Resume. No conversation data has been sent.")
      }
    }
  }

  // Cleanup runs to completion even if the user cancels a pending start.
  static func waitForStop(timeout: Duration = .seconds(10), stopped: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by:timeout)
    while !stopped() {
      guard ContinuousClock.now < deadline else { return false }
      do { try await Task.sleep(for:.milliseconds(50)) } catch { return false }
    }
    return true
  }

  func pauseCapture(ready: Bool = false, renderControls: Bool = true) {
    stopping = true
    cameraRevision += 1
    streamClock?.stop()
    let previousStop = captureStopTask
    let camera = self.camera, audioToken = self.audioToken, oldTokens = cameraTokens
    self.camera = nil; self.audioToken = nil; cameraTokens = []
    captureStopTask = Task {
      let previousStopped = await previousStop?.value ?? true
      await audioToken?.cancel()
      camera?.stop()
      for token in oldTokens { await token.cancel() }
      let cameraStopped = await Self.waitForStop { camera == nil || camera?.state == .stopped }
      return previousStopped && cameraStopped
    }
    preview = nil; previewAtMs = 0; cameraState = "Stopped"
    if renderControls { show(nil, paused:true, ready:ready) }
  }

  func stop() async {
    stopping = true
    sessionRevision += 1
    pauseCapture(renderControls:false)
    clear()
    _ = await captureStopTask?.value
    captureStopTask = nil
    await operation?.value
    display?.stop()
    let oldSession = session
    oldSession?.stop()
    let stopped = await Self.waitForStop { oldSession == nil || oldSession?.state == .stopped }
    camera = nil; display = nil
    if stopped { session = nil }
    for token in tokens { await token.cancel() }
    tokens.removeAll()
    streamClock = nil
    displayReady = false; cameraState = "Stopped"; displayState = "Stopped"
    preview = nil; previewAtMs = 0
  }
  func fail(_ message: String) { lastError = message; if !stopping { onFailure?(message) } }
}
