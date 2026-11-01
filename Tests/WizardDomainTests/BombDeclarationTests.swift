import XCTest
@testable import WizardDomain

/// `GameCommand.setBombPlayed`: the host declares the Bomb while the round is open (persisted on the round so guests
/// see it), and finalizing without explicit constraints follows that flag.
final class BombDeclarationTests: XCTestCase {
  private func makeStartedGame(players: [Player], playWithSpecialCards: Bool = true) throws -> Game {
    var game = try Game(
      id: UUID(),
      name: "Test",
      mode: .multiPhone,
      playWithSpecialCards: playWithSpecialCards,
      players: players
    )
    try game.apply(.startNewGame(startingDealer: players[0].id))
    return game
  }

  /// Plays the open round to "all bets and won tricks entered" (bets 0, won tricks as given).
  private func enter(gots: [Int], in game: inout Game, players: [Player]) throws {
    let roundIndex = game.currentRoundIndex
    for player in players {
      try game.apply(.submitBet(playerId: player.id, roundIndex: roundIndex, bet: 0))
    }
    for (index, got) in gots.enumerated() {
      try game.apply(.submitGot(playerId: players[index].id, roundIndex: roundIndex, got: got))
    }
  }

  /// Moves to round 2 (hand size 2) by finalizing round 1 normally.
  private func advanceToSecondRound(_ game: inout Game, players: [Player]) throws {
    try enter(gots: [1, 0, 0], in: &game, players: players)
    try game.apply(.finalizeCurrentRound())
    XCTAssertEqual(game.currentRoundIndex, 1)
  }

  func testDeclaringAndClearingTheBombUpdatesTheOpenRound() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeStartedGame(players: players)

    try game.apply(.setBombPlayed(roundIndex: 0, played: true))
    XCTAssertTrue(game.rounds[0].bombPlayed)
    XCTAssertTrue(game.rounds[0].inferredBombPlayed)
    XCTAssertFalse(game.rounds[0].isFinalized)

