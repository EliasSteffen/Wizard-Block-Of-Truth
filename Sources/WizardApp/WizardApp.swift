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

  private var appLocale: Locale {
    (AppLanguage(rawValue: appLanguageRaw) ?? .system).locale
  }

  var body: some Scene {
    WindowGroup {
      GameListView()
        .preferredColorScheme(AppColorScheme(rawValue: colorSchemeRaw)?.colorScheme)
        .environment(\.locale, appLocale)
        .environmentObject(multiplayerCoordinator)
    }
    .modelContainer(for: [GameSnapshotEntity.self])
  }
}

