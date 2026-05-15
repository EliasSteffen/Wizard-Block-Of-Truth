import XCTest
@testable import WizardNet
@testable import WizardDomain

final class CommandAuthorizerTests: XCTestCase {
  func testGuestCanSubmitOwnBetForCurrentRound() {
    let playerID = UUID()
    let command = GameCommand.submitBet(playerId: playerID, roundIndex: 3, bet: 1)
    XCTAssertTrue(CommandAuthorizer.isAllowedGuestCommand(command, guestPlayerId: playerID, currentRoundIndex: 3))
  }

  func testGuestCannotSubmitOtherPlayersCommand() {
    let guestID = UUID()
    let command = GameCommand.submitGot(playerId: UUID(), roundIndex: 1, got: 1)
    XCTAssertFalse(CommandAuthorizer.isAllowedGuestCommand(command, guestPlayerId: guestID, currentRoundIndex: 1))
  }

  func testGuestCannotSubmitOutsideCurrentRound() {
    let guestID = UUID()
    let command = GameCommand.submitBet(playerId: guestID, roundIndex: 4, bet: 0)
    XCTAssertFalse(CommandAuthorizer.isAllowedGuestCommand(command, guestPlayerId: guestID, currentRoundIndex: 5))
  }

  func testGuestCannotRunAdministrativeCommands() {
    let guestID = UUID()
    XCTAssertFalse(
      CommandAuthorizer.isAllowedGuestCommand(
        .finalizeCurrentRound(),
        guestPlayerId: guestID,
        currentRoundIndex: 0
      )
    )
  }
}
