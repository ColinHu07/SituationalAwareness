import SwiftUI

struct ContentView: View {
  @Bindable var model: SessionModel
  @State private var showSettings = false
  @State private var showCamera = false
  @State private var showPeople = false
  private let ink = Color(red:0.05,green:0.14,blue:0.15)
  private let mint = Color(red:0.78,green:0.94,blue:0.83)
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment:.leading, spacing:22) {
          HStack {
            Label("SITUATIONAL AWARENESS",systemImage:"eyeglasses").font(.caption.weight(.semibold)).tracking(1.5)
            Spacer()
            Circle().fill(model.phase == .active ? Color.green : Color.gray).frame(width:8,height:8)
          }
          Text("A little help.\nMore presence.").font(.system(size:38,weight:.semibold,design:.rounded))
          VStack(alignment:.leading,spacing:10) {
            HStack(spacing:12) {
              sourceButton("iPhone", icon:"iphone", mode:.phone, selected:model.captureMode == .phone)
              sourceButton("Glasses", icon:"eyeglasses", mode:.displayGlasses, selected:model.captureMode.needsGlasses)
            }.disabled(model.phase != .stopped)
            if model.captureMode.needsGlasses {
              Picker("Glasses type",selection:$model.captureMode) {
                Text("With display").tag(CaptureMode.displayGlasses)
                Text("Without display").tag(CaptureMode.regularGlasses)
              }.pickerStyle(.segmented).disabled(model.phase != .stopped)
            }
            if model.captureMode == .phone {
              Toggle("Camera",isOn:$model.phoneCameraEnabled).disabled(model.phase != .stopped)
              NavigationLink {
                PhoneCaptionsView(model:model, settingsPresented:showSettings)
              } label: {
                Label("Multi-speaker captions",systemImage:"captions.bubble")
              }.disabled(model.phase != .stopped)
                .accessibilityIdentifier("captions.open")
            }
          }.padding(18).background(.white,in:RoundedRectangle(cornerRadius:18))
          with
          if model.captureMode.needsGlasses { hardware }
          if model.simulate {
            Label("SIMULATED",systemImage:"testtube.2")
              .font(.caption.bold()).padding(10).frame(maxWidth:.infinity,alignment:.leading)
              .background(Color.orange.opacity(0.16),in:RoundedRectangle(cornerRadius:10))
          }
          VStack(alignment:.leading,spacing:16) {
            if model.phase != .stopped {
            HStack {
              Text(model.phase == .active && model.analyzesSurroundings ? "Analyzing" : model.phase.rawValue).font(.title2.weight(.semibold))
              Spacer()
              if model.isThinking || model.isTranscribing { ProgressView() }
            }
            if let scene = model.currentScene { SceneChip(scene:scene) }
            if !model.notice.isEmpty { Text(model.notice).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
            }
            HStack(spacing:12) {
              if model.phase == .stopped || model.phase == .paused {
                Button(model.phase == .paused && !model.glassesControlsReady ? "Resume" : "Start",systemImage:"play.fill") { model.startFromPhone() }
                  .buttonStyle(.borderedProminent).tint(ink).disabled(!model.canStart)
              } else {
                Button("Pause",systemImage:"pause.fill") { model.pause() }.buttonStyle(.borderedProminent).tint(ink)
              }
              if model.phase != .stopped {
                Button("Stop",systemImage:"stop.fill",role:.destructive) { model.stop() }.buttonStyle(.bordered)
              }
            }.controlSize(.large)
            if model.glassesControlsReady { Text("Select Start on the glasses to stream.").font(.caption).foregroundStyle(.secondary) }
            if !model.simulate && model.phase != .stopped {
              Button("Live view",systemImage:"viewfinder") { showCamera = true }
            }
          }.padding(20).background(.white,in:RoundedRectangle(cornerRadius:20))

          VStack(alignment:.leading,spacing:16) {
            HStack {
              Text("CUE").font(.caption.bold()).tracking(1)
              Spacer(); Image(systemName:"sparkle")
            }.foregroundStyle(mint)
            Text(model.cue ?? (model.sceneOnly ? model.analysisFeedback ?? "Ready when you are." : "Room to listen.")).font(.system(size:25,weight:.medium,design:.rounded)).foregroundStyle(.white)
              .frame(maxWidth:.infinity,minHeight:64,alignment:.leading)
            if !model.sceneOnly { HStack {
              Button("Analyze now") { model.requestCue(manual:true) }.disabled(model.phase != .active || model.isThinking || model.uploadsDisabled)
              Spacer()
              Button("Dismiss") { model.dismiss() }.disabled(model.cue == nil)
            }.font(.subheadline.weight(.semibold)).tint(mint) }
          }.padding(22).background(ink,in:RoundedRectangle(cornerRadius:20))
          if model.cue != nil { Button("Not helpful",systemImage:"hand.thumbsdown") { model.markDistracting() }.font(.caption).tint(.secondary) }
          if let feedback = model.toneFeedback { RecoveryCard(feedback:feedback) { model.dismissTone() } }
          if !model.sceneOnly { VStack(alignment:.leading,spacing:12) {
            HStack {
              Label("CAPTIONS",systemImage:"captions.bubble").font(.caption.bold()).tracking(1)
              Spacer()
              ThatWasMeButton(model:model)
            }
            Text(model.captionText ?? "—")
              .font(.system(size:25,weight:.medium,design:.rounded))
              .foregroundStyle(model.captionText == nil ? .secondary : .primary)
              .frame(maxWidth:.infinity,minHeight:80,alignment:.leading)
          }.padding(22).background(.white,in:RoundedRectangle(cornerRadius:20))

          }
          VStack(alignment:.leading,spacing:10) {
            Label("NOTES",systemImage:"note.text").font(.caption.bold()).tracking(1)
            TextField("Add a note",text:$model.contextText,axis:.vertical)
              .lineLimit(2...4).onChange(of:model.contextText) { _, _ in model.contextChanged() }
          }.padding(20).background(mint.opacity(0.45),in:RoundedRectangle(cornerRadius:18))

          if model.simulate { simulation }
          else if model.captureMode == .phone { phone }
          else if let image = model.glasses.preview {
            Image(uiImage:image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius:14))
          }
          DisclosureGroup("Transcript") {
            VStack(alignment:.leading,spacing:10) {
              if model.transcript.isEmpty { Text("—").foregroundStyle(.secondary) }
              ForEach(model.transcript) { entry in
                VStack(alignment:.leading,spacing:3) {
                  Text(Date(timeIntervalSince1970:entry.endMs/1000),style:.time).font(.caption).foregroundStyle(.secondary)
                  Text(entry.text).font(.subheadline)
                }.frame(maxWidth:.infinity,alignment:.leading)
              }
            }.padding(.top,12)
          }
          DisclosureGroup("Stats") {
            Grid(alignment:.leading,horizontalSpacing:20,verticalSpacing:10) {
              metric("Cue API",String(format:"%.0f ms",model.apiMs))
              metric("Transcription",String(format:"%.0f ms",model.transcriptionMs))
              metric("Context → phone cue",String(format:"%.0f ms",model.contextToDisplayMs))
              metric("Successful upload JSON",String(format:"%.1f KB",Double(model.uploadedBytes)/1024))
              metric("Approx. model cost",model.estimatedCost.map { String(format:"$%.5f",$0) } ?? "Unavailable")
              metric("Cues / distracting","\(model.shown) / \(model.distracting)")
              metric("Stale / audio drops","\(model.staleDrops) / \(model.audioDrops)")
              metric("Microphone source rate",model.audioRate > 0 ? "\(Int(model.audioRate)) Hz" : "Unmeasured")
            }.font(.caption).padding(.top,12)
          }
        }.padding(24)
      }.background(Color(red:0.95,green:0.97,blue:0.95))
        .toolbar {
          ToolbarItem(placement:.topBarLeading) { Button("People",systemImage:"person.2") { showPeople = true } }
          ToolbarItem(placement:.topBarTrailing) { Button("Settings",systemImage:"slider.horizontal.3") { showSettings = true } }
        }
        .sheet(isPresented:$showSettings) { settings }
        .sheet(isPresented:$showPeople) { PeopleView(store:model.people) }
        .sheet(item:$model.learnReview) { review in LearnReviewView(model:model, review:review) }
    }.tint(ink)
      .fullScreenCover(isPresented:$showCamera) { PhoneCaptureView(model:model) }
      .onChange(of:model.phase) { _, phase in
        if phase == .starting && !model.simulate { showCamera = true }
      }
  }
  // Filled in automatically from face matches and names heard in conversation.
  private var with: some View {
    HStack(spacing:10) {
      Image(systemName:"person.2.fill").foregroundStyle(ink)
      if model.presentPeople.isEmpty {
        Text("—").foregroundStyle(.secondary)
      } else {
        PresenceChips(model:model)
      }
      Spacer(minLength:0)
      if model.isLearning { ProgressView() }
    }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
      .background(.white,in:RoundedRectangle(cornerRadius:18))
      .accessibilityIdentifier("people.present")
  }
  private func sourceButton(_ title: String, icon: String, mode: CaptureMode, selected: Bool) -> some View {
    Button { model.captureMode = mode } label: {
      VStack(spacing:8) {
        Image(systemName:icon).font(.title2)
        Text(title).font(.headline)
      }
      .frame(maxWidth:.infinity).padding(.vertical,16)
      .foregroundStyle(selected ? Color.white : ink)
      .background(selected ? ink : mint.opacity(0.35),in:RoundedRectangle(cornerRadius:14))
      .overlay(alignment:.topTrailing) {
        if selected { Image(systemName:"checkmark.circle.fill").font(.caption).foregroundStyle(mint).padding(8) }
      }
    }.buttonStyle(.plain).accessibilityIdentifier(mode == .phone ? "source.phone" : "source.glasses")
  }
  @ViewBuilder private func metric(_ name:String,_ value:String) -> some View { GridRow { Text(name).foregroundStyle(.secondary); Text(value).monospacedDigit() } }
  private var simulation: some View {
    VStack(alignment:.leading,spacing:12) {
      TextField("Say something…",text:$model.simulationText,axis:.vertical).textFieldStyle(.roundedBorder)
      HStack {
        Button("Add line") { model.addSimulationLine() }
        Button("Change subject") { model.addSimulationLine("Let's talk about lunch instead.") }
      }.buttonStyle(.bordered).disabled(model.phase != .active)
      HStack {
        Button("Quiet library") { model.addSimulationScene("library") }
        Button("Group conversation") { model.addSimulationScene("group") }
        Button("Funeral") { model.addSimulationScene("funeral") }
        Button("Blunt remark") { model.addSimulationLine("Honestly, this idea is stupid.") }
      }.buttonStyle(.bordered).disabled(model.phase != .active)
      Button("Someone needs space") {
        model.simulateSurroundings = true
        model.addSimulationLine("I've had a rough day. I need some space.")
      }.disabled(model.phase != .active)
      Button("Ordering example") { model.addSimulationLine("Would you like that hot or iced?") }.disabled(model.phase != .active)
      Button("Manual display test") { model.manualDisplayTest() }.disabled(model.phase != .active)
    }
  }
  private var phone: some View {
    VStack(alignment:.leading, spacing:12) {
      if let image = model.phonePreview {
        Image(uiImage:image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius:14))
      }
    }
  }
  private var hardware: some View {
    VStack(alignment:.leading,spacing:12) {
      Button { Task { await model.glasses.register() } } label: {
        Label("Pair glasses",systemImage:"link").frame(maxWidth:.infinity)
      }.buttonStyle(.borderedProminent).controlSize(.large)
        .disabled(model.phase == .active || model.phase == .starting)
        .accessibilityIdentifier("glasses.pair")
      Text(model.glasses.devices).font(.subheadline)
      if let error = model.glasses.lastError { Text(error).font(.caption).foregroundStyle(.red) }
      if model.captureMode == .regularGlasses {
        HStack {
          Picker("Microphone",selection:$model.selectedAudioUID) {
            Text("Choose").tag("")
            ForEach(model.audioPorts) { Text($0.name).tag($0.id) }
          }
          Button("Refresh",systemImage:"arrow.clockwise") { model.refreshAudioPorts() }.labelStyle(.iconOnly)
        }.disabled(model.phase == .active || model.phase == .starting)
      }
      if model.captureMode.hasGlassesDisplay {
        Button("Test display") { model.manualDisplayTest() }.disabled(model.phase != .active)
      }
    }.padding(18).background(.white,in:RoundedRectangle(cornerRadius:18))
  }
  private var settings: some View {
    NavigationStack {
      Form {
        Section("Tone check") {
          Toggle("Coach my wording",isOn:$model.toneCheckEnabled)
          if model.wearerVoiceDbFS != nil {
            Button("Reset my voice level",role:.destructive) { model.resetWearerVoice() }
          }
        }
        Section("Development mode") {
          Toggle("Capture test only (no uploads)",isOn:$model.connectionTestOnly).disabled(model.phase != .stopped)
          Button("Use simulated demo",systemImage:"testtube.2") {
            model.captureMode = .simulated
            showSettings = false
          }.disabled(model.phase != .stopped)
          Text("Simulated demo uses typed fixtures, with no live camera or microphone. Choose iPhone or Glasses on the main screen to return to real capture.").font(.caption)
          if model.simulate { Toggle("Local scripted model (no network)",isOn:$model.localMock).disabled(model.phase != .stopped) }
          Text("The scripted model is a small fixture set, not Muse. Real capture modes use the proxy unless Capture test only is enabled.").font(.caption)
        }
        Section("Server") {
          TextField("Server URL (found automatically)",text:$model.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
          SecureField("Token",text:$model.proxyToken).textInputAutocapitalization(.never).autocorrectionDisabled()
          Button { Task { await model.connect() } } label: {
            HStack {
              Text("Connect")
              Spacer()
              switch model.connectionStatus {
              case .checking: ProgressView()
              case .connected: Image(systemName:"checkmark.circle.fill").foregroundStyle(.green)
              case .failed: Image(systemName:"xmark.circle.fill").foregroundStyle(.red)
              case .unknown: EmptyView()
              }
            }
          }.disabled(model.connectionStatus == .checking)
          if case .failed(let message) = model.connectionStatus {
            Text(message).font(.caption).foregroundStyle(.red)
          } else if model.connectionStatus == .connected {
            Text("Muse live").font(.caption).foregroundStyle(.green)
          }
        }
        Section("This conversation") {
          if model.captureMode.hasGlassesDisplay {
            Toggle("Conversation and captions",isOn:$model.glassesConversationEnabled).disabled(model.phase != .stopped)
            Text("Off keeps automatic scene cues. On adds speech captions, name detection and conversation learning.").font(.caption)
          }
          TextField("Things you chose to remember (one per line)",text:$model.contextText,axis:.vertical).lineLimit(3...5).onChange(of:model.contextText) { _, _ in model.contextChanged() }
          if model.analyzesSurroundings {
            if model.captureMode.hasGlassesDisplay {
              Toggle("Captions on glasses",isOn:$model.displayCaptions).onChange(of:model.displayCaptions) { _, _ in model.refreshDisplay() }
              Text("In conversation mode, recognized words stay visible alongside a social cue. Longer captions are shortened on the glasses; see the phone for more.").font(.caption).foregroundStyle(.secondary)
            }
            Text(model.sceneOnly ? "Scene-only test: Muse checks fresh camera images every 4 seconds (15 in reduced-power mode), with audio levels when available. No speech transcription. Recommendations update automatically." : "Muse checks about every 3 seconds during conversation, 5 seconds otherwise, or 15 seconds in reduced-power mode; one check runs at a time. The current cue stays on screen until a better one arrives. Analyze now requests a fresh check. Camera and microphone stay on until Pause or Stop.").font(.caption)
          } else {
            Stepper("Image sample every \(Int(model.sampleInterval)) seconds",value:$model.sampleInterval,in:3...30,step:1)
          }
          Text("Keeps ≤60 seconds / 12 transcript entries and one sampled image. Stop erases session memory. No raw media files are saved.").font(.caption)
        }
        Section("Recognizing friends") {
          Toggle("Recognize enrolled faces",isOn:$model.recognizeFaces)
          if model.recognizeFaces {
            LabeledContent("Match distance ≤ \(String(format:"%.2f",model.faceThreshold))") {
              Slider(value:$model.faceThreshold,in:0.2...1.0,step:0.01)
            }
          }
          Text("Add face photos in People. Matching runs on this iPhone; unmatched faces are discarded. Two face matches within 10 seconds, or one plus their name spoken within 30 seconds, adds someone to Who's here. A name alone only suggests them. Introductions like \"my name is Priya\" or \"this is my friend Dev\" add a new person automatically. If exactly one unrecognized face is in view right after their name is heard, it is offered for their profile in the review when you stop; faces of people never named are not kept. Lower the distance if strangers match; raise it if friends are missed. The live view shows distances while the camera runs.").font(.caption)
        }
        Section("Provisional cue rules") {
          Text(model.sceneOnly ? "Muse checks every 4 seconds (15 in reduced-power mode). Recommendations stay until the next result. Pause and Stop clear captured context." : "Surroundings checks submit a frame ≤10 seconds old or recognized speech ≤15 seconds old, with 1.5 seconds after the last recognized speech. Scene results expire when their image is 20 seconds old. Each check also sends up to 8 one-sentence summaries of earlier moments. A cue stays until replaced, at least 5 seconds; an unchanged cue is not redrawn. Cue confidence ≥0.6. Dismiss pauses automatic checks for 10 seconds.").font(.caption)
          Text("iPhone mode pauses when the app leaves the foreground. Glasses pocket operation and routing need hardware validation; a simulator cannot verify them.").font(.caption)
        }
      }.navigationTitle("Settings").toolbar { Button("Done") { showSettings = false } }
    }
  }
}
