import Foundation
import os
#if canImport(WizardDomain)
import WizardDomain
#endif

private let hostLog = Logger(subsystem: "WizardBlockOfTruth", category: "HostSession")

public enum HostSessionError: Error, Equatable, Sendable {
  case invalidGuest(String)
  case invalidToken
  case unauthorizedCommand
  case gameAlreadyStarted
  case gameNotInSetup
  case seatNotFound
  case nameInvalid
  case nameTaken
  /// The seat belongs to a guest device; unassign it first.
  case seatBoundToDevice
  /// `reorderSeats` must list every seat exactly once.
  case invalidSeatOrder
  case sessionEnded
}

public struct ConnectedGuest: Sendable, Equatable {
  public var connectionID: UUID
  public var playerId: UUID
  public var playerName: String
  public var guestToken: String

  public init(connectionID: UUID, playerId: UUID, playerName: String, guestToken: String) {
    self.connectionID = connectionID
    self.playerId = playerId
    self.playerName = playerName
    self.guestToken = guestToken
  }
}

/// A guest device's claim on a seat (token → seat). Persisted by the app so it survives a host relaunch.
public struct RegisteredGuest: Codable, Sendable, Equatable {
  public var playerId: UUID
  public var playerName: String

  public init(playerId: UUID, playerName: String) {
    self.playerId = playerId
    self.playerName = playerName
  }
}

/// The host's authoritative multi-phone session.
///
/// `game` is the single source of truth while hosting: host commands (`applyHostCommands`) and guest commands are
/// applied here atomically, reported synchronously through `onGameSnapshot` (the app persists there) and sent to
/// joined guests once. All callbacks run synchronously on the main actor.
@MainActor
public final class HostSessionService {
  public private(set) var game: Game
  public private(set) var revision: Int
  /// Joined guests that are connected right now.
  public private(set) var guestsByConnection: [UUID: ConnectedGuest] = [:]
  public private(set) var hostReservedPlayerId: UUID?
  public private(set) var listenerState: HostListenerState = .stopped
  /// Set once the session ended (`stop` or automatically when the game finished).
  public private(set) var endReason: SessionEndReason?
  public let sessionCode: String
  /// Language for "Player N" names when a seat is reset to a placeholder (`nil` = English).
  public var placeholderLanguageCode: String?

  /// Every accepted change (host or guest, incl. lobby changes like names/order): persist here.
  public var onGameSnapshot: ((Game, Int) -> Void)?
  /// Transport-level problems (for logs; never alert the host about a guest's failed command).
  public var onError: ((Error) -> Void)?
  public var onGuestsChanged: (([ConnectedGuest]) -> Void)?
  /// Seats changed (names, order, bound/connected flags).
  public var onLobbyUpdated: (([LobbyPlayerSlot]) -> Void)?
  /// Token → seat registry changed: persist it so guests can rejoin after a host relaunch.
  public var onRegistryChanged: (([String: RegisteredGuest]) -> Void)?
  public var onListenerStateChanged: ((HostListenerState) -> Void)?
  public var onSessionEnded: ((SessionEndReason) -> Void)?
  /// A guest command was rejected (already answered on the wire; for logs/diagnostics only).
  public var onGuestCommandRejected: ((ConnectedGuest, MultiplayerReasonCode) -> Void)?

  private enum ConnectionPhase: Equatable {
    /// Socket open, no valid hello yet. Gets nothing but replies to its own messages.
    case awaitingHello
    /// Valid hello, no seat yet: gets lobby updates.
    case pending
    /// Holds a seat: gets snapshots.
    case authenticated(token: String)
  }

  private struct ConnectionRecord {
    var phase: ConnectionPhase
    var lastHeard: Date
  }

  private let transport: any HostSessionTransport
  private let timing: SessionTiming
  private let clock: () -> Date
  private var connections: [UUID: ConnectionRecord] = [:]
  /// Maps guest token to seat; survives disconnects until the host unassigns the seat or the session ends.
  private var guestRegistry: [String: RegisteredGuest]
  private var isRunning = false
  private var heartbeatTask: Task<Void, Never>?
  private var listenerRestartTask: Task<Void, Never>?
  private var listenerRestartAttempts = 0
  private var nextPingNonce: UInt64 = 1

