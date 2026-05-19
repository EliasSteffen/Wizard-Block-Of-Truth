import SwiftUI
import SwiftData
#if canImport(Combine)
import Combine
#endif
#if canImport(WizardDomain)
import WizardDomain
#endif

private struct BetEditorPlayerItem: Identifiable {
  let playerId: UUID
  var id: UUID { playerId }
}

struct GameSessionView: View {
  let gameId: UUID

  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject private var multiplayerCoordinator: MultiplayerCoordinator
  @StateObject private var storeHolder = StoreHolder()

  @State private var showingBets = false
  @State private var betEditorPlayerItem: BetEditorPlayerItem?
  @State private var showingGot = false
  @State private var showingCloudCard = false
  @State private var playerHistorySheetItem: PlayerHistorySheetItem?
  @State private var bombPlayedThisRound: Bool = false

  @State private var betsDetent: PresentationDetent = Self.defaultEntrySheetDetent
  @State private var gotDetent: PresentationDetent = Self.defaultEntrySheetDetent

  private static var defaultEntrySheetDetent: PresentationDetent {
#if os(iOS)
    return .fraction(0.75)
#else
    return .medium
#endif
  }

  private static var entrySheetDetents: Set<PresentationDetent> {
#if os(iOS)
    return [.fraction(0.75), .large]
#else
    return [.medium, .large]
#endif
  }

