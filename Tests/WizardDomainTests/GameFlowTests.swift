import XCTest
@testable import WizardDomain

final class GameFlowTests: XCTestCase {
  func testStartNewGameCreatesRound1() throws {
    let players = TestSupport.makePlayers(3)
    var game = try Game(
      id: UUID(),
      name: "Test",
      mode: .singlePhone,
      players: players
    )

    XCTAssertTrue(game.rounds.isEmpty)
    try game.apply(.startNewGame(startingDealer: players[0].id))

    XCTAssertEqual(game.rounds.count, 1)
    XCTAssertEqual(game.currentRoundIndex, 0)
    XCTAssertEqual(game.currentRound?.handSize, 1)
    XCTAssertEqual(game.currentRound?.dealer, players[0].id)
    XCTAssertFalse(game.currentRound?.isFinalized ?? true)
  }

  func testStartNewGameRejectsUnknownDealer() throws {
    let players = TestSupport.makePlayers(3)
    var game = try Game(id: UUID(), name: "Test", mode: .singlePhone, players: players)
    let unknown = UUID()
    XCTAssertThrowsError(try game.apply(.startNewGame(startingDealer: unknown))) { err in
      XCTAssertEqual(err as? DomainError, .unknownPlayerId(unknown))
    }
  }

  func testStartNewGameRejectsWhenAlreadyStarted() throws {
    let players = TestSupport.makePlayers(3)
    var game = try Game(id: UUID(), name: "Test", mode: .singlePhone, players: players)
    try game.apply(.startNewGame(startingDealer: players[0].id))
    XCTAssertThrowsError(try game.apply(.startNewGame(startingDealer: players[1].id))) { err in
      XCTAssertEqual(err as? DomainError, .gameAlreadyStarted)
    }
  }

  func testFinalizeCurrentRoundRequiresAllInputs() throws {
    let players = TestSupport.makePlayers(3)
    var game = try Game(id: UUID(), name: "Test", mode: .singlePhone, players: players)
    try game.apply(.startNewGame(startingDealer: players[0].id))

    // Ensure we don't trip the classic bet-sum constraint for handSize=1.
    try game.apply(.submitBet(playerId: players[0].id, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: players[2].id, roundIndex: 0, bet: 0))

    XCTAssertThrowsError(try game.apply(.finalizeCurrentRound())) { err in
      XCTAssertEqual(err as? DomainError, .missingInputs)
    }
  }

  func testFinalizeCurrentRoundValidatesClassicBetSumDisallowed() throws {
    let players = TestSupport.makePlayers(3)
    var game = try Game(id: UUID(), name: "Test", mode: .singlePhone, players: players)
    try game.apply(.startNewGame(startingDealer: players[0].id))

    // Bets sum equals handSize (1) -> disallowed at finalize.
    try game.apply(.submitBet(playerId: players[0].id, roundIndex: 0, bet: 1))
    try game.apply(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: players[2].id, roundIndex: 0, bet: 0))

    // Provide got values that sum correctly.
    try game.apply(.submitGot(playerId: players[0].id, roundIndex: 0, got: 1))
    try game.apply(.submitGot(playerId: players[1].id, roundIndex: 0, got: 0))
    try game.apply(.submitGot(playerId: players[2].id, roundIndex: 0, got: 0))

