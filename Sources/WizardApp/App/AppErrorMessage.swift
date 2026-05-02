import Foundation
#if canImport(WizardDomain)
import WizardDomain
#endif

/// Resolves error text using the same language as Settings (`languageCode` = explicit `en`/`de`, or `nil` = system).
enum AppErrorMessage {
  static func presentableMessage(for error: Error?, languageCode: String?) -> String {
    guard let error else { return "" }
    if let domain = error as? DomainError {
      return domainMessage(domain, languageCode: languageCode)
    }
    return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }

  private static func domainMessage(_ error: DomainError, languageCode: String?) -> String {
    switch error {
    case .invalidPlayerCount(let count):
      return AppLocalization.format(
        "Error.Domain.InvalidPlayerCount",
        languageCode: languageCode,
        fallback: "Invalid player count: %lld. (Allowed: 2–6)",
        count
      )
    case .duplicatePlayerIds:
      return AppLocalization.string(
        "Error.Domain.DuplicatePlayerIds",
        languageCode: languageCode,
        fallback: "Duplicate player ids."
      )
    case .invalidHandSize(let size):
      return AppLocalization.format(
        "Error.Domain.InvalidHandSize",
        languageCode: languageCode,
        fallback: "Invalid hand size: %lld.",
        size
      )
    case .invalidRoundIndex(let idx):
      return AppLocalization.format(
        "Error.Domain.InvalidRoundIndex",
        languageCode: languageCode,
        fallback: "Invalid round index: %lld.",
        idx
      )
    case .invalidCurrentRoundIndex(let idx):
      return AppLocalization.format(
        "Error.Domain.InvalidCurrentRoundIndex",
        languageCode: languageCode,
        fallback: "Invalid current round index: %lld.",
        idx
      )
    case .unknownPlayerId(let id):
      return AppLocalization.format(
        "Error.Domain.UnknownPlayerId",
        languageCode: languageCode,
        fallback: "Unknown player id: %@.",
        id.uuidString
      )
    case .gameAlreadyStarted:
      return AppLocalization.string(
        "Error.Domain.GameAlreadyStarted",
        languageCode: languageCode,
        fallback: "Game already started."
      )
    case .roundAlreadyFinalized:
      return AppLocalization.string(
        "Error.Domain.RoundAlreadyFinalized",
        languageCode: languageCode,
        fallback: "Round already finalized."
      )
    case .missingInputs:
      return AppLocalization.string(
        "Error.Domain.MissingInputs",
        languageCode: languageCode,
        fallback: "Missing inputs (bet/got) for one or more players."
      )
    case .entriesDoNotMatchPlayers:
      return AppLocalization.string(
        "Error.Domain.EntriesDoNotMatchPlayers",
        languageCode: languageCode,
        fallback: "Round entries do not match players."
      )
    case .invalidBet(let playerId, let bet, let handSize):
      return AppLocalization.format(
        "Error.Domain.InvalidBet",
        languageCode: languageCode,
        fallback: "Invalid bet %lld for player %@. Allowed: 0…%lld.",
        bet,
        playerId.uuidString,
        handSize
      )
    case .invalidGot(let playerId, let got, let handSize):
      return AppLocalization.format(
        "Error.Domain.InvalidGot",
        languageCode: languageCode,
        fallback: "Invalid got %lld for player %@. Allowed: 0…%lld.",
        got,
        playerId.uuidString,
        handSize
      )
    case .invalidGotSum(let expected, let actual):
      return AppLocalization.format(
        "Error.Domain.InvalidGotSum",
        languageCode: languageCode,
        fallback: "Invalid got sum: expected %lld, got %lld.",
        expected,
        actual
      )
    case .invalidBetSum(let disallowed):
      return AppLocalization.format(
        "Error.Domain.InvalidBetSum",
        languageCode: languageCode,
        fallback: "Invalid bet sum: cannot equal %lld.",
        disallowed
      )
    case .constraintNotSatisfied(let constraint):
      let title = constraintDisplayTitle(constraint, languageCode: languageCode)
      return AppLocalization.format(
        "Error.Domain.ConstraintNotSatisfied",
        languageCode: languageCode,
        fallback: "Constraint not satisfied: %@.",
        title
      )
    case .constraintsLocked:
      return AppLocalization.string(
        "Error.Domain.ConstraintsLocked",
        languageCode: languageCode,
        fallback: "Constraints are locked after the first finalized round."
      )
    }
  }

  private static func constraintDisplayTitle(_ constraint: Constraint, languageCode: String?) -> String {
    switch constraint {
    case .game(let gameConstraint):
      switch gameConstraint {
      case .betSumNotEqualHandSize:
        return AppLocalization.string(
          "Domain.Constraint.Game.BetSumNotEqualHandSize.Title",
          languageCode: languageCode,
          fallback: "Sum of all Bets is not allowed to be equal to the hand size"
        )
      }
    case .round(let roundConstraint):
      switch roundConstraint {
      case .gotSumEqualsHandSize:
        return AppLocalization.string(
          "Domain.Constraint.Round.GotSumEqualsHandSize.Title",
          languageCode: languageCode,
          fallback: "Sum of all Won tricks must be equal to the Hand Size"
        )
      case .gotSumEqualsHandSizeMinusOne:
        return AppLocalization.string(
          "Domain.Constraint.Round.GotSumEqualsHandSizeMinusOne.Title",
          languageCode: languageCode,
          fallback: "Bomb was played"
        )
      }
    }
  }
}
