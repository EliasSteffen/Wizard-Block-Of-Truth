import XCTest
@testable import WizardNet
@testable import WizardDomain

/// Host-side house rules and round-rule permissions in multi-phone sessions.
@MainActor
final class RoundRulesNetTests: XCTestCase {
  private let sessionCode = "ABCD12"

  private func makePlayers() -> [Player] {
    (0..<3).map { idx in
      Player(
        id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idx + 1))!,
        name: "P\(idx + 1)"
      )
    }
  }

  private func makeHost(players: [Player]) throws -> HostSessionService {
    let host = HostSessionService(
      initialGame: try Game(id: UUID(), name: "Multi Phone", mode: .multiPhone, players: players),
      sessionCode: sessionCode,
      transport: MockHostTransport(),
      hostReservedPlayerId: players[0].id
    )
    try host.start()
    return host
  }

  func testStartGameAppliesFirstRoundBetSumRule() throws {
    let players = makePlayers()
    let host = try makeHost(players: players)

    try host.startGame(
      startingDealer: players[0].id,
      gameConstraints: [.betSumNotEqualHandSize],
      playWithSpecialCards: true,
      firstRoundBetSumMayEqualHandSize: true
    )

    XCTAssertTrue(host.game.firstRoundBetSumMayEqualHandSize)
    XCTAssertEqual(host.game.gameConstraints(forRoundAt: 0), [])
    XCTAssertEqual(host.game.gameConstraints(forRoundAt: 1), [.betSumNotEqualHandSize])
  }

  func testStartGameDefaultsFirstRoundBetSumRuleToOff() throws {
    let players = makePlayers()
    let host = try makeHost(players: players)

    try host.startGame(
      startingDealer: players[0].id,
      gameConstraints: [.betSumNotEqualHandSize],
      playWithSpecialCards: true
    )

    XCTAssertFalse(host.game.firstRoundBetSumMayEqualHandSize)
    XCTAssertEqual(host.game.gameConstraints(forRoundAt: 0), [.betSumNotEqualHandSize])
  }

  // MARK: - Editing finalized rounds is host-only

  private func editCommand(players: [Player], roundIndex: Int) -> GameCommand {
    .editFinalizedRound(
      roundIndex: roundIndex,
      entries: Dictionary(uniqueKeysWithValues: players.map { ($0.id, RoundEntry(bet: 0, got: 0)) }),
      bombPlayed: false,
      cloudCardPlayed: false
    )
  }

  func testGuestCannotEditFinalizedRound() {
    let players = makePlayers()
    let guestID = players[1].id
    // Denied for the current round, an earlier round, with or without special-card flags.
    for roundIndex in [0, 2] {
      XCTAssertFalse(
        CommandAuthorizer.isAllowedGuestCommand(
          editCommand(players: players, roundIndex: roundIndex),
          guestPlayerId: guestID,
          currentRoundIndex: 2
        )
      )
    }
    XCTAssertFalse(
      CommandAuthorizer.isAllowedGuestCommand(
        .editFinalizedRound(
          roundIndex: 0,
          entries: [guestID: RoundEntry(bet: 1, got: 1)],
          bombPlayed: true,
          cloudCardPlayed: true
        ),
        guestPlayerId: guestID,
        currentRoundIndex: 0
      )
    )
  }

  func testHostRejectsGuestEditFinalizedRoundCommand() throws {
    let players = makePlayers()
    let hostTransport = MockHostTransport()
    var startedGame = try Game(id: UUID(), name: "Multi Phone", mode: .multiPhone, players: players)
    try startedGame.apply(.startNewGame(startingDealer: players[0].id))
    for player in players {
      try startedGame.apply(.submitBet(playerId: player.id, roundIndex: 0, bet: 0))
    }
    try startedGame.apply(.submitGot(playerId: players[0].id, roundIndex: 0, got: 1))
    try startedGame.apply(.submitGot(playerId: players[1].id, roundIndex: 0, got: 0))
    try startedGame.apply(.submitGot(playerId: players[2].id, roundIndex: 0, got: 0))
    try startedGame.apply(.finalizeCurrentRound())

    // Valid for the domain (host could apply it), so a rejection proves the guest permission check.
    let validEdit = GameCommand.editFinalizedRound(
      roundIndex: 0,
      entries: [
        players[0].id: RoundEntry(bet: 0, got: 0),
        players[1].id: RoundEntry(bet: 0, got: 1),
        players[2].id: RoundEntry(bet: 0, got: 0),
      ],
      bombPlayed: false,
      cloudCardPlayed: false
    )
    var hostCopy = startedGame
    XCTAssertNoThrow(try hostCopy.apply(validEdit))
    XCTAssertEqual(hostCopy.rounds[0].entries[players[1].id]?.got, 1)

    let host = HostSessionService(
      initialGame: startedGame,
      sessionCode: sessionCode,
      transport: hostTransport,
      hostReservedPlayerId: players[0].id
    )
    host.reserveHostSlot(playerId: players[0].id, displayName: players[0].name)
    try host.start()

    let guest = GuestSessionService(sessionCode: sessionCode, transport: MockGuestTransport(host: hostTransport))
    let joined = expectation(description: "guest joined")
    let rejected = expectation(description: "edit command rejected")
    guest.onJoinLobby = { _ in
      try? guest.claimPlayer(playerId: players[1].id, displayName: players[1].name)
    }
    guest.onJoinAccepted = { joined.fulfill() }
    guest.onCommandResult = { result in
      if !result.accepted {
        rejected.fulfill()
      }
    }

    try guest.connect()
    wait(for: [joined], timeout: 1.0)
    let gameBefore = host.game
    try guest.submitGuestCommand(validEdit)
    wait(for: [rejected], timeout: 1.0)

    XCTAssertEqual(host.game, gameBefore)
  }
}