  public var isInSetup: Bool { !game.hasStarted }
  /// Started and not ended.
  public var isActive: Bool { isRunning && endReason == nil }
  public var registeredGuests: [String: RegisteredGuest] { guestRegistry }
  /// Seats bound to a guest device (token registered), connected or not.
  public var boundGuestPlayerIDs: Set<UUID> { Set(guestRegistry.values.map(\.playerId)) }
  public var connectedGuestPlayerIDs: Set<UUID> { Set(guestsByConnection.values.map(\.playerId)) }

  public init(
    initialGame: Game,
    sessionCode: String,
    transport: any HostSessionTransport,
    initialRevision: Int = 0,
    hostReservedPlayerId: UUID? = nil,
    guestRegistry: [String: RegisteredGuest] = [:],
    timing: SessionTiming = .standard,
    clock: @escaping () -> Date = { Date() }
  ) {
    self.game = initialGame
    self.sessionCode = sessionCode
    self.transport = transport
    self.revision = initialRevision
    self.hostReservedPlayerId = hostReservedPlayerId
    self.timing = timing
    self.clock = clock
    // Keep only registrations whose seat still exists and is not the host's.
    let seatIDs = Set(initialGame.players.map(\.id))
    self.guestRegistry = guestRegistry.filter { entry in
      seatIDs.contains(entry.value.playerId) && entry.value.playerId != hostReservedPlayerId
    }
    let inbox = MainActorEventInbox<HostTransportEvent> { [weak self] event in
      self?.handleTransportEvent(event)
    }
    transport.onEvent = { event in
      inbox.post(event)
    }
  }

  public func start() throws {
    guard endReason == nil else { throw HostSessionError.sessionEnded }
    guard !isRunning else { return }
    try transport.start()
    isRunning = true
    startHeartbeat()
  }

  /// Ends the session: tells every guest (`sessionEnded`, delivered before the sockets close), closes all
  /// connections and stops advertising. Idempotent.
  public func stop(reason: SessionEndReason = .hostEnded) {
    guard endReason == nil else { return }
    endReason = reason
    heartbeatTask?.cancel()
    heartbeatTask = nil
    listenerRestartTask?.cancel()
    listenerRestartTask = nil
    let recipients = connectionIDs { $0 != .awaitingHello }
    send(.sessionEnded(SessionEndedMessage(code: .sessionEnded(reason), detail: "Session ended.")), to: recipients)
    connections.removeAll()
    guestsByConnection.removeAll()
    if isRunning {
      transport.stop()
    }
    isRunning = false
    listenerState = .stopped
    hostLog.info("Session \(self.sessionCode, privacy: .public) ended (\(reason.rawValue, privacy: .public))")
    onSessionEnded?(reason)
  }

  /// Call when the app returns to the foreground: restarts a failed/stopped listener (same Bonjour name) and
  /// pings guests right away. Silence while the app was suspended does not count against connections.
  public func handleAppDidBecomeActive() {
    guard isActive else { return }
    let now = clock()
    for id in Array(connections.keys) {
      connections[id]?.lastHeard = now
    }
    switch listenerState {
    case .ready, .starting:
      break
    case .waiting, .failed, .stopped:
      listenerRestartTask?.cancel()
      listenerRestartTask = nil
      listenerRestartAttempts = 0
      transport.restartListener()
    }
    sendPings()
  }

