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
#if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
#endif
    .wizardBackground()
  }

  private func waitingContent(game: Game) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("UI.GuestWaiting.Message")
          .font(.subheadline)
          .foregroundStyle(.secondary)

        VStack(spacing: 10) {
          ForEach(game.players, id: \.id) { player in
            HStack {
              Text(player.name)
                .font(.headline.weight(player.id == guestPlayerID ? .bold : .semibold))
              Spacer()
              if player.id == guestPlayerID {
                Text("UI.GuestWaiting.You")
                  .font(.subheadline.weight(.semibold))
                  .foregroundStyle(.green)
              }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }
          }
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
    }
  }

  private var guestPlayerID: UUID? {
    if case .guest(let playerId) = store.role { return playerId }
    return nil
  }
}