    XCTAssertThrowsError(try game.apply(.finalizeCurrentRound())) { err in
      XCTAssertEqual(err as? DomainError, .constraintNotSatisfied(.game(.betSumNotEqualHandSize)))
    }
  }

  func testFinalizeCurrentRoundAdvancesDealerAndAppendsNextRound() throws {
    let players = TestSupport.makePlayers(3)
    var game = try Game(id: UUID(), name: "Test", mode: .singlePhone, players: players)
    try game.apply(.startNewGame(startingDealer: players[0].id))

    // Round 1, handSize=1
    // Ensure betSum != 1.
    try game.apply(.submitBet(playerId: players[0].id, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: players[2].id, roundIndex: 0, bet: 0))

    // gotSum must equal 1.
    try game.apply(.submitGot(playerId: players[0].id, roundIndex: 0, got: 1))
    try game.apply(.submitGot(playerId: players[1].id, roundIndex: 0, got: 0))
    try game.apply(.submitGot(playerId: players[2].id, roundIndex: 0, got: 0))

    try game.apply(.finalizeCurrentRound())

    XCTAssertTrue(game.rounds[0].isFinalized)
    XCTAssertEqual(game.rounds.count, 2)
    XCTAssertEqual(game.currentRoundIndex, 1)
    XCTAssertEqual(game.rounds[1].handSize, 2)
    XCTAssertEqual(game.rounds[1].dealer, players[1].id) // P1 -> P2
  }

  func testTotalsSumFromFinalizedRoundsOnly() throws {
    let players = TestSupport.makePlayers(2)
    var game = try Game(id: UUID(), name: "Test", mode: .singlePhone, players: players)
    try game.apply(.startNewGame(startingDealer: players[0].id))

    // Round 1, handSize=1, avoid betSum==1 by using (0,0)
    try game.apply(.submitBet(playerId: players[0].id, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 0))
    try game.apply(.submitGot(playerId: players[0].id, roundIndex: 0, got: 1))
    try game.apply(.submitGot(playerId: players[1].id, roundIndex: 0, got: 0))

    let beforeFinalize = try game.totalPoints()
    XCTAssertEqual(beforeFinalize[players[0].id], 0)
    XCTAssertEqual(beforeFinalize[players[1].id], 0)

    try game.apply(.finalizeCurrentRound())

    let totals = try game.totalPoints()
    // P1 bet0 got1 => -10, P2 bet0 got0 => +20
    XCTAssertEqual(totals[players[0].id], -10)
    XCTAssertEqual(totals[players[1].id], 20)
  }

  func testConstraintsCanOnlyChangeBeforeFirstFinalize() throws {
    let players = TestSupport.makePlayers(3)
    var game = try Game(id: UUID(), name: "Test", mode: .singlePhone, players: players)
    try game.apply(.startNewGame(startingDealer: players[0].id))

    // Allowed before finalize.
    XCTAssertNoThrow(try game.setGameConstraints([]))

    // Finalize round 1 (need valid inputs).
    try game.apply(.submitBet(playerId: players[0].id, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: players[2].id, roundIndex: 0, bet: 0))
    try game.apply(.submitGot(playerId: players[0].id, roundIndex: 0, got: 1))
    try game.apply(.submitGot(playerId: players[1].id, roundIndex: 0, got: 0))
    try game.apply(.submitGot(playerId: players[2].id, roundIndex: 0, got: 0))
    try game.apply(.finalizeCurrentRound())

    // Now locked.
    XCTAssertThrowsError(try game.setGameConstraints([.betSumNotEqualHandSize])) { err in
      XCTAssertEqual(err as? DomainError, .constraintsLocked)
    }
  }

  func testSubmitBetRejectsOutOfRangeImmediately() throws {
    let players = TestSupport.makePlayers(3)
    var game = try Game(id: UUID(), name: "Test", mode: .singlePhone, players: players)
    try game.apply(.startNewGame(startingDealer: players[0].id))

    XCTAssertThrowsError(try game.apply(.submitBet(playerId: players[0].id, roundIndex: 0, bet: 2))) { err in
      XCTAssertEqual(err as? DomainError, .invalidBet(playerId: players[0].id, bet: 2, handSize: 1))
    }
  }

  func testFinalizeCurrentRoundRejectsWrongGotSum() throws {
    let players = TestSupport.makePlayers(3)
    var game = try Game(id: UUID(), name: "Test", mode: .singlePhone, players: players)
    try game.apply(.startNewGame(startingDealer: players[0].id))

    // Valid bets (avoid betSum==1).
    try game.apply(.submitBet(playerId: players[0].id, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: players[2].id, roundIndex: 0, bet: 0))

    // gotSum should be 1, but we make it 0.
    try game.apply(.submitGot(playerId: players[0].id, roundIndex: 0, got: 0))
    try game.apply(.submitGot(playerId: players[1].id, roundIndex: 0, got: 0))
    try game.apply(.submitGot(playerId: players[2].id, roundIndex: 0, got: 0))

    XCTAssertThrowsError(try game.apply(.finalizeCurrentRound())) { err in
      XCTAssertEqual(err as? DomainError, .constraintNotSatisfied(.round(.gotSumEqualsHandSize)))
    }
  }

  func testSubmitGotRejectsOutOfRangeImmediately() throws {
    let players = TestSupport.makePlayers(3)
    var game = try Game(id: UUID(), name: "Test", mode: .singlePhone, players: players)
    try game.apply(.startNewGame(startingDealer: players[0].id))

    XCTAssertThrowsError(try game.apply(.submitGot(playerId: players[0].id, roundIndex: 0, got: 2))) { err in
      XCTAssertEqual(err as? DomainError, .invalidGot(playerId: players[0].id, got: 2, handSize: 1))
    }
  }

  func testSubmitBetRejectsUnknownPlayer() throws {
    let players = TestSupport.makePlayers(3)
    var game = try Game(id: UUID(), name: "Test", mode: .singlePhone, players: players)
    try game.apply(.startNewGame(startingDealer: players[0].id))
    let unknown = UUID()
    XCTAssertThrowsError(try game.apply(.submitBet(playerId: unknown, roundIndex: 0, bet: 0))) { err in
      XCTAssertEqual(err as? DomainError, .unknownPlayerId(unknown))
    }
  }

  func testSubmitGotRejectsInvalidRoundIndex() throws {
    let players = TestSupport.makePlayers(3)
    var game = try Game(id: UUID(), name: "Test", mode: .singlePhone, players: players)
    try game.apply(.startNewGame(startingDealer: players[0].id))
    XCTAssertThrowsError(try game.apply(.submitGot(playerId: players[0].id, roundIndex: 99, got: 0))) { err in
      XCTAssertEqual(err as? DomainError, .invalidRoundIndex(99))
    }
  }

  func testFinalizeRejectsAlreadyFinalized() throws {
    let players = TestSupport.makePlayers(2)
    var game = try Game(id: UUID(), name: "Test", mode: .singlePhone, players: players)
    try game.apply(.startNewGame(startingDealer: players[0].id))

    // avoid betSum==1 by using (0,0)
    try game.apply(.submitBet(playerId: players[0].id, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 0))
    try game.apply(.submitGot(playerId: players[0].id, roundIndex: 0, got: 1))
    try game.apply(.submitGot(playerId: players[1].id, roundIndex: 0, got: 0))
    try game.apply(.finalizeCurrentRound())

    // Finalize advances to the next round; switch back to the finalized round.
    game.currentRoundIndex = 0
    XCTAssertThrowsError(try game.apply(.finalizeCurrentRound())) { err in
      XCTAssertEqual(err as? DomainError, .roundAlreadyFinalized)
    }
  }

  func testFinalizeWithBombConstraintVariant() throws {
    let players = TestSupport.makePlayers(3)
    var game = try Game(id: UUID(), name: "Test", mode: .singlePhone, players: players)
    try game.apply(.startNewGame(startingDealer: players[0].id))

    // bets avoid betSum==1 by using (0,0,0)
    try game.apply(.submitBet(playerId: players[0].id, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: players[2].id, roundIndex: 0, bet: 0))

    // For handSize=1, bomb constraint expects gotSum == 0.
    try game.apply(.submitGot(playerId: players[0].id, roundIndex: 0, got: 0))
    try game.apply(.submitGot(playerId: players[1].id, roundIndex: 0, got: 0))
    try game.apply(.submitGot(playerId: players[2].id, roundIndex: 0, got: 0))

    XCTAssertNoThrow(try game.apply(.finalizeCurrentRound(roundConstraints: [.gotSumEqualsHandSizeMinusOne])))
  }
}

