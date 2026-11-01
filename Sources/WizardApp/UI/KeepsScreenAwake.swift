import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Reference-counted idle-timer switch: the screen stays awake while at least one view holds it, so overlapping
/// screens (lobby → game, sheet on top) don't fight over `isIdleTimerDisabled`. No-op without UIKit (macOS).
@MainActor
enum ScreenAwakeController {
  private static var holdCount = 0

  static var isHeld: Bool { holdCount > 0 }

  static func acquire() {
    holdCount += 1
    apply()
  }

  static func release() {
    holdCount = max(0, holdCount - 1)
    apply()
  }

  private static func apply() {
#if canImport(UIKit)
    UIApplication.shared.isIdleTimerDisabled = holdCount > 0
#endif
  }
}

@MainActor
private struct KeepsScreenAwakeModifier: ViewModifier {
  let isActive: Bool

  @State private var isHolding = false

  func body(content: Content) -> some View {
    content
      .onAppear { setHolding(isActive) }
      .onDisappear { setHolding(false) }
      .onChange(of: isActive) { _, newValue in
        setHolding(newValue)
      }
  }

  private func setHolding(_ hold: Bool) {
    guard hold != isHolding else { return }
    isHolding = hold
    if hold {
      ScreenAwakeController.acquire()
    } else {
      ScreenAwakeController.release()
    }
  }
}

extension View {
  /// Keeps the screen from auto-locking while this view is visible and `active` is true (multi-phone lobby and
  /// game screens, host and guests). Restored when the view disappears or `active` turns false.
  func keepsScreenAwake(_ active: Bool) -> some View {
    modifier(KeepsScreenAwakeModifier(isActive: active))
  }
}
