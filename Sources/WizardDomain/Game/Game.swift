import Foundation

public struct Game: Hashable, Codable, Sendable {
  public var id: UUID
  public var name: String
  public var mode: GameMode
  public var playWithSpecialCards: Bool
  public var players: [Player] // order matters (dealer rotation)
  public var rounds: [Round]
  public var currentRoundIndex: Int
  public private(set) var gameConstraints: [Constraint.GameConstraint]

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case mode
    case playWithSpecialCards
    case players
    case rounds
    case currentRoundIndex
    case gameConstraints

    // Legacy key (pre split into game/round constraints).
    case additionalConstraints
  }

  public init(
    id: UUID,
    name: String,
    mode: GameMode,
    playWithSpecialCards: Bool = true,
    players: [Player],
    rounds: [Round] = [],
    currentRoundIndex: Int? = nil,
    gameConstraints: [Constraint.GameConstraint] = [.betSumNotEqualHandSize]
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
    self.playWithSpecialCards = playWithSpecialCards
    self.players = players
    self.rounds = rounds
    self.currentRoundIndex = currentRoundIndex ?? max(0, rounds.count - 1)
    self.gameConstraints = gameConstraints

    if rounds.isEmpty {
      // Require caller to create first round via command so rules are consistent.
      self.currentRoundIndex = 0
    } else if !(0..<rounds.count).contains(self.currentRoundIndex) {
      throw DomainError.invalidCurrentRoundIndex(self.currentRoundIndex)
    }
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(UUID.self, forKey: .id)
    let name = try container.decode(String.self, forKey: .name)
    let mode = try container.decode(GameMode.self, forKey: .mode)
    let playWithSpecialCards = try container.decodeIfPresent(Bool.self, forKey: .playWithSpecialCards) ?? true
    let players = try container.decode([Player].self, forKey: .players)
    let rounds = try container.decode([Round].self, forKey: .rounds)
    let currentRoundIndex = try container.decode(Int.self, forKey: .currentRoundIndex)

    let decodedGameConstraints: [Constraint.GameConstraint]
    if let gc = try container.decodeIfPresent([Constraint.GameConstraint].self, forKey: .gameConstraints) {
      decodedGameConstraints = gc
    } else if let legacy = try container.decodeIfPresent([String].self, forKey: .additionalConstraints) {
      decodedGameConstraints = legacy.compactMap { raw in
        Constraint.GameConstraint(rawValue: raw)
      }
    } else {
      decodedGameConstraints = []
    }

    try self.init(
      id: id,
      name: name,
      mode: mode,
      playWithSpecialCards: playWithSpecialCards,
      players: players,
      rounds: rounds,
      currentRoundIndex: currentRoundIndex,
      gameConstraints: decodedGameConstraints
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(mode, forKey: .mode)
    try container.encode(playWithSpecialCards, forKey: .playWithSpecialCards)
    try container.encode(players, forKey: .players)
    try container.encode(rounds, forKey: .rounds)
    try container.encode(currentRoundIndex, forKey: .currentRoundIndex)
    try container.encode(gameConstraints, forKey: .gameConstraints)

    // Encode legacy key too, so older stored snapshots stay readable by older builds.
    var legacy: [String] = [Constraint.RoundConstraint.gotSumEqualsHandSize.rawValue]
    legacy.append(contentsOf: gameConstraints.map(\.rawValue))
    try container.encode(legacy, forKey: .additionalConstraints)
  }

  public var maxHandSizeClassic: Int {
    Rules.maxHandSize(deckSize: 60, playerCount: players.count)
  }

  public var totalRoundsPlanned: Int {
    switch players.count {
    case 2, 3:
      return 20
    case 4:
      return 15
    case 5:
      return 12
    case 6:
      return 10
    default:
      return maxHandSizeClassic
    }
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

  /// Bet and tricks taken (`got`) as shown on the live scoreboard until every player has entered a bet for the current round.
  ///
  /// Between finalized rounds, the current round has empty entries; this keeps showing the last finalized round's numbers until bidding completes for the new round.
  public func scoreboardDisplayValues(for playerId: UUID) -> (bet: Int?, got: Int?) {
    guard let round = currentRound else {
      return (nil, nil)
    }

    let allBetsPresent = round.entries.values.allSatisfy { $0.bet != nil }

    if !allBetsPresent {
      if let priorFinalized = rounds[..<currentRoundIndex].last(where: \.isFinalized),
         let entry = priorFinalized.entries[playerId] {
        return (entry.bet, entry.got)
      }
      let entry = round.entries[playerId]
      return (entry?.bet, entry?.got)
    }

    let entry = round.entries[playerId]
    return (entry?.bet, entry?.got)
  }

  public mutating func apply(_ command: GameCommand) throws {
    try command.apply(to: &self)
  }

  /// Constraints can only be changed at creation time or before the first round is finalized.
  public mutating func setGameConstraints(_ constraints: [Constraint.GameConstraint]) throws {
    if rounds.contains(where: { $0.isFinalized }) {
      throw DomainError.constraintsLocked
    }
    gameConstraints = constraints
  }
}

