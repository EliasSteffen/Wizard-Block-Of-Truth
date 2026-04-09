import SwiftUI
import SwiftData
#if canImport(WizardDomain)
import WizardDomain
#endif

@main
struct WizardApp: App {
  var body: some Scene {
    WindowGroup {
      GameListView()
    }
    .modelContainer(for: [GameSnapshotEntity.self])
  }
}

