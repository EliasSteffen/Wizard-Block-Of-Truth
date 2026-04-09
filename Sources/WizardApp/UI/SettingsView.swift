import SwiftUI

struct SettingsView: View {
  @AppStorage("app.colorScheme") private var colorSchemeRaw: String = AppColorScheme.system.rawValue
  @AppStorage("newGame.defaultPlayerCount") private var defaultPlayerCount: Int = 4
  @Environment(\.colorScheme) private var colorScheme

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
          VStack(alignment: .leading, spacing: 6) {
            Text("Appearance")
              .font(.headline)

            Text("Choose how Wizard looks on your device.")
              .font(.caption)
              .foregroundStyle(.secondary)

            Picker("Appearance", selection: selection) {
              ForEach(AppColorScheme.allCases, id: \.self) { scheme in
                Text(scheme.title).tag(scheme)
              }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Appearance")
          }
          .padding(.vertical, 4)
        }

        Section {
          VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 12) {
                Text("Default players")
                  .font(.subheadline.weight(.semibold))

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                  Button {
                    defaultPlayerCount = max(2, defaultPlayerCount - 1)
                  } label: {
                    pillText("–")
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel("Decrease default player count")
                  .disabled(defaultPlayerCount <= 2)

                  pillText("\(defaultPlayerCount)")
                    .accessibilityLabel("Default players: \(defaultPlayerCount)")

                  Button {
                    defaultPlayerCount = min(6, defaultPlayerCount + 1)
                  } label: {
                    pillText("+")
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel("Increase default player count")
                  .disabled(defaultPlayerCount >= 6)
                }
              }

              Text("Pre-fills the player count in the Create Game screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 4)
        } header: {
          Text("Default values for new Games")
        }
      }
#if os(iOS)
      .scrollContentBackground(.hidden)
#endif
      .navigationTitle("Settings")
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

