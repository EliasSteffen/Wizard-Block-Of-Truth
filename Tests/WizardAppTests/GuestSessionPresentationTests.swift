import Foundation
import XCTest
@testable import WizardApp
@testable import WizardDomain
@testable import WizardNet

/// Pure presentation logic of the guest's multi-phone screens and the game list's active-session row.
final class GuestSessionPresentationTests: XCTestCase {
  private let guest = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private let p2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  private let p3 = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

  private func players() -> [Player] {
    [Player(id: guest, name: "Gina"), Player(id: p2, name: "Bob"), Player(id: p3, name: "Cleo")]
  }

  private func startedGame(
    gameConstraints: [Constraint.GameConstraint] = [.betSumNotEqualHandSize],
    firstRoundMayAddUp: Bool = false,
    specialCards: Bool = true
  ) throws -> Game {
    var game = try Game(
      id: UUID(),
      name: "Friday",
      mode: .multiPhone,
      playWithSpecialCards: specialCards,
      players: players(),
      gameConstraints: gameConstraints,
      firstRoundBetSumMayEqualHandSize: firstRoundMayAddUp
    )
    try game.apply(.startNewGame(startingDealer: p3))
    return game
  }

  /// Plays round 1 (hand size 1) to the end and finalizes it.
  private func finishFirstRound(_ game: inout Game, bomb: Bool = false) throws {
    try game.apply(.submitBet(playerId: guest, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: p2, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: p3, roundIndex: 0, bet: 0))
    try game.apply(.submitGot(playerId: guest, roundIndex: 0, got: 0))
    try game.apply(.submitGot(playerId: p2, roundIndex: 0, got: 0))
    try game.apply(.submitGot(playerId: p3, roundIndex: 0, got: bomb ? 0 : 1))
    try game.apply(.finalizeCurrentRound(roundConstraints: bomb ? [.gotSumEqualsHandSizeMinusOne] : nil))
  }

  // MARK: - Entry phase / edit rights (decision 4)

  func testBetCanBeEnteredAndChangedUntilAllBetsAreIn() throws {
    var game = try startedGame()
    XCTAssertEqual(GuestEntryPhaseResolver.phase(game: game, guestPlayerID: guest), .enter(.bet))

    try game.apply(.submitBet(playerId: guest, roundIndex: 0, bet: 1))
    XCTAssertEqual(GuestEntryPhaseResolver.phase(game: game, guestPlayerID: guest), .review(.bet, value: 1))
    XCTAssertTrue(GuestEntryPhaseResolver.canSubmit(.bet, game: game, guestPlayerID: guest))
    XCTAssertFalse(GuestEntryPhaseResolver.canSubmit(.got, game: game, guestPlayerID: guest))

    try game.apply(.submitBet(playerId: p2, roundIndex: 0, bet: 1))
    try game.apply(.submitBet(playerId: p3, roundIndex: 0, bet: 0))
    XCTAssertFalse(GuestEntryPhaseResolver.canSubmit(.bet, game: game, guestPlayerID: guest), "all bets are in")
    XCTAssertEqual(GuestEntryPhaseResolver.phase(game: game, guestPlayerID: guest), .enter(.got))
  }

  func testWonTricksCanBeCorrectedUntilTheHostFinalizes() throws {
    var game = try startedGame()
    try game.apply(.submitBet(playerId: guest, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: p2, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: p3, roundIndex: 0, bet: 0))
    try game.apply(.submitGot(playerId: guest, roundIndex: 0, got: 1))
    XCTAssertEqual(GuestEntryPhaseResolver.phase(game: game, guestPlayerID: guest), .review(.got, value: 1))
    XCTAssertTrue(GuestEntryPhaseResolver.canSubmit(.got, game: game, guestPlayerID: guest))

    try game.apply(.submitGot(playerId: p2, roundIndex: 0, got: 0))
    try game.apply(.submitGot(playerId: p3, roundIndex: 0, got: 0))
    try game.apply(.finalizeCurrentRound())
    // Next round: betting again.
    XCTAssertEqual(game.currentRoundIndex, 1)
    XCTAssertEqual(GuestEntryPhaseResolver.phase(game: game, guestPlayerID: guest), .enter(.bet))
  }

