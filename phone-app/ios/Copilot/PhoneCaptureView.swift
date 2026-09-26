import SwiftUI

struct PhoneCaptureView: View {
  @Bindable var model: SessionModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment:.leading, spacing:20) {
          ZStack {
            RoundedRectangle(cornerRadius:20).fill(.black)
            if let image = model.phonePreview {
              Image(uiImage:image).resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius:20))
            } else {
              VStack(spacing:12) {
                if model.phase == .starting { ProgressView().tint(.white) }
                Image(systemName:model.phoneCameraEnabled ? "camera" : "mic.fill").font(.largeTitle)
                Text(model.phase == .starting ? "Starting capture…" : model.phoneCameraEnabled ? "Camera is not running" : "Audio-only session")
              }.foregroundStyle(.white).padding()
            }
          }.frame(minHeight:280)
          Text(model.phase.rawValue).font(.title2.bold())
          Text(model.notice).foregroundStyle(.secondary)
          if model.connectionTestOnly {
            Label("Capture test · no uploads or transcription",systemImage:"checkmark.shield")
          }
          if model.phase == .paused || model.phase == .stopped {
            Button("Return to setup") { model.stop(); dismiss() }.buttonStyle(.borderedProminent)
            if !model.connectionTestOnly {
              Button("Test camera and microphone without uploads") {
                model.pause()
                model.connectionTestOnly = true
                model.start()
              }.buttonStyle(.bordered).disabled(!model.consent)
            }
          }
          if model.phase == .active {
            HStack {
              Button("Pause",systemImage:"pause.fill") { model.pause() }.buttonStyle(.borderedProminent)
              Button("Stop",systemImage:"stop.fill",role:.destructive) { model.stop(); dismiss() }.buttonStyle(.bordered)
            }
          }
          if let caption = model.captionText {
            Text("Captions").font(.headline)
            Text(caption).font(.title3)
          }
          if let cue = model.cue {
            Text("AI suggestion").font(.headline)
            Text(cue).font(.title3)
            Button("Dismiss suggestion") { model.dismiss() }
          }
          TextField("Your notes",text:$model.contextText,axis:.vertical)
            .textFieldStyle(.roundedBorder)
            .onChange(of:model.contextText) { _, _ in model.contextChanged() }
        }.padding()
      }
      .navigationTitle("iPhone camera")
      .toolbar { ToolbarItem(placement:.topBarTrailing) {
        Button("Done") { model.pause(); dismiss() }
      } }
    }.interactiveDismissDisabled()
  }
}
