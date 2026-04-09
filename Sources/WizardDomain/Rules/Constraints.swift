import Foundation

public enum GameConstraint: String, Codable, Sendable, Hashable {
  /// All `got` values must equal `handSize`.
  case gotSumEqualsHandSize

  /// All `got` values must equal `handSize - 1`. Because the "Bomb" card was played and therefore the whole trick amount is reduced by one.
  case gotSumEqualsHandSizeMinusOne

  /// All `bet` values must NOT equal `handSize`.
  case betSumNotEqualHandSize
}

extension GameConstraint {
  public var title: String {
    switch self {
    case .gotSumEqualsHandSize:
      return "Got sum = hand size"
    case .gotSumEqualsHandSizeMinusOne:
      return "Bomb played (got sum = hand size - 1)"
    case .betSumNotEqualHandSize:
      return "Bet sum does not equal hand size"
    }
  }

  public var detail: String {
    switch self {
    case .gotSumEqualsHandSize:
      return "The sum of all “got” values must equal the hand size."
    case .gotSumEqualsHandSizeMinusOne:
      return "Use this for rounds where a Bomb was played and the total tricks are reduced by 1."
    case .betSumNotEqualHandSize:
      return "The sum of all bets cannot equal the hand size."
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

    case .betSumNotEqualHandSize:
      guard round.entries.values.allSatisfy({ $0.bet != nil }) else { return true }
      let betSum = round.entries.values.reduce(0) { $0 + ($1.bet ?? 0) }
      return betSum != round.handSize
    }
  }
}

