import Foundation

public enum DomainError: Error, Equatable {
  case invalidPlayerCount(Int)
  case duplicatePlayerIds
  case invalidHandSize(Int)
  case invalidRoundIndex(Int)
  case invalidCurrentRoundIndex(Int)
  case unknownPlayerId(UUID)
  case gameAlreadyStarted
  case roundAlreadyFinalized
  case missingInputs
  case entriesDoNotMatchPlayers
  case invalidBet(playerId: UUID, bet: Int, handSize: Int)
  case invalidGot(playerId: UUID, got: Int, handSize: Int)
  case invalidGotSum(expected: Int, actual: Int)
  case invalidBetSum(disallowed: Int)
  case constraintNotSatisfied(GameConstraint)
  case constraintsLocked
}

extension DomainError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidPlayerCount(let count):
      return "Invalid player count: \(count). (Allowed: 2–6)"
    case .duplicatePlayerIds:
      return "Duplicate player ids."
    case .invalidHandSize(let size):
      return "Invalid hand size: \(size)."
    case .invalidRoundIndex(let idx):
      return "Invalid round index: \(idx)."
    case .invalidCurrentRoundIndex(let idx):
      return "Invalid current round index: \(idx)."
    case .unknownPlayerId(let id):
      return "Unknown player id: \(id.uuidString)."
    case .gameAlreadyStarted:
      return "Game already started."
    case .roundAlreadyFinalized:
      return "Round already finalized."
    case .missingInputs:
      return "Missing inputs (bet/got) for one or more players."
    case .entriesDoNotMatchPlayers:
      return "Round entries do not match players."
    case .invalidBet(let playerId, let bet, let handSize):
      return "Invalid bet \(bet) for player \(playerId.uuidString). Allowed: 0…\(handSize)."
    case .invalidGot(let playerId, let got, let handSize):
      return "Invalid got \(got) for player \(playerId.uuidString). Allowed: 0…\(handSize)."
    case .invalidGotSum(let expected, let actual):
      return "Invalid got sum: expected \(expected), got \(actual)."
    case .invalidBetSum(let disallowed):
      return "Invalid bet sum: cannot equal \(disallowed)."
    case .constraintNotSatisfied(let constraint):
      return "Constraint not satisfied: \(constraint.rawValue)."
    case .constraintsLocked:
      return "Constraints are locked after the first finalized round."
    }
  }
}
