import XCTest
@testable import WizardNet
@testable import WizardDomain

/// Protocol v2 lifecycle: heartbeat, connection lost vs. session ended, rejoin, seats, permissions, atomicity,
/// auto-end, snapshot privacy and backward compatibility.
@MainActor
final class SessionLifecycleTests: XCTestCase {
  private let code = NetTestSupport.sessionCode
  private let players = NetTestSupport.players(["Hanna", "Bob", "Carol"])

  private func makeHost(
    game: Game? = nil,
    transport: MockHostTransport,
    timing: SessionTiming = NetTestSupport.quietTiming,
    clock: @escaping () -> Date = { Date() }
  ) throws -> HostSessionService {
    let host = HostSessionService(
      initialGame: try game ?? NetTestSupport.setupGame(players),
      sessionCode: code,
      transport: transport,
      hostReservedPlayerId: players[0].id,
      timing: timing,
      clock: clock
    )
    try host.start()
    return host
  }

  private func makeGuest(
    _ transport: MockGuestTransport,
    token: String? = nil,
    timing: SessionTiming = NetTestSupport.quietTiming
  ) -> GuestSessionService {
    GuestSessionService(sessionCode: code, guestToken: token, transport: transport, timing: timing)
  }

  // MARK: - Heartbeat

  func testHostPingsHelloedConnectionsAndClosesSilentOnes() throws {
    let clock = TestClock()
    let hostTransport = MockHostTransport()
    let host = try makeHost(
      transport: hostTransport,
      timing: SessionTiming(pingInterval: 3600, silenceTimeout: 15),
      clock: { clock.now }
    )
    let guestTransport = MockGuestTransport(host: hostTransport)
    let guest = makeGuest(guestTransport)
    try join(guest, seat: players[1].id, name: "Bob")

    // A socket that never says hello gets no pings (and no game data).
    let silentSocket = MockGuestTransport(host: hostTransport)
    silentSocket.emitsConnectedOnConnect = false
    try silentSocket.connect()
    drainMainQueue()

    // The guest goes half-open: nothing arrives in either direction any more.
    guestTransport.isSilenced = true

    clock.advance(5)
    host.runHeartbeat()
    XCTAssertTrue(hostTransport.envelopesSent(to: guestTransport.connectionID).contains(where: NetTestSupport.isPing))
    XCTAssertTrue(hostTransport.envelopesSent(to: silentSocket.connectionID).isEmpty)
    XCTAssertEqual(host.connectedGuestPlayerIDs, [players[1].id])

    clock.advance(11)
    host.runHeartbeat()
    XCTAssertTrue(host.guestsByConnection.isEmpty)
    XCTAssertEqual(Set(hostTransport.closedConnectionIDs), [guestTransport.connectionID, silentSocket.connectionID])
    // Connection lost ≠ seat lost: the token stays registered for a rejoin.
    XCTAssertEqual(host.boundGuestPlayerIDs, [players[1].id])
    XCTAssertTrue(host.lobbySlots[1].isBoundToDevice)
    XCTAssertFalse(host.lobbySlots[1].isConnected)
  }

  func testGuestDetectsSilenceAndReconnectsWithToken() throws {
    let hostTransport = MockHostTransport()
    _ = try makeHost(game: try NetTestSupport.startedGame(players), transport: hostTransport)
    let guestTransport = MockGuestTransport(host: hostTransport)
    let guest = makeGuest(guestTransport, timing: NetTestSupport.fastTiming(silenceTimeout: 0.25, reconnectDelays: [0.1]))
    try join(guest, seat: players[1].id, name: "Bob")
    let token = guest.guestToken

    let reconnecting = expectation(description: "reconnecting")
    reconnecting.assertForOverFulfill = false
    let reconnected = expectation(description: "connected again")
    reconnected.assertForOverFulfill = false
    var sawReconnecting = false
    guest.onConnectionStateChanged = { state in
      if case .reconnecting = state {
        sawReconnecting = true
        reconnecting.fulfill()
      } else if state == .connected, sawReconnecting {
        reconnected.fulfill()
      }
    }

    // Host pings are disabled (quiet timing), so the guest hears nothing and must give up on this socket.
    guestTransport.isSilenced = true
    wait(for: [reconnecting], timeout: 3)
    guestTransport.isSilenced = false
    wait(for: [reconnected], timeout: 3)

    XCTAssertEqual(guest.guestToken, token)
    XCTAssertEqual(guest.playerId, players[1].id)
    XCTAssertGreaterThanOrEqual(guestTransport.connectCount, 2)
  }