  var body: some View {
    Group {
      if let game = storeHolder.store?.currentGame {
        content(game: game)
      } else if storeHolder.store?.didAttemptLoad == true {
        ContentUnavailableView(
          "UI.GameSession.OpenError.Title",
          systemImage: "exclamationmark.triangle",
          description: Text(gameSessionOpenErrorDescription())
        )
        .overlay(alignment: .bottom) {
          Button("UI.Common.Retry") { loadIfNeeded(force: true) }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 16)
        }
      } else {
        ProgressView()
          .task { loadIfNeeded() }
      }
    }
    .navigationTitle(storeHolder.store?.currentGame?.name ?? String(localized: "UI.GameSession.NavigationFallback", defaultValue: "Game"))
#if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
#endif
    .onAppear { loadIfNeeded() }
    .alert("UI.Common.Error", isPresented: Binding(
      get: { shouldPresentGlobalErrorAlert },
      set: { newValue in if !newValue { storeHolder.store?.lastError = nil } }
    )) {
      Button("UI.Common.OK", role: .cancel) { storeHolder.store?.lastError = nil }
    } message: {
      Text(
        AppErrorMessage.presentableMessage(
          for: storeHolder.store?.lastError,
          languageCode: AppLanguage.catalogLookupLanguageCode
        )
      )
    }
    .wizardBackground()
    .onChange(of: multiplayerCoordinator.hostLobbyState?.gameID) { _, _ in
      attachMultiplayerStoreIfNeeded()
    }
  }

  private func attachMultiplayerStoreIfNeeded() {
    guard let multiplayerStore = multiplayerCoordinator.store(for: gameId) else { return }
    storeHolder.store = multiplayerStore
  }

  private var shouldPresentGlobalErrorAlert: Bool {
    // Avoid presenting an alert on top of (or during dismissal of) a sheet.
    if showingBets || betEditorPlayerItem != nil || showingGot || showingCloudCard || playerHistorySheetItem != nil {
      return false
    }
    guard storeHolder.store?.currentGame != nil else { return false }
    guard let err = storeHolder.store?.lastError else { return false }

#if canImport(WizardDomain)
    // Constraint failures are shown inline in `EntrySheetView`; don't also show a global alert.
    if let domainErr = err as? DomainError, case .constraintNotSatisfied = domainErr {
      return false
    }
#endif
    return true
  }

  private func gameSessionOpenErrorDescription() -> String {
    let lang = AppLanguage.catalogLookupLanguageCode
    if let err = storeHolder.store?.lastError {
      return AppErrorMessage.presentableMessage(for: err, languageCode: lang)
    }
    return AppLocalization.string("UI.GameSession.OpenError.Unknown", languageCode: lang, fallback: "Unknown error.")
  }

  private func storeNotReadyNSError() -> NSError {
    let lang = AppLanguage.catalogLookupLanguageCode
    return NSError(
      domain: "WizardApp",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: AppLocalization.string(
          "Error.Store.NotReady",
          languageCode: lang,
          fallback: "Store not ready."
        ),
      ]
    )
  }

  @ViewBuilder
  private func content(game: Game) -> some View {
    let isFinished = isGameFinished(game)
    let totals = (try? game.totalPoints()) ?? [:]

    ScrollView {
      VStack(spacing: 16) {
        Group {
          if isFinished {
            finalScoreboard(game: game, totals: totals)
          } else {
            GameSessionScoreboardView(game: game, totals: totals, options: scoreboardOptions(game: game))
          }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
      }
    }
    .safeAreaInset(edge: .top) {
      GameSessionHeaderView(game: game)
        .padding(.horizontal)
        .padding(.top, 8)
    }
    // Mirror `GameListView`: the bottom control overlays the content, so the list is "under" it.
    .safeAreaInset(edge: .bottom) {
      if !isFinished {
        primaryAction(game: game)
          .padding(.horizontal)
          .padding(.bottom, 12)
          .padding(.top, 8)
          .background(Color.clear)
      }
    }
    .sheet(isPresented: $showingBets) {
      if let round = game.currentRound {
        EntrySheetView(
          title: "UI.Button.EnterBets",
          handSize: round.handSize,
          players: game.playersInBettingOrder(for: round),
          currentValues: game.rounds[game.currentRoundIndex].entries.mapValues { $0.bet },
          valueLabel: String(localized: "UI.GameSession.Entry.Bet", defaultValue: "Bet"),
          accessory: nil,
          sumValidation: betSumNotEqualHandSizeSheetValidation(game: game, round: round),
          showPositiveSumState: true,
          allowedRange: { playerId, edited in
            betAllowedRange(game: game, playerId: playerId, editedBets: edited)
          },
          isPlayerDisabled: nil,
          additionalSumForValidation: nil,
          onSubmit: { values in
            guard let store = storeHolder.store else { return storeNotReadyNSError() }
            let cmds: [GameCommand] = values.map { (pid, bet) in
              .submitBet(playerId: pid, roundIndex: game.currentRoundIndex, bet: bet)
            }
            return store.applyBatch(cmds) { updated in
              try updated.rounds[updated.currentRoundIndex].validateConstraints(
                players: updated.players,
                gameConstraints: updated.gameConstraints,
                roundConstraints: [.gotSumEqualsHandSize]
              )
            }
          },
          liveBetsProgressRoundNumber: GameSessionScoreboardMetrics.activeRoundNumber(for: game)
        )
        .presentationDetents(Self.entrySheetDetents, selection: $betsDetent)
      }
    }
    .sheet(item: $betEditorPlayerItem) { item in
      if let round = game.currentRound,
         let player = game.players.first(where: { $0.id == item.playerId }) {
        let othersBetSum = sumOfOtherPlayersBets(round: round, excludingPlayerId: item.playerId)
        EntrySheetView(
          title: "UI.GameSession.EditSingleBet.Title",
          handSize: round.handSize,
          players: [player],
          currentValues: [item.playerId: round.entries[item.playerId]?.bet],
          valueLabel: String(localized: "UI.GameSession.Entry.Bet", defaultValue: "Bet"),
          accessory: nil,
          sumValidation: betSumNotEqualHandSizeSheetValidation(game: game, round: round),
          showPositiveSumState: true,
          allowedRange: { playerId, edited in
            var fullBets: [UUID: Int] = [:]
            for pl in game.players {
              if pl.id == item.playerId {
                fullBets[pl.id] = edited[pl.id] ?? round.entries[pl.id]?.bet ?? 0
              } else {
                fullBets[pl.id] = round.entries[pl.id]?.bet ?? 0
              }
            }
            return betAllowedRange(game: game, playerId: playerId, editedBets: fullBets)
          },
          isPlayerDisabled: nil,
          additionalSumForValidation: othersBetSum,
          onSubmit: { values in
            guard let store = storeHolder.store else { return storeNotReadyNSError() }
            guard let newBet = values[item.playerId] else {
              let lang = AppLanguage.catalogLookupLanguageCode
              return NSError(
                domain: "WizardApp",
                code: 4,
                userInfo: [
                  NSLocalizedDescriptionKey: AppLocalization.string(
                    "Error.BetEditor.MissingValue",
                    languageCode: lang,
                    fallback: "Missing bet value."
                  ),
                ]
              )
            }
            let cmd = GameCommand.submitBet(
              playerId: item.playerId,
              roundIndex: game.currentRoundIndex,
              bet: newBet
            )
            return store.applyBatch([cmd]) { updated in
              try updated.rounds[updated.currentRoundIndex].validateConstraints(
                players: updated.players,
                gameConstraints: updated.gameConstraints,
                roundConstraints: [.gotSumEqualsHandSize]
              )
            }
          },
          liveBetsProgressRoundNumber: GameSessionScoreboardMetrics.activeRoundNumber(for: game)
        )
        .presentationDetents(Self.entrySheetDetents, selection: $betsDetent)
      }
    }
    .sheet(isPresented: $showingGot) {
      if let round = game.currentRound {
        let expectedSum = expectedWonTricksTotal(game: game, bombPlayed: bombPlayedThisRound)
        EntrySheetView(
          title: "UI.Button.EnterWonTricks",
          handSize: round.handSize,
          players: game.playersInBettingOrder(for: round),
          currentValues: game.rounds[game.currentRoundIndex].entries.mapValues { $0.got },
          valueLabel: String(localized: "UI.GameSession.Entry.Won", defaultValue: "Won"),
          accessory: game.playWithSpecialCards ? AnyView(
            Toggle(isOn: $bombPlayedThisRound) {
              VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(Constraint.RoundConstraint.gotSumEqualsHandSizeMinusOne.titleKey))
                  .font(.subheadline.weight(.semibold))
              }
            }
          ) : nil,
          sumValidation: .init(
            expectedSum: expectedSum,
            rule: .equals,
            failureMessageKey: bombPlayedThisRound
              ? Constraint.RoundConstraint.gotSumEqualsHandSizeMinusOne.showOnFailureKey
              : Constraint.RoundConstraint.gotSumEqualsHandSize.showOnFailureKey,
            failureMessageFallback: bombPlayedThisRound
              ? Constraint.RoundConstraint.gotSumEqualsHandSizeMinusOne.showOnFailure
              : Constraint.RoundConstraint.gotSumEqualsHandSize.showOnFailure
          ),
          showPositiveSumState: false,
          allowedRange: { playerId, editedValues in
            wonTricksAllowedRange(
              game: game,
              playerId: playerId,
              editedValues: editedValues,
              bombPlayed: bombPlayedThisRound
            )
          },
          isPlayerDisabled: nil,
          additionalSumForValidation: nil,
          onSubmit: { values in
            guard let store = storeHolder.store else { return storeNotReadyNSError() }
            let roundConstraints =
              constraintsForFinalize(game: game, bombPlayed: bombPlayedThisRound) ?? [.gotSumEqualsHandSize]
            let cmds: [GameCommand] = values.map { (pid, got) in
              .submitGot(playerId: pid, roundIndex: game.currentRoundIndex, got: got)
            }
            return store.applyBatch(cmds) { updated in
              try updated.rounds[updated.currentRoundIndex].validateConstraints(
                players: updated.players,
                gameConstraints: updated.gameConstraints,
                roundConstraints: roundConstraints
              )
            }
          }
        )
        .presentationDetents(Self.entrySheetDetents, selection: $gotDetent)
      }
    }
    .sheet(isPresented: $showingCloudCard) {
      if let round = game.currentRound {
        EntrySheetView(
          title: "UI.Button.EnterCloudCard",
          handSize: round.handSize,
          players: game.playersInBettingOrder(for: round),
          currentValues: game.rounds[game.currentRoundIndex].entries.mapValues { $0.bet },
          valueLabel: String(localized: "UI.GameSession.Entry.Bet", defaultValue: "Bet"),
          accessory: nil,
          sumValidation: nil,
          showPositiveSumState: false,
          allowedRange: { playerId, editedValues in
            cloudCardAllowedRange(game: game, playerId: playerId, editedBets: editedValues)
          },
          isPlayerDisabled: { playerId, editedValues in
            isCloudCardPlayerLocked(game: game, playerId: playerId, editedBets: editedValues)
          },
          additionalSumForValidation: nil,
          onSubmit: { values in
            guard let store = storeHolder.store else { return storeNotReadyNSError() }
            if let validationError = validateCloudCardAdjustment(game: game, submittedBets: values) {
              return validationError
            }
            var cmds: [GameCommand] = values.map { (pid, bet) in
              .submitBet(playerId: pid, roundIndex: game.currentRoundIndex, bet: bet)
            }
            cmds.append(.markCloudCardResolved(roundIndex: game.currentRoundIndex))
            return store.applyBatch(cmds)
          }
        )
        .presentationDetents(Self.entrySheetDetents, selection: $gotDetent)
      }
    }
    .sheet(item: $playerHistorySheetItem) { item in
      PlayerRoundHistorySheet(game: game, playerId: item.id)
    }
  }

  @ViewBuilder
  private func finalScoreboard(game: Game, totals: [UUID: Int]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(String(localized: "UI.GameSession.FinalScoreboard.Title", defaultValue: "Final Scoreboard"))
        .font(.title3.weight(.bold))
        .padding(.horizontal, 2)

      GameSessionScoreboardView(game: game, totals: totals, options: scoreboardOptions(game: game))
    }
  }

  private func isGameFinished(_ game: Game) -> Bool {
    guard !game.rounds.isEmpty else { return false }
    guard game.rounds.count >= game.totalRoundsPlanned else { return false }
    return game.rounds.last?.isFinalized == true
  }

  private func constraintsForFinalize(game: Game?, bombPlayed: Bool) -> [Constraint.RoundConstraint]? {
    guard let game else { return nil }
    if !game.playWithSpecialCards {
      return [.gotSumEqualsHandSize]
    }
    return [bombPlayed ? .gotSumEqualsHandSizeMinusOne : .gotSumEqualsHandSize]
  }

  private func expectedWonTricksTotal(game: Game, bombPlayed: Bool) -> Int {
    let handSize = game.currentRound?.handSize ?? 0
    if game.playWithSpecialCards && bombPlayed {
      return max(0, handSize - 1)
    }
    return handSize
  }

  /// Live sum check for "bets may not add up to hand size" only **before** the cloud step; after Wolke, any total is allowed in the UI.
  private func betSumNotEqualHandSizeSheetValidation(
    game: Game,
    round: Round
  ) -> EntrySheetView.SumValidation? {
    guard game.gameConstraints.contains(.betSumNotEqualHandSize),
          !round.cloudCardResolved else { return nil }
    return .init(
      expectedSum: round.handSize,
      rule: .notEquals,
      failureMessageKey: Constraint.GameConstraint.betSumNotEqualHandSize.showOnFailureKey,
      failureMessageFallback: Constraint.GameConstraint.betSumNotEqualHandSize.showOnFailure
    )
  }

  /// Full `0...handSize` so every bid can be entered; invalid totals (e.g. sum = hand size when disallowed) surface via the sum bar and Done in `EntrySheetView`.
  private func betAllowedRange(
    game: Game,
    playerId _: UUID,
    editedBets _: [UUID: Int]
  ) -> ClosedRange<Int> {
    let handSize = game.currentRound?.handSize ?? 0
    return 0...max(0, handSize)
  }

  private func wonTricksAllowedRange(
    game: Game,
    playerId: UUID,
    editedValues: [UUID: Int],
    bombPlayed: Bool
  ) -> ClosedRange<Int> {
    let handSize = game.currentRound?.handSize ?? 0
    let expectedTotal = expectedWonTricksTotal(game: game, bombPlayed: bombPlayed)
    let otherPlayersSum = editedValues.reduce(into: 0) { partialResult, entry in
      guard entry.key != playerId else { return }
      partialResult += entry.value
    }
    let maxAllowed = min(handSize, max(0, expectedTotal - otherPlayersSum))
    return 0...maxAllowed
  }


  private func scoreboardOptions(game: Game) -> GameSessionScoreboardOptions {
    guard canOpenBetsFromScoreboard(game: game) else { return .readOnly }
    return GameSessionScoreboardOptions(
      onPlayerCardTap: { playerHistorySheetItem = PlayerHistorySheetItem(id: $0) },
      onBetChipTap: { openBetChipTapped(game: game, playerId: $0) },
      onWonChipTap: { openWonTricksSheetFromScoreboard(game: game) }
    )
  }

  /// Scoreboard bet chip: one-player bet editor, or full bets sheet when the round does not exist yet.
  private func openBetChipTapped(game: Game, playerId: UUID) {
    guard !isGameFinished(game) else { return }
    if game.currentRound == nil {
      startAndShowBetsIfNeeded(game: game)
      return
    }
    if let round = game.currentRound, !round.isFinalized {
      betEditorPlayerItem = BetEditorPlayerItem(playerId: playerId)
    }
  }

  private func sumOfOtherPlayersBets(round: Round, excludingPlayerId: UUID) -> Int {
    round.entries.reduce(into: 0) { partial, entry in
      guard entry.key != excludingPlayerId else { return }
      partial += entry.value.bet ?? 0
    }
  }

  private func canOpenBetsFromScoreboard(game: Game) -> Bool {
    if isGameFinished(game) { return false }
    if game.currentRound == nil { return true }
    if let round = game.currentRound, !round.isFinalized { return true }
    return false
  }

  /// Opens the won-tricks sheet, or the full bets sheet if bidding is not complete. Does not route to the cloud sheet (use the bottom bar for Wolke).
  private func openWonTricksSheetFromScoreboard(game: Game) {
    guard !isGameFinished(game) else { return }
    if game.currentRound == nil {
      startAndShowBetsIfNeeded(game: game)
      return
    }
    guard let round = game.currentRound, !round.isFinalized else { return }

    let allBetsPresent = round.entries.values.allSatisfy { $0.bet != nil }
    if !allBetsPresent {
      showingBets = true
      return
    }
    showingGot = true
  }

  private func primaryAction(game: Game) -> some View {
    let round = game.currentRound
    let entries = round?.entries ?? [:]

    let allBetsPresent = entries.values.allSatisfy { $0.bet != nil }
    let allGotPresent = entries.values.allSatisfy { $0.got != nil }

    if round == nil {
      return AnyView(
        Button(action: { startAndShowBetsIfNeeded(game: game) }) {
          Text("UI.Button.EnterBets")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .font(.headline)
        }
        .buttonStyle(.borderedProminent)
      )
    } else if !allBetsPresent {
      return AnyView(
        Button(action: { showingBets = true }) {
          Text("UI.Button.EnterBets")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .font(.headline)
        }
        .buttonStyle(.borderedProminent)
      )
    } else if !allGotPresent {
      return AnyView(
        HStack(spacing: 10) {
          if game.playWithSpecialCards, let r = round, !r.cloudCardResolved {
            Button(action: { showingCloudCard = true }) {
              Text("UI.Button.EnterCloudCard")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .font(.headline)
            }
            .buttonStyle(.bordered)
          }

          Button(action: { showingGot = true }) {
            Text("UI.Button.EnterWonTricks")
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .font(.headline)
          }
          .buttonStyle(.borderedProminent)
        }
      )
    } else {
      let isLastRound = (round?.handSize ?? 0) >= game.totalRoundsPlanned
      return AnyView(
        Button(action: { finalizeCurrentRound(game: game) }) {
          Text(isLastRound ? "UI.Button.FinishGame" : "UI.Button.FinalizeRound")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .font(.headline)
        }
        .buttonStyle(.borderedProminent)
      )
    }
  }

  /// Finalizes the current round and advances to the next (or ends the game on the last hand).
  private func finalizeCurrentRound(game: Game) {
    guard let store = storeHolder.store else { return }
    guard let round = game.currentRound, !round.isFinalized else { return }
    let constraints = constraintsForFinalize(game: game, bombPlayed: bombPlayedThisRound)
    store.apply(.finalizeCurrentRound(roundConstraints: constraints))
    guard store.lastError == nil else { return }
    bombPlayedThisRound = false
  }

  private func startAndShowBetsIfNeeded(game: Game) {
    if game.currentRound == nil {
      let dealerId = game.players.first?.id
      if let dealerId { storeHolder.store?.apply(.startNewGame(startingDealer: dealerId)) }
    }
    showingBets = true
  }

  private func validateCloudCardAdjustment(game: Game, submittedBets: [UUID: Int]) -> Error? {
    let lang = AppLanguage.catalogLookupLanguageCode
    let round = game.rounds[game.currentRoundIndex]
    if round.cloudCardResolved {
      return NSError(
        domain: "WizardApp",
        code: 5,
        userInfo: [
          NSLocalizedDescriptionKey: AppLocalization.string(
            "Error.CloudCard.AlreadyResolved",
            languageCode: lang,
            fallback: "The Cloud Card has already been recorded for this round."
          ),
        ]
      )
    }
    var changed: [(playerId: UUID, delta: Int)] = []

    for player in game.players {
      guard let currentBet = round.entries[player.id]?.bet,
            let submittedBet = submittedBets[player.id] else {
        return NSError(
          domain: "WizardApp",
          code: 2,
          userInfo: [
            NSLocalizedDescriptionKey: AppLocalization.string(
              "Error.CloudCard.BetsRequired",
              languageCode: lang,
              fallback: "Cloud Card can only be entered after all bets have been placed."
            ),
          ]
        )
      }

      let delta = submittedBet - currentBet
      if delta != 0 {
        changed.append((player.id, delta))
      }
    }

    guard changed.count == 1 else {
      return NSError(
        domain: "WizardApp",
        code: 3,
        userInfo: [
          NSLocalizedDescriptionKey: AppLocalization.string(
            "Error.CloudCard.ExactlyOneChanged",
            languageCode: lang,
            fallback: "Exactly one player's bet must be changed for Cloud Card."
          ),
        ]
      )
    }
    guard abs(changed[0].delta) == 1 else {
      return NSError(
        domain: "WizardApp",
        code: 4,
        userInfo: [
          NSLocalizedDescriptionKey: AppLocalization.string(
            "Error.CloudCard.ChangeByOne",
            languageCode: lang,
            fallback: "Cloud Card requires changing that bet by exactly 1."
          ),
        ]
      )
    }

    return nil
  }

  private func cloudCardAllowedRange(game: Game, playerId: UUID, editedBets: [UUID: Int]) -> ClosedRange<Int> {
    let round = game.rounds[game.currentRoundIndex]
    let playerIds = game.players.map(\.id)
    let baseBets = Dictionary(uniqueKeysWithValues: game.players.map { player in
      (player.id, round.entries[player.id]?.bet ?? 0)
    })
    return CloudCardAdjustmentRules.allowedRange(
      playerId: playerId,
      handSize: round.handSize,
      playerIds: playerIds,
      baseBets: baseBets,
      editedBets: editedBets
    )
  }

  private func isCloudCardPlayerLocked(game: Game, playerId: UUID, editedBets: [UUID: Int]) -> Bool {
    let round = game.rounds[game.currentRoundIndex]
    let playerIds = game.players.map(\.id)
    let baseBets = Dictionary(uniqueKeysWithValues: game.players.map { player in
      (player.id, round.entries[player.id]?.bet ?? 0)
    })
    return CloudCardAdjustmentRules.isPlayerLocked(
      playerId: playerId,
      playerIds: playerIds,
      baseBets: baseBets,
      editedBets: editedBets
    )
  }

  private func loadIfNeeded(force: Bool = false) {
    if storeHolder.store == nil {
      if let multiplayerStore = multiplayerCoordinator.store(for: gameId) {
        storeHolder.store = multiplayerStore
      } else {
        storeHolder.store = GameStore(modelContext: modelContext)
      }
      storeHolder.store?.loadGame(id: gameId)
    } else if force || storeHolder.store?.currentGame?.id != gameId {
      storeHolder.store?.loadGame(id: gameId)
    }
  }
}

@MainActor
private final class StoreHolder: ObservableObject {
  @Published var store: (any GameStoring)? {
    didSet { bindStoreChanges() }
  }

  private var cancellable: AnyCancellable?

  private func bindStoreChanges() {
    cancellable = nil
    guard let store else { return }
    cancellable = store.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
  }
}

