import Foundation
import MWDATDisplay

// Only visible content participates in equality. Enabled captions update even
// while a cue is visible; hidden captions do not redraw the lens.
struct GlassesScreen: Equatable, Sendable {
  enum Mode: Sendable { case ready, paused, starting, streaming }
  let mode: Mode
  let cue: String?
  let detail: String?
  let testOnly: Bool
  let feedback: String?
  let status: String?
  init(cue: String?, caption: String?, note: String?, paused: Bool,
       captionsEnabled: Bool, ready: Bool, starting: Bool, testOnly: Bool, feedback: String? = nil, status: String? = nil) {
    mode = starting ? .starting : paused ? (ready ? .ready : .paused) : .streaming
    self.testOnly = testOnly
    self.status = mode == .paused ? status.map { String($0.prefix(80)) } : nil
    self.feedback = mode == .streaming ? feedback.map { String($0.prefix(64)) } : nil
    self.cue = mode == .streaming ? cue.map { String($0.prefix(90)) } : nil
    if mode == .streaming && captionsEnabled {
      detail = caption.flatMap { text in
        let text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator:" ")
        guard !text.isEmpty else { return nil }
        return "Heard: " + (text.count > 60 ? "…" : "") + String(text.suffix(60))
      }
    } else if mode == .streaming && self.cue == nil {
      detail = note.map { String($0.prefix(60)) }
    } else { detail = nil }
  }
  var title: String {
    switch mode {
    case .ready: return "Ready · camera off"
    case .paused: return "Paused · camera off"
    case .starting: return "Starting…"
    case .streaming: return testOnly ? "Camera test · no uploads" : feedback ?? "Streaming"
    }
  }
  var labels: [String] {
    switch mode {
    case .ready: return ["Start", "Close"]
    case .paused: return ["Resume", "Stop", "Close"]
    case .starting: return ["Cancel"]
    case .streaming: return ["Pause", testOnly ? "Test cue" : "Analyze", "Stop"]
    }
  }
  var actions: [GlassesController.ControlAction] {
    switch mode {
    case .ready: return [.start, .close]
    case .paused: return [.start, .stop, .close]
    case .starting: return [.stop]
    case .streaming: return [.pause, .help, .stop]
    }
  }
}

@MainActor
extension GlassesController {
  // SDK send replaces the screen atomically. clearDisplay is reserved for closing
  // controls; clearing before every send produces a visible blank-frame flash.
  func show(_ cue: String?, caption: String? = nil, note: String? = nil, paused: Bool = false,
            status: String? = nil, captionsEnabled: Bool = false, ready: Bool = false,
            starting: Bool = false, testOnly: Bool = false, feedback: String? = nil) {
    guard displayReady else { return }
    let screen = GlassesScreen(cue:cue, caption:caption, note:note, paused:paused,
      captionsEnabled:captionsEnabled, ready:ready, starting:starting, testOnly:testOnly, feedback:feedback, status:status)
    guard screen != requestedScreen else { return }
    requestedScreen = screen
    displayRevision += 1
    let revision = displayRevision
    let previous = operation
    operation = Task { [weak self] in
      await previous?.value
      guard let self, self.displayRevision == revision, let display = self.display, self.displayReady else { return }
      do {
        let content = FlexBox(direction:.column, spacing:8) {
          Text(screen.title, style:.meta, color:.secondary)
          if let detail = screen.detail {
            Text(detail, style:.body)
          }
          if let cue = screen.cue {
            Text("Cue: " + cue, style:screen.detail == nil ? .body : .meta)
          }
          if screen.cue == nil && screen.detail == nil {
            Text(screen.status ?? (screen.mode == .ready ? "Select Start to stream." : screen.mode == .paused ? "Select Resume when ready." : screen.mode == .starting ? "Connecting camera and audio." : "Say a sentence, then Analyze."), style:.body)
          }
          // At most three short labels; never append Dismiss and widen the row.
          ButtonGroup {
            for index in screen.labels.indices {
              if index == 0 {
                Button(label:screen.labels[index], onClick:{ [weak self] in Task { @MainActor in self?.perform(screen.actions[index], revision:revision) } })
                  .actionRole(.primary)
              } else {
                Button(label:screen.labels[index], onClick:{ [weak self] in Task { @MainActor in self?.perform(screen.actions[index], revision:revision) } })
              }
            }
          }
        }.padding(12)
        try await display.send(content)
      } catch {
        guard self.displayRevision == revision else { return }
        self.requestedScreen = nil
        self.fail("Display write failed: \(error.localizedDescription)")
      }
    }
  }

  enum ControlAction { case start, pause, stop, close, help, dismiss }
  func perform(_ action: ControlAction, revision: Int) {
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
    requestedScreen = nil
    displayRevision += 1
    let previous = operation
    let cap = display
    operation = Task { [weak self] in
      await previous?.value
      do { try await cap?.clearDisplay() } catch { self?.lastError = "Display clear failed: \(error.localizedDescription)" }
    }
  }
}
