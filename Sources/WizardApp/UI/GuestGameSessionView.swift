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
      waitingPhaseView(game: game, guestPlayerID: guestPlayerID)
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

    return VStack(spacing: 0) {
      Spacer(minLength: 0)

      Text(titleKey)
        .font(.title.weight(.bold))
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)

      Spacer(minLength: 0)

      ValueStepperControl(
        value: $draftValue,
        range: range,
        style: .prominent
      )

      if let submitError {
        Text(submitError)
          .font(.footnote)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
          .padding(.top, 12)
      }

      Spacer(minLength: 0)
    }
    .safeAreaInset(edge: .top) {
      sessionHeader(game: game)
        .padding(.horizontal)
        .padding(.top, 8)
    }
    .safeAreaInset(edge: .bottom) {
      WizardPrimaryActionButton(title: "UI.GuestSession.Submit") {
        submitEntry(game: game, guestPlayerID: guestPlayerID, phase: phase)
      }
      .padding(.horizontal)
      .padding(.bottom, 12)
      .padding(.top, 8)
    }
  }

  private func waitingPhaseView(game: Game, guestPlayerID: UUID) -> some View {
    ScrollView {
      VStack(spacing: 16) {
        Text("UI.GuestSession.Waiting")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 2)

        compactScoreboard(game: game, guestPlayerID: guestPlayerID)
      }
      .padding(.horizontal)
      .padding(.top, 8)
      .padding(.bottom, 16)
    }
    .safeAreaInset(edge: .top) {
      sessionHeader(game: game)
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
        compactScoreboard(game: game, guestPlayerID: nil, totals: totals)
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
    }
    .safeAreaInset(edge: .top) {
      sessionHeader(game: game)
        .padding(.horizontal)
        .padding(.top, 8)
    }
  }

  private func compactScoreboard(
    game: Game,
    guestPlayerID: UUID?,
    totals: [UUID: Int]? = nil
  ) -> some View {
    let resolvedTotals = totals ?? ((try? game.totalPoints()) ?? [:])

    return VStack(spacing: 10) {
      ForEach(game.players, id: \.id) { player in
        let display = game.scoreboardDisplayValues(for: player.id)
        let isYou = player.id == guestPlayerID

        HStack(spacing: 12) {
          Text(player.name)
            .font(.headline.weight(isYou ? .bold : .semibold))
            .lineLimit(1)
          Spacer(minLength: 0)
          HStack(spacing: 14) {
            scoreColumn(
              titleKey: "UI.GameSession.Entry.Bet",
              value: display.bet
            )
            scoreColumn(
              titleKey: "UI.GameSession.Entry.Won",
              value: display.got
            )
            VStack(alignment: .trailing, spacing: 2) {
              Text("UI.GuestSession.Points")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
              Text("\(resolvedTotals[player.id, default: 0])")
                .font(.headline.weight(.semibold).monospacedDigit())
            }
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(
              isYou ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.18),
              lineWidth: isYou ? 2 : 1
            )
        }
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func scoreColumn(titleKey: LocalizedStringKey, value: Int?) -> some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(titleKey)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      if let value {
        Text("\(value)")
          .font(.subheadline.weight(.semibold).monospacedDigit())
      } else {
        Text("UI.Common.EmptyValue")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func sessionHeader(game: Game) -> some View {
    let round = game.currentRound
    let players = game.players
    let roundText = roundProgressText(for: game)
    let dealerName: String = {
      guard let dealerId = round?.dealer,
            let dealer = players.first(where: { $0.id == dealerId }) else {
        return String(localized: "UI.Common.EmptyValue", defaultValue: "—")
      }
      return dealer.name
    }()

    return VStack(alignment: .center, spacing: 8) {
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Text("UI.GameSession.Header.Dealer")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(dealerName)
          .font(.headline.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 0)
      }

      HStack(spacing: 10) {
        Spacer(minLength: 0)
        Text("UI.GameSession.Header.Round")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(verbatim: roundText)
          .font(.headline.weight(.semibold).monospacedDigit())
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
    }
  }

  private func roundProgressText(for game: Game) -> String {
    guard !game.rounds.isEmpty else {
      return String(localized: "UI.Common.EmptyValue", defaultValue: "—")
    }
    let current = min(game.currentRoundIndex + 1, game.totalRoundsPlanned)
    let total = game.totalRoundsPlanned
    return "\(current)/\(total)"
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