  func testCloudCardEndsBetting() throws {
    var game = try startedGame()
    try game.apply(.submitBet(playerId: guest, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: p2, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: p3, roundIndex: 0, bet: 0))
    try game.apply(.markCloudCardResolved(roundIndex: 0))
    XCTAssertFalse(GuestEntryPhaseResolver.canSubmit(.bet, game: game, guestPlayerID: guest))
    XCTAssertEqual(GuestEntryPhaseResolver.phase(game: game, guestPlayerID: guest), .enter(.got))
  }

  func testFinishedGameHasNoEntry() throws {
    let players = [Player(id: guest, name: "Gina"), Player(id: p2, name: "Bob")]
    var game = try Game(id: UUID(), name: "Duel", mode: .multiPhone, players: players, gameConstraints: [])
    try game.apply(.startNewGame(startingDealer: p2))
    for roundIndex in 0..<game.totalRoundsPlanned {
      let handSize = roundIndex + 1
      try game.apply(.submitBet(playerId: guest, roundIndex: roundIndex, bet: 0))
      try game.apply(.submitBet(playerId: p2, roundIndex: roundIndex, bet: 0))
      try game.apply(.submitGot(playerId: guest, roundIndex: roundIndex, got: handSize))
      try game.apply(.submitGot(playerId: p2, roundIndex: roundIndex, got: 0))
      try game.apply(.finalizeCurrentRound())
    }
    XCTAssertTrue(GuestEntryPhaseResolver.isGameFinished(game))
    XCTAssertEqual(GuestEntryPhaseResolver.phase(game: game, guestPlayerID: guest), .gameFinished)
    XCTAssertEqual(ActiveSessionStatus.host(game: game), .finished)
  }

  // MARK: - Bet-sum hint

  func testForbiddenBetIsKnownWhenTheGuestBetsLast() throws {
    var game = try startedGame()
    XCTAssertNil(GuestEntryPhaseResolver.forbiddenBet(game: game, guestPlayerID: guest), "others still missing")
    try game.apply(.submitBet(playerId: p2, roundIndex: 0, bet: 0))
    try game.apply(.submitBet(playerId: p3, roundIndex: 0, bet: 0))
    XCTAssertEqual(GuestEntryPhaseResolver.forbiddenBet(game: game, guestPlayerID: guest), 1)
  }

  func testForbiddenBetRespectsHouseRules() throws {
    var mayAddUp = try startedGame(firstRoundMayAddUp: true)
    try mayAddUp.apply(.submitBet(playerId: p2, roundIndex: 0, bet: 0))
    try mayAddUp.apply(.submitBet(playerId: p3, roundIndex: 0, bet: 0))
    XCTAssertNil(GuestEntryPhaseResolver.forbiddenBet(game: mayAddUp, guestPlayerID: guest), "first round may add up")

    var noRule = try startedGame(gameConstraints: [])
    try noRule.apply(.submitBet(playerId: p2, roundIndex: 0, bet: 0))
    try noRule.apply(.submitBet(playerId: p3, roundIndex: 0, bet: 0))
    XCTAssertNil(GuestEntryPhaseResolver.forbiddenBet(game: noRule, guestPlayerID: guest))

    var overshoot = try startedGame()
    try overshoot.apply(.submitBet(playerId: p2, roundIndex: 0, bet: 1))
    try overshoot.apply(.submitBet(playerId: p3, roundIndex: 0, bet: 1))
    XCTAssertNil(GuestEntryPhaseResolver.forbiddenBet(game: overshoot, guestPlayerID: guest), "sum already above hand")
  }

  // MARK: - Stepper seeding (L8)

