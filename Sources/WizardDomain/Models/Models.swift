import Foundation

public enum GameMode: String, Codable, Sendable {
  case singlePhone
  case multiPhone
}

public struct Player: Hashable, Codable, Sendable {
  public var id: UUID
  public var name: String

  public init(id: UUID, name: String) {
    self.id = id
    self.name = name
  }
}

public struct RoundEntry: Hashable, Codable, Sendable {
  public var bet: Int?
  public var got: Int?

  public init(bet: Int? = nil, got: Int? = nil) {
    self.bet = bet
    self.got = got
  }

  public func pointsDelta() throws -> Int {
    guard let bet, let got else {
      throw DomainError.missingInputs
    }
    if bet == got {
      return 20 + 10 * bet
    }
    return -10 * abs(bet - got)
  }
}

public struct Round: Hashable, Sendable {
  public var handSize: Int
  public var dealer: UUID
  public var entries: [UUID: RoundEntry]
  public var isFinalized: Bool
  /// True after the cloud-card adjustment was committed for this round (only one cloud card per round).
  public var cloudCardResolved: Bool

  public init(
    handSize: Int,
    dealer: UUID,
    entries: [UUID: RoundEntry],
    isFinalized: Bool = false,
    cloudCardResolved: Bool = false
  ) {
    self.handSize = handSize
    self.dealer = dealer
    self.entries = entries
    self.isFinalized = isFinalized
    self.cloudCardResolved = cloudCardResolved
  }
}

extension Round: Codable {
  private enum CodingKeys: String, CodingKey {
    case handSize
    case dealer
    case entries
    case isFinalized
    case cloudCardResolved
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    handSize = try container.decode(Int.self, forKey: .handSize)
    dealer = try container.decode(UUID.self, forKey: .dealer)
    entries = try container.decode([UUID: RoundEntry].self, forKey: .entries)
    isFinalized = try container.decode(Bool.self, forKey: .isFinalized)
    cloudCardResolved = try container.decodeIfPresent(Bool.self, forKey: .cloudCardResolved) ?? false
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(handSize, forKey: .handSize)
    try container.encode(dealer, forKey: .dealer)
    try container.encode(entries, forKey: .entries)
    try container.encode(isFinalized, forKey: .isFinalized)
    try container.encode(cloudCardResolved, forKey: .cloudCardResolved)
  }
}

extension Round {

  public func validateConstraints(
    players: [Player],
    gameConstraints: [Constraint.GameConstraint],
    roundConstraints: [Constraint.RoundConstraint]
  ) throws {
    if handSize <= 0 {
      throw DomainError.invalidHandSize(handSize)
    }

    let playerIds = Set(players.map(\.id))
    guard playerIds.contains(dealer) else {
      throw DomainError.unknownPlayerId(dealer)
    }
    guard Set(entries.keys) == playerIds else {
      throw DomainError.entriesDoNotMatchPlayers
    }

    for (pid, entry) in entries {
      if let bet = entry.bet, !(0...handSize).contains(bet) {
        throw DomainError.invalidBet(playerId: pid, bet: bet, handSize: handSize)
      }
      if let got = entry.got, !(0...handSize).contains(got) {
        throw DomainError.invalidGot(playerId: pid, got: got, handSize: handSize)
      }
    }

    for constraint in gameConstraints {
      let wrapped: Constraint = .game(constraint)
      if !wrapped.isSatisfied(round: self, players: players) {
        throw DomainError.constraintNotSatisfied(wrapped)
      }
    }
    for constraint in roundConstraints {
      let wrapped: Constraint = .round(constraint)
      if !wrapped.isSatisfied(round: self, players: players) {
        throw DomainError.constraintNotSatisfied(wrapped)
      }
    }
  }

  public func pointsDeltas() throws -> [UUID: Int] {
    var deltas: [UUID: Int] = [:]
    deltas.reserveCapacity(entries.count)
    for (pid, entry) in entries {
      deltas[pid] = try entry.pointsDelta()
    }
    return deltas
  }
}

