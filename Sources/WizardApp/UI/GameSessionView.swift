import SwiftUI
import SwiftData
#if canImport(Combine)
import Combine
#endif
#if canImport(WizardDomain)
import WizardDomain
#endif

struct GameSessionView: View {
  let gameId: UUID

  @Environment(\.modelContext) private var modelContext
  @StateObject private var storeHolder = StoreHolder()

  @State private var showingBets = false
  @State private var showingGot = false
  @State private var showingCloudCard = false
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
          description: Text(storeHolder.store?.lastError?.localizedDescription ?? String(localized: "UI.GameSession.OpenError.Unknown", defaultValue: "Unknown error."))
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
      Text(storeHolder.store?.lastError?.localizedDescription ?? "")
    }
    .wizardBackground()
  }

  private var shouldPresentGlobalErrorAlert: Bool {
    // Avoid presenting an alert on top of (or during dismissal of) a sheet.
    if showingBets || showingGot || showingCloudCard { return false }
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

  @ViewBuilder
  private func content(game: Game) -> some View {
    let totals = (try? game.totalPoints()) ?? [:]
    let isFinished = isGameFinished(game)

    ScrollView {
      VStack(spacing: 16) {
        Group {
          if isFinished {
            finalScoreboard(game: game, totals: totals)
          } else {
            scoreboard(game: game, totals: totals)
          }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 8)
      }
    }
    .safeAreaInset(edge: .top) {
      header(game: game)
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
          players: game.players,
          currentValues: game.rounds[game.currentRoundIndex].entries.mapValues { $0.bet },
          valueLabel: String(localized: "UI.GameSession.Entry.Bet", defaultValue: "Bet"),
          accessory: nil,
          sumValidation: game.gameConstraints.contains(.betSumNotEqualHandSize) ? .init(
            expectedSum: round.handSize,
            rule: .notEquals,
            failureMessageKey: Constraint.GameConstraint.betSumNotEqualHandSize.showOnFailureKey,
            failureMessageFallback: Constraint.GameConstraint.betSumNotEqualHandSize.showOnFailure
          ) : nil,
          showPositiveSumState: true,
          allowedRange: nil,
          isPlayerDisabled: nil,
          onSubmit: { values in
            guard let store = storeHolder.store else { return NSError(domain: "WizardApp", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Error.Store.NotReady", defaultValue: "Store not ready.")]) }
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
          }
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
          players: game.players,
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
          onSubmit: { values in
            guard let store = storeHolder.store else { return NSError(domain: "WizardApp", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Error.Store.NotReady", defaultValue: "Store not ready.")]) }
            let constraints = constraintsForFinalize(game: game, bombPlayed: bombPlayedThisRound) ?? [.gotSumEqualsHandSize]
            var cmds: [GameCommand] = values.map { (pid, got) in
              .submitGot(playerId: pid, roundIndex: game.currentRoundIndex, got: got)
            }
            cmds.append(.finalizeCurrentRound(roundConstraints: constraints))

            let err = store.applyBatch(cmds)
            if err == nil {
              bombPlayedThisRound = false
            }
            return err
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
          players: game.players,
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
          onSubmit: { values in
            guard let store = storeHolder.store else { return NSError(domain: "WizardApp", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Error.Store.NotReady", defaultValue: "Store not ready.")]) }
            if let validationError = validateCloudCardAdjustment(game: game, submittedBets: values) {
              return validationError
            }
            let cmds: [GameCommand] = values.map { (pid, bet) in
              .submitBet(playerId: pid, roundIndex: game.currentRoundIndex, bet: bet)
            }
            return store.applyBatch(cmds)
          }
        )
        .presentationDetents(Self.entrySheetDetents, selection: $gotDetent)
      }
    }
  }

  @ViewBuilder
  private func finalScoreboard(game: Game, totals: [UUID: Int]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(String(localized: "UI.GameSession.FinalScoreboard.Title", defaultValue: "Final Scoreboard"))
        .font(.title3.weight(.bold))
        .padding(.horizontal, 2)

      scoreboard(game: game, totals: totals)
    }
  }

  private func isGameFinished(_ game: Game) -> Bool {
    guard !game.rounds.isEmpty else { return false }
    guard game.rounds.count >= game.totalRoundsPlanned else { return false }
    return game.rounds.last?.isFinalized == true
  }

  private var activeRoundNumber: Int {
    guard let game = storeHolder.store?.currentGame, !game.rounds.isEmpty else { return 0 }
    return min(game.currentRoundIndex + 1, game.totalRoundsPlanned)
  }

  private var activeRoundTarget: Int {
    storeHolder.store?.currentGame?.totalRoundsPlanned ?? 0
  }

  private var activeRoundText: String {
    let current = activeRoundNumber
    let total = activeRoundTarget
    guard current > 0, total > 0 else {
      return String(localized: "UI.Common.EmptyValue", defaultValue: "—")
    }
    return "\(current)/\(total)"
  }

  private var activeBetsProgressText: String {
    guard let game = storeHolder.store?.currentGame,
          let round = game.currentRound else {
      return "\(0)/\(0)"
    }
    let betsSum = round.entries.values.reduce(into: 0) { partialResult, entry in
      partialResult += entry.bet ?? 0
    }
    return "\(betsSum)/\(activeRoundNumber)"
  }

  private func header(game: Game) -> some View {
    let round = game.currentRound
    let players = game.players
    let roundText = activeRoundText
    let betsText = activeBetsProgressText
    let dealerName: String = {
      guard let dealerId = round?.dealer,
            let dealer = players.first(where: { $0.id == dealerId }) else { return String(localized: "UI.Common.EmptyValue", defaultValue: "—") }
      return dealer.name
    }()

    return HStack(alignment: .center, spacing: 10) {
      Text("UI.GameSession.Header.Round")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .baselineOffset(0)
      Text(verbatim: roundText)
        .font(.headline.weight(.semibold).monospacedDigit())

      Text("UI.GameSession.Header.Separator")
        .foregroundStyle(.secondary.opacity(0.7))

      Text("UI.GameSession.Header.Dealer")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .baselineOffset(0)
      Text(dealerName)
        .font(.headline.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.tail)

      Text("UI.GameSession.Header.Separator")
        .foregroundStyle(.secondary.opacity(0.7))

      Text(String(localized: "UI.GameSession.Header.Bets", defaultValue: "Bets"))
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .baselineOffset(0)
      Text(verbatim: betsText)
        .font(.headline.weight(.semibold).monospacedDigit())

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
    }
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


  private func scoreboard(game: Game, totals: [UUID: Int]) -> some View {
    let placeDeltas = placeDeltasComparedToPreviousRound(in: game)
    let sortedPlayers = game.players.sorted { a, b in
      let ta = totals[a.id, default: 0]
      let tb = totals[b.id, default: 0]
      if ta != tb { return ta > tb }
      return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    return VStack(spacing: 10) {
      ForEach(Array(sortedPlayers.enumerated()), id: \.element.id) { idx, p in
        let total = totals[p.id, default: 0]
        let currentEntry = game.currentRound.flatMap { $0.entries[p.id] }
        let placeDelta = placeDeltas?[p.id]

        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
              Text(String(localized: "UI.GameSession.Score.RankPrefix", defaultValue: "#\(idx + 1)"))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
              if let placeDelta {
                Text(placeDeltaString(placeDelta))
                  .font(.caption2.weight(.semibold).monospacedDigit())
                  .foregroundStyle(placeDeltaColor(placeDelta))
              }
            }
            .frame(width: 36, alignment: .leading)

            Text(p.name)
              .font(.headline.weight(.semibold))
              .lineLimit(1)
              .truncationMode(.tail)

            Spacer(minLength: 0)

            if idx == 0 {
              Image(systemName: "crown.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.yellow.opacity(0.9))
            }
          }

          HStack(alignment: .bottom, spacing: 10) {
            entryChip(titleKey: "UI.GameSession.Entry.Bet", value: currentEntry?.bet)
            entryChip(titleKey: "UI.GameSession.Entry.Won", value: currentEntry?.got)

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 2) {
              Text("\(total)")
                .font(.title3.weight(.semibold).monospacedDigit())
            }
          }
        }
        .padding(14)
        .background {
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
              LinearGradient(
                colors: [
                  Color.white.opacity(0.20),
                  Color.white.opacity(0.06),
                  Color.white.opacity(0.02),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
              .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .overlay {
              RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            }
        }
        .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 6)
      }
    }
  }

  private func entryChip(titleKey: String, value: Int?) -> some View {
    let text = value.map(String.init) ?? String(localized: "UI.Common.EmptyValue", defaultValue: "—")
    let isMissing = value == nil

    return VStack(alignment: .leading, spacing: 2) {
      Text(LocalizedStringKey(titleKey))
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(text)
        .font(.headline.weight(.semibold).monospacedDigit())
        .foregroundStyle(isMissing ? .secondary : .primary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(width: 72, alignment: .leading)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
    }
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
          if game.playWithSpecialCards {
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
      return AnyView(
        Button(action: {
          guard let store = storeHolder.store else { return }
          let constraints = constraintsForFinalize(game: store.currentGame, bombPlayed: bombPlayedThisRound)
          store.apply(.finalizeCurrentRound(roundConstraints: constraints))
          if store.lastError == nil {
            bombPlayedThisRound = false
          }
        }) {
          Text("UI.Button.FinalizeRound")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .font(.headline)
        }
        .buttonStyle(.borderedProminent)
      )
    }
  }

  private func startAndShowBetsIfNeeded(game: Game) {
    if game.currentRound == nil {
      let dealerId = game.players.first?.id
      if let dealerId { storeHolder.store?.apply(.startNewGame(startingDealer: dealerId)) }
    }
    showingBets = true
  }

  private func validateCloudCardAdjustment(game: Game, submittedBets: [UUID: Int]) -> Error? {
    let round = game.rounds[game.currentRoundIndex]
    var changed: [(playerId: UUID, delta: Int)] = []

    for player in game.players {
      guard let currentBet = round.entries[player.id]?.bet,
            let submittedBet = submittedBets[player.id] else {
        return NSError(
          domain: "WizardApp",
          code: 2,
          userInfo: [NSLocalizedDescriptionKey: String(localized: "Error.CloudCard.BetsRequired", defaultValue: "Cloud Card can only be entered after all bets have been placed.")]
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
        userInfo: [NSLocalizedDescriptionKey: String(localized: "Error.CloudCard.ExactlyOneChanged", defaultValue: "Exactly one player's bet must be changed for Cloud Card.")]
      )
    }
    guard abs(changed[0].delta) == 1 else {
      return NSError(
        domain: "WizardApp",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: String(localized: "Error.CloudCard.ChangeByOne", defaultValue: "Cloud Card requires changing that bet by exactly 1.")]
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

  private func placeDeltaString(_ delta: Int) -> String {
    if delta > 0 { return "▲\(delta)" }
    if delta < 0 { return "▼\(abs(delta))" }
    return "•"
  }

  private func placeDeltaColor(_ delta: Int) -> Color {
    if delta > 0 { return .green }
    if delta < 0 { return .red }
    return .secondary
  }

  private func placeDeltasComparedToPreviousRound(in game: Game) -> [UUID: Int]? {
    let finalizedRounds = game.rounds.filter(\.isFinalized)
    guard finalizedRounds.count >= 2 else { return nil }

    var totalsBeforeMostRecent = Dictionary(uniqueKeysWithValues: game.players.map { ($0.id, 0) })

    for round in finalizedRounds.dropLast() {
      for player in game.players {
        guard let entry = round.entries[player.id],
              let delta = try? entry.pointsDelta() else { continue }
        totalsBeforeMostRecent[player.id, default: 0] += delta
      }
    }

    var totalsAfterMostRecent = totalsBeforeMostRecent
    if let mostRecentRound = finalizedRounds.last {
      for player in game.players {
        guard let entry = mostRecentRound.entries[player.id],
              let delta = try? entry.pointsDelta() else { continue }
        totalsAfterMostRecent[player.id, default: 0] += delta
      }
    }

    let previousRanks = ranks(for: totalsBeforeMostRecent, players: game.players)
    let currentRanks = ranks(for: totalsAfterMostRecent, players: game.players)

    return Dictionary(uniqueKeysWithValues: game.players.map { player in
      let previous = previousRanks[player.id, default: game.players.count]
      let current = currentRanks[player.id, default: game.players.count]
      return (player.id, previous - current)
    })
  }

  private func ranks(for totals: [UUID: Int], players: [Player]) -> [UUID: Int] {
    let sorted = players.sorted { a, b in
      let ta = totals[a.id, default: 0]
      let tb = totals[b.id, default: 0]
      if ta != tb { return ta > tb }
      return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
    var result: [UUID: Int] = [:]
    for (index, player) in sorted.enumerated() {
      result[player.id] = index + 1
    }
    return result
  }

  private func loadIfNeeded(force: Bool = false) {
    if storeHolder.store == nil {
      storeHolder.store = GameStore(modelContext: modelContext)
      storeHolder.store?.loadGame(id: gameId)
    } else if force || storeHolder.store?.currentGame?.id != gameId {
      storeHolder.store?.loadGame(id: gameId)
    }
  }
}

@MainActor
private final class StoreHolder: ObservableObject {
  @Published var store: GameStore? {
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

