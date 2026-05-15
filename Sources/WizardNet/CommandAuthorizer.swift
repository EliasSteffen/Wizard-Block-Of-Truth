import Foundation
#if canImport(WizardDomain)
import WizardDomain
#endif

public enum CommandAuthorizer {
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
}
