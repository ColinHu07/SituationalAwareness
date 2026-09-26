import Foundation
import MWDATDisplay

// Display-only rendering; camera/session transport is shared with regular glasses.
@MainActor
extension GlassesController {
  // Serialize all display writes: a dismissal/stop queued behind an in-flight send always wins.
  func show(_ cue: String?, caption: String? = nil, note: String? = nil, paused: Bool = false) {
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
          if let caption, !paused {
            Text("Captions · completed speech", style:.meta, color:.secondary)
            Text(String(caption.suffix(140)), style:.body)
          }
          if let cue { Text("Suggestion", style:.meta, color:.secondary); Text(cue, style:.body) }
          else if let note, !paused { Text("Your note", style:.meta, color:.secondary); Text(String(note.prefix(80)), style:.body) }
          else if caption == nil { Text(paused ? "Copilot paused" : "Copilot", style:.meta, color:.secondary) }
          ButtonGroup {
            if paused {
              Button(label:"Resume", onClick:{ [weak self] in Task { @MainActor in self?.onResume?() } })
            } else {
              if cue != nil { Button(label:"Dismiss", onClick:{ [weak self] in Task { @MainActor in self?.onDismiss?() } }) }
              Button(label:"Help", onClick:{ [weak self] in Task { @MainActor in self?.onHelp?() } })
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
