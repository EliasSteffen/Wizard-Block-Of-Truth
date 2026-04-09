import SwiftUI

struct SettingsView: View {
  @AppStorage("app.colorScheme") private var colorSchemeRaw: String = AppColorScheme.system.rawValue

  private var selection: Binding<AppColorScheme> {
    Binding(
      get: { AppColorScheme(rawValue: colorSchemeRaw) ?? .system },
      set: { colorSchemeRaw = $0.rawValue }
    )
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Appearance", selection: selection) {
            ForEach(AppColorScheme.allCases, id: \.self) { scheme in
              Text(scheme.title).tag(scheme)
            }
          }
          .pickerStyle(.segmented)
        }
      }
#if os(iOS)
      .scrollContentBackground(.hidden)
#endif
      .navigationTitle("Settings")
    }
    .wizardBackground()
  }
}