  func testInitialDraftStartsFromOwnValueOrBet() {
    XCTAssertEqual(GuestEntryPhaseResolver.initialDraft(kind: .bet, ownBet: nil, ownGot: nil, handSize: 3), 0)
    XCTAssertEqual(GuestEntryPhaseResolver.initialDraft(kind: .bet, ownBet: 2, ownGot: nil, handSize: 3), 2)
    XCTAssertEqual(GuestEntryPhaseResolver.initialDraft(kind: .got, ownBet: 2, ownGot: nil, handSize: 3), 2)
    XCTAssertEqual(GuestEntryPhaseResolver.initialDraft(kind: .got, ownBet: 2, ownGot: 1, handSize: 3), 1)
    XCTAssertEqual(GuestEntryPhaseResolver.initialDraft(kind: .got, ownBet: 5, ownGot: nil, handSize: 3), 3)
    XCTAssertEqual(GuestEntryPhaseResolver.initialDraft(kind: .got, ownBet: nil, ownGot: nil, handSize: 3), 0)
  }

  func testDraftIsReseededOnPhaseChangeButNotByOtherPlayers() throws {
    var game = try startedGame()
    try game.apply(.submitBet(playerId: guest, roundIndex: 0, bet: 1))
    let reviewingBet = try XCTUnwrap(GuestEntryPhaseResolver.context(game: game, guestPlayerID: guest))

    try game.apply(.submitBet(playerId: p2, roundIndex: 0, bet: 0))
    let otherBetIn = try XCTUnwrap(GuestEntryPhaseResolver.context(game: game, guestPlayerID: guest))
    XCTAssertEqual(reviewingBet.draftSeedKey, otherBetIn.draftSeedKey)

    try game.apply(.submitBet(playerId: p3, roundIndex: 0, bet: 1))
    let enteringTricks = try XCTUnwrap(GuestEntryPhaseResolver.context(game: game, guestPlayerID: guest))
    XCTAssertNotEqual(otherBetIn.draftSeedKey, enteringTricks.draftSeedKey)
    XCTAssertEqual(enteringTricks.draftSeedKey.kind, .got)

    try game.apply(.submitGot(playerId: guest, roundIndex: 0, got: 0))
    let correctedTricks = try XCTUnwrap(GuestEntryPhaseResolver.context(game: game, guestPlayerID: guest))
    XCTAssertNotEqual(enteringTricks.draftSeedKey, correctedTricks.draftSeedKey, "own value changed")
  }

  // MARK: - Connection banner

  func testConnectionBannerMapping() {
    XCTAssertNil(GuestConnectionBanner.make(state: .connected, transportFailure: nil))
    XCTAssertNil(GuestConnectionBanner.make(state: .idle, transportFailure: nil))
    XCTAssertEqual(GuestConnectionBanner.make(state: .connecting, transportFailure: nil), .connecting)
    XCTAssertEqual(
      GuestConnectionBanner.make(state: .reconnecting(attempt: 3), transportFailure: .localNetworkDenied),
      .reconnecting(attempt: 3, localNetworkDenied: true)
    )
    XCTAssertEqual(
      GuestConnectionBanner.make(state: .reconnecting(attempt: 1), transportFailure: .network("x")),
      .reconnecting(attempt: 1, localNetworkDenied: false)
    )
    XCTAssertNil(GuestConnectionBanner.make(state: .ended(.gameFinished), transportFailure: nil))
    XCTAssertEqual(
      GuestConnectionBanner.make(state: .ended(.kicked), transportFailure: nil),
      .ended(.kicked, canPickSeatAgain: true)
    )
    XCTAssertEqual(
      GuestConnectionBanner.make(state: .ended(.seatReleased), transportFailure: nil),
      .ended(.seatReleased, canPickSeatAgain: true)
    )
    XCTAssertEqual(
      GuestConnectionBanner.make(state: .ended(.hostEnded), transportFailure: nil),
      .ended(.hostEnded, canPickSeatAgain: false)
    )
    XCTAssertEqual(
      GuestConnectionBanner.make(state: .ended(.left), transportFailure: nil),
      .ended(.left, canPickSeatAgain: false)
    )
  }