  // MARK: - Connection lost vs. session ended

  func testConnectionLossReconnectsButSessionEndDoesNot() throws {
    let hostTransport = MockHostTransport()
    let host = try makeHost(game: try NetTestSupport.startedGame(players), transport: hostTransport)
    let guestTransport = MockGuestTransport(host: hostTransport)
    let guest = makeGuest(guestTransport)
    try join(guest, seat: players[1].id, name: "Bob")
    let token = try XCTUnwrap(guest.guestToken)

    let back = expectation(description: "rejoined after connection loss")
    back.assertForOverFulfill = false
    var states: [GuestConnectionState] = []
    guest.onConnectionStateChanged = { state in
      states.append(state)
      if state == .connected { back.fulfill() }
    }
    guestTransport.simulateConnectionLoss()
    wait(for: [back], timeout: 2)
    XCTAssertEqual(states.first, .reconnecting(attempt: 1))
    XCTAssertEqual(guest.guestToken, token)
    XCTAssertEqual(host.connectedGuestPlayerIDs, [players[1].id])
    let connectsBeforeEnd = guestTransport.connectCount

    let ended = expectation(description: "session ended")
    var endReason: GuestSessionEndReason?
    guest.onSessionEnded = { reason in
      endReason = reason
      ended.fulfill()
    }
    host.stop()
    wait(for: [ended], timeout: 2)
    XCTAssertEqual(endReason, .hostEnded)
    XCTAssertEqual(guest.connectionState, .ended(.hostEnded))

    drainMainQueue(seconds: 0.2)
    XCTAssertEqual(guestTransport.connectCount, connectsBeforeEnd, "an ended session must not reconnect")
  }

  func testRejoinReplacesOldConnection() throws {
    let hostTransport = MockHostTransport()
    let host = try makeHost(game: try NetTestSupport.startedGame(players), transport: hostTransport)
    let oldTransport = MockGuestTransport(host: hostTransport)
    let oldGuest = makeGuest(oldTransport, timing: NetTestSupport.fastTiming(reconnectDelays: [30]))
    try join(oldGuest, seat: players[1].id, name: "Bob")

    let newTransport = MockGuestTransport(host: hostTransport)
    let newGuest = makeGuest(newTransport, token: oldGuest.guestToken)
    let rejoined = expectation(description: "rejoined")
    newGuest.onJoinAccepted = { rejoined.fulfill() }
    try newGuest.connect()
    wait(for: [rejoined], timeout: 2)

    XCTAssertTrue(hostTransport.closedConnectionIDs.contains(oldTransport.connectionID))
    XCTAssertEqual(host.guestsByConnection.count, 1)
    XCTAssertEqual(host.guestsByConnection.values.first?.connectionID, newTransport.connectionID)
    XCTAssertEqual(newGuest.playerId, players[1].id)
    oldGuest.disconnect()
  }

  // MARK: - Seats

  func testSeatKeptAfterPreStartDropAndReleasedOnUnassign() throws {
    let hostTransport = MockHostTransport()
    let host = try makeHost(transport: hostTransport)
    let first = makeGuest(MockGuestTransport(host: hostTransport))
    try join(first, seat: players[1].id, name: "Bobby")
    first.disconnect()
    drainMainQueue()

    let slot = host.lobbySlots[1]
    XCTAssertTrue(slot.isBoundToDevice)
    XCTAssertFalse(slot.isConnected)
    XCTAssertFalse(slot.isClaimable)
    XCTAssertEqual(slot.name, "Bobby")

    let second = makeGuest(MockGuestTransport(host: hostTransport))
    let lobby = expectation(description: "lobby")
    lobby.assertForOverFulfill = false
    second.onJoinLobby = { _ in lobby.fulfill() }
    try second.connect()
    wait(for: [lobby], timeout: 2)
    XCTAssertEqual(try claimResult(second, seat: players[1].id, name: "Zed"), .seatTaken)

    XCTAssertTrue(host.unassignSeat(playerId: players[1].id))
    XCTAssertTrue(host.lobbySlots[1].isClaimable)
    XCTAssertEqual(host.lobbySlots[1].name, "Bobby", "name is kept when the seat is released")
    XCTAssertTrue(host.registeredGuests.isEmpty)

    XCTAssertNil(try claimResult(second, seat: players[1].id, name: "Zed"))
    XCTAssertEqual(host.game.players[1].name, "Zed")
  }