  /// Seats the host on `playerId` and names that seat. Refuses seats bound to a guest device. If the host moves
  /// away from a seat that carries the host's name, that seat goes back to its placeholder name.
  @discardableResult
  public func reserveHostSlot(playerId: UUID, displayName: String) -> Bool {
    let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let index = game.players.firstIndex(where: { $0.id == playerId }) else { return false }
    guard !boundGuestPlayerIDs.contains(playerId) else { return false }
    let name = String(trimmed.prefix(SeatNameRules.maxLength))
    var updated = game
    if let previous = hostReservedPlayerId, previous != playerId,
       let previousIndex = updated.players.firstIndex(where: { $0.id == previous }),
       updated.players[previousIndex].name == name {
      updated.players[previousIndex].name = PlayerNaming.placeholderName(
        playerNumber: previousIndex + 1,
        languageCode: placeholderLanguageCode
      )
    }
    updated.players[index].name = name
    hostReservedPlayerId = playerId
    if updated != game {
      commit(updated)
    } else {
      broadcastLobbyUpdate()
    }
    return true
  }

  public func startGame(
    startingDealer: UUID,
    gameConstraints: [Constraint.GameConstraint],
    playWithSpecialCards: Bool,
    firstRoundBetSumMayEqualHandSize: Bool = false
  ) throws {
    guard isInSetup else { throw HostSessionError.gameAlreadyStarted }
    guard game.players.contains(where: { $0.id == startingDealer }) else {
      throw DomainError.unknownPlayerId(startingDealer)
    }
    try game.setGameConstraints(gameConstraints)
    try game.setFirstRoundBetSumMayEqualHandSize(firstRoundBetSumMayEqualHandSize)
    game.playWithSpecialCards = playWithSpecialCards
    try game.apply(.startNewGame(startingDealer: startingDealer))
    revision += 1

    didCommitGameChange(wasStarted: false)
  }

  /// Applies host commands atomically on a copy (all or nothing, then `validate`), commits, persists (via
  /// `onGameSnapshot`) and broadcasts once. Returns the error instead of throwing so store code can mirror it.
  /// Ends the session automatically when this finishes the game.
  @discardableResult
  public func applyHostCommands(_ commands: [GameCommand], validate: ((Game) throws -> Void)? = nil) -> Error? {
    guard endReason == nil else { return HostSessionError.sessionEnded }
    var updated = game
    do {
      for command in commands {
        try updated.apply(command)
      }
      try validate?(updated)
    } catch {
      return error
    }
    guard updated != game else { return nil }
    commit(updated)
    return nil
  }

  @discardableResult
  public func applyHostCommand(_ command: GameCommand) -> Error? {
    applyHostCommands([command])
  }

  // MARK: - Seats (host lobby)

  /// Renames a seat (any time; the host is the authority). Names follow `SeatNameRules`.
  public func renameSeat(playerId: UUID, to rawName: String) throws {
    guard endReason == nil else { throw HostSessionError.sessionEnded }
    guard let index = game.players.firstIndex(where: { $0.id == playerId }) else {
      throw HostSessionError.seatNotFound
    }
    guard let name = SeatNameRules.normalized(rawName) else { throw HostSessionError.nameInvalid }
    guard !SeatNameRules.isTaken(name, in: game.players, excluding: [playerId]) else {
      throw HostSessionError.nameTaken
    }
    var updated = game
    updated.players[index].name = name
    guard updated != game else { return }
    for (token, registered) in guestRegistry where registered.playerId == playerId {
      guestRegistry[token]?.playerName = name
    }
    commit(updated)
  }

