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

public struct Round: Hashable, Codable, Sendable {
  public var handSize: Int
  public var dealer: UUID
  public var entries: [UUID: RoundEntry]
  public var isFinalized: Bool

  public init(
    handSize: Int,
    dealer: UUID,
    entries: [UUID: RoundEntry],
    isFinalized: Bool = false
  ) {
    self.handSize = handSize
    self.dealer = dealer
    self.entries = entries
    self.isFinalized = isFinalized
  }

  public func validateConstraints(players: [Player], additionalConstraints: [GameConstraint]) throws {
    if handSize <= 0 {
      throw DomainError.invalidHandSize(handSize)
    }

    for (pid, entry) in entries {
      if let bet = entry.bet, !(0...handSize).contains(bet) {
        throw DomainError.invalidBet(playerId: pid, bet: bet, handSize: handSize)
      }
      if let got = entry.got, !(0...handSize).contains(got) {
        throw DomainError.invalidGot(playerId: pid, got: got, handSize: handSize)
      }
    }

    for constraint in additionalConstraints {
      if !constraint.isSatisfied(round: self, players: players) {
        throw DomainError.constraintNotSatisfied(constraint)
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

