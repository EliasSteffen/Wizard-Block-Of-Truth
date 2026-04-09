import Foundation

public enum GameConstraint: String, Codable, Sendable, Hashable {
  /// If all `got` values are present, their sum must equal `handSize`.
  case gotSumEqualsHandSize

  /// If all `bet` values are present, their sum must NOT equal `handSize`.
  case betSumNotEqualHandSize
}

extension GameConstraint {
  public func isSatisfied(round: Round, players: [Player]) -> Bool {
    switch self {
    case .gotSumEqualsHandSize:
      // Don't block partial entry; finalize already requires complete inputs.
      guard round.entries.values.allSatisfy({ $0.got != nil }) else { return true }
      let gotSum = round.entries.values.reduce(0) { $0 + ($1.got ?? 0) }
      return gotSum == round.handSize

    case .betSumNotEqualHandSize:
      // Don't block partial entry; finalize already requires complete inputs.
      guard round.entries.values.allSatisfy({ $0.bet != nil }) else { return true }
      let betSum = round.entries.values.reduce(0) { $0 + ($1.bet ?? 0) }
      return betSum != round.handSize
    }
  }
}

