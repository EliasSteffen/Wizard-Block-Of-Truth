import SwiftUI
import SwiftData
#if canImport(WizardDomain)
import WizardDomain
#endif

@main
struct WizardApp: App {
  @AppStorage("app.colorScheme") private var colorSchemeRaw: String = AppColorScheme.system.rawValue

  var body: some Scene {
    WindowGroup {
      GameListView()
        .preferredColorScheme(AppColorScheme(rawValue: colorSchemeRaw)?.colorScheme)
    }
    .modelContainer(for: [GameSnapshotEntity.self])
  }
}

