import SwiftUI
#if canImport(WizardDomain)
import WizardDomain
#endif

struct GuestGameSessionView: View {
  @ObservedObject var store: MultiplayerGameStore

  @State private var betDraft: Int = 0
  @State private var gotDraft: Int = 0

  private var guestPlayerID: UUID? {
    if case .guest(let playerId) = store.role { return playerId }
    return nil
  }

  var body: some View {
    Group {
      if let game = store.currentGame {
        content(game: game)
      } else {
        ProgressView()
      }
    }
    .navigationTitle(store.currentGame?.name ?? String(localized: "UI.GameSession.NavigationFallback", defaultValue: "Game"))
    .onChange(of: store.currentGame?.currentRoundIndex) { _, _ in
      seedDraftsFromCurrentRound()
    }
    .onAppear { seedDraftsFromCurrentRound() }
  }

  private func content(game: Game) -> some View {
    let totals = (try? game.totalPoints()) ?? [:]
    let round = game.currentRound

    return List {
      Section("Scoreboard") {
        ForEach(game.players, id: \.id) { player in
          let entry = round?.entries[player.id]
          HStack {
            Text(player.name)
              .font(.headline)
            Spacer()
            Text("Bet: \(entry?.bet.map(String.init) ?? "—")")
            Text("Won: \(entry?.got.map(String.init) ?? "—")")
            Text("Pts: \(totals[player.id, default: 0])")
              .monospacedDigit()
          }
        }
      }

      if let round, let guestPlayerID {
        Section("Your Entry") {
          Stepper("Bet: \(betDraft)", value: $betDraft, in: 0...round.handSize)
          Button("Submit Bet") {
            store.apply(.submitBet(playerId: guestPlayerID, roundIndex: game.currentRoundIndex, bet: betDraft))
          }

          Stepper("Won Tricks: \(gotDraft)", value: $gotDraft, in: 0...round.handSize)
          Button("Submit Won Tricks") {
            store.apply(.submitGot(playerId: guestPlayerID, roundIndex: game.currentRoundIndex, got: gotDraft))
          }
        }
      }
    }
  }

  private func seedDraftsFromCurrentRound() {
    guard let game = store.currentGame,
          let round = game.currentRound,
          let guestPlayerID else { return }
    betDraft = round.entries[guestPlayerID]?.bet ?? 0
    gotDraft = round.entries[guestPlayerID]?.got ?? 0
  }
}
