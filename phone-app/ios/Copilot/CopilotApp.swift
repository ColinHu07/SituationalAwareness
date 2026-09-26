import SwiftUI

@main
struct CopilotApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @State private var model = SessionModel()
  var body: some Scene {
    WindowGroup {
      ContentView(model:model)
        .onOpenURL { url in
          // Meta AI can return after a cold launch, before Glasses is selected.
          // The controller filters for the SDK's registration callback.
          Task { await model.glasses.handle(url) }
        }
        .onChange(of:scenePhase) { _, phase in
          if phase == .background { model.sceneBecameInactive() }
        }
    }
  }
}
