import XCTest
@testable import WizardDomain

/// `GameCommand.editFinalizedRound` and the persisted / inferred Bomb flag on `Round`.
final class EditFinalizedRoundTests: XCTestCase {
  private func makeGame(
    players: [Player],
    playWithSpecialCards: Bool = true,
    gameConstraints: [Constraint.GameConstraint] = [.betSumNotEqualHandSize],
    firstRoundBetSumMayEqualHandSize: Bool = false
  ) throws -> Game {
    var game = try Game(
      id: UUID(),
      name: "Test",
      mode: .singlePhone,
      playWithSpecialCards: playWithSpecialCards,
      players: players,
      gameConstraints: gameConstraints,
      firstRoundBetSumMayEqualHandSize: firstRoundBetSumMayEqualHandSize
    )
    try game.apply(.startNewGame(startingDealer: players[0].id))
    return game
  }

  /// Finalizes the current round with bets (0, 0, …) and won tricks (handSize, 0, …).
  private func finalizeCurrentRound(_ game: inout Game, players: [Player]) throws {
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

  /// Game with rounds 1 and 2 finalized; round 3 (handSize 3) is open.
  private func makeGameWithTwoFinalizedRounds(
    players: [Player],
    playWithSpecialCards: Bool = true,
    firstRoundBetSumMayEqualHandSize: Bool = false
  ) throws -> Game {
    var game = try makeGame(
      players: players,
      playWithSpecialCards: playWithSpecialCards,
      firstRoundBetSumMayEqualHandSize: firstRoundBetSumMayEqualHandSize
    )
    try finalizeCurrentRound(&game, players: players)
    try finalizeCurrentRound(&game, players: players)
    XCTAssertEqual(game.currentRoundIndex, 2)
    return game
  }

  private func entries(_ players: [Player], bets: [Int?], gots: [Int?]) -> [UUID: RoundEntry] {
    var result: [UUID: RoundEntry] = [:]
    for (idx, player) in players.enumerated() {
      result[player.id] = RoundEntry(bet: bets[idx], got: gots[idx])
    }
    return result
  }

  // MARK: - Happy path

  func testEditFinalizedRoundUpdatesEntriesAndTotals() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGameWithTwoFinalizedRounds(players: players)

    // Before: round 2 (handSize 2) bets (0,0,0), gots (2,0,0) → P1 -20, P2 +20, P3 +20.
    // Round 1 (handSize 1) bets (0,0,0), gots (1,0,0) → P1 -10, P2 +20, P3 +20.
    let before = try game.totalPoints()
    XCTAssertEqual(before[players[0].id], -30)
    XCTAssertEqual(before[players[1].id], 40)
    XCTAssertEqual(before[players[2].id], 40)

    let originalRound = game.rounds[1]
    let untouchedRound0 = game.rounds[0]
    let untouchedRound2 = game.rounds[2]

    // Correct round 2: bets (2,1,0) sum 3 ≠ 2; gots (2,0,0) sum 2.
    try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: entries(players, bets: [2, 1, 0], gots: [2, 0, 0]),
      bombPlayed: false,
      cloudCardPlayed: false
    ))

    let edited = game.rounds[1]
    XCTAssertEqual(edited.entries[players[0].id], RoundEntry(bet: 2, got: 2))
    XCTAssertEqual(edited.entries[players[1].id], RoundEntry(bet: 1, got: 0))
    XCTAssertEqual(edited.entries[players[2].id], RoundEntry(bet: 0, got: 0))
    XCTAssertTrue(edited.isFinalized)
    XCTAssertEqual(edited.handSize, originalRound.handSize)
    XCTAssertEqual(edited.dealer, originalRound.dealer)
    XCTAssertFalse(edited.bombPlayed)
    XCTAssertFalse(edited.cloudCardResolved)

    // Other rounds and the current round index are untouched.
    XCTAssertEqual(game.rounds[0], untouchedRound0)
    XCTAssertEqual(game.rounds[2], untouchedRound2)
    XCTAssertEqual(game.rounds.count, 3)
    XCTAssertEqual(game.currentRoundIndex, 2)

    // Totals recompute: round 2 now P1 +40 (2/2), P2 -10 (1/0), P3 +20 (0/0).
    let after = try game.totalPoints()
    XCTAssertEqual(after[players[0].id], -10 + 40)
    XCTAssertEqual(after[players[1].id], 20 - 10)
    XCTAssertEqual(after[players[2].id], 20 + 20)
  }

  func testEditCanClearBombAndCloudFlags() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGameWithTwoFinalizedRounds(players: players)

    try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: entries(players, bets: [1, 1, 0], gots: [1, 0, 0]),
      bombPlayed: true,
      cloudCardPlayed: true
    ))
    XCTAssertTrue(game.rounds[1].bombPlayed)
    XCTAssertTrue(game.rounds[1].cloudCardResolved)

    try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: entries(players, bets: [0, 1, 0], gots: [1, 1, 0]),
      bombPlayed: false,
      cloudCardPlayed: false
    ))
    XCTAssertFalse(game.rounds[1].bombPlayed)
    XCTAssertFalse(game.rounds[1].cloudCardResolved)
  }

  // MARK: - Rejections

  func testEditRejectsRoundThatIsNotFinalized() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGameWithTwoFinalizedRounds(players: players)

    XCTAssertThrowsError(try game.apply(.editFinalizedRound(
      roundIndex: 2,
      entries: entries(players, bets: [0, 0, 0], gots: [3, 0, 0]),
      bombPlayed: false,
      cloudCardPlayed: false
    ))) { err in
      XCTAssertEqual(err as? DomainError, .roundNotFinalized)
    }
  }

  func testEditRejectsInvalidRoundIndex() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGameWithTwoFinalizedRounds(players: players)

    for invalidIndex in [-1, 3, 99] {
      XCTAssertThrowsError(try game.apply(.editFinalizedRound(
        roundIndex: invalidIndex,
        entries: entries(players, bets: [0, 0, 0], gots: [1, 0, 0]),
        bombPlayed: false,
        cloudCardPlayed: false
      ))) { err in
        XCTAssertEqual(err as? DomainError, .invalidRoundIndex(invalidIndex))
      }
    }
  }

  func testEditRejectsEntriesThatDoNotMatchPlayers() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGameWithTwoFinalizedRounds(players: players)

    var missingPlayer = entries(players, bets: [0, 0, 0], gots: [2, 0, 0])
    missingPlayer.removeValue(forKey: players[2].id)
    XCTAssertThrowsError(try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: missingPlayer,
      bombPlayed: false,
      cloudCardPlayed: false
    ))) { err in
      XCTAssertEqual(err as? DomainError, .entriesDoNotMatchPlayers)
    }

    var extraPlayer = entries(players, bets: [0, 0, 0], gots: [2, 0, 0])
    extraPlayer[UUID()] = RoundEntry(bet: 0, got: 0)
    XCTAssertThrowsError(try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: extraPlayer,
      bombPlayed: false,
      cloudCardPlayed: false
    ))) { err in
      XCTAssertEqual(err as? DomainError, .entriesDoNotMatchPlayers)
    }
  }

  func testEditRejectsMissingBetOrGot() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGameWithTwoFinalizedRounds(players: players)

    XCTAssertThrowsError(try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: entries(players, bets: [0, nil, 0], gots: [2, 0, 0]),
      bombPlayed: false,
      cloudCardPlayed: false
    ))) { err in
      XCTAssertEqual(err as? DomainError, .missingInputs)
    }

    XCTAssertThrowsError(try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: entries(players, bets: [0, 0, 0], gots: [2, 0, nil]),
      bombPlayed: false,
      cloudCardPlayed: false
    ))) { err in
      XCTAssertEqual(err as? DomainError, .missingInputs)
    }
  }

  func testEditRejectsValuesOutsideHandSize() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGameWithTwoFinalizedRounds(players: players)

    XCTAssertThrowsError(try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: entries(players, bets: [3, 0, 0], gots: [2, 0, 0]),
      bombPlayed: false,
      cloudCardPlayed: false
    ))) { err in
      XCTAssertEqual(err as? DomainError, .invalidBet(playerId: players[0].id, bet: 3, handSize: 2))
    }

    XCTAssertThrowsError(try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: entries(players, bets: [0, 0, 0], gots: [-1, 3, 0]),
      bombPlayed: false,
      cloudCardPlayed: false
    ))) { err in
      guard case .invalidGot? = err as? DomainError else {
        return XCTFail("Expected invalidGot, got \(err)")
      }
    }
  }

  func testEditRejectsWrongWonTricksSum() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGameWithTwoFinalizedRounds(players: players)

    // handSize 2, won tricks sum 1 without Bomb.
    XCTAssertThrowsError(try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: entries(players, bets: [0, 0, 0], gots: [1, 0, 0]),
      bombPlayed: false,
      cloudCardPlayed: false
    ))) { err in
      XCTAssertEqual(err as? DomainError, .constraintNotSatisfied(.round(.gotSumEqualsHandSize)))
    }
  }

  func testEditWithBombRequiresWonTricksSumHandSizeMinusOne() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGameWithTwoFinalizedRounds(players: players)

    // Bomb but won tricks still add up to the hand size → rejected.
    XCTAssertThrowsError(try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: entries(players, bets: [0, 0, 0], gots: [2, 0, 0]),
      bombPlayed: true,
      cloudCardPlayed: false
    ))) { err in
      XCTAssertEqual(err as? DomainError, .constraintNotSatisfied(.round(.gotSumEqualsHandSizeMinusOne)))
    }

    // Bomb with won tricks = handSize - 1 → accepted and recorded.
    try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: entries(players, bets: [0, 0, 0], gots: [1, 0, 0]),
      bombPlayed: true,
      cloudCardPlayed: false
    ))
    XCTAssertTrue(game.rounds[1].bombPlayed)
    XCTAssertTrue(game.rounds[1].inferredBombPlayed)
    XCTAssertEqual(game.rounds[1].entries[players[0].id], RoundEntry(bet: 0, got: 1))
  }

  func testEditRejectsSpecialCardsWhenDisabled() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGameWithTwoFinalizedRounds(players: players, playWithSpecialCards: false)

    XCTAssertThrowsError(try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: entries(players, bets: [0, 0, 0], gots: [1, 0, 0]),
      bombPlayed: true,
      cloudCardPlayed: false
    ))) { err in
      XCTAssertEqual(err as? DomainError, .specialCardsNotEnabled)
    }

    XCTAssertThrowsError(try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: entries(players, bets: [1, 1, 0], gots: [2, 0, 0]),
      bombPlayed: false,
      cloudCardPlayed: true
    ))) { err in
      XCTAssertEqual(err as? DomainError, .specialCardsNotEnabled)
    }

    // Without special cards a regular correction still works.
    XCTAssertNoThrow(try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: entries(players, bets: [1, 0, 0], gots: [1, 1, 0]),
      bombPlayed: false,
      cloudCardPlayed: false
    )))
  }

  func testEditRejectsBetSumEqualHandSizeUnlessCloudWasPlayed() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGameWithTwoFinalizedRounds(players: players)

    // handSize 2, bets add up to 2.
    let addingUp = entries(players, bets: [1, 1, 0], gots: [1, 1, 0])
    XCTAssertThrowsError(try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: addingUp,
      bombPlayed: false,
      cloudCardPlayed: false
    ))) { err in
      XCTAssertEqual(err as? DomainError, .constraintNotSatisfied(.game(.betSumNotEqualHandSize)))
    }

    try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: addingUp,
      bombPlayed: false,
      cloudCardPlayed: true
    ))
    XCTAssertTrue(game.rounds[1].cloudCardResolved)
    XCTAssertEqual(game.rounds[1].entries, addingUp)
  }

  func testEditAllowsBetSumEqualHandSizeWithoutBetSumRule() throws {
    let players = TestSupport.makePlayers(3)
    var game = try Game(id: UUID(), name: "Test", mode: .singlePhone, players: players, gameConstraints: [])
    try game.apply(.startNewGame(startingDealer: players[0].id))
    try finalizeCurrentRound(&game, players: players)

    XCTAssertNoThrow(try game.apply(.editFinalizedRound(
      roundIndex: 0,
      entries: entries(players, bets: [1, 0, 0], gots: [1, 0, 0]),
      bombPlayed: false,
      cloudCardPlayed: false
    )))
  }

  func testEditHonorsFirstRoundBetSumExemption() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGameWithTwoFinalizedRounds(players: players, firstRoundBetSumMayEqualHandSize: true)

    // Round 1 (handSize 1): bets may add up with the house rule.
    try game.apply(.editFinalizedRound(
      roundIndex: 0,
      entries: entries(players, bets: [1, 0, 0], gots: [1, 0, 0]),
      bombPlayed: false,
      cloudCardPlayed: false
    ))
    XCTAssertEqual(game.rounds[0].entries[players[0].id], RoundEntry(bet: 1, got: 1))

    // Round 2 (handSize 2): the regular rule still applies.
    XCTAssertThrowsError(try game.apply(.editFinalizedRound(
      roundIndex: 1,
      entries: entries(players, bets: [1, 1, 0], gots: [1, 1, 0]),
      bombPlayed: false,
      cloudCardPlayed: false
    ))) { err in
      XCTAssertEqual(err as? DomainError, .constraintNotSatisfied(.game(.betSumNotEqualHandSize)))
    }
  }

  func testEditFirstRoundBetSumIsRejectedWithoutExemption() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGameWithTwoFinalizedRounds(players: players)

    XCTAssertThrowsError(try game.apply(.editFinalizedRound(
      roundIndex: 0,
      entries: entries(players, bets: [1, 0, 0], gots: [1, 0, 0]),
      bombPlayed: false,
      cloudCardPlayed: false
    ))) { err in
      XCTAssertEqual(err as? DomainError, .constraintNotSatisfied(.game(.betSumNotEqualHandSize)))
    }
  }

  func testFailedEditLeavesGameUnchanged() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGameWithTwoFinalizedRounds(players: players)
    let snapshot = game

    let failingCommands: [GameCommand] = [
      // Wrong won-tricks sum.
      .editFinalizedRound(roundIndex: 1, entries: entries(players, bets: [2, 1, 0], gots: [1, 0, 0]), bombPlayed: false, cloudCardPlayed: false),
      // Bet sum equals hand size.
      .editFinalizedRound(roundIndex: 1, entries: entries(players, bets: [1, 1, 0], gots: [2, 0, 0]), bombPlayed: true, cloudCardPlayed: false),
      // Out of range.
      .editFinalizedRound(roundIndex: 1, entries: entries(players, bets: [0, 0, 5], gots: [2, 0, 0]), bombPlayed: false, cloudCardPlayed: true),
      // Open round.
      .editFinalizedRound(roundIndex: 2, entries: entries(players, bets: [0, 0, 0], gots: [3, 0, 0]), bombPlayed: false, cloudCardPlayed: false),
    ]
    for command in failingCommands {
      XCTAssertThrowsError(try game.apply(command))
      XCTAssertEqual(game, snapshot)
    }
  }

  // MARK: - Bomb flag

  func testFinalizeRecordsWhetherBombWasPlayed() throws {
    let players = TestSupport.makePlayers(3)
    var game = try makeGame(players: players)

    // Round 1 without Bomb.
    try finalizeCurrentRound(&game, players: players)
    XCTAssertFalse(game.rounds[0].bombPlayed)

    // Round 2 (handSize 2) with Bomb: won tricks add up to 1.
    for player in players {
      try game.apply(.submitBet(playerId: player.id, roundIndex: 1, bet: 0))
    }
    try game.apply(.submitGot(playerId: players[0].id, roundIndex: 1, got: 1))
    try game.apply(.submitGot(playerId: players[1].id, roundIndex: 1, got: 0))
    try game.apply(.submitGot(playerId: players[2].id, roundIndex: 1, got: 0))
    try game.apply(.finalizeCurrentRound(roundConstraints: [.gotSumEqualsHandSizeMinusOne]))
    XCTAssertTrue(game.rounds[1].bombPlayed)
    XCTAssertFalse(game.rounds[2].bombPlayed)
  }

  func testInferredBombPlayedForLegacyFinalizedRounds() throws {
    let players = TestSupport.makePlayers(3)
    let ids = players.map(\.id)

    // Legacy finalized round with won tricks = handSize - 1 and no stored flag → Bomb inferred.
    let legacyBomb = Round(
      handSize: 3,
      dealer: ids[0],
      entries: [ids[0]: RoundEntry(bet: 1, got: 1), ids[1]: RoundEntry(bet: 0, got: 1), ids[2]: RoundEntry(bet: 0, got: 0)],
      isFinalized: true
    )
    XCTAssertFalse(legacyBomb.bombPlayed)
    XCTAssertTrue(legacyBomb.inferredBombPlayed)

    // Won tricks = handSize → no Bomb.
    let legacyRegular = Round(
      handSize: 3,
      dealer: ids[0],
      entries: [ids[0]: RoundEntry(bet: 1, got: 2), ids[1]: RoundEntry(bet: 0, got: 1), ids[2]: RoundEntry(bet: 0, got: 0)],
      isFinalized: true
    )
    XCTAssertFalse(legacyRegular.inferredBombPlayed)

    // Open rounds are never inferred.
    var open = legacyBomb
    open.isFinalized = false
    XCTAssertFalse(open.inferredBombPlayed)

    // The stored flag wins.
    var stored = legacyRegular
    stored.bombPlayed = true
    XCTAssertTrue(stored.inferredBombPlayed)
  }

  func testRoundDecodesLegacyJSONWithoutBombPlayed() throws {
    let players = TestSupport.makePlayers(1)
    let pid = players[0].id
    let round = Round(handSize: 1, dealer: pid, entries: [pid: RoundEntry(bet: 0, got: 0)], isFinalized: true, bombPlayed: true)
    let data = try JSONEncoder().encode(round)
    var jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNotNil(jsonObject["bombPlayed"])
    jsonObject.removeValue(forKey: "bombPlayed")
    let legacyData = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
    let decoded = try JSONDecoder().decode(Round.self, from: legacyData)
    XCTAssertFalse(decoded.bombPlayed)
    // got sum 0 == handSize - 1 → inferred for the editor.
    XCTAssertTrue(decoded.inferredBombPlayed)
  }

  func testRoundRoundTripsBombPlayedThroughCodable() throws {
    let players = TestSupport.makePlayers(2)
    let ids = players.map(\.id)
    let round = Round(
      handSize: 2,
      dealer: ids[0],
      entries: [ids[0]: RoundEntry(bet: 1, got: 1), ids[1]: RoundEntry(bet: 0, got: 0)],
      isFinalized: true,
      cloudCardResolved: false,
      bombPlayed: true
    )
    let decoded = try JSONDecoder().decode(Round.self, from: JSONEncoder().encode(round))
    XCTAssertEqual(decoded, round)
  }

  // MARK: - Wire format

  func testEditFinalizedRoundCommandRoundTripsThroughCodable() throws {
    let players = TestSupport.makePlayers(3)
    let command = GameCommand.editFinalizedRound(
      roundIndex: 4,
      entries: entries(players, bets: [1, 2, 0], gots: [1, 1, 2]),
      bombPlayed: true,
      cloudCardPlayed: false
    )
    let decoded = try JSONDecoder().decode(GameCommand.self, from: JSONEncoder().encode(command))
    XCTAssertEqual(decoded, command)
  }
}
