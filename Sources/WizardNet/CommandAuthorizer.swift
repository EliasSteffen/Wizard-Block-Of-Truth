import Foundation
#if canImport(WizardDomain)
import WizardDomain
#endif

/// Guest permissions (decision 4: guests own their values, the host overrides).
///
/// A guest may only send `submitBet` / `submitGot` for their own seat in the current, not finalized round:
/// - `submitBet` only while at least one bet of that round is still missing (before this command) and the
///   Cloud card was not played,
/// - `submitGot` only once every bet is in.
/// Everything else is host-only. The host additionally rejects a bet that makes the bet sum equal the hand size
/// while that house rule applies (`betSumViolation(in:roundIndex:)`, checked after applying on a copy).
public enum CommandAuthorizer {
  /// Allow-list of command kinds a guest may send at all (own seat, current round). Everything else is host-only.
  public static func isAllowedGuestCommand(
    _ command: GameCommand,
    guestPlayerId: UUID,
    currentRoundIndex: Int
  ) -> Bool {
    switch command {
    case .submitBet(let playerId, let roundIndex, _):
      return playerId == guestPlayerId && roundIndex == currentRoundIndex
    case .submitGot(let playerId, let roundIndex, _):
      return playerId == guestPlayerId && roundIndex == currentRoundIndex
    default:
      return false
    }
  }

  /// Full permission check against the host's current game. `nil` = allowed.
  public static func guestCommandRejection(
    _ command: GameCommand,
    guestPlayerId: UUID,
    game: Game
  ) -> MultiplayerReasonCode? {
    let playerId: UUID
    let roundIndex: Int
    let isBet: Bool
    switch command {
    case .submitBet(let commandPlayerId, let commandRoundIndex, _):
      playerId = commandPlayerId
      roundIndex = commandRoundIndex
      isBet = true
    case .submitGot(let commandPlayerId, let commandRoundIndex, _):
      playerId = commandPlayerId
      roundIndex = commandRoundIndex
      isBet = false
    default:
      // Allow-list: every other command (incl. ones added later) is host-only.
      return .notAuthorized
    }

    guard playerId == guestPlayerId else { return .notYourSeat }
    guard game.hasStarted else { return .gameNotStarted }
    guard roundIndex == game.currentRoundIndex, game.rounds.indices.contains(roundIndex) else {
      return .notCurrentRound
    }
    let round = game.rounds[roundIndex]
    guard !round.isFinalized else { return .roundFinalized }

    let allBetsPresent = round.entries.values.allSatisfy { $0.bet != nil }
    if isBet {
      if allBetsPresent || round.cloudCardResolved {
        return .betsComplete
      }
    } else if !allBetsPresent {
      return .betsIncomplete
    }
    return nil
  }

  /// Game constraints that apply while bidding in the round at `roundIndex`.
  ///
  /// The single place the host derives them from, so the "first round may add up" house rule only needs to be
  /// wired in here.
  public static func applicableGameConstraints(for game: Game, roundIndex: Int) -> [Constraint.GameConstraint] {
    // TODO(merge): use Game.gameConstraints(forRoundAt:)
    game.gameConstraints
  }

  /// `.betSumEqualsHandSize` when every bet of the round is in, they add up to the hand size and the bet-sum rule
  /// applies (not after a Cloud card). `nil` otherwise.
  public static func betSumViolation(in game: Game, roundIndex: Int) -> MultiplayerReasonCode? {
    guard game.rounds.indices.contains(roundIndex) else { return nil }
    let round = game.rounds[roundIndex]
    let constraints = applicableGameConstraints(for: game, roundIndex: roundIndex)
    guard constraints.contains(.betSumNotEqualHandSize) else { return nil }
    let rule = Constraint.game(.betSumNotEqualHandSize)
    guard !rule.isSatisfied(round: round, players: game.players) else { return nil }
    return .betSumEqualsHandSize(handSize: round.handSize)
  }

  /// Reason code for an error thrown while applying a guest command on the host.
  public static func reasonCode(for error: Error) -> MultiplayerReasonCode {
    guard let domainError = error as? DomainError else { return .internalError }
    if case .roundAlreadyFinalized = domainError { return .roundFinalized }
    if case .invalidBet = domainError { return .invalidValue }
    if case .invalidGot = domainError { return .invalidValue }
    if case .invalidRoundIndex = domainError { return .notCurrentRound }
    if case .unknownPlayerId = domainError { return .seatNotFound }
    if case .entriesDoNotMatchPlayers = domainError { return .seatNotFound }
    return .internalError
  }
}
