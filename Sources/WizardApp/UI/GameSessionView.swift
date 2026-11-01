import SwiftUI
import SwiftData
#if canImport(Combine)
import Combine
#endif
#if canImport(WizardDomain)
import WizardDomain
#endif

private struct PlayerEntryItem: Identifiable {
  let playerId: UUID
  var id: UUID { playerId }
}

/// Game screen for single-phone games and the multi-phone host.
///
/// While a multi-phone session is live (`liveHostStore`), the host's bulk entry sheets only cover seats without a
/// phone, the primary action waits for guests' values, single values can be overridden from the scoreboard chips and
/// the Bomb is declared on this screen. Single-phone behaviour is unchanged. `isReadOnlyGuestCopy` shows a guest's
/// saved copy of a finished game without any editing.
struct GameSessionView: View {
  let gameId: UUID
  /// A finished game a guest kept from a host's session (`GuestFinishedGames`): no entries, no edits, no hosting.
  var isReadOnlyGuestCopy: Bool = false

  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject private var multiplayerCoordinator: MultiplayerCoordinator
  @StateObject private var storeHolder = StoreHolder()

  @State private var showingBets = false
  @State private var betEditorPlayerItem: PlayerEntryItem?
  @State private var wonEditorPlayerItem: PlayerEntryItem?
  @State private var showingGot = false
  @State private var showingCloudCard = false
  @State private var playerHistorySheetItem: PlayerHistorySheetItem?
  /// Bomb toggle inside the won-tricks sheet: seeded from the round when the sheet opens, saved with the values.
  @State private var bombPlayedThisRound: Bool = false
  /// Finalizing failed because the won tricks don't add up (shown with expected vs. entered sum).
  @State private var finalizeMismatch: MultiPhoneHostRules.TrickSumMismatch?

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
    .alert(
      Text("UI.GameSession.FinalizeError.Title"),
      isPresented: Binding(
        get: { finalizeMismatch != nil },
        set: { newValue in if !newValue { finalizeMismatch = nil } }
      ),
      presenting: finalizeMismatch
    ) { _ in
      Button("UI.GameSession.FinalizeError.EditWonTricks") {
        finalizeMismatch = nil
        if let game = storeHolder.store?.currentGame {
          presentWonTricksSheet(game: game)
        }
      }
      Button("UI.Common.OK", role: .cancel) { finalizeMismatch = nil }
    } message: { mismatch in
      Text(MultiPhoneHostRules.trickSumMismatchMessage(mismatch, languageCode: AppLanguage.catalogLookupLanguageCode))
    }
    .wizardBackground()
    .reviewPromptOnGameFinish(gameId: gameId, isFinished: storeHolder.store?.currentGame.map { isGameFinished($0) })
    .keepsScreenAwake(liveHostStore != nil)
    .onChange(of: multiplayerCoordinator.hostLobbyState?.gameID) { _, _ in
      attachMultiplayerStoreIfNeeded()
    }
  }

  private func attachMultiplayerStoreIfNeeded() {
    guard !isReadOnlyGuestCopy, let multiplayerStore = multiplayerCoordinator.store(for: gameId) else { return }
    storeHolder.store = multiplayerStore
  }

  /// The multi-phone host's store while its session is live (`nil` for single-phone games, guests, read-only copies
  /// and after the session ended).
  private var liveHostStore: MultiplayerGameStore? {
    guard !isReadOnlyGuestCopy,
          let store = storeHolder.store as? MultiplayerGameStore,
          store.role == .host,
          store.isHostSessionLive
    else { return nil }
    return store
  }

  private var shouldPresentGlobalErrorAlert: Bool {
    // Avoid presenting an alert on top of (or during dismissal of) a sheet.
    if showingBets || betEditorPlayerItem != nil || wonEditorPlayerItem != nil || showingGot || showingCloudCard
      || playerHistorySheetItem != nil || finalizeMismatch != nil {
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
    let hostStore = liveHostStore

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
      VStack(spacing: 8) {
        GameSessionHeaderView(game: game)
        if isReadOnlyGuestCopy {
          readOnlyCopyNote
        }
        if let hostStore {
          hostSessionStatus(game: game, store: hostStore)
        }
      }
      .padding(.horizontal)
      .padding(.top, 8)
    }
    // Mirror `GameListView`: the bottom control overlays the content, so the list is "under" it.
    .safeAreaInset(edge: .bottom) {
      if !isFinished && !isReadOnlyGuestCopy {
        bottomControls(game: game)
          .padding(.horizontal)
          .padding(.bottom, 12)
          .padding(.top, 8)
          .background(Color.clear)
      }
    }
    .sheet(isPresented: $showingBets) {
      if let round = game.currentRound {
        betsSheet(game: game, round: round)
      }
    }
    .sheet(item: $betEditorPlayerItem) { item in
      if let round = game.currentRound,
         let player = game.players.first(where: { $0.id == item.playerId }) {
        singleBetSheet(game: game, round: round, player: player)
      }
    }
    .sheet(isPresented: $showingGot) {
      if let round = game.currentRound {
        wonTricksSheet(game: game, round: round)
      }
    }
    .sheet(item: $wonEditorPlayerItem) { item in
      if let round = game.currentRound,
         let player = game.players.first(where: { $0.id == item.playerId }) {
        singleWonTricksSheet(game: game, round: round, player: player)
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
      PlayerRoundHistorySheet(
        game: game,
        playerId: item.id,
        applyRoundEdit: isReadOnlyGuestCopy ? nil : roundEditHandler
      )
    }
  }

  // MARK: - Entry sheets

  /// "Enter bets". Multi-phone host: only seats without a phone (guests' rows are never written); the bet-sum rule is
  /// checked live once every guest's bet is in (otherwise when the last bet arrives).
  private func betsSheet(game: Game, round: Round) -> some View {
    let hostStore = liveHostStore
    let bound = hostStore?.boundGuestPlayerIDs ?? []
    let ordered = game.playersInBettingOrder(for: round)
    let rows = hostStore == nil ? ordered : MultiPhoneHostRules.bulkEntryPlayers(ordered, boundPlayerIDs: bound)
    let validation: EntrySheetView.SumValidation?
    if hostStore == nil || MultiPhoneHostRules.allEntered(.bets, in: round, playerIDs: bound) {
      validation = betSumNotEqualHandSizeSheetValidation(game: game, round: round)
    } else {
      validation = nil
    }
    let guestNote: AnyView? = hostStore != nil && !bound.isEmpty
      ? AnyView(multiPhoneSheetNote("UI.GameSession.Multiplayer.BulkBets.Note"))
      : nil
    let roundIndex = game.currentRoundIndex

    return EntrySheetView(
      title: "UI.Button.EnterBets",
      handSize: round.handSize,
      players: rows,
      currentValues: round.entries.mapValues { $0.bet },
      valueLabel: String(localized: "UI.GameSession.Entry.Bet", defaultValue: "Bet"),
      accessory: guestNote,
      sumValidation: validation,
      showPositiveSumState: true,
      allowedRange: { playerId, edited in
        betAllowedRange(game: game, playerId: playerId, editedBets: edited)
      },
      isPlayerDisabled: nil,
      additionalSumForValidation: hostStore == nil
        ? nil
        : MultiPhoneHostRules.enteredSum(.bets, in: round, playerIDs: bound),
      onSubmit: { values in
        guard let store = storeHolder.store else { return storeNotReadyNSError() }
        let cmds: [GameCommand] = values.map { (pid, bet) in
          .submitBet(playerId: pid, roundIndex: roundIndex, bet: bet)
        }
        return store.applyBatch(cmds) { updated in
          try updated.rounds[updated.currentRoundIndex].validateConstraints(
            players: updated.players,
            gameConstraints: updated.gameConstraints(forRoundAt: updated.currentRoundIndex),
            roundConstraints: [.gotSumEqualsHandSize]
          )
        }
      },
      liveBetsProgressRoundNumber: GameSessionScoreboardMetrics.activeRoundNumber(for: game)
    )
    .presentationDetents(Self.entrySheetDetents, selection: $betsDetent)
  }

  /// One player's bet (scoreboard bet chip). The multi-phone host can override any player, guests included.
  private func singleBetSheet(game: Game, round: Round, player: Player) -> some View {
    let othersBetSum = sumOfOtherPlayersBets(round: round, excludingPlayerId: player.id)
    let othersAllBet = game.players
      .filter { $0.id != player.id }
      .allSatisfy { round.entries[$0.id]?.bet != nil }
    // Multi-phone host: while another bet is missing the sum isn't final yet, so don't block "Done".
    let validation = liveHostStore == nil || othersAllBet
      ? betSumNotEqualHandSizeSheetValidation(game: game, round: round)
      : nil
    let roundIndex = game.currentRoundIndex

    return EntrySheetView(
      title: "UI.GameSession.EditSingleBet.Title",
      handSize: round.handSize,
      players: [player],
      currentValues: [player.id: round.entries[player.id]?.bet],
      valueLabel: String(localized: "UI.GameSession.Entry.Bet", defaultValue: "Bet"),
      accessory: nil,
      sumValidation: validation,
      showPositiveSumState: true,
      allowedRange: { playerId, edited in
        var fullBets: [UUID: Int] = [:]
        for pl in game.players {
          if pl.id == player.id {
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
        guard let newBet = values[player.id] else {
          return missingValueError(key: "Error.BetEditor.MissingValue", fallback: "Missing bet value.")
        }
        let cmd = GameCommand.submitBet(playerId: player.id, roundIndex: roundIndex, bet: newBet)
        return store.applyBatch([cmd]) { updated in
          try updated.rounds[updated.currentRoundIndex].validateConstraints(
            players: updated.players,
            gameConstraints: updated.gameConstraints(forRoundAt: updated.currentRoundIndex),
            roundConstraints: [.gotSumEqualsHandSize]
          )
        }
      },
      liveBetsProgressRoundNumber: GameSessionScoreboardMetrics.activeRoundNumber(for: game)
    )
    .presentationDetents(Self.entrySheetDetents, selection: $betsDetent)
  }

  /// "Enter won tricks". Single-phone: every player, the sum must add up (minus one with the Bomb toggle).
  /// Multi-phone host: only seats without a phone; guests' values may still be missing or wrong, so the sum is shown
  /// for information and checked when the round is finalized.
  private func wonTricksSheet(game: Game, round: Round) -> some View {
    let hostStore = liveHostStore
    let bound = hostStore?.boundGuestPlayerIDs ?? []
    let ordered = game.playersInBettingOrder(for: round)
    let rows = hostStore == nil ? ordered : MultiPhoneHostRules.bulkEntryPlayers(ordered, boundPlayerIDs: bound)
    let expectedSum = expectedWonTricksTotal(game: game, bombPlayed: bombPlayedThisRound)
    let isMultiPhoneHost = hostStore != nil

    let validation: EntrySheetView.SumValidation?
    let allowedRange: ((UUID, [UUID: Int]) -> ClosedRange<Int>)?
    if isMultiPhoneHost {
      validation = nil
      allowedRange = nil
    } else {
      validation = .init(
        expectedSum: expectedSum,
        rule: .equals,
        failureMessageKey: bombPlayedThisRound
          ? Constraint.RoundConstraint.gotSumEqualsHandSizeMinusOne.showOnFailureKey
          : Constraint.RoundConstraint.gotSumEqualsHandSize.showOnFailureKey,
        failureMessageFallback: bombPlayedThisRound
          ? Constraint.RoundConstraint.gotSumEqualsHandSizeMinusOne.showOnFailure
          : Constraint.RoundConstraint.gotSumEqualsHandSize.showOnFailure
      )
      let bombPlayed = bombPlayedThisRound
      allowedRange = { playerId, editedValues in
        wonTricksAllowedRange(
          game: game,
          playerId: playerId,
          editedValues: editedValues,
          bombPlayed: bombPlayed
        )
      }
    }

    return EntrySheetView(
      title: "UI.Button.EnterWonTricks",
      handSize: round.handSize,
      players: rows,
      currentValues: round.entries.mapValues { $0.got },
      valueLabel: String(localized: "UI.GameSession.Entry.Won", defaultValue: "Won"),
      accessory: wonTricksSheetAccessory(game: game, showsGuestNote: isMultiPhoneHost && !bound.isEmpty),
      sumValidation: validation,
      showPositiveSumState: false,
      allowedRange: allowedRange,
      isPlayerDisabled: nil,
      additionalSumForValidation: isMultiPhoneHost
        ? MultiPhoneHostRules.enteredSum(.wonTricks, in: round, playerIDs: bound)
        : nil,
      onSubmit: { values in
        submitWonTricks(values, game: game, round: round, validatesSum: !isMultiPhoneHost)
      },
      sumTarget: isMultiPhoneHost ? expectedSum : nil
    )
    .presentationDetents(Self.entrySheetDetents, selection: $gotDetent)
  }

  /// Bomb toggle (special cards) and, for the multi-phone host, which rows the sheet covers.
  private func wonTricksSheetAccessory(game: Game, showsGuestNote: Bool) -> AnyView? {
    guard game.playWithSpecialCards || showsGuestNote else { return nil }
    return AnyView(
      VStack(alignment: .leading, spacing: 8) {
        if game.playWithSpecialCards {
          Toggle(isOn: $bombPlayedThisRound) {
            VStack(alignment: .leading, spacing: 2) {
              Text(LocalizedStringKey(Constraint.RoundConstraint.gotSumEqualsHandSizeMinusOne.titleKey))
                .font(.subheadline.weight(.semibold))
            }
          }
        }
        if showsGuestNote {
          multiPhoneSheetNote("UI.GameSession.Multiplayer.BulkWon.Note")
        }
      }
    )
  }

  /// Saves the sheet's won tricks together with the sheet's Bomb toggle (`setBombPlayed`, persisted on the round).
  private func submitWonTricks(_ values: [UUID: Int], game: Game, round: Round, validatesSum: Bool) -> Error? {
    guard let store = storeHolder.store else { return storeNotReadyNSError() }
    let roundIndex = game.currentRoundIndex
    var commands: [GameCommand] = []
    if game.playWithSpecialCards, round.bombPlayed != bombPlayedThisRound {
      commands.append(.setBombPlayed(roundIndex: roundIndex, played: bombPlayedThisRound))
    }
    commands.append(contentsOf: values.map { entry in
      GameCommand.submitGot(playerId: entry.key, roundIndex: roundIndex, got: entry.value)
    })
    guard validatesSum else {
      // Multi-phone host: guests' won tricks may still be missing or wrong; finalize checks the sum.
      return store.applyBatch(commands)
    }
    let roundConstraints = constraintsForFinalize(game: game, bombPlayed: bombPlayedThisRound) ?? [.gotSumEqualsHandSize]
    return store.applyBatch(commands) { updated in
      try updated.rounds[updated.currentRoundIndex].validateConstraints(
        players: updated.players,
        gameConstraints: updated.gameConstraints(forRoundAt: updated.currentRoundIndex),
        roundConstraints: roundConstraints
      )
    }
  }

  /// One player's won tricks (multi-phone host: scoreboard won chip). The sum is checked when finalizing, so a host
  /// can fix several wrong guest values one at a time.
  private func singleWonTricksSheet(game: Game, round: Round, player: Player) -> some View {
    let othersWonSum = round.entries.reduce(0) { partial, entry in
      entry.key == player.id ? partial : partial + (entry.value.got ?? 0)
    }
    let roundIndex = game.currentRoundIndex
    let expectedSum = MultiPhoneHostRules.expectedWonTricksSum(
      handSize: round.handSize,
      bombPlayed: game.playWithSpecialCards && round.bombPlayed
    )

    return EntrySheetView(
      title: "UI.GameSession.EditSingleWon.Title",
      handSize: round.handSize,
      players: [player],
      currentValues: [player.id: round.entries[player.id]?.got],
      valueLabel: String(localized: "UI.GameSession.Entry.Won", defaultValue: "Won"),
      accessory: nil,
      sumValidation: nil,
      showPositiveSumState: false,
      allowedRange: nil,
      isPlayerDisabled: nil,
      additionalSumForValidation: othersWonSum,
      onSubmit: { values in
        guard let store = storeHolder.store else { return storeNotReadyNSError() }
        guard let got = values[player.id] else {
          return missingValueError(key: "Error.WonEditor.MissingValue", fallback: "Missing won tricks value.")
        }
        return store.applyBatch([.submitGot(playerId: player.id, roundIndex: roundIndex, got: got)])
      },
      sumTarget: expectedSum
    )
    .presentationDetents(Self.entrySheetDetents, selection: $gotDetent)
  }

  private func multiPhoneSheetNote(_ key: LocalizedStringKey) -> some View {
    Text(key)
      .font(.footnote)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func missingValueError(key: String, fallback: String) -> NSError {
    NSError(
      domain: "WizardApp",
      code: 4,
      userInfo: [
        NSLocalizedDescriptionKey: AppLocalization.string(
          key,
          languageCode: AppLanguage.catalogLookupLanguageCode,
          fallback: fallback
        ),
      ]
    )
  }

  /// Corrections of finalized rounds (round editor in the player history). Host / single-phone only: guests use
  /// `GuestGameSessionView`, and a guest-role store never gets a handler. On the multi-phone host, `applyBatch` on
  /// `MultiplayerGameStore` persists the edit and broadcasts the new snapshot to all guests.
  private var roundEditHandler: ((GameCommand) -> Error?)? {
    if let multiplayerStore = storeHolder.store as? MultiplayerGameStore, multiplayerStore.role != .host {
      return nil
    }
    return { command in
      guard let store = storeHolder.store else { return storeNotReadyNSError() }
      let error = store.applyBatch([command])
      if error != nil {
        // Shown inline in `RoundEditorView`; don't surface it again as a global alert once the sheets close.
        store.lastError = nil
      }
      return error
    }
  }

  // MARK: - Header / final scoreboard extras

  @ViewBuilder
  private func hostSessionStatus(game: Game, store: MultiplayerGameStore) -> some View {
    if let health = MultiPhoneHostRules.sessionHealth(for: store.hostListenerState) {
      HostSessionHealthBanner(health: health) {
        multiplayerCoordinator.handleScenePhase(.active)
      }
      .padding(12)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    HostGuestPhonesStrip(
      players: game.players,
      boundPlayerIDs: store.boundGuestPlayerIDs,
      connectedPlayerIDs: store.connectedGuestPlayerIDs
    )
  }

  private var readOnlyCopyNote: some View {
    Label {
      Text("UI.GameSession.GuestCopy.Note")
    } icon: {
      Image(systemName: "lock.fill")
    }
    .font(.footnote.weight(.semibold))
    .foregroundStyle(.secondary)
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  @ViewBuilder
  private func finalScoreboard(game: Game, totals: [UUID: Int]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(String(localized: "UI.GameSession.FinalScoreboard.Title", defaultValue: "Final Scoreboard"))
        .font(.title3.weight(.bold))
        .padding(.horizontal, 2)

      if game.mode == .multiPhone && !isReadOnlyGuestCopy {
        // The engine ends the session with the last round; guests keep a read-only copy.
        Label {
          Text("UI.GameSession.SessionEnded.Note")
        } icon: {
          Image(systemName: "checkmark.circle")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
      }

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
    guard game.gameConstraints(forRoundAt: game.currentRoundIndex).contains(.betSumNotEqualHandSize),
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
    let openHistory: (UUID) -> Void = { playerHistorySheetItem = PlayerHistorySheetItem(id: $0) }
    guard !isReadOnlyGuestCopy, canOpenBetsFromScoreboard(game: game) else {
      // Finished game / read-only copy: no more entries, but the round history stays reachable (corrections only
      // when `roundEditHandler` is passed, never for read-only copies).
      return GameSessionScoreboardOptions(onPlayerCardTap: openHistory)
    }
    if liveHostStore != nil {
      // Multi-phone host: every chip edits exactly that player's value (overrides a guest's entry explicitly).
      return GameSessionScoreboardOptions(
        onPlayerCardTap: openHistory,
        onBetChipTap: { openBetChipTapped(game: game, playerId: $0) },
        onWonChipTapForPlayer: { openWonChipTapped(game: game, playerId: $0) }
      )
    }
    return GameSessionScoreboardOptions(
      onPlayerCardTap: openHistory,
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
      betEditorPlayerItem = PlayerEntryItem(playerId: playerId)
    }
  }

  /// Multi-phone host won chip: that player's won tricks once all bets are in (their bet while bidding is open).
  private func openWonChipTapped(game: Game, playerId: UUID) {
    guard !isGameFinished(game), let round = game.currentRound, !round.isFinalized else { return }
    if round.entries.values.allSatisfy({ $0.bet != nil }) {
      wonEditorPlayerItem = PlayerEntryItem(playerId: playerId)
    } else {
      betEditorPlayerItem = PlayerEntryItem(playerId: playerId)
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
    presentWonTricksSheet(game: game)
  }

  /// Opens the won-tricks sheet with its Bomb toggle seeded from the round's declared Bomb.
  private func presentWonTricksSheet(game: Game) {
    guard let round = game.currentRound, !round.isFinalized else { return }
    bombPlayedThisRound = game.playWithSpecialCards && round.bombPlayed
    showingGot = true
  }

  // MARK: - Bottom controls

  @ViewBuilder
  private func bottomControls(game: Game) -> some View {
    if let hostStore = liveHostStore, let round = game.currentRound {
      multiPhoneHostControls(game: game, round: round, boundPlayerIDs: hostStore.boundGuestPlayerIDs)
    } else {
      primaryAction(game: game)
    }
  }

  /// Multi-phone host: bulk entry only while a seat without a phone is missing a value, otherwise a waiting state
  /// naming the guests; the Bomb is declared here (host-only, persisted so guests see it) and Cloud stays host-only.
  @ViewBuilder
  private func multiPhoneHostControls(game: Game, round: Round, boundPlayerIDs: Set<UUID>) -> some View {
    let step = MultiPhoneHostRules.entryStep(
      for: round,
      orderedPlayers: game.playersInBettingOrder(for: round),
      boundPlayerIDs: boundPlayerIDs
    )
    let allBetsPresent = round.entries.values.allSatisfy { $0.bet != nil }
    let showsCloud = game.playWithSpecialCards && allBetsPresent && !round.cloudCardResolved

    VStack(spacing: 10) {
      if game.playWithSpecialCards && allBetsPresent {
        bombToggle(game: game, round: round)
      }

      switch step {
      case .enter(.bets):
        primaryButton("UI.Button.EnterBets") { showingBets = true }
      case .enter(.wonTricks):
        HStack(spacing: 10) {
          if showsCloud {
            cloudCardButton
          }
          primaryButton("UI.Button.EnterWonTricks") { presentWonTricksSheet(game: game) }
        }
      case .waiting(let kind, let players):
        if kind == .wonTricks && showsCloud {
          cloudCardButton
        }
        waitingCard(kind: kind, players: players)
      case .finalize:
        finalizeButton(game: game, round: round)
      }
    }
  }

  private func bombToggle(game: Game, round: Round) -> some View {
    Toggle(isOn: Binding(
      get: { round.bombPlayed },
      set: { setBombPlayed($0, game: game) }
    )) {
      Label {
        Text(LocalizedStringKey(Constraint.RoundConstraint.gotSumEqualsHandSizeMinusOne.titleKey))
      } icon: {
        Image(systemName: "burst.fill")
      }
      .font(.subheadline.weight(.semibold))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private func setBombPlayed(_ played: Bool, game: Game) {
    guard let store = storeHolder.store,
          let round = game.currentRound,
          !round.isFinalized,
          round.bombPlayed != played
    else { return }
    store.applyBatch([.setBombPlayed(roundIndex: game.currentRoundIndex, played: played)])
  }

  private func waitingCard(kind: MultiPhoneHostRules.EntryKind, players: [Player]) -> some View {
    let languageCode = AppLanguage.catalogLookupLanguageCode
    return VStack(spacing: 4) {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text(MultiPhoneHostRules.waitingTitle(for: players, languageCode: languageCode))
          .font(.headline)
          .multilineTextAlignment(.center)
      }
      Text(MultiPhoneHostRules.waitingHint(for: kind, languageCode: languageCode))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  private func primaryButton(_ titleKey: LocalizedStringKey, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(titleKey)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .font(.headline)
    }
    .buttonStyle(.borderedProminent)
  }

  private var cloudCardButton: some View {
    Button(action: { showingCloudCard = true }) {
      Text("UI.Button.EnterCloudCard")
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .font(.headline)
    }
    .buttonStyle(.bordered)
  }

  private func finalizeButton(game: Game, round: Round) -> some View {
    let isLastRound = round.handSize >= game.totalRoundsPlanned
    return Button(action: { finalizeCurrentRound(game: game) }) {
      Text(isLastRound ? "UI.Button.FinishGame" : "UI.Button.FinalizeRound")
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .font(.headline)
    }
    .buttonStyle(.borderedProminent)
  }

  /// Single-phone (and a multi-phone game without a live session) bottom action.
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

          Button(action: { presentWonTricksSheet(game: game) }) {
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

  /// Finalizes the current round and advances to the next (or ends the game on the last hand). The round's declared
  /// Bomb picks the won-tricks sum; if the won tricks don't add up, a fix-it alert shows expected vs. entered sum.
  private func finalizeCurrentRound(game: Game) {
    guard let store = storeHolder.store else { return }
    guard let round = game.currentRound, !round.isFinalized else { return }
    let constraints = MultiPhoneHostRules.finalizeConstraints(for: round, playWithSpecialCards: game.playWithSpecialCards)
    guard let error = store.applyBatch([.finalizeCurrentRound(roundConstraints: constraints)]) else { return }
    if let domainError = error as? DomainError,
       case .constraintNotSatisfied(let constraint) = domainError,
       case .round = constraint,
       let mismatch = MultiPhoneHostRules.trickSumMismatch(in: round, playWithSpecialCards: game.playWithSpecialCards) {
      store.lastError = nil
      finalizeMismatch = mismatch
    }
    // Any other error stays in `lastError` and is shown by the global alert.
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
      if !isReadOnlyGuestCopy, let multiplayerStore = multiplayerCoordinator.store(for: gameId) {
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