  // MARK: - Command feedback

  func testCommandFeedback() {
    XCTAssertNil(GuestCommandFeedback.message(for: nil))
    XCTAssertNil(GuestCommandFeedback.message(for: .accepted))
    let betSum = GuestCommandFeedback.message(for: .rejected(.betSumEqualsHandSize(handSize: 7)))
    XCTAssertTrue(betSum?.contains("7") == true)
    XCTAssertNotNil(GuestCommandFeedback.message(for: .rejected(.roundFinalized)))
    XCTAssertNotNil(GuestCommandFeedback.message(for: .timedOut))
  }

  // MARK: - Join screen

  func testJoinFailureClassification() {
    XCTAssertEqual(JoinFailureKind.classify(GuestSessionError.localNetworkDenied), .localNetworkDenied)
    XCTAssertEqual(JoinFailureKind.classify(GuestSessionError.hostIncompatibleOrUnreachable), .incompatibleHost)
    XCTAssertEqual(JoinFailureKind.classify(GuestSessionError.joinRejected(.versionMismatch)), .incompatibleHost)
    XCTAssertEqual(JoinFailureKind.classify(GuestSessionError.joinRejected(.tokenInvalid)), .seatReleased)
    XCTAssertEqual(JoinFailureKind.classify(GuestSessionError.joinRejected(.nameTaken)), .name)
    XCTAssertEqual(JoinFailureKind.classify(GuestSessionError.joinRejected(.nameInvalid)), .name)
    XCTAssertEqual(JoinFailureKind.classify(GuestSessionError.joinRejected(.seatTaken)), .seat)
    XCTAssertEqual(JoinFailureKind.classify(GuestSessionError.joinRejected(.sessionNotFound)), .general)
    XCTAssertEqual(JoinFailureKind.classify(GuestSessionError.hostUnreachable), .general)
    XCTAssertEqual(JoinFailureKind.classify(NSError(domain: "x", code: 1)), .general)
  }

  func testJoinTargetFindsItsHost() {
    let friday = DiscoveredSession(id: "ABC234-Friday", code: "ABC234", displayName: "Friday", serviceName: "ABC234-Friday")
    let other = DiscoveredSession(id: "XYZ789-Other", code: "XYZ789", displayName: "Other", serviceName: "XYZ789-Other")
    let sessions = [other, friday]

    XCTAssertEqual(
      GuestJoinTarget(serviceName: "ABC234-Friday", sessionCode: "ABC234", gameName: "Friday").match(in: sessions),
      friday
    )
    XCTAssertEqual(
      GuestJoinTarget(serviceName: nil, sessionCode: "abc234", gameName: "Friday").match(in: sessions),
      friday,
      "app 1.1 saved sessions have no service name: match by code"
    )
    XCTAssertEqual(
      GuestJoinTarget(serviceName: "ABC234-Renamed", sessionCode: "ABC234", gameName: "Friday").match(in: sessions),
      friday
    )
    XCTAssertNil(GuestJoinTarget(serviceName: nil, sessionCode: "QQQ222", gameName: "Gone").match(in: sessions))
    XCTAssertFalse(GuestJoinTarget.codesMatch("", ""))
  }

  func testJoinTargetFromSavedSession() {
    let saved = SavedGuestSession(
      guestToken: "token",
      sessionCode: "ABC234",
      playerId: guest,
      playerName: "Gina",
      hostDisplayName: nil,
      serviceName: "ABC234-Friday",
      gameName: nil
    )
    let target = GuestJoinTarget(saved: saved)
    XCTAssertEqual(target.gameName, "Friday")
    XCTAssertEqual(target.guestToken, "token")
    XCTAssertEqual(target.playerName, "Gina")
  }

  // MARK: - Bomb / Cloud indicator

