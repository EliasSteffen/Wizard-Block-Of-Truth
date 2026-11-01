import SwiftUI

extension View {
  /// Checks the App Store for a newer version on appear and whenever the scene becomes active (throttled by
  /// `AppUpdateChecker`), and offers a dismissible "Update available" alert.
  @MainActor
  func appUpdateCheck() -> some View {
    modifier(AppUpdateCheckModifier())
  }
}

private struct AppUpdateCheckModifier: ViewModifier {
  @StateObject private var checker = AppUpdateChecker()
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL

  func body(content: Content) -> some View {
    content
      .task {
        await checker.checkIfNeeded()
      }
      .onChange(of: scenePhase) { _, newPhase in
        guard newPhase == .active else { return }
        Task { await checker.checkIfNeeded() }
      }
      .alert(
        "UI.UpdateCheck.Alert.Title",
        isPresented: Binding(
          get: { checker.availableUpdate != nil },
          set: { isPresented in if !isPresented { checker.dismissUpdate() } }
        ),
        presenting: checker.availableUpdate
      ) { update in
        Button("UI.UpdateCheck.Alert.Update") {
          openURL(update.storeURL)
          checker.dismissUpdate()
        }
        Button("UI.UpdateCheck.Alert.Skip") {
          checker.skipVersion(of: update)
        }
        Button("UI.UpdateCheck.Alert.Later", role: .cancel) {
          checker.dismissUpdate()
        }
      } message: { update in
        Text(
          AppLocalization.format(
            "UI.UpdateCheck.Alert.Message",
            languageCode: AppLanguage.catalogLookupLanguageCode,
            fallback: "Version %@ of Wizard Block of Truth is available in the App Store.",
            update.version
          )
        )
      }
  }
}
