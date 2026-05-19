import SwiftUI

struct GameSessionContainerView: View {
  let gameId: UUID

  @EnvironmentObject private var multiplayerCoordinator: MultiplayerCoordinator
  @State private var multiplayerSheetMode: GameSessionMultiplayerSheetMode?

  private var isGuestSession: Bool {
    guard let store = multiplayerCoordinator.store(for: gameId) else { return false }
    if case .guest = store.role { return true }
    return false
  }

  private var isHosting: Bool {
    multiplayerCoordinator.isHosting(gameID: gameId)
  }

  var body: some View {
    sessionContent
      .gameSessionHostMultiplayerToolbar(
        gameID: gameId,
        isGuestSession: isGuestSession,
        isHosting: isHosting,
        sheetMode: $multiplayerSheetMode
      )
  }

  @ViewBuilder
  private var sessionContent: some View {
    if let multiplayerStore = multiplayerCoordinator.store(for: gameId) {
      switch multiplayerStore.role {
      case .guest:
        if multiplayerStore.currentGame?.hasStarted == true {
          GuestGameSessionView(store: multiplayerStore)
        } else {
          GuestWaitingView(store: multiplayerStore)
        }
      case .host:
        if multiplayerStore.currentGame?.hasStarted == true {
          GameSessionView(gameId: gameId)
        } else {
          MultiplayerLobbyView(gameID: gameId, onGameStarted: {})
        }
      }
    } else if multiplayerCoordinator.hostLobbyState?.gameID == gameId {
      MultiplayerLobbyView(gameID: gameId, onGameStarted: {})
    } else {
      GameSessionView(gameId: gameId)
    }
  }
}
