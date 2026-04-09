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

