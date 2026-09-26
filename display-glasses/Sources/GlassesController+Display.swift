import Foundation
import MWDATDisplay

// Display-only rendering; camera/session transport is shared with regular glasses.
@MainActor
extension GlassesController {
  // Serialize all display writes: a dismissal/stop queued behind an in-flight send always wins.
  func show(_ cue: String?, caption: String? = nil, note: String? = nil, paused: Bool = false,
            status: String? = nil, captionsEnabled: Bool = false) {
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
          if paused {
            Text("Analysis paused", style:.body)
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
            if paused {
              Button(label:"Resume analysis", onClick:{ [weak self] in Task { @MainActor in self?.onResume?() } })
            } else {
              if cue != nil { Button(label:"Dismiss", onClick:{ [weak self] in Task { @MainActor in self?.onDismiss?() } }) }
              Button(label:"Analyze now", onClick:{ [weak self] in Task { @MainActor in self?.onHelp?() } })
              Button(label:"Pause", onClick:{ [weak self] in Task { @MainActor in self?.onPause?() } })
            }
            Button(label:"Stop", onClick:{ [weak self] in Task { @MainActor in self?.onStop?() } })
          }
        }
        try await display.send(content)
        if self.displayRevision != revision { try await display.clearDisplay() }
      } catch { self.fail("Display write failed: \(error.localizedDescription)") }
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
