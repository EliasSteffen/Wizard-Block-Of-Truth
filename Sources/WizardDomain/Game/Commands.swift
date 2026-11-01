import Foundation

public enum GameCommand: Hashable, Codable, Sendable {
  case startNewGame(startingDealer: UUID)
  case submitBet(playerId: UUID, roundIndex: Int, bet: Int)
  case submitGot(playerId: UUID, roundIndex: Int, got: Int)
  case finalizeCurrentRound(roundConstraints: [Constraint.RoundConstraint]? = nil)
  case markCloudCardResolved(roundIndex: Int)
  /// Declares (or clears) the Bomb for a round that is still open (host / single-phone only). Persisted on the round
  /// (`Round.bombPlayed`) so guests see it; `finalizeCurrentRound` without explicit constraints then expects the won
  /// tricks to add up to `handSize - 1`. Declaring requires `playWithSpecialCards`; clearing is always allowed.
  case setBombPlayed(roundIndex: Int, played: Bool)
  /// Corrects an already finalized round (host / single-phone only): replaces every player's bet and won tricks and
  /// records whether the Bomb / Cloud card were played. Validated atomically; see `applyEditFinalizedRound`.
  case editFinalizedRound(roundIndex: Int, entries: [UUID: RoundEntry], bombPlayed: Bool, cloudCardPlayed: Bool)
}

extension GameCommand {
  func apply(to game: inout Game) throws {
    switch self {
    case .startNewGame(let startingDealer):
      guard game.rounds.isEmpty else { throw DomainError.gameAlreadyStarted }
      guard game.players.contains(where: { $0.id == startingDealer }) else {
        throw DomainError.unknownPlayerId(startingDealer)
      }
      let firstHandSize = 1
      let entries = Dictionary(uniqueKeysWithValues: game.players.map { ($0.id, RoundEntry()) })
      let round = Round(
        handSize: firstHandSize,
        dealer: startingDealer,
        entries: entries,
        isFinalized: false,
        cloudCardResolved: false
      )
      game.rounds = [round]
      game.currentRoundIndex = 0

    case .submitBet(let playerId, let roundIndex, let bet):
      try mutateEntry(game: &game, playerId: playerId, roundIndex: roundIndex) { entry in
        entry.bet = bet
      }
      try validateImmediateInputs(game: game, roundIndex: roundIndex)

    case .submitGot(let playerId, let roundIndex, let got):
      try mutateEntry(game: &game, playerId: playerId, roundIndex: roundIndex) { entry in
        entry.got = got
      }
      try validateImmediateInputs(game: game, roundIndex: roundIndex)

    case .markCloudCardResolved(let roundIndex):
      guard (0..<game.rounds.count).contains(roundIndex) else {
        throw DomainError.invalidRoundIndex(roundIndex)
      }
      if game.rounds[roundIndex].isFinalized {
        throw DomainError.roundAlreadyFinalized
      }
      game.rounds[roundIndex].cloudCardResolved = true

    case .setBombPlayed(let roundIndex, let played):
      guard (0..<game.rounds.count).contains(roundIndex) else {
        throw DomainError.invalidRoundIndex(roundIndex)
      }
      if game.rounds[roundIndex].isFinalized {
        throw DomainError.roundAlreadyFinalized
      }
      if played && !game.playWithSpecialCards {
        throw DomainError.specialCardsNotEnabled
      }
      game.rounds[roundIndex].bombPlayed = played

    case .editFinalizedRound(let roundIndex, let entries, let bombPlayed, let cloudCardPlayed):
      try applyEditFinalizedRound(
        game: &game,
        roundIndex: roundIndex,
        entries: entries,
        bombPlayed: bombPlayed,
        cloudCardPlayed: cloudCardPlayed
      )

    case .finalizeCurrentRound(let roundConstraints):
      guard !game.rounds.isEmpty else {
        throw DomainError.invalidRoundIndex(game.currentRoundIndex)
      }
      let roundIndex = game.currentRoundIndex
      if !(0..<game.rounds.count).contains(roundIndex) {
        throw DomainError.invalidRoundIndex(roundIndex)
      }
      if game.rounds[roundIndex].isFinalized {
        throw DomainError.roundAlreadyFinalized
      }
      // Validate constraints before finalizing. Game constraints (e.g. bet sum ≠ hand size)
      // apply only during bidding; after cloud adjustment the bet sum may equal hand size.
      // Without explicit constraints the round's declared Bomb (`setBombPlayed`) picks the won-tricks sum rule.
      let roundConstraintsToUse = roundConstraints
        ?? [game.rounds[roundIndex].bombPlayed ? .gotSumEqualsHandSizeMinusOne : .gotSumEqualsHandSize]
      try game.rounds[roundIndex].validateConstraints(
        players: game.players,
        gameConstraints: [],
        roundConstraints: roundConstraintsToUse
      )
      // Ensure all inputs present.
      let entries = game.rounds[roundIndex].entries
      guard entries.values.allSatisfy({ $0.bet != nil && $0.got != nil }) else {
        throw DomainError.missingInputs
      }

      game.rounds[roundIndex].bombPlayed = roundConstraintsToUse.contains(.gotSumEqualsHandSizeMinusOne)
      game.rounds[roundIndex].isFinalized = true

      // Only-up progression: append next round until planned total is reached.
      let handSize = game.rounds[roundIndex].handSize
      if handSize >= game.totalRoundsPlanned {
        // Game ends; keep currentRoundIndex at last round.
        game.currentRoundIndex = roundIndex
        return
      }

      let nextHandSize = handSize + 1
      let nextDealer = try Rules.nextDealer(
        players: game.players,
        currentDealer: game.rounds[roundIndex].dealer
      )
      let nextEntries = Dictionary(uniqueKeysWithValues: game.players.map { ($0.id, RoundEntry()) })
      let nextRound = Round(
        handSize: nextHandSize,
        dealer: nextDealer,
        entries: nextEntries,
        isFinalized: false,
        cloudCardResolved: false
      )
      game.rounds.append(nextRound)
      game.currentRoundIndex = game.rounds.count - 1
    }
  }