  func testUnassignKicksConnectedGuest() throws {
    let hostTransport = MockHostTransport()
    let host = try makeHost(transport: hostTransport)
    let guestTransport = MockGuestTransport(host: hostTransport)
    let guest = makeGuest(guestTransport)
    try join(guest, seat: players[2].id, name: "Carla")

    let kicked = expectation(description: "kicked")
    guest.onSessionEnded = { reason in
      XCTAssertEqual(reason, .kicked)
      kicked.fulfill()
    }
    host.unassignSeat(playerId: players[2].id)
    wait(for: [kicked], timeout: 2)
    XCTAssertEqual(guest.connectionState, .ended(.kicked))
    XCTAssertTrue(hostTransport.closedConnectionIDs.contains(guestTransport.connectionID))
    XCTAssertFalse(host.isSeatBoundToDevice(players[2].id))
  }

  func testReconnectWithReleasedSeatEndsSession() throws {
    let hostTransport = MockHostTransport()
    let host = try makeHost(transport: hostTransport)
    let guestTransport = MockGuestTransport(host: hostTransport)
    let guest = makeGuest(guestTransport, timing: NetTestSupport.fastTiming(reconnectDelays: [0.2]))
    try join(guest, seat: players[2].id, name: "Carla")

    let ended = expectation(description: "seat released")
    guest.onSessionEnded = { reason in
      XCTAssertEqual(reason, .seatReleased)
      ended.fulfill()
    }
    guestTransport.simulateConnectionLoss()
    drainMainQueue()
    // While the guest is away, the host frees the seat.
    host.unassignSeat(playerId: players[2].id)
    wait(for: [ended], timeout: 2)
    XCTAssertNil(guest.guestToken)
  }

  func testLeaveReleasesSeat() throws {
    let hostTransport = MockHostTransport()
    let host = try makeHost(transport: hostTransport)
    let guest = makeGuest(MockGuestTransport(host: hostTransport))
    try join(guest, seat: players[1].id, name: "Bob")
    XCTAssertTrue(host.isSeatBoundToDevice(players[1].id))

    guest.leave()
    drainMainQueue()
    XCTAssertFalse(host.isSeatBoundToDevice(players[1].id))
    XCTAssertEqual(guest.connectionState, .ended(.left))
  }

  func testClaimBySeatIdValidatesNames() throws {
    let hostTransport = MockHostTransport()
    let host = try makeHost(transport: hostTransport)
    let guest = makeGuest(MockGuestTransport(host: hostTransport))
    let lobby = expectation(description: "lobby")
    lobby.assertForOverFulfill = false
    guest.onJoinLobby = { _ in lobby.fulfill() }
    try guest.connect()
    wait(for: [lobby], timeout: 2)

    XCTAssertEqual(try claimResult(guest, seat: players[2].id, name: "   "), .nameInvalid)
    XCTAssertEqual(try claimResult(guest, seat: players[2].id, name: String(repeating: "x", count: 25)), .nameInvalid)
    XCTAssertEqual(try claimResult(guest, seat: players[2].id, name: "bob"), .nameTaken)
    XCTAssertEqual(try claimResult(guest, seat: players[0].id, name: "Dana"), .seatTaken)
    XCTAssertEqual(try claimResult(guest, seat: UUID(), name: "Dana"), .seatNotFound)
    XCTAssertEqual(guest.connectionState, .connected, "claim rejections are not fatal")

    // The guest may keep the host-given name of its seat.
    XCTAssertNil(try claimResult(guest, seat: players[2].id, name: "  Carol  "))
    XCTAssertEqual(guest.playerName, "Carol")
    XCTAssertEqual(host.game.players[2].name, "Carol")
    XCTAssertEqual(host.boundGuestPlayerIDs, [players[2].id])
  }

