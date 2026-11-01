import XCTest
@testable import WizardDomain

/// House rule "Erste Runde darf aufgehen" (`Game.firstRoundBetSumMayEqualHandSize`).
final class FirstRoundBetSumRuleTests: XCTestCase {
  private func makeGame(
    players: [Player],
    gameConstraints: [Constraint.GameConstraint] = [.betSumNotEqualHandSize],
    firstRoundBetSumMayEqualHandSize: Bool = false
  ) throws -> Game {
    try Game(
      id: UUID(),
      name: "Test",
      mode: .singlePhone,
      players: players,
      gameConstraints: gameConstraints,
      firstRoundBetSumMayEqualHandSize: firstRoundBetSumMayEqualHandSize
    )
  }

  /// Bets (0, 0, 0) and won tricks (handSize, 0, 0) for every player, then finalize.
  private func finalizeCurrentRoundWithValidInputs(_ game: inout Game, players: [Player]) throws {
    let roundIndex = game.currentRoundIndex
    let handSize = game.rounds[roundIndex].handSize
    for player in players {
      try game.apply(.submitBet(playerId: player.id, roundIndex: roundIndex, bet: 0))
    }
    try game.apply(.submitGot(playerId: players[0].id, roundIndex: roundIndex, got: handSize))
    for player in players.dropFirst() {
      try game.apply(.submitGot(playerId: player.id, roundIndex: roundIndex, got: 0))
    }
    try game.apply(.finalizeCurrentRound())
  }

  func testFlagDefaultsToOff() throws {
    let game = try makeGame(players: TestSupport.makePlayers(3))
    XCTAssertFalse(game.firstRoundBetSumMayEqualHandSize)
    XCTAssertEqual(game.gameConstraints(forRoundAt: 0), [.betSumNotEqualHandSize])
    XCTAssertEqual(game.gameConstraints(forRoundAt: 1), [.betSumNotEqualHandSize])
  }

  func testFlagWaivesBetSumRuleOnlyForFirstRound() throws {
    let game = try makeGame(players: TestSupport.makePlayers(3), firstRoundBetSumMayEqualHandSize: true)
    XCTAssertTrue(game.firstRoundBetSumMayEqualHandSize)
    XCTAssertEqual(game.gameConstraints(forRoundAt: 0), [])
    XCTAssertEqual(game.gameConstraints(forRoundAt: 1), [.betSumNotEqualHandSize])
    XCTAssertEqual(game.gameConstraints(forRoundAt: 5), [.betSumNotEqualHandSize])
    // The stored rule set itself is unchanged.
    XCTAssertEqual(game.gameConstraints, [.betSumNotEqualHandSize])
  }

  func testFlagWithoutBetSumRuleHasNoEffect() throws {
    let game = try makeGame(
      players: TestSupport.makePlayers(3),
      gameConstraints: [],
      firstRoundBetSumMayEqualHandSize: true
    )
    XCTAssertEqual(game.gameConstraints(forRoundAt: 0), [])
    XCTAssertEqual(game.gameConstraints(forRoundAt: 1), [])
  }

  func testFirstRoundBetsMayAddUpWhenFlagEnabled() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGame(players: players, firstRoundBetSumMayEqualHandSize: true)
    try game.apply(.startNewGame(startingDealer: players[0].id))

