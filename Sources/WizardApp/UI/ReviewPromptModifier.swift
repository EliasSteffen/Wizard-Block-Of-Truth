import SwiftUI
import StoreKit

extension View {
  /// Asks for an App Store rating shortly after the shown game switches from "in progress" to "finished"
  /// (see `ReviewPromptPolicy`). Pass `nil` for `isFinished` while the game is not loaded yet, so opening an
  /// already finished game never counts as finishing it.
  @MainActor
  func reviewPromptOnGameFinish(gameId: UUID?, isFinished: Bool?) -> some View {
    modifier(ReviewPromptOnGameFinishModifier(state: .init(gameId: gameId, isFinished: isFinished)))
  }
}

private struct ReviewPromptOnGameFinishModifier: ViewModifier {
  struct ObservedState: Equatable {
    let gameId: UUID?
    let isFinished: Bool?
  }

  let state: ObservedState

  @Environment(\.requestReview) private var requestReview

  func body(content: Content) -> some View {
    content
      .onChange(of: state) { oldState, newState in
        guard let gameId = newState.gameId,
              oldState.gameId == gameId,
              oldState.isFinished == false,
              newState.isFinished == true
        else { return }
        guard ReviewPromptPolicy().recordFinishedGame(gameId) else { return }

        // Let the final scoreboard settle (and any sheet finish dismissing) before the system prompt.
        let reviewAction = requestReview
        Task { @MainActor in
          try? await Task.sleep(for: ReviewPromptPolicy.requestDelay)
          reviewAction()
        }
      }
  }
}
