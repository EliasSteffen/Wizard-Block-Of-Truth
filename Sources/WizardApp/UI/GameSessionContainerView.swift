import SwiftUI

struct GameSessionContainerView: View {
  let gameId: UUID

  @EnvironmentObject private var multiplayerCoordinator: MultiplayerCoordinator

  var body: some View {
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
