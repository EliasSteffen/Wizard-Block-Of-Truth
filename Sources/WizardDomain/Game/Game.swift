import Foundation

public struct Game: Hashable, Codable, Sendable {
  public var id: UUID
  public var name: String
  public var mode: GameMode
  public var players: [Player] // order matters (dealer rotation)
  public var rounds: [Round]
  public var currentRoundIndex: Int
  public private(set) var additionalConstraints: [GameConstraint]

  public init(
    id: UUID,
    name: String,
    mode: GameMode,
    players: [Player],
    rounds: [Round] = [],
    currentRoundIndex: Int? = nil,
    additionalConstraints: [GameConstraint] = [.gotSumEqualsHandSize, .betSumNotEqualHandSize]
  ) throws {
    guard (2...6).contains(players.count) else {
      throw DomainError.invalidPlayerCount(players.count)
    }
    guard Set(players.map(\.id)).count == players.count else {
      throw DomainError.duplicatePlayerIds
    }
    self.id = id
    self.name = name
    self.mode = mode
    self.players = players
    self.rounds = rounds
    self.currentRoundIndex = currentRoundIndex ?? max(0, rounds.count - 1)
    self.additionalConstraints = additionalConstraints

    if rounds.isEmpty {
      // Require caller to create first round via command so rules are consistent.
      self.currentRoundIndex = 0
    } else if !(0..<rounds.count).contains(self.currentRoundIndex) {
      throw DomainError.invalidCurrentRoundIndex(self.currentRoundIndex)
    }
  }

  public var maxHandSizeClassic: Int {
    Rules.maxHandSize(deckSize: 60, playerCount: players.count)
  }

  public var currentRound: Round? {
    guard !rounds.isEmpty else { return nil }
    guard (0..<rounds.count).contains(currentRoundIndex) else { return nil }
    return rounds[currentRoundIndex]
  }

  public func totalPoints() throws -> [UUID: Int] {
    var totals: [UUID: Int] = Dictionary(uniqueKeysWithValues: players.map { ($0.id, 0) })
    for round in rounds where round.isFinalized {
      let deltas = try round.pointsDeltas()
      for (pid, delta) in deltas {
        totals[pid, default: 0] += delta
      }
    }
    return totals
  }

  public mutating func apply(_ command: GameCommand) throws {
    try command.apply(to: &self)
  }

  /// Constraints can only be changed at creation time or before the first round is finalized.
  public mutating func setAdditionalConstraints(_ constraints: [GameConstraint]) throws {
    if rounds.contains(where: { $0.isFinalized }) {
      throw DomainError.constraintsLocked
    }
    additionalConstraints = constraints
  }
}

