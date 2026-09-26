import SwiftUI

// Both capture sources use the same session, Muse client, and phone cue surface.
struct PhoneCaptureView: View {
  @Bindable var model: SessionModel
  @Environment(\.dismiss) private var dismiss
  private let ink = Color(red:0.05,green:0.14,blue:0.15)
  private let mint = Color(red:0.78,green:0.94,blue:0.83)

  private var usesGlasses: Bool { model.captureMode.needsGlasses }
  private var cameraEnabled: Bool { usesGlasses || model.phoneCameraEnabled }
  private var sourceName: String { usesGlasses ? "Glasses" : "iPhone" }
  private var expectedAudioSource: String {
    model.captureMode == .displayGlasses ? "glasses_pcm" : usesGlasses ? "glasses_hfp" : "phone"
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment:.leading,spacing:20) {
          if usesGlasses && model.glasses.updateRequired {
            VStack(alignment:.leading,spacing:10) {
              Label("Glasses app update required",systemImage:"arrow.down.circle").font(.headline)
              Text(GlassesController.updateInstructions).font(.subheadline)
              Button("Open Meta glasses app updater",systemImage:"arrow.up.forward.app") {
                Task { await model.glasses.openGlassesAppUpdate() }
              }.buttonStyle(.borderedProminent)
              Text("Capture cannot start until Meta completes this update.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading)
              .padding(18).background(.white,in:RoundedRectangle(cornerRadius:18))
          }
          preview
          if let scene = model.currentScene { SceneChip(scene:scene) }
          PresenceStrip(model:model)
          cueCard
          sessionStatus
          if model.lastSceneSummary != nil || model.lastAnalysisOutcome != nil {
            VStack(alignment:.leading,spacing:8) {
              Label("SEEING",systemImage:"eye").font(.caption.bold()).tracking(1)
              if let summary = model.lastSceneSummary { Text(summary).font(.subheadline) }
              if let outcome = model.lastAnalysisOutcome {
                Text(outcome).font(.caption).foregroundStyle(.secondary)
              }
            }.frame(maxWidth:.infinity,alignment:.leading)
              .padding(18).background(.white,in:RoundedRectangle(cornerRadius:18))
          }
          if !model.sceneOnly {
          captions
          VStack(alignment:.leading,spacing:8) {
            Label("NOTES",systemImage:"note.text").font(.caption.bold()).tracking(1)
            TextField("Add a note",text:$model.contextText,axis:.vertical)
              .lineLimit(2...4)
              .onChange(of:model.contextText) { _, _ in model.contextChanged() }
          }.padding(18).background(mint.opacity(0.45),in:RoundedRectangle(cornerRadius:18))
          }
        }.padding(20)
      }.background(Color(red:0.95,green:0.97,blue:0.95))
        .safeAreaInset(edge:.bottom) { captureControls }
        .navigationTitle(sourceName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement:.topBarTrailing) {
          Button("Setup") { model.pause(); dismiss() }
        } }
    }.tint(ink).interactiveDismissDisabled()
  }

  private var preview: some View {
    VStack(alignment:.leading,spacing:10) {
      HStack {
        Label(sourceName.uppercased(),systemImage:usesGlasses ? "eyeglasses" : "iphone")
          .font(.caption.bold()).tracking(1)
        Spacer()
        Text(model.phase == .active ? "LIVE" : model.phase.rawValue.uppercased())
          .font(.caption2.bold()).foregroundStyle(.secondary)
      }
      ZStack {
        RoundedRectangle(cornerRadius:18).fill(.black)
        if let image = usesGlasses ? model.glasses.preview : model.phonePreview {
          Image(uiImage:image).resizable().scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius:18))
        } else {
          VStack(spacing:12) {
            if model.phase == .starting { ProgressView().tint(.white) }
            Image(systemName:cameraEnabled ? "camera" : "mic.fill").font(.largeTitle)
            if !previewPlaceholder.isEmpty { Text(previewPlaceholder).font(.subheadline).multilineTextAlignment(.center) }
          }.foregroundStyle(.white).padding(24)
        }
      }.aspectRatio(16.0/9.0,contentMode:.fit)
    }
  }

  private var previewPlaceholder: String {
    if model.openingGlassesControls && model.phase == .starting { return "Opening glasses controls…" }
    if model.glassesControlsReady { return "Ready on glasses. Press Start with your wristband." }
    if model.phase == .starting { return "Opening \(sourceName.lowercased()) camera…" }
    return ""
  }

  private var sessionStatus: some View {
    VStack(alignment:.leading,spacing:14) {
      HStack {
        Text(model.phase == .active ? model.analysisStatus : model.phase.rawValue)
          .font(.title3.weight(.semibold))
        Spacer()
        if model.isThinking || model.isTranscribing || model.phase == .starting { ProgressView() }
      }
      if !model.notice.isEmpty {
        Text(model.notice).font(.subheadline).foregroundStyle(.secondary)
          .accessibilityIdentifier("capture.notice")
      }
      DisclosureGroup("Input status") {
        TimelineView(.periodic(from:.now,by:1)) { context in
          inputStatus(at:context.date.timeIntervalSince1970 * 1000)
        }
      }
      if usesGlasses, let error = model.glasses.lastError, error != model.notice {
        Label(error,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.red)
      }
    }.padding(18).background(.white,in:RoundedRectangle(cornerRadius:18))
  }

  private var captureControls: some View {
    HStack(spacing:12) {
      if model.phase == .paused {
        Button(model.captureMode.hasGlassesDisplay ? "Start glasses" : usesGlasses && model.glasses.updateRequired ? "Retry after update" : "Resume",systemImage:"play.fill") { model.startFromPhone() }
          .buttonStyle(.borderedProminent).disabled(!model.canStart)
      } else if model.phase == .active {
        Button("Pause",systemImage:"pause.fill") { model.pause() }.buttonStyle(.borderedProminent)
      }
      if model.phase != .stopped {
        Button("Stop",systemImage:"stop.fill",role:.destructive) { model.stop(); dismiss() }
          .buttonStyle(.bordered)
      } else {
        Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
      }
      Spacer(minLength:0)
    }.controlSize(.large).padding(.horizontal,20).padding(.vertical,12)
      .background(.ultraThinMaterial)
  }

  private func inputStatus(at timestamp: Double) -> some View {
    let active = model.phase == .active
    let cameraTime = usesGlasses ? model.glasses.previewAtMs : (model.latestFrame?.capturedAtMs ?? 0)
    let cameraFresh = active && cameraTime > 0 && timestamp - cameraTime >= -1000 && timestamp - cameraTime < 5000
    let audio = model.latestAudioContext
    let audioFresh = active && audio?.source == expectedAudioSource && (audio.map { timestamp - $0.capturedAtMs >= -1000 && timestamp - $0.capturedAtMs < 5000 } ?? false)
    let frames = usesGlasses ? model.glasses.framesReceived : model.phoneFramesReceived
    return VStack(alignment:.leading,spacing:8) {
      statusRow("Camera",value:!cameraEnabled ? "Off" : cameraFresh ? "\(frames)" : active || model.phase == .starting ? "Waiting" : "Off",active:cameraFresh)
      statusRow("Mic",value:audioFresh ? "On" : active || model.phase == .starting ? "Waiting" : "Off",active:audioFresh)
      if model.captureMode.hasGlassesDisplay {
        statusRow("Display",value:model.glasses.displayState,active:active && model.glasses.displayState.lowercased() == "started")
      }
      statusRow("Muse",value:model.offline ? "Offline" : model.isThinking ? "Analyzing" : model.isTranscribing ? "Transcribing" : model.modelMode,active:active && !model.uploadsDisabled && model.modelMode == "live")
    }
  }

  private func statusRow(_ title: String, value: String, active: Bool) -> some View {
    HStack(alignment:.firstTextBaseline,spacing:8) {
      Circle().fill(active ? Color.green : Color.gray.opacity(0.5)).frame(width:7,height:7)
      Text(title).font(.caption.weight(.semibold))
      Spacer(minLength:8)
      Text(value).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
    }
  }

  private var cueCard: some View {
    VStack(alignment:.leading,spacing:16) {
      HStack {
        Label(model.sceneOnly ? "SCENE" : "CUE",systemImage:"sparkle")
          .font(.caption.bold()).tracking(1)
        Spacer()
      }.foregroundStyle(mint)
      Text(model.cue ?? emptyCueText)
        .font(.system(size:27,weight:.medium,design:.rounded))
        .foregroundStyle(.white).frame(maxWidth:.infinity,minHeight:70,alignment:.leading)
        .accessibilityIdentifier("capture.cue")
      if !model.sceneOnly { HStack {
        Button("Analyze now") { model.requestCue(manual:true) }
          .disabled(model.phase != .active || model.isThinking || model.uploadsDisabled)
        Spacer()
        Button("Dismiss") { model.dismiss() }.disabled(model.cue == nil)
      }.font(.subheadline.weight(.semibold)).tint(mint) }
    }.padding(22).background(ink,in:RoundedRectangle(cornerRadius:20))
  }

  private var emptyCueText: String {
    if model.offline { return "Server offline" }
    if model.sceneOnly {
      if model.phase != .active { return "Start streaming to check the scene." }
      return model.analysisFeedback ?? "Waiting for a fresh camera frame…"
    }
    return "Room to listen."
  }

  private var captions: some View {
    VStack(alignment:.leading,spacing:10) {
      Label("CAPTIONS",systemImage:"captions.bubble").font(.caption.bold()).tracking(1)
      Text(model.captionText ?? "—")
        .font(.title3).foregroundStyle(model.captionText == nil ? .secondary : .primary)
        .frame(maxWidth:.infinity,minHeight:45,alignment:.leading)
    }.padding(18).background(.white,in:RoundedRectangle(cornerRadius:18))
  }
}
