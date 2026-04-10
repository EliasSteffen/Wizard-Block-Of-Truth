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
  case constraintNotSatisfied(Constraint)
  case constraintsLocked
}

extension DomainError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidPlayerCount(let count):
      return String(localized: "Error.Domain.InvalidPlayerCount", defaultValue: "Invalid player count: \(count). (Allowed: 2–6)")
    case .duplicatePlayerIds:
      return String(localized: "Error.Domain.DuplicatePlayerIds", defaultValue: "Duplicate player ids.")
    case .invalidHandSize(let size):
      return String(localized: "Error.Domain.InvalidHandSize", defaultValue: "Invalid hand size: \(size).")
    case .invalidRoundIndex(let idx):
      return String(localized: "Error.Domain.InvalidRoundIndex", defaultValue: "Invalid round index: \(idx).")
    case .invalidCurrentRoundIndex(let idx):
      return String(localized: "Error.Domain.InvalidCurrentRoundIndex", defaultValue: "Invalid current round index: \(idx).")
    case .unknownPlayerId(let id):
      return String(localized: "Error.Domain.UnknownPlayerId", defaultValue: "Unknown player id: \(id.uuidString).")
    case .gameAlreadyStarted:
      return String(localized: "Error.Domain.GameAlreadyStarted", defaultValue: "Game already started.")
    case .roundAlreadyFinalized:
      return String(localized: "Error.Domain.RoundAlreadyFinalized", defaultValue: "Round already finalized.")
    case .missingInputs:
      return String(localized: "Error.Domain.MissingInputs", defaultValue: "Missing inputs (bet/got) for one or more players.")
    case .entriesDoNotMatchPlayers:
      return String(localized: "Error.Domain.EntriesDoNotMatchPlayers", defaultValue: "Round entries do not match players.")
    case .invalidBet(let playerId, let bet, let handSize):
      return String(localized: "Error.Domain.InvalidBet", defaultValue: "Invalid bet \(bet) for player \(playerId.uuidString). Allowed: 0…\(handSize).")
    case .invalidGot(let playerId, let got, let handSize):
      return String(localized: "Error.Domain.InvalidGot", defaultValue: "Invalid got \(got) for player \(playerId.uuidString). Allowed: 0…\(handSize).")
    case .invalidGotSum(let expected, let actual):
      return String(localized: "Error.Domain.InvalidGotSum", defaultValue: "Invalid got sum: expected \(expected), got \(actual).")
    case .invalidBetSum(let disallowed):
      return String(localized: "Error.Domain.InvalidBetSum", defaultValue: "Invalid bet sum: cannot equal \(disallowed).")
    case .constraintNotSatisfied(let constraint):
      return String(localized: "Error.Domain.ConstraintNotSatisfied", defaultValue: "Constraint not satisfied: \(constraint.title).")
    case .constraintsLocked:
      return String(localized: "Error.Domain.ConstraintsLocked", defaultValue: "Constraints are locked after the first finalized round.")
    }
  }
}