  func testHostRenamesAndReordersSeatsBeforeStart() throws {
    let hostTransport = MockHostTransport()
    let host = try makeHost(transport: hostTransport)
    let guest = makeGuest(MockGuestTransport(host: hostTransport))
    let lobby = expectation(description: "lobby")
    lobby.assertForOverFulfill = false
    guest.onJoinLobby = { _ in lobby.fulfill() }
    try guest.connect()
    wait(for: [lobby], timeout: 2)

    try host.renameSeat(playerId: players[2].id, to: " Zoe ")
    XCTAssertEqual(host.game.players[2].name, "Zoe")
    XCTAssertThrowsError(try host.renameSeat(playerId: players[1].id, to: "zoe")) { error in
      XCTAssertEqual(error as? HostSessionError, .nameTaken)
    }
    XCTAssertThrowsError(try host.renameSeat(playerId: players[1].id, to: "")) { error in
      XCTAssertEqual(error as? HostSessionError, .nameInvalid)
    }
    XCTAssertThrowsError(try host.renameSeat(playerId: UUID(), to: "Max")) { error in
      XCTAssertEqual(error as? HostSessionError, .seatNotFound)
    }

    let reordered = expectation(description: "guest sees new order")
    reordered.assertForOverFulfill = false
    let newOrder = [players[2].id, players[0].id, players[1].id]
    guest.onLobbyUpdated = { slots in
      if slots.map(\.playerId) == newOrder { reordered.fulfill() }
    }
    try host.reorderSeats(newOrder)
    XCTAssertEqual(host.game.players.map(\.id), newOrder)
    wait(for: [reordered], timeout: 2)
    XCTAssertEqual(guest.lobbySlots.map(\.name), ["Zoe", "Hanna", "Bob"])

    XCTAssertThrowsError(try host.reorderSeats([players[0].id, players[1].id])) { error in
      XCTAssertEqual(error as? HostSessionError, .invalidSeatOrder)
    }

    try host.startGame(startingDealer: players[0].id, gameConstraints: [.betSumNotEqualHandSize], playWithSpecialCards: true)
    XCTAssertThrowsError(try host.reorderSeats(newOrder.reversed())) { error in
      XCTAssertEqual(error as? HostSessionError, .gameAlreadyStarted)
    }
  }

  // MARK: - Guest permissions and validation on the host

  func testBetMakingSumEqualHandSizeIsRejectedAndRolledBack() throws {
    let hostTransport = MockHostTransport()
    let host = try makeHost(game: try NetTestSupport.startedGame(players), transport: hostTransport)
    let guest = makeGuest(MockGuestTransport(host: hostTransport))
    try join(guest, seat: players[1].id, name: "Bob")

    XCTAssertNil(host.applyHostCommands([
      .submitBet(playerId: players[0].id, roundIndex: 0, bet: 0),
      .submitBet(playerId: players[2].id, roundIndex: 0, bet: 0),
    ]))
    drainMainQueue()
    let before = host.game
    let revisionBefore = host.revision

    // Hand size 1: 0 + 1 + 0 == 1 → rejected, nothing applied.
    XCTAssertEqual(
      try submit(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 1), as: guest),
      .rejected(.betSumEqualsHandSize(handSize: 1))
    )
    XCTAssertEqual(host.game, before)
    XCTAssertEqual(host.revision, revisionBefore)
    XCTAssertNil(host.game.rounds[0].entries[players[1].id]?.bet)

