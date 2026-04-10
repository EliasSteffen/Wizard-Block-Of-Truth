import SwiftUI

struct SettingsView: View {
  @AppStorage("app.colorScheme") private var colorSchemeRaw: String = AppColorScheme.system.rawValue
  @AppStorage("app.language") private var appLanguageRaw: String = AppLanguage.system.rawValue
  @AppStorage("newGame.defaultPlayerCount") private var defaultPlayerCount: Int = 4
  @Environment(\.colorScheme) private var colorScheme

  private var selection: Binding<AppColorScheme> {
    Binding(
      get: { AppColorScheme(rawValue: colorSchemeRaw) ?? .system },
      set: { colorSchemeRaw = $0.rawValue }
    )
  }

  private var languageSelection: Binding<AppLanguage> {
    Binding(
      get: { AppLanguage(rawValue: appLanguageRaw) ?? .system },
      set: { appLanguageRaw = $0.rawValue }
    )
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          VStack(alignment: .leading, spacing: 6) {
            Text("UI.Settings.Appearance.Title")
              .font(.headline)

            Text("UI.Settings.Appearance.Description")
              .font(.caption)
              .foregroundStyle(.secondary)

            Picker("UI.Settings.Appearance.Title", selection: selection) {
              ForEach(AppColorScheme.allCases, id: \.self) { scheme in
                Text(LocalizedStringKey(scheme.titleKey)).tag(scheme)
              }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("UI.Settings.Appearance.Title")
          }
          .padding(.vertical, 4)
        }

        Section {
          VStack(alignment: .leading, spacing: 6) {
            Text("UI.Settings.Language.Title")
              .font(.headline)

            Text("UI.Settings.Language.Description")
              .font(.caption)
              .foregroundStyle(.secondary)

            Picker("UI.Settings.Language.Title", selection: languageSelection) {
              ForEach(AppLanguage.allCases, id: \.self) { language in
                Text(LocalizedStringKey(language.titleKey)).tag(language)
              }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("UI.Settings.Language.Title")
          }
          .padding(.vertical, 4)
        }

        Section {
          VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 12) {
                Text("UI.Settings.DefaultPlayers.Title")
                  .font(.subheadline.weight(.semibold))

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                  Button {
                    defaultPlayerCount = max(2, defaultPlayerCount - 1)
                  } label: {
                    pillText(String(localized: "UI.Common.Symbol.EnDash", defaultValue: "–"))
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel("UI.Settings.DefaultPlayers.Decrease")
                  .disabled(defaultPlayerCount <= 2)

                  pillText("\(defaultPlayerCount)")
                    .accessibilityLabel(
                      String(
                        localized: "UI.Settings.DefaultPlayers.Current",
                        defaultValue: "Default players: \(defaultPlayerCount)"
                      )
                    )

                  Button {
                    defaultPlayerCount = min(6, defaultPlayerCount + 1)
                  } label: {
                    pillText(String(localized: "UI.Common.Symbol.Plus", defaultValue: "+"))
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel("UI.Settings.DefaultPlayers.Increase")
                  .disabled(defaultPlayerCount >= 6)
                }
              }

              Text("UI.Settings.DefaultPlayers.Description")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 4)
        } header: {
          Text("UI.Settings.DefaultValues.Header")
        }
      }
#if os(iOS)
      .scrollContentBackground(.hidden)
#endif
      .navigationTitle("UI.Settings.NavigationTitle")
    }
    .wizardBackground()
  }

  private func pillText(_ text: String) -> some View {
    let fg = colorScheme == .dark ? Color.white : Color.black
    let bg = colorScheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.65)
    return Text(text)
      .font(.headline)
      .foregroundStyle(fg)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(bg, in: Capsule())
  }
}

