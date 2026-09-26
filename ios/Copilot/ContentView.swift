import SwiftUI

struct ContentView: View {
  @Bindable var model: SessionModel
  @State private var showSettings = false
  private let ink = Color(red:0.05,green:0.14,blue:0.15)
  private let mint = Color(red:0.78,green:0.94,blue:0.83)
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment:.leading, spacing:22) {
          HStack {
            Label("CONVERSATION COPILOT",systemImage:"eyeglasses").font(.caption.weight(.semibold)).tracking(1.5)
            Spacer()
            Circle().fill(model.phase == .active ? Color.green : Color.gray).frame(width:8,height:8)
          }
          VStack(alignment:.leading,spacing:7) {
            Text("A little help.\nMore presence.").font(.system(size:38,weight:.semibold,design:.rounded))
            Text("Brief cues, only when they help.").foregroundStyle(.secondary)
          }
          VStack(alignment:.leading,spacing:10) {
            Text("Use Aside with").font(.headline)
            Picker("Input and output",selection:$model.captureMode) {
              ForEach(CaptureMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu).disabled(model.phase != .stopped)
            Text(model.captureMode.description).font(.caption).foregroundStyle(.secondary)
            if model.captureMode == .phone {
              Toggle("Include rear camera",isOn:$model.phoneCameraEnabled).disabled(model.phase != .stopped)
              Toggle("Capture test only (no uploads)",isOn:$model.connectionTestOnly).disabled(model.phase != .stopped)
              Text("Keep the phone app open. You can test microphone/camera permissions without an API key; captions require the live Muse backend.").font(.caption).foregroundStyle(.secondary)
            }
          }.padding(18).background(.white,in:RoundedRectangle(cornerRadius:18))
          if model.simulate {
            Label("SIMULATED DEVICE & INPUT",systemImage:"testtube.2")
              .font(.caption.bold()).padding(10).frame(maxWidth:.infinity,alignment:.leading)
              .background(Color.orange.opacity(0.16),in:RoundedRectangle(cornerRadius:10))
          }
          if !model.simulate && model.connectionTestOnly {
            Label("CAPTURE TEST · NO UPLOADS",systemImage:"cable.connector").font(.caption.bold()).foregroundStyle(.orange)
          }
          VStack(alignment:.leading,spacing:16) {
            HStack {
              Text(model.phase.rawValue).font(.title2.weight(.semibold))
              Spacer()
              if model.isThinking || model.isTranscribing { ProgressView() }
            }
            Text(model.notice).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if model.phase == .stopped {
              Toggle("We are adults and everyone agrees to the selected capture and processing",isOn:$model.consent)
                .font(.subheadline)
              Text(model.simulate || model.connectionTestOnly ? "This selected test mode does not upload recordings. Stop if anyone withdraws consent." : "Brief audio and optional images go to your proxy and Meta. Standard API provider retention applies. Stop if anyone withdraws consent.")
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing:12) {
              if model.phase == .stopped || model.phase == .paused {
                Button(model.phase == .paused ? "Resume" : "Start session",systemImage:"play.fill") { model.start() }
                  .buttonStyle(.borderedProminent).tint(ink).disabled(!model.canStart)
              } else {
                Button("Pause",systemImage:"pause.fill") { model.pause() }.buttonStyle(.borderedProminent).tint(ink)
              }
              if model.phase != .stopped {
                Button("Stop",systemImage:"stop.fill",role:.destructive) { model.stop() }.buttonStyle(.bordered)
              }
            }.controlSize(.large)
          }.padding(20).background(.white,in:RoundedRectangle(cornerRadius:20))

          VStack(alignment:.leading,spacing:12) {
            Label(model.simulate ? "SIMULATED CAPTIONS" : "CAPTIONS",systemImage:"captions.bubble").font(.caption.bold()).tracking(1)
            Text(model.captionText ?? (model.connectionTestOnly ? "Capture test: no transcription." : "Speech will appear here."))
              .font(.system(size:25,weight:.medium,design:.rounded))
              .frame(maxWidth:.infinity,minHeight:80,alignment:.leading)
            Text("Completed speech chunks, not word-by-word streaming. Recognition can be wrong; no speaker identity is inferred.")
              .font(.caption).foregroundStyle(.secondary)
          }.padding(22).background(.white,in:RoundedRectangle(cornerRadius:20))

          VStack(alignment:.leading,spacing:10) {
            Label("YOUR NOTES",systemImage:"note.text").font(.caption.bold()).tracking(1)
            TextField("e.g. Small iced latte · ask about oat milk",text:$model.contextText,axis:.vertical)
              .lineLimit(2...4).onChange(of:model.contextText) { _, _ in model.contextChanged() }
            Text("Written by you. Kept for this session and cleared on Stop.").font(.caption).foregroundStyle(.secondary)
          }.padding(20).background(mint.opacity(0.45),in:RoundedRectangle(cornerRadius:18))

          VStack(alignment:.leading,spacing:16) {
            HStack {
              Text(model.simulate ? "SIMULATED SUGGESTION" : "AI SUGGESTION").font(.caption.bold()).tracking(1)
              Spacer(); Image(systemName:"sparkle")
            }.foregroundStyle(mint)
            Text(model.cue ?? "Room to listen.").font(.system(size:25,weight:.medium,design:.rounded)).foregroundStyle(.white)
              .frame(maxWidth:.infinity,minHeight:64,alignment:.leading)
            if model.cue == nil { Text("A cue will appear when there is enough clear context.").font(.caption).foregroundStyle(.white.opacity(0.6)) }
            HStack {
              Button("Help me respond") { model.requestCue(manual:true) }.disabled(model.phase != .active)
              Spacer()
              Button("Dismiss") { model.dismiss() }.disabled(model.cue == nil)
            }.font(.subheadline.weight(.semibold)).tint(mint)
          }.padding(22).background(ink,in:RoundedRectangle(cornerRadius:20))
          if model.cue != nil { Button("That cue was distracting") { model.markDistracting() }.font(.caption).tint(.secondary) }
          if model.simulate { simulation }
          else if model.captureMode == .phone { phone }
          else { hardware }
          DisclosureGroup("Recent transcript · memory only") {
            VStack(alignment:.leading,spacing:10) {
              if model.transcript.isEmpty { Text("No speech captured.").foregroundStyle(.secondary) }
              ForEach(model.transcript) { entry in
                VStack(alignment:.leading,spacing:3) {
                  Text(Date(timeIntervalSince1970:entry.endMs/1000),style:.time).font(.caption).foregroundStyle(.secondary)
                  Text(entry.text).font(.subheadline)
                }.frame(maxWidth:.infinity,alignment:.leading)
              }
            }.padding(.top,12)
          }
          DisclosureGroup("Session measurements") {
            Grid(alignment:.leading,horizontalSpacing:20,verticalSpacing:10) {
              metric("Cue API",String(format:"%.0f ms",model.apiMs))
              metric("Transcription",String(format:"%.0f ms",model.transcriptionMs))
              metric("Speech → phone cue",String(format:"%.0f ms",model.contextToDisplayMs))
              metric("Successful upload JSON",String(format:"%.1f KB",Double(model.uploadedBytes)/1024))
              metric("Approx. model cost",model.estimatedCost.map { String(format:"$%.5f",$0) } ?? "Unavailable")
              metric("Cues / distracting","\(model.shown) / \(model.distracting)")
              metric("Stale / audio drops","\(model.staleDrops) / \(model.audioDrops)")
              metric("Microphone source rate",model.audioRate > 0 ? "\(Int(model.audioRate)) Hz" : "Unmeasured")
            }.font(.caption).padding(.top,12)
            Text("Timing ends at phone cue readiness, not hardware display acknowledgment. Zero means no reported measurement. Cost includes ASR when reported. Defaults need hardware calibration.").font(.caption2).foregroundStyle(.secondary).padding(.top,8)
          }
          Text("No face identification, emotion reading or medical claims. Glasses HFP favors the wearer; partner speech may be suppressed.").font(.caption).foregroundStyle(.secondary)
        }.padding(24)
      }.background(Color(red:0.95,green:0.97,blue:0.95))
        .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Settings",systemImage:"slider.horizontal.3") { showSettings = true } } }
        .sheet(isPresented:$showSettings) { settings }
    }.tint(ink)
  }
  @ViewBuilder private func metric(_ name:String,_ value:String) -> some View { GridRow { Text(name).foregroundStyle(.secondary); Text(value).monospacedDigit() } }
  private var simulation: some View {
    VStack(alignment:.leading,spacing:12) {
      Text("Demo input").font(.headline)
      Text("Typed fixtures are simulated speech. Nothing is recorded.").font(.caption).foregroundStyle(.secondary)
      TextField("A partner’s line…",text:$model.simulationText,axis:.vertical).textFieldStyle(.roundedBorder)
      HStack {
        Button("Add line") { model.addSimulationLine() }
        Button("Change subject") { model.addSimulationLine("Let's talk about lunch instead.") }
      }.buttonStyle(.bordered).disabled(model.phase != .active)
      Button("Ordering example") { model.addSimulationLine("Would you like that hot or iced?") }.disabled(model.phase != .active)
      Button("Manual display test") { model.manualDisplayTest() }.disabled(model.phase != .active)
    }
  }
  private var phone: some View {
    DisclosureGroup("iPhone camera preview") {
      if let image = model.phonePreview {
        Image(uiImage:image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius:14))
        Text("Rear camera · \(model.phoneFramesReceived) received frames. Only occasional samples are sent for suggestions.").font(.caption)
      } else {
        Text(model.phoneCameraEnabled ? "Start a consented session to receive camera frames." : "Audio-only selected. No camera access.").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  private var hardware: some View {
    VStack(alignment:.leading,spacing:12) {
      Text("Glasses connection").font(.headline)
      Toggle("Connection test only (no uploads)",isOn:$model.connectionTestOnly).disabled(model.phase != .stopped)
      Text(model.glasses.devices).font(.subheadline)
      if let error = model.glasses.lastError { Text(error).font(.caption).foregroundStyle(.red) }
      Text("DAT: \(model.glasses.registration) · Camera: \(model.glasses.cameraState) · Display: \(model.glasses.displayState)").font(.caption).foregroundStyle(.secondary)
      if let image = model.glasses.preview {
        Image(uiImage:image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius:14))
        Text("Glasses frame received · \(model.glasses.framesReceived) total").font(.caption)
      }
      Button("Pair / register with Meta AI") { Task { await model.glasses.register() } }.disabled(model.phase == .active)
      Button("Refresh Bluetooth audio inputs") { model.refreshAudioPorts() }.disabled(model.phase == .active || model.phase == .starting)
      Picker("Glasses microphone",selection:$model.selectedAudioUID) {
        Text("Choose glasses HFP input").tag("")
        ForEach(model.audioPorts) { Text($0.name).tag($0.id) }
      }.disabled(model.phase == .active || model.phase == .starting)
      Text("Choose your glasses, not another Bluetooth headset. Capture stops if this route changes.").font(.caption).foregroundStyle(.secondary)
      Button("Manual glasses display test") { model.manualDisplayTest() }.disabled(model.phase != .active)
    }
  }
  private var settings: some View {
    NavigationStack {
      Form {
        Section("Development mode") {
          Text("Choose iPhone, Meta glasses, Display glasses or Simulated demo on the main screen.").font(.caption)
          if model.simulate { Toggle("Local scripted model (no network)",isOn:$model.localMock).disabled(model.phase != .stopped) }
          Text("The scripted model is a small fixture set, not Muse. Real capture modes use the proxy unless Capture test only is enabled.").font(.caption)
        }
        Section("Trusted proxy") {
          TextField("https://your-proxy.example",text:$model.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
          SecureField("Proxy bearer token",text:$model.proxyToken).textInputAutocapitalization(.never).autocorrectionDisabled()
          Button("Save in Keychain") { model.saveConnection() }
          Button("Check proxy") { Task { await model.checkBackend() } }
          Text("Model mode: \(model.modelMode)").font(.caption)
          Text("Enter the proxy token, never the Muse Spark API key. Your model key belongs only in the backend environment.").font(.caption)
        }.disabled(model.phase == .active || model.phase == .starting)
        Section("This conversation") {
          TextField("Things you chose to remember (one per line)",text:$model.contextText,axis:.vertical).lineLimit(3...5).onChange(of:model.contextText) { _, _ in model.contextChanged() }
          Stepper("Image sample every \(Int(model.sampleInterval)) seconds",value:$model.sampleInterval,in:3...30,step:1)
          Text("Keeps ≤60 seconds / 12 transcript entries and one sampled image. Stop erases session memory. No raw media files are saved.").font(.caption)
        }
        Section("Provisional cue rules") {
          Text("At least 1.5 seconds of quiet; fresh speech ≤15 seconds; frame ≤10 seconds; confidence ≥0.8; automatic cooldown 30 seconds; cue lifetime 8 seconds. Each new speech buffer invalidates old suggestions.").font(.caption)
          Text("iPhone mode pauses when the app leaves the foreground. Glasses pocket operation and routing need hardware validation; a simulator cannot verify them.").font(.caption)
        }
      }.navigationTitle("Settings").toolbar { Button("Done") { showSettings = false } }
    }
  }
}
