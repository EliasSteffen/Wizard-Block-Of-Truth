import Foundation

public enum Constraint: Codable, Sendable, Hashable {
  case game(GameConstraint)
  case round(RoundConstraint)

  public enum GameConstraint: String, Codable, Sendable, Hashable, CaseIterable {
    /// All `bet` values must NOT equal `handSize`.
    case betSumNotEqualHandSize
  }

  public enum RoundConstraint: String, Codable, Sendable, Hashable, CaseIterable {
    /// All `got` values must equal `handSize`.
    case gotSumEqualsHandSize

    /// All `got` values must equal `handSize - 1`. Because the "Bomb" card was played and therefore the whole trick amount is reduced by one.
    case gotSumEqualsHandSizeMinusOne
  }
}

extension Constraint {
  public var title: String {
    switch self {
    case .game(let gameConstraint):
      return gameConstraint.title
    case .round(let roundConstraint):
      return roundConstraint.title
    }
  }

  public var showOnFailure: String {
    switch self {
    case .game(let gameConstraint):
      return gameConstraint.showOnFailure
    case .round(let roundConstraint):
      return roundConstraint.showOnFailure
    }
  }

  public func isSatisfied(round: Round, players: [Player]) -> Bool {
    switch self {
    case .game(let gameConstraint):
      return gameConstraint.isSatisfied(round: round, players: players)
    case .round(let roundConstraint):
      return roundConstraint.isSatisfied(round: round, players: players)
    }
  }
}

extension Constraint.GameConstraint {
  public var title: String {
    switch self {
    case .betSumNotEqualHandSize:
      return "Sum of all Bets is not allowed to be equal to the hand size"
    }
  }

  public var showOnFailure: String {
    switch self {
    case .betSumNotEqualHandSize:
      return "Bets cannot add up to the hand size."
    }
  }

  public func isSatisfied(round: Round, players: [Player]) -> Bool {
    switch self {
    case .betSumNotEqualHandSize:
      guard round.entries.values.allSatisfy({ $0.bet != nil }) else { return true }
      let betSum = round.entries.values.reduce(0) { $0 + ($1.bet ?? 0) }
      return betSum != round.handSize
    }
  }
}

extension Constraint.RoundConstraint {
  public var title: String {
    switch self {
    case .gotSumEqualsHandSize:
      return "Sum of all Won tricks must be equal to the Hand Size"
    case .gotSumEqualsHandSizeMinusOne:
      return "Bomb was played"
    }
  }

  public var showOnFailure: String {
    switch self {
    case .gotSumEqualsHandSize:
      return "Won tricks must add up to the hand size."
    case .gotSumEqualsHandSizeMinusOne:
      return "With Bomb, won tricks must add up to hand size − 1."
    }
  }

  public func isSatisfied(round: Round, players: [Player]) -> Bool {
    switch self {
    case .gotSumEqualsHandSize:
      guard round.entries.values.allSatisfy({ $0.got != nil }) else { return true }
      let gotSum = round.entries.values.reduce(0) { $0 + ($1.got ?? 0) }
      return gotSum == round.handSize

    case .gotSumEqualsHandSizeMinusOne:
      guard round.entries.values.allSatisfy({ $0.got != nil }) else { return true }
      let gotSum = round.entries.values.reduce(0) { $0 + ($1.got ?? 0) }
      return gotSum == round.handSize - 1
    }
  }
}

