import SwiftUI
#if canImport(WizardDomain)
import WizardDomain
#endif

struct GuestWaitingView: View {
  @ObservedObject var store: MultiplayerGameStore

  var body: some View {
    Group {
      if let game = store.currentGame {
        waitingContent(game: game)
      } else {
        ProgressView()
      }
    }
    .navigationTitle(store.currentGame?.name ?? String(localized: "UI.GameSession.NavigationFallback", defaultValue: "Game"))
  }

  private func waitingContent(game: Game) -> some View {
    List {
      Section {
        Text("UI.GuestWaiting.Message")
          .foregroundStyle(.secondary)
      }

      Section("UI.GuestWaiting.Players.Header") {
        ForEach(game.players, id: \.id) { player in
          HStack {
            Text(player.name)
            Spacer()
            if player.id == guestPlayerID {
              Text("UI.GuestWaiting.You")
                .foregroundStyle(.green)
            }
          }
        }
      }
    }
  }

  private var guestPlayerID: UUID? {
    if case .guest(let playerId) = store.role { return playerId }
    return nil
  }
}
