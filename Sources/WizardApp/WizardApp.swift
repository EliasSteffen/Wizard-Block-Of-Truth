import SwiftUI
import SwiftData
#if canImport(WizardDomain)
import WizardDomain
#endif

@main
struct WizardApp: App {
  @AppStorage("app.colorScheme") private var colorSchemeRaw: String = AppColorScheme.system.rawValue
  @AppStorage("app.language") private var appLanguageRaw: String = AppLanguage.system.rawValue
  @StateObject private var multiplayerCoordinator = MultiplayerCoordinator()
  @Environment(\.scenePhase) private var scenePhase

  private var appLocale: Locale {
    (AppLanguage(rawValue: appLanguageRaw) ?? .system).locale
  }

  var body: some Scene {
    WindowGroup {
      GameListView()
        .appUpdateCheck()
        .preferredColorScheme(AppColorScheme(rawValue: colorSchemeRaw)?.colorScheme)
        .environment(\.locale, appLocale)
        .environmentObject(multiplayerCoordinator)
        .onChange(of: scenePhase) { _, phase in
          // Foreground: host restarts a failed listener (same code), guests reconnect right away.
          multiplayerCoordinator.handleScenePhase(phase)
        }
    }
    .modelContainer(for: [GameSnapshotEntity.self])
  }
}

