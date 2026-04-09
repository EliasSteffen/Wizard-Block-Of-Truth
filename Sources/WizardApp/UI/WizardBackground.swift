import SwiftUI

enum WizardBackground {
  static var gradient: LinearGradient {
    LinearGradient(
      colors: [
        .indigo.opacity(0.25),
        .cyan.opacity(0.18),
        .purple.opacity(0.15),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }
}

extension View {
  func wizardBackground() -> some View {
    background(WizardBackground.gradient.ignoresSafeArea())
  }
}