  func testSpecialCardsSummary() throws {
    var game = try startedGame()
    XCTAssertTrue(GuestSpecialCardsSummary.make(game: game).isEmpty)

    try finishFirstRound(&game, bomb: true)
    var summary = GuestSpecialCardsSummary.make(game: game)
    XCTAssertEqual(summary.previousRoundNumber, 1)
    XCTAssertTrue(summary.bombPreviousRound)
    XCTAssertFalse(summary.cloudPreviousRound)
    XCTAssertFalse(summary.bombThisRound)

    try game.apply(.markCloudCardResolved(roundIndex: 1))
    summary = GuestSpecialCardsSummary.make(game: game)
    XCTAssertTrue(summary.cloudThisRound)

    var plain = try startedGame(specialCards: false)
    try plain.apply(.markCloudCardResolved(roundIndex: 0))
    XCTAssertTrue(GuestSpecialCardsSummary.make(game: plain).isEmpty, "no special cards in this game")
  }

  // MARK: - Active session row

  func testActiveSessionStatus() throws {
    let setup = try Game(id: UUID(), name: "Friday", mode: .multiPhone, players: players())
    let started = try startedGame()

    XCTAssertEqual(ActiveSessionStatus.guest(game: setup, connectionState: .connected), .lobby)
    XCTAssertEqual(
      ActiveSessionStatus.guest(game: started, connectionState: .connected),
      .playing(round: 1, totalRounds: started.totalRoundsPlanned)
    )
    XCTAssertEqual(ActiveSessionStatus.guest(game: started, connectionState: .reconnecting(attempt: 2)), .reconnecting(attempt: 2))
    XCTAssertEqual(ActiveSessionStatus.guest(game: started, connectionState: .connecting), .connecting)
    XCTAssertEqual(ActiveSessionStatus.guest(game: started, connectionState: .ended(.gameFinished)), .finished)
    XCTAssertEqual(ActiveSessionStatus.guest(game: started, connectionState: .ended(.hostEnded)), .ended(.hostEnded))
    XCTAssertTrue(ActiveSessionStatus.ended(.kicked).isEnded)
    XCTAssertFalse(ActiveSessionStatus.finished.isEnded)
    XCTAssertEqual(ActiveSessionStatus.host(game: nil), .lobby)
    XCTAssertEqual(ActiveSessionStatus.host(game: setup), .lobby)
  }

  // MARK: - Waiting room

  func testWaitingSeatsFollowTheLobby() {
    let slots = [
      LobbyPlayerSlot(playerId: p3, name: "Hanna", isHost: true, isBoundToDevice: false, isConnected: false, isPlaceholderName: false),
      LobbyPlayerSlot(playerId: guest, name: "Gina", isHost: false, isBoundToDevice: true, isConnected: true, isPlaceholderName: false),
      LobbyPlayerSlot(playerId: p2, name: "Bob", isHost: false, isBoundToDevice: true, isConnected: false, isPlaceholderName: false),
      LobbyPlayerSlot(playerId: UUID(), name: "Player 4", isHost: false, isBoundToDevice: false, isConnected: false, isPlaceholderName: true),
    ]
    let seats = GuestWaitingSeat.make(slots: slots, players: [], guestPlayerID: guest)
    XCTAssertEqual(seats.map(\.number), [1, 2, 3, 4])
    XCTAssertEqual(seats.map(\.name), ["Hanna", "Gina", "Bob", "Player 4"])
    XCTAssertTrue(seats[0].isHost)
    XCTAssertTrue(seats[1].isYou)
    XCTAssertEqual(seats.map(\.device), [.noPhone, .connected, .offline, .noPhone])

    let fallback = GuestWaitingSeat.make(slots: [], players: players(), guestPlayerID: guest)
    XCTAssertEqual(fallback.map(\.name), ["Gina", "Bob", "Cleo"])
    XCTAssertEqual(fallback.first?.isYou, true)
  }
}
