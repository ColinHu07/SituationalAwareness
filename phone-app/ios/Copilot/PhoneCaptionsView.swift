import SwiftUI
import UIKit

struct PhoneCaptionsView: View {
  @Bindable var model: SessionModel
  var settingsPresented: Bool = false
  @State private var session = PhoneCaptionSession()
  @Environment(\.scenePhase) private var scenePhase
  private let ink = Color(red:0.05,green:0.14,blue:0.15)
  private let mint = Color(red:0.78,green:0.94,blue:0.83)

  var body: some View {
    ScrollViewReader { scroll in
      ScrollView {
        LazyVStack(alignment:.leading,spacing:18) {
          HStack(alignment:.firstTextBaseline) {
            Text("Live captions")
              .font(.system(.largeTitle,design:.rounded,weight:.semibold))
              .foregroundStyle(ink)
            Spacer()
            if !session.rows.isEmpty {
              Button {
                let full = session.rows.map { "\(session.displaySpeakerName(for:$0.speakerLabel)): \($0.text)" }.joined(separator:"\n\n")
                UIPasteboard.general.string = full
              } label: {
                Label("Copy all", systemImage:"doc.on.doc")
              }
              .font(.subheadline.weight(.medium))
              .buttonStyle(.bordered)
              .tint(ink)
              .accessibilityIdentifier("captions.copyAll")
            }
          }
          if session.phase == .stopped {
            Text("Tap Start when everyone agrees to transcription.")
              .font(.body).foregroundStyle(.secondary)
          }
          if !session.status.isEmpty {
            Text(session.status)
              .font(.subheadline).foregroundStyle(.secondary)
              .fixedSize(horizontal:false,vertical:true)
          }
          DisclosureGroup("Timing & debug") {
            VStack(alignment:.leading,spacing:12) {
              Text(session.diagnostics.summary)
                .font(.system(.caption,design:.monospaced))
                .textSelection(.enabled)
                .frame(maxWidth:.infinity,alignment:.leading)
              Text("Compare captured → sent → proxy → Muse audio offsets over time. These snapshots arrive at different times, so a gap alone is not an exact delay. Speaker labels and final text may arrive later than partial text.")
                .font(.caption).foregroundStyle(.secondary)
              Text("Event age is estimated from the first audio callback and Muse's stream offset, not individual word timing. Send completion is not a server acknowledgement. Caption state updates are measured; screen rendering is not. Server +time has its own clock.")
                .font(.caption2).foregroundStyle(.secondary)
              ShareLink(item:session.diagnostics.exportText) {
                Label("Share timing log",systemImage:"square.and.arrow.up")
              }.disabled(session.diagnostics.entries.isEmpty)
              if !session.diagnostics.entries.isEmpty { ScrollView {
                Text(session.diagnostics.entries.reversed().map(\.line).joined(separator:"\n\n"))
                  .font(.system(.caption2,design:.monospaced))
                  .textSelection(.enabled)
                  .frame(maxWidth:.infinity,alignment:.leading)
              }.frame(height:230) }
              Text("Newest first · last 200 events · timing only, no audio or transcript text. Stop keeps this log; Start begins a new one.")
                .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top,10)
          }
          .accessibilityIdentifier("captions.debug")
          .padding(16).background(.white,in:RoundedRectangle(cornerRadius:16))
          if session.rows.isEmpty {
            Text("Captions will appear here.")
              .font(.title3).foregroundStyle(.secondary)
              .frame(maxWidth:.infinity,minHeight:180,alignment:.leading)
              .padding(22)
              .background(.white,in:RoundedRectangle(cornerRadius:20))
          } else {
            ForEach(session.rows) { row in
              VStack(alignment:.leading,spacing:10) {
                Text(session.displaySpeakerName(for:row.speakerLabel))
                  .font(.headline).foregroundStyle(ink)
                  .padding(.horizontal,12).padding(.vertical,6)
                  .background(mint,in:Capsule())
                Text(row.text)
                  .font(.system(.title2,design:.rounded,weight:.medium))
                  .foregroundStyle(ink)
                  .fixedSize(horizontal:false,vertical:true)
                  .textSelection(.enabled)
              }
              .frame(maxWidth:.infinity,alignment:.leading)
              .padding(22)
              .background(.white,in:RoundedRectangle(cornerRadius:20))
              .accessibilityElement(children:.combine)
              .accessibilityIdentifier("captions.row.\(row.id)")
              .id(row.id)
              .contextMenu {
                Button {
                  UIPasteboard.general.string = "\(session.displaySpeakerName(for:row.speakerLabel)): \(row.text)"
                } label: {
                  Label("Copy caption", systemImage:"doc.on.doc")
                }
                ShareLink(item:"\(session.displaySpeakerName(for:row.speakerLabel)): \(row.text)") {
                  Label("Share caption", systemImage:"square.and.arrow.up")
                }
              }
            }
          }
        }.padding(20)
      }
      .onChange(of:session.rows.last?.id) { _, _ in
        if let last = session.rows.last { scroll.scrollTo(last.id,anchor:.bottom) }
      }
    }
    .background(Color(red:0.95,green:0.97,blue:0.95))
    .safeAreaInset(edge:.bottom) {
      Button {
        if session.phase == .stopped {
          session.start(endpoint:model.endpoint,token:model.proxyToken)
        } else {
          session.stop()
        }
      } label: {
        Label(session.phase == .stopped ? "Start" : "Stop",
              systemImage:session.phase == .stopped ? "mic.fill" : "stop.fill")
          .font(.title3.weight(.semibold))
          .frame(maxWidth:.infinity,minHeight:44)
      }
      .buttonStyle(.borderedProminent).tint(ink).controlSize(.large)
      .accessibilityIdentifier("captions.start-stop")
      .padding(.horizontal,20).padding(.vertical,12)
      .background(.ultraThinMaterial)
    }
    .onChange(of:scenePhase) { _, phase in
      // The microphone permission prompt briefly makes the app inactive.
      if phase == .background { session.stop() }
    }
    .onChange(of:settingsPresented) { _, presented in
      if presented { session.stop() }
    }
    .onAppear { session.attachPeople(model.people) }
    .onDisappear { session.stop() }
    .toolbar {
      if !session.rows.isEmpty {
        ToolbarItem(placement:.topBarTrailing) {
          ShareLink(item:session.rows.map { "\(session.displaySpeakerName(for:$0.speakerLabel)): \($0.text)" }.joined(separator:"\n\n")) {
            Label("Share captions", systemImage:"square.and.arrow.up")
          }
        }
      }
    }
  }
}
