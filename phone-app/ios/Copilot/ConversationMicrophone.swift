@preconcurrency import AVFoundation
import Foundation
import os

struct AudioPort: Identifiable { let id: String; let name: String }

// Audio callbacks stay off the main actor. The fixed-size buffer never holds over six seconds.
final class ConversationMicrophone: @unchecked Sendable {
  private struct State {
    var samples: [Int16] = []
    var chunkStart: Double = 0
    var lastVoice: Double = 0
    var started = false
    var converter: AVAudioConverter?
  }
  private let lock = OSAllocatedUnfairLock(initialState: State())
  private let engine = AVAudioEngine()
  private var observers: [NSObjectProtocol] = []
  private var selectedUID = ""
  private var selectedPortType: AVAudioSession.Port = .bluetoothHFP
  private var tapInstalled = false
  var onChunk: (@Sendable (AudioChunk) -> Void)?
  var onVoice: (@Sendable (Double) -> Void)?
  var onFailure: (@Sendable (String) -> Void)?
  private(set) var actualSampleRate: Double = 0

  @MainActor func availablePorts() throws -> [AudioPort] {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode:.videoRecording, options:[.allowBluetoothHFP])
    try session.setActive(true)
    let ports = (session.availableInputs ?? []).filter { $0.portType == .bluetoothHFP }.map { AudioPort(id:$0.uid, name:$0.portName) }
    try? session.setActive(false, options:.notifyOthersOnDeactivation)
    return ports
  }

  @MainActor func start(uid: String) async throws {
    try await start(portType:.bluetoothHFP, uid:uid)
  }

  @MainActor func startPhone() async throws {
    try await start(portType:.builtInMic, uid:nil)
  }

  @MainActor private func start(portType: AVAudioSession.Port, uid requestedUID: String?) async throws {
    guard await AVAudioApplication.requestRecordPermission() else { throw CopilotError(message:"Microphone permission denied. Enable it in iOS Settings.") }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode:.videoRecording, options:portType == .bluetoothHFP ? [.allowBluetoothHFP] : [.defaultToSpeaker])
    try session.setActive(true)
    guard let port = session.availableInputs?.first(where: { $0.portType == portType && (requestedUID == nil || $0.uid == requestedUID) }) else {
      try? session.setActive(false)
      throw CopilotError(message:"Selected microphone unavailable. No other microphone was substituted.")
    }
    let uid = port.uid
    selectedUID = uid; selectedPortType = portType
    try session.setPreferredInput(port)
    // Official DAT microphone guide requires routing to settle BEFORE camera streaming.
    if portType == .bluetoothHFP { try await Task.sleep(for:.seconds(2)) }
    guard session.currentRoute.inputs.contains(where: { $0.portType == portType && $0.uid == uid }) else {
      try? session.setActive(false)
      throw CopilotError(message:"iOS did not select the requested microphone. Start was cancelled.")
    }
    let input = engine.inputNode
    let format = input.outputFormat(forBus:0)
    guard format.sampleRate > 0, format.channelCount > 0,
          let output = AVAudioFormat(commonFormat:.pcmFormatInt16, sampleRate:16000, channels:1, interleaved:true),
          let converter = AVAudioConverter(from:format, to:output) else { throw CopilotError(message:"No usable microphone audio format.") }
    actualSampleRate = format.sampleRate
    lock.withLockUnchecked { $0 = State(); $0.started = true; $0.converter = converter }
    input.installTap(onBus:0, bufferSize:1024, format:format) { [weak self] buffer, _ in self?.receive(buffer) }
    tapInstalled = true
    observers.append(NotificationCenter.default.addObserver(forName:AVAudioSession.routeChangeNotification, object:session, queue:.main) { [weak self] _ in
      guard let self, self.lock.withLockUnchecked({ $0.started }) else { return }
      if !session.currentRoute.inputs.contains(where: { $0.portType == self.selectedPortType && $0.uid == self.selectedUID }) {
        self.lock.withLockUnchecked { $0.started = false; $0.samples.removeAll() }
        self.onFailure?("Selected microphone route lost; recording paused. No other microphone was substituted.")
      }
    })
    observers.append(NotificationCenter.default.addObserver(forName:AVAudioSession.interruptionNotification, object:session, queue:.main) { [weak self] _ in
      guard let self, self.lock.withLockUnchecked({ $0.started }) else { return }
      self.lock.withLockUnchecked { $0.started = false; $0.samples.removeAll() }
      self.onFailure?("Audio interrupted; resume deliberately when ready.")
    })
    engine.prepare()
    try engine.start()
  }

  private func receive(_ buffer: AVAudioPCMBuffer) {
    // Drop the buffer at the source if the OS has switched to a different microphone.
    guard AVAudioSession.sharedInstance().currentRoute.inputs.contains(where: { $0.portType == selectedPortType && $0.uid == selectedUID }) else { return }
    let timestamp = nowMs()
    var chunk: AudioChunk?
    var voice = false
    lock.withLockUnchecked { state in
      guard state.started, let converter = state.converter,
            let output = AVAudioPCMBuffer(pcmFormat:converter.outputFormat, frameCapacity:AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 64)) else { return }
      // AVAudioConverter invokes its input block synchronously during convert.
      nonisolated(unsafe) var supplied = false
      var error: NSError?
      converter.convert(to:output, error:&error) { _, status in
        if supplied { status.pointee = .noDataNow; return nil }
        supplied = true; status.pointee = .haveData; return buffer
      }
      guard error == nil, let pointer = output.int16ChannelData?[0], output.frameLength > 0 else { return }
      let samples = Array(UnsafeBufferPointer(start:pointer, count:Int(output.frameLength)))
      let rms = sqrt(samples.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) } / Double(samples.count))
      voice = rms > 0.012 // provisional energy VAD; calibrate against glasses noise on hardware
      if voice { state.lastVoice = timestamp }
      if state.samples.isEmpty { state.chunkStart = timestamp - Double(samples.count) / 16 }
      state.samples.append(contentsOf:samples)
      // Flush early after silence; cap continuous speech at six seconds. Silence-only chunks never upload.
      if state.samples.count >= 96000 || (state.samples.count >= 16000 && timestamp - state.lastVoice > 450) {
        if state.lastVoice >= state.chunkStart {
          chunk = AudioChunk(audioBase64:Self.wav(state.samples).base64EncodedString(), startedAtMs:state.chunkStart, endedAtMs:state.lastVoice)
        }
        state.samples.removeAll(keepingCapacity:true)
      }
    }
    if voice { onVoice?(timestamp) }
    if let chunk { onChunk?(chunk) }
  }

  @MainActor func stop() {
    lock.withLockUnchecked { $0.started = false; $0.samples.removeAll(); $0.converter = nil }
    engine.stop()
    if tapInstalled { engine.inputNode.removeTap(onBus:0); tapInstalled = false }
    observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
    try? AVAudioSession.sharedInstance().setActive(false, options:.notifyOthersOnDeactivation)
  }

  static func wav(_ samples: [Int16]) -> Data {
    var data = Data()
    func text(_ value: String) { data.append(Data(value.utf8)) }
    func number<T: FixedWidthInteger>(_ value: T) { var le = value.littleEndian; withUnsafeBytes(of:&le) { data.append(contentsOf:$0) } }
    text("RIFF"); number(UInt32(36 + samples.count * 2)); text("WAVEfmt "); number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(16000)); number(UInt32(32000)); number(UInt16(2)); number(UInt16(16)); text("data"); number(UInt32(samples.count * 2))
    samples.withUnsafeBytes { data.append(contentsOf:$0) }
    return data
  }
}
