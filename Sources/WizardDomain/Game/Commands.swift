import Foundation

public enum GameCommand: Hashable, Codable, Sendable {
  case startNewGame(startingDealer: UUID)
  case submitBet(playerId: UUID, roundIndex: Int, bet: Int)
  case submitGot(playerId: UUID, roundIndex: Int, got: Int)
  case finalizeCurrentRound
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
        isFinalized: false
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

    case .finalizeCurrentRound:
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
      // Validate constraints before finalizing.
      try game.rounds[roundIndex].validateConstraints(
        players: game.players,
        additionalConstraints: game.additionalConstraints
      )
      // Ensure all inputs present.
      let entries = game.rounds[roundIndex].entries
      guard entries.values.allSatisfy({ $0.bet != nil && $0.got != nil }) else {
        throw DomainError.missingInputs
      }

      game.rounds[roundIndex].isFinalized = true

      // Only-up progression: append next round until max reached.
      let handSize = game.rounds[roundIndex].handSize
      if handSize >= game.maxHandSizeClassic {
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
        isFinalized: false
      )
      game.rounds.append(nextRound)
      game.currentRoundIndex = game.rounds.count - 1
    }
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