  /// Validates the corrected round on a copy and only then writes it back, so a failure leaves `game` untouched.
  /// Keeps `handSize`, `dealer` and `isFinalized`; other rounds and `currentRoundIndex` are not changed.
  private func applyEditFinalizedRound(
    game: inout Game,
    roundIndex: Int,
    entries: [UUID: RoundEntry],
    bombPlayed: Bool,
    cloudCardPlayed: Bool
  ) throws {
    guard (0..<game.rounds.count).contains(roundIndex) else {
      throw DomainError.invalidRoundIndex(roundIndex)
    }
    guard game.rounds[roundIndex].isFinalized else {
      throw DomainError.roundNotFinalized
    }
    if (bombPlayed || cloudCardPlayed) && !game.playWithSpecialCards {
      throw DomainError.specialCardsNotEnabled
    }
    guard Set(entries.keys) == Set(game.players.map(\.id)) else {
      throw DomainError.entriesDoNotMatchPlayers
    }
    guard entries.values.allSatisfy({ $0.bet != nil && $0.got != nil }) else {
      throw DomainError.missingInputs
    }

    var edited = game.rounds[roundIndex]
    edited.entries = entries
    edited.bombPlayed = bombPlayed
    // A played Cloud card lifts the bet-sum rule (see `Constraint.GameConstraint.isSatisfied`).
    edited.cloudCardResolved = cloudCardPlayed

    // Ranges (0...handSize), bet sum (rule for this round, waived after Cloud) and won-tricks sum (minus one with Bomb).
    try edited.validateConstraints(
      players: game.players,
      gameConstraints: game.gameConstraints(forRoundAt: roundIndex),
      roundConstraints: [bombPlayed ? .gotSumEqualsHandSizeMinusOne : .gotSumEqualsHandSize]
    )

    game.rounds[roundIndex] = edited
  }

  private func mutateEntry(
    game: inout Game,
    playerId: UUID,
    roundIndex: Int,
    mutate: (inout RoundEntry) -> Void
  ) throws {
    guard game.players.contains(where: { $0.id == playerId }) else {
      throw DomainError.unknownPlayerId(playerId)
    }
    guard (0..<game.rounds.count).contains(roundIndex) else {
      throw DomainError.invalidRoundIndex(roundIndex)
    }
    if game.rounds[roundIndex].isFinalized {
      throw DomainError.roundAlreadyFinalized
    }
    guard var entry = game.rounds[roundIndex].entries[playerId] else {
      throw DomainError.entriesDoNotMatchPlayers
    }
    mutate(&entry)
    game.rounds[roundIndex].entries[playerId] = entry
  }

  private func validateImmediateInputs(game: Game, roundIndex: Int) throws {
    guard (0..<game.rounds.count).contains(roundIndex) else {
      throw DomainError.invalidRoundIndex(roundIndex)
    }

    let round = game.rounds[roundIndex]
    let handSize = round.handSize

    // Minimal immediate validation: range-only.
    for (pid, entry) in round.entries {
      if let bet = entry.bet, !(0...handSize).contains(bet) {
        throw DomainError.invalidBet(playerId: pid, bet: bet, handSize: handSize)
      }
      if let got = entry.got, !(0...handSize).contains(got) {
        throw DomainError.invalidGot(playerId: pid, got: got, handSize: handSize)
      }
    }
  }
}

