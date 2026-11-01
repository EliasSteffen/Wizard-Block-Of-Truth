import Foundation
import SwiftData
import XCTest
@testable import WizardApp
@testable import WizardDomain
@testable import WizardNet

/// App-layer multi-phone behaviour with in-memory transports and an in-memory SwiftData store.
@MainActor
final class MultiplayerCoordinatorTests: XCTestCase {
  private final class TransportBox {
    var hosts: [MockHostTransport] = []
    var guests: [MockGuestTransport] = []
  }

  private struct Environment {
    let coordinator: MultiplayerCoordinator
    let container: ModelContainer
    let context: ModelContext
    let defaults: UserDefaults
    let transports: TransportBox

    var hostTransport: MockHostTransport? { transports.hosts.last }
  }

  private func makeDefaults() -> (UserDefaults, String) {
    let suiteName = "MultiplayerCoordinatorTests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
  }

  private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
      for: GameSnapshotEntity.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
  }

  private func makeEnvironment(
    code: String = "ABCD12",
    defaults: UserDefaults,
    container: ModelContainer? = nil
  ) throws -> Environment {
    let container = try container ?? makeContainer()
    let box = TransportBox()
    let factory = MultiplayerTransportFactory(
      makeHostTransport: { _ in
        let transport = MockHostTransport()
        box.hosts.append(transport)
        return transport
      },
      makeGuestTransport: { _ in
        let transport = MockGuestTransport(host: box.hosts.last ?? MockHostTransport())
        box.guests.append(transport)
        return transport
      }
    )
    let coordinator = MultiplayerCoordinator(
      defaults: defaults,
      transportFactory: factory,
      timing: SessionTiming(pingInterval: 3600, silenceTimeout: 3600, reconnectDelays: [0.05]),
      makeSessionCode: { code }
    )
    return Environment(
      coordinator: coordinator,
      container: container,
      context: ModelContext(container),
      defaults: defaults,
      transports: box
    )
  }

  /// Creates an unstarted multi-phone game with "Player N" seats and returns it.
  private func createGame(named name: String, in context: ModelContext) throws -> Game {
    let players = (0..<3).map { index in
      Player(id: UUID(), name: PlayerNaming.placeholderName(playerNumber: index + 1, languageCode: "en"))
    }
    let store = GameStore(modelContext: context)
    store.createGame(name: name, mode: .multiPhone, players: players)
    return try XCTUnwrap(store.currentGame)
  }

  /// Reads the game as saved to SwiftData (a fresh context only sees saved data).
  private func savedGame(_ id: UUID, in container: ModelContainer) -> Game? {
    let store = GameStore(modelContext: ModelContext(container))
    store.loadGame(id: id)
    return store.currentGame
  }

  private func joinGuest(_ guest: GuestSessionService, seat: UUID, name: String) {
    let joined = expectation(description: "guest joined")
    joined.assertForOverFulfill = false
    guest.onJoinLobby = { _ in
      try? guest.claimPlayer(playerId: seat, displayName: name)
    }
    guest.onSlotClaimed = { joined.fulfill() }
    guest.onJoinAccepted = { joined.fulfill() }
    XCTAssertNoThrow(try guest.connect())
    wait(for: [joined], timeout: 2)
  }

  private func drain(_ seconds: TimeInterval = 0.05) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
  }

  // MARK: - Host authority

  func testGuestCommandIsPersistedBeforeItIsBroadcast() throws {
    let (defaults, suite) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let env = try makeEnvironment(defaults: defaults)
    let game = try createGame(named: "Friday", in: env.context)
    let seats = game.players.map(\.id)

    try env.coordinator.startHosting(gameID: game.id, modelContext: env.context, hostPlayerId: seats[0], hostDisplayName: "Hanna")
    try env.coordinator.startHostedGame(
      gameID: game.id,
      startingDealerId: seats[0],
      gameConstraints: [.betSumNotEqualHandSize],
      playWithSpecialCards: true
    )
    let hostTransport = try XCTUnwrap(env.hostTransport)
    let guest = GuestSessionService(sessionCode: "ABCD12", transport: MockGuestTransport(host: hostTransport))
    joinGuest(guest, seat: seats[1], name: "Bob")

    var savedWhenBroadcast: Int??
    let snapshot = expectation(description: "snapshot with the guest's bet")
    snapshot.assertForOverFulfill = false
    guest.onGameSnapshot = { [container = env.container] game, _ in
      guard game.rounds[0].entries[seats[1]]?.bet == 0 else { return }
      if savedWhenBroadcast == nil {
        savedWhenBroadcast = self.savedGame(game.id, in: container)?.rounds[0].entries[seats[1]]?.bet
      }
      snapshot.fulfill()
    }
    try guest.submitGuestCommand(.submitBet(playerId: seats[1], roundIndex: 0, bet: 0))
    wait(for: [snapshot], timeout: 2)

    XCTAssertEqual(savedWhenBroadcast, .some(.some(0)), "saved to SwiftData before guests saw it")
    let saved = try XCTUnwrap(savedGame(game.id, in: env.container))
    XCTAssertEqual(saved.players[0].name, "Hanna")
    XCTAssertEqual(saved.players[1].name, "Bob")
    XCTAssertEqual(saved.mode, .multiPhone)
    let store = try XCTUnwrap(env.coordinator.store(for: game.id))
    XCTAssertEqual(store.currentGame?.rounds[0].entries[seats[1]]?.bet, 0)
    XCTAssertNil(store.lastError)
    XCTAssertTrue(store.isPlayerBoundToGuestDevice(seats[1]))
    XCTAssertFalse(store.isPlayerBoundToGuestDevice(seats[2]))
  }

  func testLoadGameDoesNotClobberLiveSessionAndHostCommandsBuildOnIt() throws {
    let (defaults, suite) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let env = try makeEnvironment(defaults: defaults)
    let game = try createGame(named: "Friday", in: env.context)
    let seats = game.players.map(\.id)
    try env.coordinator.startHosting(gameID: game.id, modelContext: env.context, hostPlayerId: seats[0], hostDisplayName: "Hanna")
    try env.coordinator.startHostedGame(
      gameID: game.id,
      startingDealerId: seats[0],
      gameConstraints: [.betSumNotEqualHandSize],
      playWithSpecialCards: true
    )
    let store = try XCTUnwrap(env.coordinator.store(for: game.id))
    let staleCopy = try XCTUnwrap(store.currentGame)

    let guest = GuestSessionService(sessionCode: "ABCD12", transport: MockGuestTransport(host: try XCTUnwrap(env.hostTransport)))
    joinGuest(guest, seat: seats[1], name: "Bob")
    let accepted = expectation(description: "guest bet accepted")
    guest.onCommandOutcome = { _, outcome in
      XCTAssertEqual(outcome, .accepted)
      accepted.fulfill()
    }
    try guest.submitGuestCommand(.submitBet(playerId: seats[1], roundIndex: 0, bet: 0))
    wait(for: [accepted], timeout: 2)

    // Someone writes an older copy to disk behind the session's back; a reload must not resurrect it.
    GameStore(modelContext: env.context).replaceCurrentGame(staleCopy)
    store.loadGame(id: game.id)
    XCTAssertEqual(store.currentGame?.rounds[0].entries[seats[1]]?.bet, 0)

    // Host commands go through the session game (not the stale disk copy) and are saved.
    XCTAssertNil(store.applyBatch([.submitBet(playerId: seats[0], roundIndex: 0, bet: 0)], validate: nil))
    XCTAssertEqual(store.currentGame?.rounds[0].entries[seats[1]]?.bet, 0)
    XCTAssertEqual(store.currentGame?.rounds[0].entries[seats[0]]?.bet, 0)
    XCTAssertEqual(savedGame(game.id, in: env.container)?.rounds[0].entries[seats[1]]?.bet, 0)

    // A failing batch changes nothing.
    XCTAssertNotNil(store.applyBatch([.submitBet(playerId: seats[2], roundIndex: 0, bet: 9)], validate: nil))
    XCTAssertNil(store.currentGame?.rounds[0].entries[seats[2]]?.bet)
  }

  func testOnlyOneHostedSessionAtATime() throws {
    let (defaults, suite) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let env = try makeEnvironment(defaults: defaults)
    let first = try createGame(named: "First", in: env.context)
    let second = try createGame(named: "Second", in: env.context)

    try env.coordinator.startHosting(gameID: first.id, modelContext: env.context, hostPlayerId: first.players[0].id, hostDisplayName: "Hanna")
    XCTAssertThrowsError(
      try env.coordinator.startHosting(gameID: second.id, modelContext: env.context, hostPlayerId: second.players[0].id, hostDisplayName: "Hanna")
    ) { error in
      XCTAssertEqual(error as? MultiplayerCoordinatorError, .anotherSessionActive(gameID: first.id, gameName: "First"))
    }
    // Same game again just returns the running lobby.
    XCTAssertNoThrow(
      try env.coordinator.startHosting(gameID: first.id, modelContext: env.context, hostPlayerId: first.players[0].id, hostDisplayName: "Hanna")
    )
    XCTAssertEqual(env.transports.hosts.count, 1)
    XCTAssertEqual(env.coordinator.activeHostedGameID, first.id)

    env.coordinator.endSession(gameID: first.id)
    XCTAssertFalse(env.coordinator.isHosting(gameID: first.id))
    XCTAssertNil(env.coordinator.store(for: first.id))
    XCTAssertNil(env.coordinator.hostLobbyState)
    XCTAssertFalse(env.transports.hosts[0].isRunning)
    XCTAssertFalse(env.coordinator.hasResumableHostSession(gameID: first.id))

    try env.coordinator.startHosting(gameID: second.id, modelContext: env.context, hostPlayerId: second.players[0].id, hostDisplayName: "Hanna")
    XCTAssertTrue(env.coordinator.isHosting(gameID: second.id))
  }

  func testEndSessionTellsGuestsBeforeClosing() throws {
    let (defaults, suite) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let env = try makeEnvironment(defaults: defaults)
    let game = try createGame(named: "Friday", in: env.context)
    try env.coordinator.startHosting(gameID: game.id, modelContext: env.context, hostPlayerId: game.players[0].id, hostDisplayName: "Hanna")
    let guest = GuestSessionService(sessionCode: "ABCD12", transport: MockGuestTransport(host: try XCTUnwrap(env.hostTransport)))
    joinGuest(guest, seat: game.players[1].id, name: "Bob")

    let ended = expectation(description: "guest told")
    guest.onSessionEnded = { reason in
      XCTAssertEqual(reason, .hostEnded)
      ended.fulfill()
    }
    env.coordinator.endSession(gameID: game.id)
    wait(for: [ended], timeout: 2)
  }

  func testResumeHostingAfterRelaunchKeepsCodeAndGuestSeats() throws {
    let (defaults, suite) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let container = try makeContainer()
    let before = try makeEnvironment(code: "AAAAAA", defaults: defaults, container: container)
    let game = try createGame(named: "Friday", in: before.context)
    try before.coordinator.startHosting(gameID: game.id, modelContext: before.context, hostPlayerId: game.players[0].id, hostDisplayName: "Hanna")
    let guest = GuestSessionService(sessionCode: "AAAAAA", transport: MockGuestTransport(host: try XCTUnwrap(before.hostTransport)))
    joinGuest(guest, seat: game.players[1].id, name: "Bob")
    let token = try XCTUnwrap(guest.guestToken)

    // "Relaunch": a fresh coordinator (new random code generator) with the same UserDefaults and database.
    let after = try makeEnvironment(code: "ZZZZZZ", defaults: defaults, container: container)
    XCTAssertTrue(after.coordinator.hasResumableHostSession(gameID: game.id))
    let lobby = try XCTUnwrap(try after.coordinator.resumeHosting(gameID: game.id, modelContext: after.context))
    XCTAssertEqual(lobby.sessionCode, "AAAAAA")
    XCTAssertEqual(lobby.hostPlayerId, game.players[0].id)
    XCTAssertEqual(lobby.boundGuestPlayerIDs, [game.players[1].id])
    XCTAssertEqual(lobby.players[1].name, "Bob")

    let rejoining = GuestSessionService(
      sessionCode: "AAAAAA",
      guestToken: token,
      transport: MockGuestTransport(host: try XCTUnwrap(after.hostTransport))
    )
    let rejoined = expectation(description: "rejoined after host relaunch")
    rejoining.onSlotClaimed = { rejoined.fulfill() }
    try rejoining.connect()
    wait(for: [rejoined], timeout: 2)
    XCTAssertEqual(rejoining.playerId, game.players[1].id)
  }

  // MARK: - Guest side

  func testSavedGuestSessionIsClearedOnlyByItsToken() throws {
    let (defaults, suite) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let saved = SavedGuestSession(
      guestToken: "new",
      sessionCode: "ABCD12",
      playerId: UUID(),
      playerName: "Bob",
      hostDisplayName: nil,
      serviceName: "ABCD12-Friday",
      gameName: "Friday"
    )
    SavedGuestSession.save(saved, defaults: defaults)
    SavedGuestSession.clear(token: "old", defaults: defaults)
    XCTAssertEqual(SavedGuestSession.load(defaults: defaults), saved)
    SavedGuestSession.clear(token: "new", defaults: defaults)
    XCTAssertNil(SavedGuestSession.load(defaults: defaults))
  }

  func testSavedGuestSessionFromAppOneOneStillDecodes() throws {
    let (defaults, suite) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let legacy = #"{"guestToken":"t","sessionCode":"ABCD12","playerId":"00000000-0000-0000-0000-000000000001","playerName":"Bob"}"#
    defaults.set(Data(legacy.utf8), forKey: "multiplayer.savedGuestSession")
    let loaded = try XCTUnwrap(SavedGuestSession.load(defaults: defaults))
    XCTAssertEqual(loaded.guestToken, "t")
    XCTAssertNil(loaded.serviceName)
  }

  func testGuestStoreSavesTokenAtClaimAndClearsItOnlyWhenTheSessionEnds() throws {
    let (defaults, suite) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let env = try makeEnvironment(defaults: defaults)
    let game = try createGame(named: "Friday", in: env.context)
    try env.coordinator.startHosting(gameID: game.id, modelContext: env.context, hostPlayerId: game.players[0].id, hostDisplayName: "Hanna")

    let guest = env.coordinator.connectGuest(serviceName: "ABCD12-Friday", sessionCode: "ABCD12")
    let guestTransport = try XCTUnwrap(env.transports.guests.last)
    var sessionID: UUID?
    let claimed = expectation(description: "claimed")
    guest.onJoinLobby = { _ in
      try? guest.claimPlayer(playerId: game.players[1].id, displayName: "Bob")
    }
    guest.onSlotClaimed = {
      // Hand-over at claimAccepted, like JoinGameView.
      sessionID = env.coordinator.registerJoinedGuest(
        guest,
        playerId: guest.playerId!,
        setupPlayers: guest.setupPlayers,
        serviceName: "ABCD12-Friday"
      )
      claimed.fulfill()
    }
    try guest.connect()
    wait(for: [claimed], timeout: 2)

    drain()  // the lobby update that follows claimAccepted
    let store = try XCTUnwrap(env.coordinator.store(for: try XCTUnwrap(sessionID)))
    XCTAssertEqual(store.role, .guest(playerId: game.players[1].id))
    XCTAssertEqual(store.currentGame?.hasStarted, false)
    XCTAssertEqual(store.currentGame?.players[1].name, "Bob")
    let saved = try XCTUnwrap(SavedGuestSession.load(defaults: defaults))
    XCTAssertEqual(saved.guestToken, guest.guestToken)
    XCTAssertEqual(saved.serviceName, "ABCD12-Friday")

    // Losing the connection keeps the saved session (auto-reconnect uses it).
    guestTransport.simulateConnectionLoss()
    drain()
    XCTAssertNotNil(SavedGuestSession.load(defaults: defaults))
    let reconnected = expectation(description: "connected again")
    reconnected.assertForOverFulfill = false
    let cancellable = store.$connectionState.sink { state in
      if state == .connected { reconnected.fulfill() }
    }
    wait(for: [reconnected], timeout: 2)
    cancellable.cancel()

    // The game starts: the store follows.
    try env.coordinator.startHostedGame(
      gameID: game.id,
      startingDealerId: game.players[0].id,
      gameConstraints: [.betSumNotEqualHandSize],
      playWithSpecialCards: true
    )
    drain()
    XCTAssertEqual(store.currentGame?.hasStarted, true)

    // A guest command that breaks the bet-sum rule is reported as a rejection.
    let hostStore = try XCTUnwrap(env.coordinator.store(for: game.id))
    XCTAssertNil(hostStore.applyBatch([
      .submitBet(playerId: game.players[0].id, roundIndex: 0, bet: 0),
      .submitBet(playerId: game.players[2].id, roundIndex: 0, bet: 0),
    ], validate: nil))
    drain()
    store.apply(.submitBet(playerId: game.players[1].id, roundIndex: 0, bet: 1))
    XCTAssertNotNil(store.pendingCommand)
    drain(0.1)
    XCTAssertNil(store.pendingCommand)
    XCTAssertEqual(store.lastRejection, .betSumEqualsHandSize(handSize: 1))

    // The host ends the session: now the saved session is gone.
    env.coordinator.endSession(gameID: game.id)
    drain()
    XCTAssertEqual(store.connectionState, .ended(.hostEnded))
    XCTAssertNil(SavedGuestSession.load(defaults: defaults))
  }

  func testFinishedGameEndsSessionAndGuestKeepsReadOnlyCopy() throws {
    let (defaults, suite) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let env = try makeEnvironment(defaults: defaults)

    // A two-player game needs 20 rounds; play them through quickly as host, except the guest's values.
    let players = [
      Player(id: UUID(), name: PlayerNaming.placeholderName(playerNumber: 1, languageCode: "en")),
      Player(id: UUID(), name: PlayerNaming.placeholderName(playerNumber: 2, languageCode: "en")),
    ]
    let gameStore = GameStore(modelContext: env.context)
    gameStore.createGame(name: "Duel", mode: .multiPhone, players: players, gameConstraints: [])
    let game = try XCTUnwrap(gameStore.currentGame)
    try env.coordinator.startHosting(gameID: game.id, modelContext: env.context, hostPlayerId: players[0].id, hostDisplayName: "Hanna")
    try env.coordinator.startHostedGame(gameID: game.id, startingDealerId: players[0].id, gameConstraints: [], playWithSpecialCards: false)

    let guestContainer = try makeContainer()
    let guestContext = ModelContext(guestContainer)
    let guest = env.coordinator.connectGuest(serviceName: "ABCD12-Duel", sessionCode: "ABCD12")
    var sessionID: UUID?
    let joined = expectation(description: "joined")
    guest.onJoinLobby = { _ in
      try? guest.claimPlayer(playerId: players[1].id, displayName: "Bob")
    }
    guest.onJoinAccepted = {
      sessionID = env.coordinator.registerJoinedGuest(
        guest,
        playerId: guest.playerId!,
        setupPlayers: guest.setupPlayers,
        serviceName: "ABCD12-Duel",
        modelContext: guestContext
      )
      joined.fulfill()
    }
    try guest.connect()
    wait(for: [joined], timeout: 2)
    let guestStore = try XCTUnwrap(env.coordinator.store(for: try XCTUnwrap(sessionID)))
    let hostStore = try XCTUnwrap(env.coordinator.store(for: game.id))

    let total = try XCTUnwrap(hostStore.currentGame?.totalRoundsPlanned)
    for roundIndex in 0..<total {
      let handSize = roundIndex + 1
      XCTAssertNil(hostStore.applyBatch([
        .submitBet(playerId: players[0].id, roundIndex: roundIndex, bet: 0),
        .submitBet(playerId: players[1].id, roundIndex: roundIndex, bet: 0),
        .submitGot(playerId: players[0].id, roundIndex: roundIndex, got: handSize),
        .submitGot(playerId: players[1].id, roundIndex: roundIndex, got: 0),
      ], validate: nil))
      hostStore.apply(.finalizeCurrentRound())
      XCTAssertNil(hostStore.lastError)
    }

    XCTAssertFalse(env.coordinator.isHosting(gameID: game.id), "session ends automatically")
    XCTAssertFalse(env.coordinator.hasResumableHostSession(gameID: game.id))
    drain(0.3)
    XCTAssertEqual(guestStore.connectionState, .ended(.gameFinished))
    XCTAssertTrue(GuestFinishedGames.contains(game.id, defaults: defaults))
    let copy = GameStore(modelContext: guestContext)
    copy.loadGame(id: game.id)
    XCTAssertEqual(copy.currentGame?.rounds.count, total)
    XCTAssertEqual(copy.currentGame?.rounds.last?.isFinalized, true)
  }
}
