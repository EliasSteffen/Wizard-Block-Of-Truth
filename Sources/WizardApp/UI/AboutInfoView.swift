import SwiftUI

struct AboutInfoView: View {
  @Environment(\.dismiss) private var dismiss
  @AppStorage("app.language") private var appLanguageRaw: String = AppLanguage.system.rawValue

  private static let wizardWikipediaURL = URL(string: "https://en.wikipedia.org/wiki/Wizard_(card_game)")!
  private static let releaseNotesURL = URL(
    string: "https://eliassteffen.github.io/Wizard-Block-Of-Truth/release-notes/"
  )!

  private var currentLanguageCode: String? {
    let selected = AppLanguage(rawValue: appLanguageRaw) ?? .system
    return selected == .system ? nil : selected.rawValue
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("UI.Info.Body")
            .font(.body)
            .foregroundStyle(.primary)

          Link(destination: Self.wizardWikipediaURL) {
            Text("UI.Info.LinkTitle")
          }
          .font(.body.weight(.medium))

          Link(destination: Self.releaseNotesURL) {
            Text("UI.Info.ReleaseNotes.LinkTitle")
          }
          .font(.body.weight(.medium))

          Text("UI.Info.Attribution")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      .navigationTitle(
        AppLocalization.string("UI.Info.Title", languageCode: currentLanguageCode, fallback: "About")
      )
#if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
#endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("UI.Common.Done") {
            dismiss()
          }
        }
      }
    }
  }
}
