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

  // MARK: - Permission matrix against the host's game (decision 4)

  private let players = NetTestSupport.players(["Ann", "Ben", "Cid"])
  private var guest: UUID { players[1].id }

  private func rejection(_ command: GameCommand, in game: Game) -> MultiplayerReasonCode? {
    CommandAuthorizer.guestCommandRejection(command, guestPlayerId: guest, game: game)
  }

  private func game(bets: [Int?], gots: [Int?] = [nil, nil, nil]) throws -> Game {
    var game = try NetTestSupport.startedGame(players)
    for (index, bet) in bets.enumerated() {
      if let bet { try game.apply(.submitBet(playerId: players[index].id, roundIndex: 0, bet: bet)) }
    }
    for (index, got) in gots.enumerated() {
      if let got { try game.apply(.submitGot(playerId: players[index].id, roundIndex: 0, got: got)) }
    }
    return game
  }

  func testGuestMayBetWhileBetsAreIncomplete() throws {
    XCTAssertNil(rejection(.submitBet(playerId: guest, roundIndex: 0, bet: 1), in: try game(bets: [nil, nil, nil])))
  }

  func testGuestMayChangeOwnBetWhileAnotherBetIsMissing() throws {
    XCTAssertNil(rejection(.submitBet(playerId: guest, roundIndex: 0, bet: 0), in: try game(bets: [0, 1, nil])))
  }

  func testGuestCannotBetOnceAllBetsAreIn() throws {
    XCTAssertEqual(
      rejection(.submitBet(playerId: guest, roundIndex: 0, bet: 0), in: try game(bets: [0, 1, 1])),
      .betsComplete
    )
  }

  func testGuestCannotBetAfterCloudCard() throws {
    var cloud = try game(bets: [0, nil, nil])
    try cloud.apply(.markCloudCardResolved(roundIndex: 0))
    XCTAssertEqual(rejection(.submitBet(playerId: guest, roundIndex: 0, bet: 1), in: cloud), .betsComplete)
  }

  func testGuestCannotEnterWonTricksBeforeAllBets() throws {
    XCTAssertEqual(
      rejection(.submitGot(playerId: guest, roundIndex: 0, got: 1), in: try game(bets: [0, 1, nil])),
      .betsIncomplete
    )
  }

  func testGuestMayEnterAndCorrectWonTricksOnceAllBetsAreIn() throws {
    XCTAssertNil(rejection(.submitGot(playerId: guest, roundIndex: 0, got: 1), in: try game(bets: [0, 1, 1])))
    XCTAssertNil(
      rejection(.submitGot(playerId: guest, roundIndex: 0, got: 0), in: try game(bets: [0, 1, 1], gots: [nil, 1, nil]))
    )
  }

  func testGuestCannotTouchAnotherSeat() throws {
    let current = try game(bets: [nil, nil, nil])
    XCTAssertEqual(rejection(.submitBet(playerId: players[0].id, roundIndex: 0, bet: 0), in: current), .notYourSeat)
    XCTAssertEqual(rejection(.submitGot(playerId: players[2].id, roundIndex: 0, got: 0), in: current), .notYourSeat)
  }

  func testGuestCannotTouchPastRound() throws {
    var played = try game(bets: [0, 0, 0], gots: [1, 0, 0])
    try played.apply(.finalizeCurrentRound())
    XCTAssertEqual(played.currentRoundIndex, 1)
    XCTAssertEqual(rejection(.submitGot(playerId: guest, roundIndex: 0, got: 1), in: played), .notCurrentRound)
    XCTAssertEqual(rejection(.submitBet(playerId: guest, roundIndex: 0, bet: 1), in: played), .notCurrentRound)
    XCTAssertNil(rejection(.submitBet(playerId: guest, roundIndex: 1, bet: 1), in: played))
  }

  func testGuestCannotTouchFinalizedRound() throws {
    let entries = Dictionary(uniqueKeysWithValues: players.enumerated().map { index, player in
      (player.id, RoundEntry(bet: 0, got: index == 0 ? 1 : 0))
    })
    let finalized = try Game(
      id: UUID(),
      name: "Done",
      mode: .multiPhone,
      players: players,
      rounds: [Round(handSize: 1, dealer: players[0].id, entries: entries, isFinalized: true)],
      currentRoundIndex: 0
    )
    XCTAssertEqual(rejection(.submitGot(playerId: guest, roundIndex: 0, got: 1), in: finalized), .roundFinalized)
    XCTAssertEqual(rejection(.submitBet(playerId: guest, roundIndex: 0, bet: 1), in: finalized), .roundFinalized)
  }

  func testGuestCommandsBeforeStartAreRejected() throws {
    let setup = try NetTestSupport.setupGame(players)
    XCTAssertEqual(rejection(.submitBet(playerId: guest, roundIndex: 0, bet: 0), in: setup), .gameNotStarted)
  }

  func testHostOnlyCommandsAreNotAuthorized() throws {
    let current = try game(bets: [0, 1, 1], gots: [1, 0, 0])
    XCTAssertEqual(rejection(.finalizeCurrentRound(), in: current), .notAuthorized)
    XCTAssertEqual(rejection(.markCloudCardResolved(roundIndex: 0), in: current), .notAuthorized)
    XCTAssertEqual(rejection(.startNewGame(startingDealer: guest), in: current), .notAuthorized)
  }

  func testBetSumViolation() throws {
    // Hand size 1: bets 0 + 1 + 0 = 1 → violates the rule.
    XCTAssertEqual(CommandAuthorizer.betSumViolation(in: try game(bets: [0, 1, 0]), roundIndex: 0), .betSumEqualsHandSize(handSize: 1))
    XCTAssertNil(CommandAuthorizer.betSumViolation(in: try game(bets: [0, 1, 1]), roundIndex: 0))
    XCTAssertNil(CommandAuthorizer.betSumViolation(in: try game(bets: [0, 1, nil]), roundIndex: 0))

    var withoutRule = try game(bets: [0, 1, 0])
    try withoutRule.setGameConstraints([])
    XCTAssertNil(CommandAuthorizer.betSumViolation(in: withoutRule, roundIndex: 0))

    var afterCloud = try game(bets: [0, 1, 0])
    try afterCloud.apply(.markCloudCardResolved(roundIndex: 0))
    XCTAssertNil(CommandAuthorizer.betSumViolation(in: afterCloud, roundIndex: 0))
  }

  func testApplicableGameConstraintsFollowTheGame() throws {
    var current = try game(bets: [nil, nil, nil])
    XCTAssertEqual(CommandAuthorizer.applicableGameConstraints(for: current, roundIndex: 0), [.betSumNotEqualHandSize])
    try current.setGameConstraints([])
    XCTAssertEqual(CommandAuthorizer.applicableGameConstraints(for: current, roundIndex: 0), [])
  }

  func testDomainErrorsMapToReasonCodes() {
    XCTAssertEqual(CommandAuthorizer.reasonCode(for: DomainError.roundAlreadyFinalized), .roundFinalized)
    XCTAssertEqual(
      CommandAuthorizer.reasonCode(for: DomainError.invalidBet(playerId: UUID(), bet: 9, handSize: 1)),
      .invalidValue
    )
    XCTAssertEqual(CommandAuthorizer.reasonCode(for: DomainError.missingInputs), .internalError)
  }
}
