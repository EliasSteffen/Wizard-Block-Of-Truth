import SwiftUI
import SwiftData

@main
struct WizardApp: App {
  var body: some Scene {
    WindowGroup {
      GameListView()
    }
    .modelContainer(for: [GameSnapshotEntity.self])
  }
}

