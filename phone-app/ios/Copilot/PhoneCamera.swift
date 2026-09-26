@preconcurrency import AVFoundation
import CoreImage
import UIKit
import os

/// Camera only. AVAudioEngine owns the explicitly chosen microphone/audio session.
final class PhoneCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  private struct State { var generation = 0; var active = false; var deliveryPending = false }
  private let state = OSAllocatedUnfairLock(initialState:State())
  private let queue = DispatchQueue(label:"aside.phone-camera", qos:.userInitiated)
  private let session = AVCaptureSession()
  private let ciContext = CIContext()
  private var observers: [NSObjectProtocol] = []
  private var lastFrameAt: Double = 0
  var onFrame: (@MainActor @Sendable (UIImage, Double) -> Void)?
  var onFailure: (@MainActor @Sendable (String) -> Void)?

  @MainActor func start() async throws {
    let generation = state.withLock { s in s.generation += 1; return s.generation }
    guard await AVCaptureDevice.requestAccess(for:.video) else {
      throw CopilotError(message:"iPhone camera permission denied. Enable it in Settings, or choose audio-only before starting.")
    }
    try Task.checkCancellation()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        do {
          guard state.withLock({ $0.generation == generation }) else { throw CancellationError() }
          session.beginConfiguration()
          session.sessionPreset = .vga640x480
          session.automaticallyConfiguresApplicationAudioSession = false
          for input in session.inputs { session.removeInput(input) }
          for output in session.outputs { session.removeOutput(output) }
          do {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for:.video, position:.back) else {
              throw CopilotError(message:"No rear phone camera available. Simulator needs Simulated demo mode, or use audio-only on an iPhone.")
            }
            let input = try AVCaptureDeviceInput(device:device)
            guard session.canAddInput(input) else { throw CopilotError(message:"Cannot attach the phone camera.") }
            session.addInput(input)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue:queue)
            guard session.canAddOutput(output) else { throw CopilotError(message:"Cannot receive phone camera frames.") }
            session.addOutput(output)
            if let connection = output.connection(with:.video), connection.isVideoRotationAngleSupported(90) {
              connection.videoRotationAngle = 90
            }
          } catch { session.commitConfiguration(); throw error }
          session.commitConfiguration()
          guard state.withLock({ $0.generation == generation }) else { throw CancellationError() }
          observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
          for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(NotificationCenter.default.addObserver(forName:name, object:session, queue:nil) { [weak self] _ in
              guard let self, self.state.withLock({ $0.active && $0.generation == generation }) else { return }
              Task { @MainActor [weak self] in
                guard let self, self.state.withLock({ $0.active && $0.generation == generation }) else { return }
                self.onFailure?("Phone camera interrupted. Session paused; resume deliberately.")
              }
            })
          }
          state.withLock { $0.active = true }
          session.startRunning()
          guard session.isRunning else { throw CopilotError(message:"Phone camera could not start.") }
          continuation.resume()
        } catch { state.withLock { $0.active = false }; continuation.resume(throwing:error) }
      }
    }
    try Task.checkCancellation()
  }

  func stop() {
    state.withLock { $0.generation += 1; $0.active = false }
    queue.async { [self] in
      session.stopRunning()
      observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
      lastFrameAt = 0
    }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    let captured = nowMs()
    guard captured - lastFrameAt >= 33, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let generation: Int? = state.withLock { s in
      guard s.active, !s.deliveryPending else { return nil }; s.deliveryPending = true; return s.generation
    }
    guard let generation else { return }
    lastFrameAt = captured
    let ciImage = CIImage(cvPixelBuffer:pixelBuffer)
    guard let image = ciContext.createCGImage(ciImage, from:ciImage.extent) else {
      state.withLock { $0.deliveryPending = false }; return
    }
    let frame = UIImage(cgImage:image)
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.state.withLock { $0.deliveryPending = false } }
      guard self.state.withLock({ $0.active && $0.generation == generation }) else { return }
      self.onFrame?(frame,captured)
    }
  }
}