  /// Reorders seats before the start (`game.players` order drives dealer rotation and betting order).
  /// `orderedPlayerIDs` must contain every seat exactly once. The dealer is picked at start, so it stays valid.
  public func reorderSeats(_ orderedPlayerIDs: [UUID]) throws {
    guard endReason == nil else { throw HostSessionError.sessionEnded }
    guard isInSetup else { throw HostSessionError.gameAlreadyStarted }
    let byID = Dictionary(game.players.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    guard orderedPlayerIDs.count == game.players.count,
          Set(orderedPlayerIDs) == Set(byID.keys) else {
      throw HostSessionError.invalidSeatOrder
    }
    var updated = game
    updated.players = orderedPlayerIDs.compactMap { byID[$0] }
    guard updated != game else { return }
    commit(updated)
  }

  /// Unassigns (kicks) a seat: revokes its token(s), tells a connected guest `sessionEnded(kicked)` and closes the
  /// connection. The seat keeps its name and becomes claimable. Returns false if no device was bound to it.
  @discardableResult
  public func unassignSeat(playerId: UUID) -> Bool {
    let tokens = guestRegistry.filter { $0.value.playerId == playerId }.map(\.key)
    guard !tokens.isEmpty else { return false }
    for token in tokens {
      guestRegistry.removeValue(forKey: token)
    }
    let kicked = connectionIDs { phase in
      if case .authenticated(let token) = phase { return tokens.contains(token) }
      return false
    }
    send(.sessionEnded(SessionEndedMessage(code: .kicked, detail: "Seat unassigned by host.")), to: kicked)
    for id in kicked {
      connections.removeValue(forKey: id)
      transport.close(connectionID: id)
    }
    onRegistryChanged?(guestRegistry)
    refreshGuests()
    broadcastLobbyUpdate()
    return true
  }

  /// True when a guest device holds a token for this seat (connected or not).
  public func isSeatBoundToDevice(_ playerId: UUID) -> Bool {
    boundGuestPlayerIDs.contains(playerId)
  }

  public var lobbySlots: [LobbyPlayerSlot] {
    let bound = boundGuestPlayerIDs
    let connected = connectedGuestPlayerIDs
    return game.players.enumerated().map { index, player in
      LobbyPlayerSlot(
        playerId: player.id,
        name: player.name,
        isHost: player.id == hostReservedPlayerId,
        isBoundToDevice: bound.contains(player.id),
        isConnected: connected.contains(player.id),
        isPlaceholderName: PlayerNaming.isPlaceholderName(player.name, playerNumber: index + 1)
      )
    }
  }

  /// The final round of the game is finalized.
  public nonisolated static func isGameFinished(_ game: Game) -> Bool {
    guard let lastRound = game.rounds.last, lastRound.isFinalized else { return false }
    return game.rounds.count >= game.totalRoundsPlanned
  }

  // MARK: - Heartbeat

  private func startHeartbeat() {
    heartbeatTask?.cancel()
    let interval = timing.pingInterval
    heartbeatTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: SessionTiming.nanoseconds(interval))
        guard !Task.isCancelled, let self else { return }
        self.runHeartbeat()
      }
    }
  }

  /// One heartbeat tick: closes connections that were silent for longer than `timing.silenceTimeout`
  /// (half-open sockets) and pings the others.
  func runHeartbeat() {
    guard isActive else { return }
    let now = clock()
    var droppedGuest = false
    for (id, record) in connections where now.timeIntervalSince(record.lastHeard) > timing.silenceTimeout {
      hostLog.notice("Closing silent connection \(id.uuidString, privacy: .public)")
      connections.removeValue(forKey: id)
      transport.close(connectionID: id)
      if case .authenticated = record.phase {
        droppedGuest = true
      }
    }
    if droppedGuest {
      guestConnectionDidChange()
    }
    sendPings()
  }

  private func sendPings() {
    let recipients = connectionIDs { $0 != .awaitingHello }
    guard !recipients.isEmpty else { return }
    let nonce = nextPingNonce
    nextPingNonce &+= 1
    send(.ping(PingMessage(nonce: nonce)), to: recipients)
  }

  private func scheduleListenerRestart() {
    guard isActive, listenerRestartTask == nil,
          listenerRestartAttempts < timing.maxListenerRestartAttempts else { return }
    listenerRestartAttempts += 1
    let delay = timing.listenerRestartDelay * Double(listenerRestartAttempts)
    listenerRestartTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: SessionTiming.nanoseconds(delay))
      guard !Task.isCancelled, let self else { return }
      self.listenerRestartTask = nil
      guard self.isActive else { return }
      hostLog.info("Restarting listener (attempt \(self.listenerRestartAttempts))")
      self.transport.restartListener()
    }
  }

  // MARK: - Transport events

  private func handleTransportEvent(_ event: HostTransportEvent) {
    switch event {
    case .listenerStateChanged(let state):
      handleListenerState(state)
    case .connected(let connectionID):
      guard isActive else {
        transport.close(connectionID: connectionID)
        return
      }
      connections[connectionID] = ConnectionRecord(phase: .awaitingHello, lastHeard: clock())
    case .disconnected(let connectionID, let reason):
      guard let record = connections.removeValue(forKey: connectionID) else { return }
      hostLog.info("Connection \(connectionID.uuidString, privacy: .public) lost: \(String(describing: reason), privacy: .public)")
      if case .authenticated = record.phase {
        // The seat stays bound (token kept) so the guest can rejoin.
        guestConnectionDidChange()
      }
    case .received(let connectionID, let envelope):
      guard isActive, connections[connectionID] != nil else { return }
      connections[connectionID]?.lastHeard = clock()
      handleEnvelope(envelope, connectionID: connectionID)
    }
  }

  private func handleListenerState(_ state: HostListenerState) {
    guard endReason == nil else { return }
    listenerState = state
    switch state {
    case .ready:
      listenerRestartAttempts = 0
    case .failed:
      scheduleListenerRestart()
    case .starting, .waiting, .stopped:
      break
    }
    onListenerStateChanged?(state)
  }

  private func handleEnvelope(_ envelope: WireEnvelope, connectionID: UUID) {
    guard envelope.version == WireProtocolVersion.current else {
      rejectIncompatibleVersion(envelope.version, connectionID: connectionID)
      return
    }
    switch envelope.payload {
    case .hello(let hello):
      handleHello(hello, connectionID: connectionID)
    case .claimPlayer(let claim):
      handleClaimPlayer(claim, connectionID: connectionID)
    case .guestCommand(let guestCommand):
      handleGuestCommand(guestCommand, connectionID: connectionID)
    case .leaveSession(let leave):
      handleLeave(leave, connectionID: connectionID)
    case .ping(let ping):
      send(.pong(PongMessage(nonce: ping.nonce)), to: [connectionID])
    case .pong:
      break
    case .joinLobby, .claimAccepted, .joinAccepted, .joinRejected, .gameSnapshot, .commandResult, .sessionEnded:
      break
    }
  }

  /// A v1 (or unknown) peer: answer in a format it can decode, then close.
  private func rejectIncompatibleVersion(_ version: Int, connectionID: UUID) {
    hostLog.notice("Rejecting wire protocol v\(version) on \(connectionID.uuidString, privacy: .public)")
    let replyVersion = version == WireProtocolVersion.legacyV1 ? WireProtocolVersion.legacyV1 : WireProtocolVersion.current
    let rejection = JoinRejectedMessage(code: .versionMismatch, detail: LegacyWireV1.updateRequiredReason)
    sendEnvelope(WireEnvelope(version: replyVersion, payload: .joinRejected(rejection)), to: [connectionID])
    dropConnection(connectionID)
  }

  private func handleHello(_ hello: HelloMessage, connectionID: UUID) {
    guard connections[connectionID]?.phase == .awaitingHello else { return }
    guard Self.codesMatch(hello.sessionCode, sessionCode) else {
      sendJoinRejected(.sessionNotFound, detail: "Invalid session code.", to: connectionID)
      dropConnection(connectionID)
      return
    }

    if let token = hello.guestToken {
      if let registered = guestRegistry[token] {
        resumeGuest(token: token, registered: registered, connectionID: connectionID)
        return
      }
      // Seat was released (or the registry was lost): say so, then continue like a new guest.
      sendJoinRejected(.tokenInvalid, detail: "Unknown guest token.", to: connectionID)
    }

    connections[connectionID]?.phase = .pending
    sendLobby(to: connectionID)
  }

  private func resumeGuest(token: String, registered: RegisteredGuest, connectionID: UUID) {
    // Newest connection wins: an older socket for the same token is stale/half-open.
    let stale = connectionIDs { $0 == .authenticated(token: token) }.filter { $0 != connectionID }
    for id in stale {
      connections.removeValue(forKey: id)
      transport.close(connectionID: id)
    }
    connections[connectionID]?.phase = .authenticated(token: token)
    if game.hasStarted {
      sendJoinAccepted(to: connectionID, token: token, playerId: registered.playerId)
    } else {
      let accepted = ClaimAcceptedMessage(
        guestToken: token,
        playerId: registered.playerId,
        playerName: currentName(of: registered.playerId) ?? registered.playerName
      )
      send(.claimAccepted(accepted), to: [connectionID])
    }
    guestConnectionDidChange()
  }

  private func handleClaimPlayer(_ claim: ClaimPlayerMessage, connectionID: UUID) {
    guard let record = connections[connectionID] else { return }
    let currentToken: String?
    switch record.phase {
    case .awaitingHello:
      sendJoinRejected(.notAuthorized, detail: "Send hello before claiming a player.", to: connectionID)
      return
    case .pending:
      currentToken = nil
    case .authenticated(let token):
      guard isInSetup else {
        sendJoinRejected(.notAuthorized, detail: "Seats cannot be switched after the start.", to: connectionID)
        return
      }
      currentToken = token
    }
    let previousSeat = currentToken.flatMap { guestRegistry[$0]?.playerId }

    let seatId: UUID
    if let requested = claim.playerId {
      guard game.players.contains(where: { $0.id == requested }) else {
        sendJoinRejected(.seatNotFound, detail: "Unknown player.", to: connectionID)
        return
      }
      guard isSeatClaimable(requested, byToken: currentToken) else {
        sendJoinRejected(.seatTaken, detail: "That player is already taken.", to: connectionID)
        return
      }
      seatId = requested
    } else if let open = firstClaimableSeat(byToken: currentToken) {
      seatId = open
    } else {
      sendJoinRejected(.seatTaken, detail: "No open player slots.", to: connectionID)
      return
    }

    guard let name = SeatNameRules.normalized(claim.displayName) else {
      sendJoinRejected(.nameInvalid, detail: "Name must have 1…\(SeatNameRules.maxLength) characters.", to: connectionID)
      return
    }
    var excludedSeats: Set<UUID> = [seatId]
    if let previousSeat {
      excludedSeats.insert(previousSeat)
    }
    guard !SeatNameRules.isTaken(name, in: game.players, excluding: excludedSeats) else {
      sendJoinRejected(.nameTaken, detail: "Name already used.", to: connectionID)
      return
    }

    let token = currentToken ?? Self.makeGuestToken()
    guestRegistry[token] = RegisteredGuest(playerId: seatId, playerName: name)
    connections[connectionID]?.phase = .authenticated(token: token)
    onRegistryChanged?(guestRegistry)

    var updated = game
    if let previousSeat, previousSeat != seatId,
       let previousIndex = updated.players.firstIndex(where: { $0.id == previousSeat }) {
      // Switching seats before the start: the old seat goes back to its default name.
      updated.players[previousIndex].name = PlayerNaming.placeholderName(
        playerNumber: previousIndex + 1,
        languageCode: placeholderLanguageCode
      )
    }
    if let index = updated.players.firstIndex(where: { $0.id == seatId }) {
      updated.players[index].name = name
    }
    let nameChanged = updated != game
    if nameChanged {
      game = updated
      revision += 1
      onGameSnapshot?(game, revision)
    }

    // The claimer hears about its own seat before any lobby/snapshot broadcast.
    if game.hasStarted {
      sendJoinAccepted(to: connectionID, token: token, playerId: seatId)
      if nameChanged {
        broadcastSnapshot()
      }
    } else {
      send(.claimAccepted(ClaimAcceptedMessage(guestToken: token, playerId: seatId, playerName: name)), to: [connectionID])
    }
    guestConnectionDidChange()
  }

  private func handleLeave(_ message: LeaveSessionMessage, connectionID: UUID) {
    guard case .authenticated(let token)? = connections[connectionID]?.phase, token == message.guestToken else {
      return
    }
    guestRegistry.removeValue(forKey: token)
    connections.removeValue(forKey: connectionID)
    transport.close(connectionID: connectionID)
    onRegistryChanged?(guestRegistry)
    guestConnectionDidChange()
  }

  private func handleGuestCommand(_ message: GuestCommandMessage, connectionID: UUID) {
    guard case .authenticated(let token)? = connections[connectionID]?.phase,
          token == message.guestToken,
          let registered = guestRegistry[token]
    else {
      let result = CommandResultMessage(
        commandID: message.commandID,
        accepted: false,
        code: .notAuthorized,
        detail: "Guest not joined.",
        revision: revision
      )
      send(.commandResult(result), to: [connectionID])
      return
    }
    let guest = ConnectedGuest(
      connectionID: connectionID,
      playerId: registered.playerId,
      playerName: currentName(of: registered.playerId) ?? registered.playerName,
      guestToken: token
    )

    if let code = CommandAuthorizer.guestCommandRejection(message.command, guestPlayerId: registered.playerId, game: game) {
      rejectGuestCommand(message, guest: guest, code: code, detail: "Command not permitted.")
      return
    }

    var updated = game
    do {
      try updated.apply(message.command)
    } catch {
      rejectGuestCommand(message, guest: guest, code: CommandAuthorizer.reasonCode(for: error), detail: String(describing: error))
      return
    }
    if case .submitBet(_, let roundIndex, _) = message.command,
       let violation = CommandAuthorizer.betSumViolation(in: updated, roundIndex: roundIndex) {
      // Rolled back: `updated` is discarded, `game` was never touched.
      rejectGuestCommand(message, guest: guest, code: violation, detail: "Bets may not add up to the hand size.")
      return
    }

    game = updated
    revision += 1
    didCommitGameChange(wasStarted: true)
    let result = CommandResultMessage(commandID: message.commandID, accepted: true, revision: revision)
    send(.commandResult(result), to: [connectionID])
  }

  private func rejectGuestCommand(
    _ message: GuestCommandMessage,
    guest: ConnectedGuest,
    code: MultiplayerReasonCode,
    detail: String
  ) {
    hostLog.info("Rejected guest command from \(guest.playerName, privacy: .public): \(code.rawCode, privacy: .public)")
    let result = CommandResultMessage(
      commandID: message.commandID,
      accepted: false,
      code: code,
      detail: detail,
      revision: revision
    )
    send(.commandResult(result), to: [guest.connectionID])
    onGuestCommandRejected?(guest, code)
  }

  // MARK: - Commit & broadcast

  private func commit(_ updated: Game) {
    let wasStarted = game.hasStarted
    game = updated
    revision += 1
    didCommitGameChange(wasStarted: wasStarted)
  }

  /// After every accepted change: persist (synchronously, via `onGameSnapshot`), then tell the guests once.
  private func didCommitGameChange(wasStarted: Bool) {
    onGameSnapshot?(game, revision)
    refreshGuests()
    guard game.hasStarted else {
      broadcastLobbyUpdate()
      return
    }
    if !wasStarted {
      for (connectionID, record) in connections {
        guard case .authenticated(let token) = record.phase, let registered = guestRegistry[token] else { continue }
        sendJoinAccepted(to: connectionID, token: token, playerId: registered.playerId)
      }
      // Guests still picking a seat learn that the game started.
      broadcastLobbyUpdate()
    }
    broadcastSnapshot()
    if Self.isGameFinished(game) {
      stop(reason: .gameFinished)
    }
  }

  private func guestConnectionDidChange() {
    refreshGuests()
    broadcastLobbyUpdate()
  }

  private func refreshGuests() {
    var guests: [UUID: ConnectedGuest] = [:]
    for (connectionID, record) in connections {
      guard case .authenticated(let token) = record.phase, let registered = guestRegistry[token] else { continue }
      guests[connectionID] = ConnectedGuest(
        connectionID: connectionID,
        playerId: registered.playerId,
        playerName: currentName(of: registered.playerId) ?? registered.playerName,
        guestToken: token
      )
    }
    guard guests != guestsByConnection else { return }
    guestsByConnection = guests
    onGuestsChanged?(guests.values.sorted(by: { $0.playerName < $1.playerName }))
  }

  private var authenticatedConnectionIDs: [UUID] {
    connectionIDs { phase in
      if case .authenticated = phase { return true }
      return false
    }
  }

  private func connectionIDs(where predicate: (ConnectionPhase) -> Bool) -> [UUID] {
    connections.compactMap { entry in
      predicate(entry.value.phase) ? entry.key : nil
    }
  }

  private func broadcastSnapshot() {
    send(.gameSnapshot(GameSnapshotMessage(revision: revision, game: game)), to: authenticatedConnectionIDs)
  }

  /// Lobby goes to guests still picking a seat, and before the start also to every joined guest.
  private func broadcastLobbyUpdate() {
    let slots = lobbySlots
    let inSetup = isInSetup
    let recipients = connectionIDs { phase in
      switch phase {
      case .awaitingHello:
        return false
      case .pending:
        return true
      case .authenticated:
        return inSetup
      }
    }
    send(.joinLobby(lobbyMessage(slots: slots)), to: recipients)
    onLobbyUpdated?(slots)
  }

  private func sendLobby(to connectionID: UUID) {
    send(.joinLobby(lobbyMessage(slots: lobbySlots)), to: [connectionID])
  }

  private func lobbyMessage(slots: [LobbyPlayerSlot]) -> JoinLobbyMessage {
    JoinLobbyMessage(gameID: game.id, gameName: game.name, hasStarted: game.hasStarted, slots: slots)
  }

  private func sendJoinAccepted(to connectionID: UUID, token: String, playerId: UUID) {
    let accepted = JoinAcceptedMessage(guestToken: token, playerId: playerId, revision: revision, game: game)
    send(.joinAccepted(accepted), to: [connectionID])
  }

  private func sendJoinRejected(_ code: MultiplayerReasonCode, detail: String, to connectionID: UUID) {
    send(.joinRejected(JoinRejectedMessage(code: code, detail: detail)), to: [connectionID])
  }

  private func dropConnection(_ connectionID: UUID) {
    let record = connections.removeValue(forKey: connectionID)
    transport.close(connectionID: connectionID)
    if let phase = record?.phase, case .authenticated = phase {
      guestConnectionDidChange()
    }
  }

  private func send(_ payload: WirePayload, to connectionIDs: [UUID]) {
    sendEnvelope(WireEnvelope(payload: payload), to: connectionIDs)
  }

  private func sendEnvelope(_ envelope: WireEnvelope, to connectionIDs: [UUID]) {
    guard !connectionIDs.isEmpty else { return }
    do {
      try transport.send(envelope, to: connectionIDs)
    } catch {
      hostLog.error("Send failed: \(String(describing: error), privacy: .public)")
      onError?(error)
    }
  }

  // MARK: - Helpers

  private func isSeatClaimable(_ playerId: UUID, byToken token: String?) -> Bool {
    if playerId == hostReservedPlayerId { return false }
    return !guestRegistry.contains { entry in entry.value.playerId == playerId && entry.key != token }
  }

  /// First seat a guest may take: placeholder-named seats first, then any other open seat.
  private func firstClaimableSeat(byToken token: String?) -> UUID? {
    let open = game.players.enumerated().filter { isSeatClaimable($0.element.id, byToken: token) }
    if let placeholder = open.first(where: { PlayerNaming.isPlaceholderName($0.element.name, playerNumber: $0.offset + 1) }) {
      return placeholder.element.id
    }
    return open.first?.element.id
  }

  private func currentName(of playerId: UUID) -> String? {
    game.players.first(where: { $0.id == playerId })?.name
  }

  private nonisolated static func makeGuestToken() -> String {
    UUID().uuidString
  }

  nonisolated static func codesMatch(_ lhs: String, _ rhs: String) -> Bool {
    lhs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      == rhs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }
}
