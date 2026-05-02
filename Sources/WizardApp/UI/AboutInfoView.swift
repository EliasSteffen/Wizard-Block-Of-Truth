import SwiftUI

struct AboutInfoView: View {
  @Environment(\.dismiss) private var dismiss

  private static let wizardWikipediaURL = URL(string: "https://en.wikipedia.org/wiki/Wizard_(card_game)")!

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

          Text("UI.Info.Attribution")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      .navigationTitle("UI.Info.Title")
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