    XCTAssertEqual(try submit(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 0), as: guest), .accepted)
    XCTAssertEqual(host.game.rounds[0].entries[players[1].id]?.bet, 0)

    // All bets are in now: bets are locked for the guest, won tricks open.
    XCTAssertEqual(
      try submit(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 1), as: guest),
      .rejected(.betsComplete)
    )
    XCTAssertEqual(try submit(.submitGot(playerId: players[1].id, roundIndex: 0, got: 1), as: guest), .accepted)
    XCTAssertEqual(try submit(.submitGot(playerId: players[1].id, roundIndex: 0, got: 0), as: guest), .accepted)
    XCTAssertEqual(
      try submit(.submitGot(playerId: players[2].id, roundIndex: 0, got: 1), as: guest),
      .rejected(.notYourSeat)
    )
    XCTAssertEqual(try submit(.finalizeCurrentRound(), as: guest), .rejected(.notAuthorized))
  }

  func testGuestCannotEnterWonTricksBeforeAllBets() throws {
    let hostTransport = MockHostTransport()
    _ = try makeHost(game: try NetTestSupport.startedGame(players), transport: hostTransport)
    let guest = makeGuest(MockGuestTransport(host: hostTransport))
    try join(guest, seat: players[1].id, name: "Bob")
    XCTAssertEqual(
      try submit(.submitGot(playerId: players[1].id, roundIndex: 0, got: 1), as: guest),
      .rejected(.betsIncomplete)
    )
  }

  func testCommandWithoutAnswerTimesOut() throws {
    let hostTransport = MockHostTransport()
    _ = try makeHost(game: try NetTestSupport.startedGame(players), transport: hostTransport)
    let guestTransport = MockGuestTransport(host: hostTransport)
    let guest = makeGuest(guestTransport, timing: NetTestSupport.fastTiming(commandTimeout: 0.2))
    try join(guest, seat: players[1].id, name: "Bob")

    guestTransport.isSilenced = true
    XCTAssertEqual(try submit(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 0), as: guest), .timedOut)
    XCTAssertTrue(guest.pendingCommands.isEmpty)
  }

  // MARK: - Host authority

  func testHostBatchIsAtomic() throws {
    let hostTransport = MockHostTransport()
    let host = try makeHost(game: try NetTestSupport.startedGame(players), transport: hostTransport)
    let guestTransport = MockGuestTransport(host: hostTransport)
    let guest = makeGuest(guestTransport)
    try join(guest, seat: players[1].id, name: "Bob")

    var persisted: [Int] = []
    host.onGameSnapshot = { _, revision in persisted.append(revision) }
    let before = host.game
    let revisionBefore = host.revision
    let snapshotsBefore = hostTransport.envelopesSent(to: guestTransport.connectionID).filter(NetTestSupport.isSnapshot).count

    let error = host.applyHostCommands([
      .submitBet(playerId: players[0].id, roundIndex: 0, bet: 0),
      .submitBet(playerId: players[2].id, roundIndex: 0, bet: 5),
    ])
    XCTAssertEqual(error as? DomainError, .invalidBet(playerId: players[2].id, bet: 5, handSize: 1))
    XCTAssertEqual(host.game, before)

    struct ValidationFailed: Error {}
    XCTAssertNotNil(host.applyHostCommands([.submitBet(playerId: players[0].id, roundIndex: 0, bet: 0)]) { _ in
      throw ValidationFailed()
    })
    XCTAssertEqual(host.game, before)
    XCTAssertEqual(host.revision, revisionBefore)
    XCTAssertTrue(persisted.isEmpty)

    XCTAssertNil(host.applyHostCommands([
      .submitBet(playerId: players[0].id, roundIndex: 0, bet: 0),
      .submitBet(playerId: players[2].id, roundIndex: 0, bet: 1),
    ]))
    XCTAssertEqual(host.revision, revisionBefore + 1)
    XCTAssertEqual(persisted, [revisionBefore + 1], "one commit → persisted once")
    let snapshotsAfter = hostTransport.envelopesSent(to: guestTransport.connectionID).filter(NetTestSupport.isSnapshot).count
    XCTAssertEqual(snapshotsAfter, snapshotsBefore + 1, "one commit → broadcast once")
  }

  func testSessionEndsAutomaticallyWhenGameIsFinished() throws {
    let six = NetTestSupport.players(["A", "B", "C", "D", "E", "F"])
    var rounds: [Round] = []
    for index in 0..<10 {
      let handSize = index + 1
      let entries = Dictionary(uniqueKeysWithValues: six.enumerated().map { seat, player in
        (player.id, RoundEntry(bet: 0, got: seat == 0 ? handSize : 0))
      })
      rounds.append(Round(handSize: handSize, dealer: six[index % 6].id, entries: entries, isFinalized: index < 9))
    }
    let almostDone = try Game(id: UUID(), name: "Last", mode: .multiPhone, players: six, rounds: rounds, currentRoundIndex: 9)
    XCTAssertEqual(almostDone.totalRoundsPlanned, 10)

    let hostTransport = MockHostTransport()
    let host = HostSessionService(
      initialGame: almostDone,
      sessionCode: code,
      transport: hostTransport,
      hostReservedPlayerId: six[0].id,
      timing: NetTestSupport.quietTiming
    )
    try host.start()
    let guest = makeGuest(MockGuestTransport(host: hostTransport))
    try join(guest, seat: six[1].id, name: "Bee")

    var events: [String] = []
    let ended = expectation(description: "ended")
    guest.onGameSnapshot = { game, _ in
      if HostSessionService.isGameFinished(game) { events.append("final snapshot") }
    }
    guest.onSessionEnded = { reason in
      events.append("ended \(reason)")
      ended.fulfill()
    }
    var hostEnd: SessionEndReason?
    host.onSessionEnded = { hostEnd = $0 }

    XCTAssertNil(host.applyHostCommands([.finalizeCurrentRound()]))
    XCTAssertEqual(hostEnd, .gameFinished)
    XCTAssertFalse(host.isActive)
    XCTAssertEqual(host.endReason, .gameFinished)

    wait(for: [ended], timeout: 2)
    XCTAssertEqual(events, ["final snapshot", "ended gameFinished"])
    XCTAssertTrue(HostSessionService.isGameFinished(try XCTUnwrap(guest.game)))
    XCTAssertNotNil(host.applyHostCommands([.finalizeCurrentRound()]), "ended session accepts no more commands")
  }

  func testSnapshotsAreOnlySentToJoinedGuests() throws {
    let hostTransport = MockHostTransport()
    let host = try makeHost(game: try NetTestSupport.startedGame(players), transport: hostTransport)

    let joinedTransport = MockGuestTransport(host: hostTransport)
    try join(makeGuest(joinedTransport), seat: players[1].id, name: "Bob")

    let pickingTransport = MockGuestTransport(host: hostTransport)
    let picking = makeGuest(pickingTransport)
    let lobby = expectation(description: "lobby")
    lobby.assertForOverFulfill = false
    picking.onJoinLobby = { _ in lobby.fulfill() }
    try picking.connect()
    wait(for: [lobby], timeout: 2)

    let silentTransport = MockGuestTransport(host: hostTransport)
    silentTransport.emitsConnectedOnConnect = false
    try silentTransport.connect()
    drainMainQueue()

    XCTAssertNil(host.applyHostCommands([.submitBet(playerId: players[0].id, roundIndex: 0, bet: 0)]))
    drainMainQueue()

    XCTAssertTrue(hostTransport.envelopesSent(to: joinedTransport.connectionID).contains(where: NetTestSupport.isSnapshot))
    XCTAssertFalse(hostTransport.envelopesSent(to: pickingTransport.connectionID).contains(where: NetTestSupport.isSnapshot))
    XCTAssertTrue(hostTransport.envelopesSent(to: silentTransport.connectionID).isEmpty)
  }

  // MARK: - Listener

  func testFailedListenerIsRestarted() throws {
    let hostTransport = MockHostTransport()
    let host = try makeHost(transport: hostTransport, timing: NetTestSupport.fastTiming())
    drainMainQueue()  // the initial `.ready` from `start()`
    XCTAssertEqual(host.listenerState, .ready)
    let ready = expectation(description: "listener ready again")
    ready.assertForOverFulfill = false
    host.onListenerStateChanged = { state in
      if state == .ready { ready.fulfill() }
    }
    hostTransport.simulateListenerState(.failed(.network("suspended")))
    wait(for: [ready], timeout: 2)
    XCTAssertEqual(hostTransport.listenerRestartCount, 1)

    hostTransport.simulateListenerState(.stopped)
    drainMainQueue()
    host.handleAppDidBecomeActive()
    XCTAssertEqual(hostTransport.listenerRestartCount, 2)
  }

  // MARK: - Mixed versions (decision 1)

  func testV1HelloGetsV1DecodableRejectionAndIsClosed() throws {
    let hostTransport = MockHostTransport()
    _ = try makeHost(transport: hostTransport)
    let oldGuest = MockGuestTransport(host: hostTransport)
    try oldGuest.connect()
    oldGuest.sendRawFrame(NetTestSupport.legacyV1HelloFrame(sessionCode: code))
    drainMainQueue()

    XCTAssertEqual(oldGuest.receivedFrames.count, 1)
    let v1 = try LegacyV1Mirror.decodeJoinRejected(frame: try XCTUnwrap(oldGuest.receivedFrames.first))
    XCTAssertEqual(v1.version, 1)
    XCTAssertEqual(v1.payload.type, .joinRejected)
    XCTAssertTrue(v1.payload.joinRejected.reason.contains("update"))
    XCTAssertEqual(hostTransport.closedConnectionIDs, [oldGuest.connectionID])
  }

  func testGuestReportsIncompatibleHostWhenHelloIsNeverAnswered() throws {
    // A transport nobody answers on behaves like a v1 host, which ignores v2 hellos.
    let silentHost = MockHostTransport()
    try silentHost.start()
    let guest = makeGuest(MockGuestTransport(host: silentHost), timing: NetTestSupport.fastTiming(helloReplyTimeout: 0.2))
    let failed = expectation(description: "incompatible host reported")
    guest.onError = { error in
      XCTAssertEqual(error as? GuestSessionError, .hostIncompatibleOrUnreachable)
      failed.fulfill()
    }
    try guest.connect()
    wait(for: [failed], timeout: 2)
    XCTAssertEqual(guest.connectionState, .ended(.connectFailed(.hostIncompatibleOrUnreachable)))
  }

  func testUnreachableHostIsReported() throws {
    let stoppedHost = MockHostTransport()
    let guest = makeGuest(MockGuestTransport(host: stoppedHost))
    let failed = expectation(description: "unreachable reported")
    guest.onError = { error in
      XCTAssertEqual(error as? GuestSessionError, .hostUnreachable)
      failed.fulfill()
    }
    try guest.connect()
    wait(for: [failed], timeout: 2)
  }

  func testLocalNetworkDenialIsReported() throws {
    let hostTransport = MockHostTransport()
    try hostTransport.start()
    let guestTransport = MockGuestTransport(host: hostTransport)
    guestTransport.nextConnectFailure = .localNetworkDenied
    let guest = makeGuest(guestTransport)
    let failed = expectation(description: "denial reported")
    guest.onError = { error in
      XCTAssertEqual(error as? GuestSessionError, .localNetworkDenied)
      failed.fulfill()
    }
    try guest.connect()
    wait(for: [failed], timeout: 2)
  }

  // MARK: - Mock transport realism

  func testAsyncChunkedDeliveryKeepsOrder() throws {
    let hostTransport = MockHostTransport()
    hostTransport.delivery = .mainQueue
    hostTransport.chunkSize = 7
    let host = try makeHost(transport: hostTransport)
    let guestTransport = MockGuestTransport(host: hostTransport)
    guestTransport.delivery = .mainQueue
    guestTransport.chunkSize = 5
    let guest = makeGuest(guestTransport)
    try join(guest, seat: players[1].id, name: "Bob")

    let snapshot = expectation(description: "snapshot with bet")
    snapshot.assertForOverFulfill = false
    guest.onGameSnapshot = { game, _ in
      if game.rounds.first?.entries[self.players[1].id]?.bet == 1 { snapshot.fulfill() }
    }
    try host.startGame(startingDealer: players[0].id, gameConstraints: [.betSumNotEqualHandSize], playWithSpecialCards: true)
    drainMainQueue()
    XCTAssertEqual(try submit(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 1), as: guest), .accepted)
    wait(for: [snapshot], timeout: 2)
  }
}
