import Foundation
import MWDATDisplay

// Only visible content participates in equality. Speech updates never redraw the lens.
struct GlassesScreen: Equatable, Sendable {
  enum Mode: Sendable { case ready, paused, starting, streaming }
  let mode: Mode
  let cue: String?
  let detail: String?
  let testOnly: Bool
  let feedback: String?
  let status: String?
  let sceneOnly: Bool
  init(cue: String?, caption: String?, note: String?, paused: Bool,
       captionsEnabled: Bool, ready: Bool, starting: Bool, testOnly: Bool, feedback: String? = nil, status: String? = nil, sceneOnly: Bool = false) {
    mode = starting ? .starting : paused ? (ready ? .ready : .paused) : .streaming
    self.testOnly = testOnly
    self.sceneOnly = sceneOnly
    self.status = mode == .paused ? status.map { String($0.prefix(80)) } : nil
    self.feedback = mode == .streaming ? feedback.map { String($0.prefix(64)) } : nil
    self.cue = mode == .streaming ? cue.map { String($0.prefix(90)) } : nil
    // Captions stay on the phone. Keep the arguments for older callers, but never render them.
    detail = nil
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
    case .streaming: if sceneOnly && !testOnly { return ["Pause", "Stop"] }; return ["Pause", testOnly ? "Test cue" : "Analyze", "Stop"]
    }
  }
  var actions: [GlassesController.ControlAction] {
    switch mode {
    case .ready: return [.start, .close]
    case .paused: return [.start, .stop, .close]
    case .starting: return [.stop]
    case .streaming: return sceneOnly && !testOnly ? [.pause, .stop] : [.pause, .help, .stop]
    }
  }
}

@MainActor
extension GlassesController {
  // SDK send replaces the screen atomically. clearDisplay is reserved for closing
  // controls; clearing before every send produces a visible blank-frame flash.
  func show(_ cue: String?, caption: String? = nil, note: String? = nil, paused: Bool = false,
            status: String? = nil, captionsEnabled: Bool = false, ready: Bool = false,
            starting: Bool = false, testOnly: Bool = false, feedback: String? = nil, sceneOnly: Bool = false) {
    guard displayReady else { return }
    let screen = GlassesScreen(cue:cue, caption:caption, note:note, paused:paused,
      captionsEnabled:captionsEnabled, ready:ready, starting:starting, testOnly:testOnly, feedback:feedback, status:status, sceneOnly:sceneOnly)
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
            Text(screen.status ?? (screen.mode == .ready ? "Select Start to stream." : screen.mode == .paused ? "Select Resume when ready." : screen.mode == .starting ? "Connecting camera and audio." : screen.sceneOnly ? "Watching the scene automatically." : "Listening for context automatically."), style:.body)
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
