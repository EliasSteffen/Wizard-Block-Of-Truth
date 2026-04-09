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