    // Round 1 (handSize 1): bets add up to the hand size.
    try game.apply(.submitBet(playerId: players[0].id, roundIndex: 0, bet: 1))
    try game.apply(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: players[2].id, roundIndex: 0, bet: 0))

    // Same validation the bet sheets run after applying bets.
    XCTAssertNoThrow(
      try game.rounds[0].validateConstraints(
        players: game.players,
        gameConstraints: game.gameConstraints(forRoundAt: 0),
        roundConstraints: [.gotSumEqualsHandSize]
      )
    )
  }

  func testFirstRoundBetsMayNotAddUpWhenFlagDisabled() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGame(players: players)
    try game.apply(.startNewGame(startingDealer: players[0].id))

    try game.apply(.submitBet(playerId: players[0].id, roundIndex: 0, bet: 1))
    try game.apply(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: players[2].id, roundIndex: 0, bet: 0))

    XCTAssertThrowsError(
      try game.rounds[0].validateConstraints(
        players: game.players,
        gameConstraints: game.gameConstraints(forRoundAt: 0),
        roundConstraints: [.gotSumEqualsHandSize]
      )
    ) { err in
      XCTAssertEqual(err as? DomainError, .constraintNotSatisfied(.game(.betSumNotEqualHandSize)))
    }
  }

  func testSecondRoundStillEnforcesBetSumRuleWhenFlagEnabled() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGame(players: players, firstRoundBetSumMayEqualHandSize: true)
    try game.apply(.startNewGame(startingDealer: players[0].id))
    try finalizeCurrentRoundWithValidInputs(&game, players: players)
    XCTAssertEqual(game.currentRoundIndex, 1)

    // Round 2 (handSize 2): bets add up to the hand size → rejected.
    try game.apply(.submitBet(playerId: players[0].id, roundIndex: 1, bet: 1))
    try game.apply(.submitBet(playerId: players[1].id, roundIndex: 1, bet: 1))
    try game.apply(.submitBet(playerId: players[2].id, roundIndex: 1, bet: 0))

    XCTAssertThrowsError(
      try game.rounds[1].validateConstraints(
        players: game.players,
        gameConstraints: game.gameConstraints(forRoundAt: 1),
        roundConstraints: [.gotSumEqualsHandSize]
      )
    ) { err in
      XCTAssertEqual(err as? DomainError, .constraintNotSatisfied(.game(.betSumNotEqualHandSize)))
    }
  }

  func testFlagCanOnlyChangeBeforeFirstFinalize() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGame(players: players)
    try game.apply(.startNewGame(startingDealer: players[0].id))

    XCTAssertNoThrow(try game.setFirstRoundBetSumMayEqualHandSize(true))
    XCTAssertTrue(game.firstRoundBetSumMayEqualHandSize)
    XCTAssertNoThrow(try game.setFirstRoundBetSumMayEqualHandSize(false))
    XCTAssertFalse(game.firstRoundBetSumMayEqualHandSize)

    try finalizeCurrentRoundWithValidInputs(&game, players: players)

    XCTAssertThrowsError(try game.setFirstRoundBetSumMayEqualHandSize(true)) { err in
      XCTAssertEqual(err as? DomainError, .constraintsLocked)
    }
    XCTAssertFalse(game.firstRoundBetSumMayEqualHandSize)
  }

  func testGameRoundTripsFlagThroughCodable() throws {
    let original = try makeGame(players: TestSupport.makePlayers(3), firstRoundBetSumMayEqualHandSize: true)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Game.self, from: data)
    XCTAssertTrue(decoded.firstRoundBetSumMayEqualHandSize)
    XCTAssertEqual(decoded, original)
  }

  func testGameDecodesLegacyJSONWithoutFirstRoundFlagAsDisabled() throws {
    let original = try makeGame(players: TestSupport.makePlayers(3), firstRoundBetSumMayEqualHandSize: true)
    let encoded = try JSONEncoder().encode(original)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertNotNil(json["firstRoundBetSumMayEqualHandSize"])
    json.removeValue(forKey: "firstRoundBetSumMayEqualHandSize")

    let legacyData = try JSONSerialization.data(withJSONObject: json, options: [])
    let decoded = try JSONDecoder().decode(Game.self, from: legacyData)

    XCTAssertFalse(decoded.firstRoundBetSumMayEqualHandSize)
    XCTAssertEqual(decoded.gameConstraints(forRoundAt: 0), [.betSumNotEqualHandSize])
  }
}
