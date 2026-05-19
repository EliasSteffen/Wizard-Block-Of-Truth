import SwiftUI

/// Full-width prominent action matching `GameSessionView` primary controls (e.g. Enter Bets).
struct WizardPrimaryActionButton: View {
  let title: LocalizedStringKey
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .font(.headline)
    }
    .buttonStyle(.borderedProminent)
  }
}
