import XCTest
@testable import WizardNet
@testable import WizardDomain

@MainActor
final class SessionSyncTests: XCTestCase {
  private let sessionCode = "ABCD12"

  private func makePlayers() -> [Player] {
    (0..<3).map { idx in
      Player(
        id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idx + 1))!,
        name: "P\(idx + 1)"
      )
    }
  }

  private func makeSetupGame() throws -> Game {
    try Game(id: UUID(), name: "Multi Phone", mode: .multiPhone, players: makePlayers())
  }

  private func makeStartedGame() throws -> Game {
    let players = makePlayers()
    var game = try Game(id: UUID(), name: "Multi Phone", mode: .multiPhone, players: players)
    try game.apply(.startNewGame(startingDealer: players[0].id))
    return game
  }

  private func startHostGame(_ host: HostSessionService, dealerId: UUID) throws {
    try host.startGame(
      startingDealer: dealerId,
      gameConstraints: [.betSumNotEqualHandSize],
      playWithSpecialCards: true
    )
  }

  func testGuestReceivesSnapshotAfterAcceptedCommand() throws {
    let players = makePlayers()
    let hostTransport = MockHostTransport()
    let host = HostSessionService(
      initialGame: try makeSetupGame(),
      sessionCode: sessionCode,
      transport: hostTransport,
      hostReservedPlayerId: players[0].id
    )
    host.reserveHostSlot(playerId: players[0].id, displayName: players[0].name)
    try host.start()

    let guest = GuestSessionService(sessionCode: sessionCode, transport: MockGuestTransport(host: hostTransport))

    let claimed = expectation(description: "guest claimed slot")
    let expectation = expectation(description: "guest snapshot updated")
    guest.onJoinLobby = { _ in
      try? guest.claimPlayer(playerId: players[1].id, displayName: players[1].name)
    }
    guest.onSlotClaimed = {
      claimed.fulfill()
      try? self.startHostGame(host, dealerId: players[0].id)
    }
    guest.onGameSnapshot = { game, _ in
      if game.rounds[0].entries[players[1].id]?.bet == 1 {
        expectation.fulfill()
      }
    }

    try guest.connect()
    wait(for: [claimed], timeout: 1.0)
    try guest.submitGuestCommand(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 1))

    wait(for: [expectation], timeout: 1.0)
  }

  func testUnauthorizedGuestCommandIsRejected() throws {
    let players = makePlayers()
    let hostTransport = MockHostTransport()
    let host = HostSessionService(initialGame: try makeStartedGame(), sessionCode: sessionCode, transport: hostTransport)
    try host.start()

    let guest = GuestSessionService(sessionCode: sessionCode, transport: MockGuestTransport(host: hostTransport))

    let claimed = expectation(description: "guest claimed slot")
    let expectation = expectation(description: "command rejected")
    guest.onJoinLobby = { _ in
      try? guest.claimPlayer(playerId: players[1].id, displayName: players[1].name)
    }
    guest.onJoinAccepted = {
      claimed.fulfill()
    }
    guest.onCommandResult = { result in
      if !result.accepted { expectation.fulfill() }
    }

    try guest.connect()
    wait(for: [claimed], timeout: 1.0)
    try guest.submitGuestCommand(.submitBet(playerId: players[0].id, roundIndex: 0, bet: 1))

    wait(for: [expectation], timeout: 1.0)
  }

  func testGuestCommandRejectedBeforeGameStarts() throws {
    let players = makePlayers()
    let hostTransport = MockHostTransport()
    let host = HostSessionService(initialGame: try makeSetupGame(), sessionCode: sessionCode, transport: hostTransport)
    try host.start()

    let guest = GuestSessionService(sessionCode: sessionCode, transport: MockGuestTransport(host: hostTransport))
    let claimed = expectation(description: "guest claimed")
    let rejected = expectation(description: "command rejected")

    guest.onJoinLobby = { _ in
      try? guest.claimPlayer(playerId: players[1].id, displayName: players[1].name)
    }
    guest.onSlotClaimed = { claimed.fulfill() }
    guest.onCommandResult = { result in
      if !result.accepted, result.reason?.contains("not started") == true {
        rejected.fulfill()
      }
    }

    try guest.connect()
    wait(for: [claimed], timeout: 1.0)
    try guest.submitGuestCommand(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 1))
    wait(for: [rejected], timeout: 1.0)
  }

  func testInvalidSessionCodeIsRejected() throws {
    let hostTransport = MockHostTransport()
    let host = HostSessionService(initialGame: try makeSetupGame(), sessionCode: sessionCode, transport: hostTransport)
    try host.start()

    let guest = GuestSessionService(sessionCode: "WRONG1", transport: MockGuestTransport(host: hostTransport))
    let rejected = expectation(description: "join rejected")
    guest.onError = { error in
      if case GuestSessionError.joinRejected = error {
        rejected.fulfill()
      }
    }
    try guest.connect()
    wait(for: [rejected], timeout: 1.0)
  }

  func testHelloWaitsForTransportReady() throws {
    let players = makePlayers()
    let hostTransport = MockHostTransport()
    let host = HostSessionService(
      initialGame: try makeSetupGame(),
      sessionCode: sessionCode,
      transport: hostTransport,
      hostReservedPlayerId: players[0].id
    )
    host.reserveHostSlot(playerId: players[0].id, displayName: players[0].name)
    try host.start()

    let guestTransport = MockGuestTransport(host: hostTransport)
    guestTransport.emitsConnectedOnConnect = false
    let guest = GuestSessionService(sessionCode: sessionCode, transport: guestTransport)

    let lobby = expectation(description: "lobby received after ready")
    guest.onJoinLobby = { _ in lobby.fulfill() }

    try guest.connect()
    let noEarlyLobby = expectation(description: "no lobby before ready")
    noEarlyLobby.isInverted = true
    wait(for: [noEarlyLobby], timeout: 0.2)

    guestTransport.finishConnect()
    wait(for: [lobby], timeout: 1.0)
  }

  func testJoinLobbyListsUnclaimedSlots() throws {
    let players = makePlayers()
    let hostTransport = MockHostTransport()
    let host = HostSessionService(
      initialGame: try makeSetupGame(),
      sessionCode: sessionCode,
      transport: hostTransport,
      hostReservedPlayerId: players[0].id
    )
    host.reserveHostSlot(playerId: players[0].id, displayName: players[0].name)
    try host.start()

    let guest = GuestSessionService(sessionCode: sessionCode, transport: MockGuestTransport(host: hostTransport))
    let lobby = expectation(description: "lobby received")
    guest.onJoinLobby = { slots in
      XCTAssertEqual(slots.count, 3)
      XCTAssertTrue(slots.first(where: { $0.playerId == players[0].id })?.isClaimed == true)
      XCTAssertTrue(slots.filter { $0.playerId != players[0].id }.allSatisfy { !$0.isClaimed })
      lobby.fulfill()
    }
    try guest.connect()
    wait(for: [lobby], timeout: 1.0)
  }

  func testClaimingTakenSlotIsRejected() throws {
    let players = makePlayers()
    let hostTransport = MockHostTransport()
    let host = HostSessionService(initialGame: try makeSetupGame(), sessionCode: sessionCode, transport: hostTransport)
    try host.start()

    let guestA = GuestSessionService(sessionCode: sessionCode, transport: MockGuestTransport(host: hostTransport))
    let guestB = GuestSessionService(sessionCode: sessionCode, transport: MockGuestTransport(host: hostTransport))

    let aClaimed = expectation(description: "guest A claimed")
    let bRejected = expectation(description: "guest B rejected")

    guestA.onJoinLobby = { _ in
      try? guestA.claimPlayer(playerId: players[1].id, displayName: "Alice")
    }
    guestA.onSlotClaimed = { aClaimed.fulfill() }

    guestB.onJoinLobby = { _ in
      try? guestB.claimPlayer(playerId: players[1].id, displayName: "Bob")
    }
    guestB.onError = { error in
      if case GuestSessionError.joinRejected(let reason) = error, reason.contains("taken") {
        bRejected.fulfill()
      }
    }

    try guestA.connect()
    wait(for: [aClaimed], timeout: 1.0)
    try guestB.connect()
    wait(for: [bRejected], timeout: 1.0)
  }

  func testCustomDisplayNameUpdatesHostPlayer() throws {
    let players = makePlayers()
    let hostTransport = MockHostTransport()
    let host = HostSessionService(initialGame: try makeSetupGame(), sessionCode: sessionCode, transport: hostTransport)
    try host.start()

    let guest = GuestSessionService(sessionCode: sessionCode, transport: MockGuestTransport(host: hostTransport))
    let claimed = expectation(description: "guest claimed")

    guest.onJoinLobby = { _ in
      try? guest.claimPlayer(playerId: players[2].id, displayName: "Custom Name")
    }
    guest.onSlotClaimed = { claimed.fulfill() }

    try guest.connect()
    wait(for: [claimed], timeout: 1.0)

    XCTAssertEqual(
      host.game.players.first(where: { $0.id == players[2].id })?.name,
      "Custom Name"
    )
    XCTAssertTrue(host.game.rounds.isEmpty)
  }

  func testStartGameNotifiesClaimedGuests() throws {
    let players = makePlayers()
    let hostTransport = MockHostTransport()
    let host = HostSessionService(
      initialGame: try makeSetupGame(),
      sessionCode: sessionCode,
      transport: hostTransport,
      hostReservedPlayerId: players[0].id
    )
    host.reserveHostSlot(playerId: players[0].id, displayName: "Host")
    try host.start()

    let guest = GuestSessionService(sessionCode: sessionCode, transport: MockGuestTransport(host: hostTransport))
    let claimed = expectation(description: "guest claimed slot")
    let started = expectation(description: "game started for guest")

    guest.onJoinLobby = { _ in
      try? guest.claimPlayer(playerId: players[1].id, displayName: "Guest")
    }
    guest.onSlotClaimed = { claimed.fulfill() }
    guest.onJoinAccepted = { started.fulfill() }

    try guest.connect()
    wait(for: [claimed], timeout: 1.0)

    try host.startGame(
      startingDealer: players[0].id,
      gameConstraints: [.betSumNotEqualHandSize],
      playWithSpecialCards: true
    )

    wait(for: [started], timeout: 1.0)
    XCTAssertFalse(host.game.rounds.isEmpty)
    XCTAssertEqual(guest.game?.rounds.count, 1)
  }

  func testClaimDuringStartedGameSendsJoinAccepted() throws {
    let players = makePlayers()
    let hostTransport = MockHostTransport()
    let host = HostSessionService(
      initialGame: try makeStartedGame(),
      sessionCode: sessionCode,
      transport: hostTransport,
      hostReservedPlayerId: players[0].id
    )
    host.reserveHostSlot(playerId: players[0].id, displayName: players[0].name)
    try host.start()

    let guest = GuestSessionService(sessionCode: sessionCode, transport: MockGuestTransport(host: hostTransport))
    let joined = expectation(description: "join accepted during live game")

    guest.onJoinLobby = { _ in
      try? guest.claimPlayer(playerId: players[2].id, displayName: "Late Guest")
    }
    guest.onJoinAccepted = { joined.fulfill() }

    try guest.connect()
    wait(for: [joined], timeout: 1.0)

    XCTAssertEqual(guest.playerId, players[2].id)
    XCTAssertFalse(guest.game?.rounds.isEmpty ?? true)
  }

  func testGuestReconnectsWithTokenAfterDisconnect() throws {
    let players = makePlayers()
    let hostTransport = MockHostTransport()
    let host = HostSessionService(
      initialGame: try makeStartedGame(),
      sessionCode: sessionCode,
      transport: hostTransport,
      hostReservedPlayerId: players[0].id
    )
    host.reserveHostSlot(playerId: players[0].id, displayName: players[0].name)
    try host.start()

    let guestTransport1 = MockGuestTransport(host: hostTransport)
    let guest1 = GuestSessionService(sessionCode: sessionCode, transport: guestTransport1)
    var savedToken: String?
    let joined = expectation(description: "guest joined")

    guest1.onJoinLobby = { _ in
      try? guest1.claimPlayer(playerId: players[1].id, displayName: players[1].name)
    }
    guest1.onJoinAccepted = {
      savedToken = guest1.guestToken
      joined.fulfill()
    }

    try guest1.connect()
    wait(for: [joined], timeout: 1.0)
    XCTAssertNotNil(savedToken)

    guest1.disconnect()

    let guest2 = GuestSessionService(
      sessionCode: sessionCode,
      guestToken: savedToken,
      transport: MockGuestTransport(host: hostTransport)
    )
    let rejoined = expectation(description: "guest rejoined with token")
    guest2.onJoinAccepted = { rejoined.fulfill() }

    try guest2.connect()
    wait(for: [rejoined], timeout: 1.0)

    XCTAssertEqual(guest2.playerId, players[1].id)
    XCTAssertEqual(guest2.game?.rounds.count, guest1.game?.rounds.count)
  }
}
