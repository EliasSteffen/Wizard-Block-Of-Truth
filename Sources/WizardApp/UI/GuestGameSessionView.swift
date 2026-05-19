import SwiftUI
#if canImport(WizardDomain)
import WizardDomain
#endif

struct GuestGameSessionView: View {
  @ObservedObject var store: MultiplayerGameStore

  @State private var draftValue: Int = 0
  @State private var submitError: String?

  private var guestPlayerID: UUID? {
    if case .guest(let playerId) = store.role { return playerId }
    return nil
  }

  var body: some View {
    Group {
      if let game = store.currentGame, let guestPlayerID {
        content(game: game, guestPlayerID: guestPlayerID)
      } else {
        ProgressView()
      }
    }
    .navigationTitle(store.currentGame?.name ?? String(localized: "UI.GameSession.NavigationFallback", defaultValue: "Game"))
#if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
#endif
    .wizardBackground()
    .onChange(of: store.currentGame?.currentRoundIndex) { _, _ in
      seedDraftFromCurrentRound()
    }
    .onAppear { seedDraftFromCurrentRound() }
  }

  @ViewBuilder
  private func content(game: Game, guestPlayerID: UUID) -> some View {
    let phase = GuestEntryPhaseResolver.phase(game: game, guestPlayerID: guestPlayerID)

    switch phase {
    case .enterBet, .enterGot:
      entryPhaseView(game: game, guestPlayerID: guestPlayerID, phase: phase)
    case .waiting:
      waitingPhaseView(game: game)
    case .gameFinished:
      finishedPhaseView(game: game)
    }
  }

  private func entryPhaseView(game: Game, guestPlayerID: UUID, phase: GuestEntryPhase) -> some View {
    let round = game.currentRound!
    let range = 0...round.handSize
    let titleKey: LocalizedStringKey = phase == .enterBet
      ? "UI.GuestSession.EnterBet"
      : "UI.GuestSession.EnterWonTricks"
    let totals = (try? game.totalPoints()) ?? [:]

    return ScrollView {
      GameSessionScoreboardView(game: game, totals: totals, options: .readOnly)
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
    .safeAreaInset(edge: .top) {
      GameSessionHeaderView(game: game)
        .padding(.horizontal)
        .padding(.top, 8)
    }
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: 10) {
        Text(titleKey)
          .font(.title3.weight(.bold))
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)

        ValueStepperControl(
          value: $draftValue,
          range: range,
          style: .compact
        )

        if let submitError {
          Text(submitError)
            .font(.footnote)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }

        WizardPrimaryActionButton(title: "UI.GuestSession.Submit") {
          submitEntry(game: game, guestPlayerID: guestPlayerID, phase: phase)
        }
      }
      .padding(.horizontal)
      .padding(.top, 8)
      .padding(.bottom, 12)
    }
  }

  private func waitingPhaseView(game: Game) -> some View {
    let totals = (try? game.totalPoints()) ?? [:]

    return ScrollView {
      VStack(spacing: 16) {
        Text("UI.GuestSession.Waiting")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 2)

        GameSessionScoreboardView(game: game, totals: totals, options: .readOnly)
      }
      .padding(.horizontal)
      .padding(.top, 8)
      .padding(.bottom, 16)
    }
    .safeAreaInset(edge: .top) {
      GameSessionHeaderView(game: game)
        .padding(.horizontal)
        .padding(.top, 8)
    }
  }

  private func finishedPhaseView(game: Game) -> some View {
    let totals = (try? game.totalPoints()) ?? [:]

    return ScrollView {
      VStack(spacing: 16) {
        Text("UI.GameSession.FinalScoreboard.Title")
          .font(.title3.weight(.bold))
          .frame(maxWidth: .infinity, alignment: .leading)

        GameSessionScoreboardView(game: game, totals: totals, options: .readOnly)
      }
      .padding(.horizontal)
      .padding(.top, 8)
      .padding(.bottom, 16)
    }
    .safeAreaInset(edge: .top) {
      GameSessionHeaderView(game: game)
        .padding(.horizontal)
        .padding(.top, 8)
    }
  }

  private func seedDraftFromCurrentRound() {
    guard let game = store.currentGame,
          let round = game.currentRound,
          let guestPlayerID else { return }
    submitError = nil
    let phase = GuestEntryPhaseResolver.phase(game: game, guestPlayerID: guestPlayerID)
    switch phase {
    case .enterBet:
      draftValue = round.entries[guestPlayerID]?.bet ?? 0
    case .enterGot:
      draftValue = round.entries[guestPlayerID]?.got ?? 0
    case .waiting, .gameFinished:
      break
    }
  }

  private func submitEntry(game: Game, guestPlayerID: UUID, phase: GuestEntryPhase) {
    submitError = nil
    let command: GameCommand
    switch phase {
    case .enterBet:
      command = .submitBet(
        playerId: guestPlayerID,
        roundIndex: game.currentRoundIndex,
        bet: draftValue
      )
    case .enterGot:
      command = .submitGot(
        playerId: guestPlayerID,
        roundIndex: game.currentRoundIndex,
        got: draftValue
      )
    case .waiting, .gameFinished:
      return
    }
    store.apply(command)
    if let err = store.lastError {
      submitError = AppErrorMessage.presentableMessage(
        for: err,
        languageCode: AppLanguage.catalogLookupLanguageCode
      )
    }
  }
}