    try game.apply(.setBombPlayed(roundIndex: 0, played: false))
    XCTAssertFalse(game.rounds[0].bombPlayed)
  }

  func testDeclaringTheBombDoesNotTouchEntries() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeStartedGame(players: players)
    try enter(gots: [1, 0, 0], in: &game, players: players)
    let entriesBefore = game.rounds[0].entries

    try game.apply(.setBombPlayed(roundIndex: 0, played: true))

    XCTAssertEqual(game.rounds[0].entries, entriesBefore)
    XCTAssertFalse(game.rounds[0].cloudCardResolved)
  }

  func testDeclaringTheBombRequiresSpecialCards() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeStartedGame(players: players, playWithSpecialCards: false)

    XCTAssertThrowsError(try game.apply(.setBombPlayed(roundIndex: 0, played: true))) { error in
      XCTAssertEqual(error as? DomainError, .specialCardsNotEnabled)
    }
    XCTAssertFalse(game.rounds[0].bombPlayed)
    // Clearing is harmless and always allowed.
    XCTAssertNoThrow(try game.apply(.setBombPlayed(roundIndex: 0, played: false)))
  }

  func testDeclaringTheBombOnAFinalizedRoundFails() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeStartedGame(players: players)
    try advanceToSecondRound(&game, players: players)

    XCTAssertThrowsError(try game.apply(.setBombPlayed(roundIndex: 0, played: true))) { error in
      XCTAssertEqual(error as? DomainError, .roundAlreadyFinalized)
    }
    XCTAssertFalse(game.rounds[0].bombPlayed)
  }

  func testDeclaringTheBombForAnUnknownRoundFails() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeStartedGame(players: players)

    XCTAssertThrowsError(try game.apply(.setBombPlayed(roundIndex: 3, played: true))) { error in
      XCTAssertEqual(error as? DomainError, .invalidRoundIndex(3))
    }
    XCTAssertThrowsError(try game.apply(.setBombPlayed(roundIndex: -1, played: true))) { error in
      XCTAssertEqual(error as? DomainError, .invalidRoundIndex(-1))
    }
  }

  func testDeclaringTheBombBeforeTheGameStartedFails() throws {
    let players = TestSupport.makePlayers(3)
    var game = try Game(id: UUID(), name: "Setup", mode: .multiPhone, players: players)

    XCTAssertThrowsError(try game.apply(.setBombPlayed(roundIndex: 0, played: true))) { error in
      XCTAssertEqual(error as? DomainError, .invalidRoundIndex(0))
    }
  }

  // MARK: - Finalize follows the declared Bomb

  func testFinalizeWithoutConstraintsUsesTheDeclaredBomb() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeStartedGame(players: players)
    try advanceToSecondRound(&game, players: players)

    // Hand size 2 with the Bomb: won tricks must add up to 1.
    try game.apply(.setBombPlayed(roundIndex: 1, played: true))
    try enter(gots: [1, 0, 0], in: &game, players: players)
    try game.apply(.finalizeCurrentRound())

    XCTAssertTrue(game.rounds[1].isFinalized)
    XCTAssertTrue(game.rounds[1].bombPlayed)
    XCTAssertEqual(game.currentRoundIndex, 2)
    XCTAssertFalse(game.rounds[2].bombPlayed, "The next round starts without a Bomb")
  }

  func testFinalizeWithDeclaredBombRejectsAFullTrickSum() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeStartedGame(players: players)
    try advanceToSecondRound(&game, players: players)

    try game.apply(.setBombPlayed(roundIndex: 1, played: true))
    try enter(gots: [2, 0, 0], in: &game, players: players)

    XCTAssertThrowsError(try game.apply(.finalizeCurrentRound())) { error in
      XCTAssertEqual(error as? DomainError, .constraintNotSatisfied(.round(.gotSumEqualsHandSizeMinusOne)))
    }
    XCTAssertFalse(game.rounds[1].isFinalized)
    XCTAssertTrue(game.rounds[1].bombPlayed, "A failed finalize keeps the declaration")
  }

  func testFinalizeWithoutBombRejectsAReducedTrickSum() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeStartedGame(players: players)
    try advanceToSecondRound(&game, players: players)

    try enter(gots: [1, 0, 0], in: &game, players: players)

    XCTAssertThrowsError(try game.apply(.finalizeCurrentRound())) { error in
      XCTAssertEqual(error as? DomainError, .constraintNotSatisfied(.round(.gotSumEqualsHandSize)))
    }
  }

  func testExplicitFinalizeConstraintsWinOverTheDeclaredFlag() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeStartedGame(players: players)
    try advanceToSecondRound(&game, players: players)

    try game.apply(.setBombPlayed(roundIndex: 1, played: true))
    try enter(gots: [2, 0, 0], in: &game, players: players)
    try game.apply(.finalizeCurrentRound(roundConstraints: [.gotSumEqualsHandSize]))

    XCTAssertTrue(game.rounds[1].isFinalized)
    XCTAssertFalse(game.rounds[1].bombPlayed, "The constraint actually used decides the stored flag")
  }

  func testDeclaredBombCountsForScoring() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeStartedGame(players: players)

    // Hand size 1 with the Bomb: nobody wins a trick; every bet of 0 is exact (+20 each).
    try game.apply(.setBombPlayed(roundIndex: 0, played: true))
    try enter(gots: [0, 0, 0], in: &game, players: players)
    try game.apply(.finalizeCurrentRound())

    let totals = try game.totalPoints()
    for player in players {
      XCTAssertEqual(totals[player.id], 20)
    }
  }

  func testSetBombPlayedCommandRoundTripsThroughCodable() throws {
    let command = GameCommand.setBombPlayed(roundIndex: 4, played: true)
    let data = try JSONEncoder().encode(command)
    XCTAssertEqual(try JSONDecoder().decode(GameCommand.self, from: data), command)
  }
}
