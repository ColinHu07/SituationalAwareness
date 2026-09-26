import Foundation
import MWDATDisplay

// Display-only rendering; camera/session transport is shared with regular glasses.
@MainActor
extension GlassesController {
  // Serialize all display writes: a dismissal/stop queued behind an in-flight send always wins.
  func show(_ cue: String?, caption: String? = nil, note: String? = nil, paused: Bool = false,
            status: String? = nil, captionsEnabled: Bool = false, ready: Bool = false, starting: Bool = false) {
    displayRevision += 1
    let revision = displayRevision
    let previous = operation
    operation = Task { [weak self] in
      await previous?.value
      guard let self, self.displayRevision == revision, let display = self.display, self.displayReady else { return }
      do {
        try await display.clearDisplay()
        guard self.displayRevision == revision else { return }
        let content = FlexBox(direction:.column, spacing:12) {
          if starting {
            Text("Starting stream…", style:.body)
          } else if paused {
            Text(ready ? "Ready to stream" : "Streaming paused", style:.body)
            Text("Camera and microphone are off.", style:.meta, color:.secondary)
          } else {
            if let cue {
              Text("Social cue", style:.meta, color:.secondary)
              Text(cue, style:.body)
              if let status { Text(status, style:.meta, color:.secondary) }
            } else {
              Text("Muse", style:.meta, color:.secondary)
              Text(status ?? "Watching surroundings", style:.body)
              if let note, !note.isEmpty {
                Text("Your note", style:.meta, color:.secondary)
                Text(String(note.prefix(80)), style:.meta)
              }
            }
            // Cues get the first glance; completed speech is optional, secondary context.
            if captionsEnabled, let caption, !caption.isEmpty {
              Text("Heard · completed speech", style:.meta, color:.secondary)
              Text(String(caption.suffix(120)), style:.meta)
            }
          }
          ButtonGroup {
            if starting {
              Button(label:"Stop streaming", onClick:{ [weak self] in Task { @MainActor in self?.perform(.stop, revision:revision) } })
                .actionRole(.primary)
            } else if paused {
              Button(label:ready ? "Start streaming" : "Resume streaming", onClick:{ [weak self] in Task { @MainActor in self?.perform(.start, revision:revision) } })
                .actionRole(.primary)
              if !ready {
                Button(label:"Stop streaming", onClick:{ [weak self] in Task { @MainActor in self?.perform(.stop, revision:revision) } })
              }
              Button(label:"Close controls", onClick:{ [weak self] in Task { @MainActor in self?.perform(.close, revision:revision) } })
            } else {
              Button(label:"Pause streaming", onClick:{ [weak self] in Task { @MainActor in self?.perform(.pause, revision:revision) } })
                .actionRole(.primary)
              Button(label:"Analyze now", onClick:{ [weak self] in Task { @MainActor in self?.perform(.help, revision:revision) } })
              if cue != nil { Button(label:"Dismiss", onClick:{ [weak self] in Task { @MainActor in self?.perform(.dismiss, revision:revision) } }) }
              Button(label:"Stop streaming", onClick:{ [weak self] in Task { @MainActor in self?.perform(.stop, revision:revision) } })
            }
          }
        }
        try await display.send(content)
        if self.displayRevision != revision { try await display.clearDisplay() }
      } catch {
        guard self.displayRevision == revision else { return }
        self.fail("Display write failed: \(error.localizedDescription)")
      }
    }
  }

  enum ControlAction { case start, pause, stop, close, help, dismiss }
  func perform(_ action: ControlAction, revision: Int) {
    // A click queued by an old screen must never act on a new capture session.
    guard displayRevision == revision else { return }
    switch action {
    case .start: onResume?()
    case .pause: onPause?()
    case .stop: onStop?()
    case .close: onDisconnect?()
    case .help: onHelp?()
    case .dismiss: onDismiss?()
    }
  }

  func clear() {
    displayRevision += 1
    let previous = operation
    let cap = display
    operation = Task { [weak self] in
      await previous?.value
      do { try await cap?.clearDisplay() } catch { self?.lastError = "Display clear failed: \(error.localizedDescription)" }
    }
  }
}
