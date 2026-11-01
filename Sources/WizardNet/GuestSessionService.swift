import Foundation
import os
#if canImport(WizardDomain)
import WizardDomain
#endif

private let guestLog = Logger(subsystem: "WizardBlockOfTruth", category: "GuestSession")

public enum GuestSessionError: Error, Equatable, Sendable {
  /// Not connected to the host right now (e.g. while reconnecting).
  case notConnected
  /// No seat yet.
  case notJoined
  case joinRejected(MultiplayerReasonCode)
  /// Local Network access is denied (Settings › Privacy & Security › Local Network).
  case localNetworkDenied
  /// No TCP connection within the connect timeout (host gone, other network, …).
  case hostUnreachable
  /// Connected, but the host never answered `hello` (likely an older app version) or sent something unreadable.
  case hostIncompatibleOrUnreachable
  /// The connection dropped before a seat was taken.
  case connectionLost
  /// A command got no `commandResult` within `SessionTiming.commandTimeout`.
  case commandTimedOut
}

/// Why a guest session is over.
public enum GuestSessionEndReason: Equatable, Sendable {
  case hostEnded
  /// The final snapshot (received right before this) is the final scoreboard.
  case gameFinished
  /// The host unassigned this guest's seat.
  case kicked
  /// The rejoin token is no longer valid on the host (seat released).
  case seatReleased
  /// The guest left (`leave()`) or closed the session locally (`disconnect()`).
  case left
  /// The host refused the join for good (e.g. `versionMismatch`, `sessionNotFound`).
  case rejected(MultiplayerReasonCode)
  /// The first connection attempt failed (no seat yet), see the error.
  case connectFailed(GuestSessionError)

  /// The saved rejoin data is useless after these (cleared by the app).
  public var invalidatesSavedSession: Bool {
    switch self {
    case .hostEnded, .gameFinished, .kicked, .seatReleased, .left:
      return true
    case .rejected, .connectFailed:
      return false
    }
  }
}

public enum GuestConnectionState: Equatable, Sendable {
  case idle
  /// First connection: waiting for TCP and the host's answer to `hello`.
  case connecting
  case connected
  /// Connection lost while holding a seat; reconnecting automatically with the saved token.
  case reconnecting(attempt: Int)
  case ended(GuestSessionEndReason)

  public var isEnded: Bool {
    if case .ended = self { return true }
    return false
  }
}

public enum GuestCommandOutcome: Equatable, Sendable {
  case accepted
  case rejected(MultiplayerReasonCode)
  case timedOut
}

public struct PendingGuestCommand: Equatable, Sendable {
  public let id: UUID
  public let command: GameCommand
  public let sentAt: Date

  public init(id: UUID, command: GameCommand, sentAt: Date) {
    self.id = id
    self.command = command
    self.sentAt = sentAt
  }
}

/// A guest's connection to a host session: joining, seat claiming, snapshots, commands, heartbeat watchdog and
/// automatic reconnects (connection lost ≠ session ended). All callbacks run synchronously on the main actor.
@MainActor
public final class GuestSessionService {
  public let sessionCode: String

  public private(set) var playerId: UUID?
  public private(set) var playerName: String?
  public private(set) var game: Game?
  public private(set) var revision: Int = -1
  public private(set) var guestToken: String?
  public private(set) var setupPlayers: [Player] = []
  /// Latest lobby (seats with name/host/bound/connected flags).
  public private(set) var lobbySlots: [LobbyPlayerSlot] = []
  public private(set) var lobbyGameID: UUID?
  public private(set) var lobbyGameName: String?
  public private(set) var connectionState: GuestConnectionState = .idle
  /// Why the transport is stuck right now (e.g. `.localNetworkDenied` while connecting/reconnecting).
  public private(set) var lastTransportFailure: TransportFailure?
  /// Commands sent but not answered yet.
  public private(set) var pendingCommands: [UUID: PendingGuestCommand] = [:]

  /// Lobby received while no seat is claimed yet (show the seat picker).
  public var onJoinLobby: (([LobbyPlayerSlot]) -> Void)?
  /// Every lobby update (also after claiming, until the game starts).
  public var onLobbyUpdated: (([LobbyPlayerSlot]) -> Void)?
  /// `claimAccepted`: `guestToken`, `playerId` and `playerName` are set (persist the token now).
  public var onSlotClaimed: (() -> Void)?
  public var onJoinAccepted: (() -> Void)?
  public var onGameSnapshot: ((Game, Int) -> Void)?
  public var onCommandResult: ((CommandResultMessage) -> Void)?
  public var onCommandOutcome: ((UUID, GuestCommandOutcome) -> Void)?
  public var onConnectionStateChanged: ((GuestConnectionState) -> Void)?
  /// `lastTransportFailure` changed (e.g. Local Network denied while connecting or reconnecting).
  public var onTransportFailureChanged: ((TransportFailure?) -> Void)?
  public var onSessionEnded: ((GuestSessionEndReason) -> Void)?
  public var onError: ((Error) -> Void)?

  private let transport: any GuestSessionTransport
  private let timing: SessionTiming
  private let clock: () -> Date
  /// The current transport connection (attempt) is ours and its events matter.
  private var tracksConnection = false
  private var transportConnected = false
  /// Waiting for the host's first answer on the current connection.
  private var awaitingHandshake = false
  private var hasSentHello = false
  private var lastHeard = Date.distantPast
  private var reconnectAttempt = 0
  private var helloTimerTask: Task<Void, Never>?
  private var watchdogTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var commandTimeoutTasks: [UUID: Task<Void, Never>] = [:]

  /// Holds a seat (token + player).
  public var hasSeat: Bool { guestToken != nil && playerId != nil }

  public init(
    sessionCode: String,
    guestToken: String? = nil,
    transport: any GuestSessionTransport,
    timing: SessionTiming = .standard,
    clock: @escaping () -> Date = { Date() }
  ) {
    self.sessionCode = sessionCode
    self.guestToken = guestToken
    self.transport = transport
    self.timing = timing
    self.clock = clock
    let inbox = MainActorEventInbox<GuestTransportEvent> { [weak self] event in
      self?.handleTransportEvent(event)
    }
    transport.onEvent = { event in
      inbox.post(event)
    }
  }

  public func connect() throws {
    guard case .idle = connectionState else { return }
    setState(.connecting)
    try openConnection()
  }

  /// Claims a seat (`playerId`, or `nil` for the first open seat) with a display name.
  public func claimPlayer(playerId: UUID?, displayName: String) throws {
    guard transportConnected else { throw GuestSessionError.notConnected }
    let claim = ClaimPlayerMessage(playerId: playerId, displayName: displayName)
    try transport.send(WireEnvelope(payload: .claimPlayer(claim)))
  }

  /// Sends a bet/got for the own seat. The outcome arrives via `onCommandOutcome` (accepted / rejected / timed out).
  @discardableResult
  public func submitGuestCommand(_ command: GameCommand) throws -> UUID {
    guard let guestToken, playerId != nil else {
      throw GuestSessionError.notJoined
    }
    guard connectionState == .connected, transportConnected else {
      throw GuestSessionError.notConnected
    }
    let commandID = UUID()
    let message = GuestCommandMessage(guestToken: guestToken, command: command, commandID: commandID)
    try transport.send(WireEnvelope(payload: .guestCommand(message)))
    pendingCommands[commandID] = PendingGuestCommand(id: commandID, command: command, sentAt: clock())
    let timeout = timing.commandTimeout
    commandTimeoutTasks[commandID] = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: SessionTiming.nanoseconds(timeout))
      guard !Task.isCancelled, let self else { return }
      self.commandTimedOut(commandID)
    }
    return commandID
  }

  /// Leaves for good: tells the host to release the seat, then closes.
  public func leave() {
    guard !connectionState.isEnded else { return }
    if transportConnected, let guestToken {
      try? transport.send(WireEnvelope(payload: .leaveSession(LeaveSessionMessage(guestToken: guestToken))))
    }
    end(.left)
  }

  /// Closes the connection without telling the host (the host keeps the seat for a rejoin with the token).
  public func disconnect() {
    end(.left)
  }

  /// Retries right away while reconnecting (e.g. app back in the foreground, or a "Retry" button).
  public func reconnectNow() {
    guard case .reconnecting = connectionState, !tracksConnection else { return }
    reconnectTask?.cancel()
    reconnectTask = nil
    performReconnectAttempt()
  }

  /// Call when the app returns to the foreground.
  public func handleAppDidBecomeActive() {
    switch connectionState {
    case .reconnecting:
      reconnectNow()
    case .connected:
      if clock().timeIntervalSince(lastHeard) > timing.silenceTimeout {
        connectionLost()
      } else {
        try? transport.send(WireEnvelope(payload: .ping(PingMessage(nonce: UInt64.random(in: 1...UInt64.max)))))
      }
    case .idle, .connecting, .ended:
      break
    }
  }

  /// Liveness check (also driven by the internal watchdog timer): no message for `silenceTimeout` = connection lost.
  func checkLiveness() {
    guard connectionState == .connected, tracksConnection, !awaitingHandshake else { return }
    guard clock().timeIntervalSince(lastHeard) > timing.silenceTimeout else { return }
    guestLog.notice("No message from host for \(self.timing.silenceTimeout)s; reconnecting")
    connectionLost()
  }

  // MARK: - Connection lifecycle

  private func openConnection() throws {
    tracksConnection = true
    transportConnected = false
    awaitingHandshake = true
    hasSentHello = false
    do {
      try transport.connect()
    } catch {
      tracksConnection = false
      throw error
    }
  }

  private func performReconnectAttempt() {
    guard case .reconnecting = connectionState, !tracksConnection else { return }
    do {
      try openConnection()
    } catch {
      attemptFailed(.hostUnreachable)
    }
  }

  private func scheduleReconnect() {
    reconnectAttempt += 1
    setState(.reconnecting(attempt: reconnectAttempt))
    reconnectTask?.cancel()
    let delay = timing.reconnectDelay(attempt: reconnectAttempt)
    reconnectTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: SessionTiming.nanoseconds(delay))
      guard !Task.isCancelled, let self else { return }
      self.reconnectTask = nil
      self.performReconnectAttempt()
    }
  }

  /// The current attempt/connection is unusable. First connect → session ends with the error; with a seat →
  /// reconnect; while picking a seat → ends with `.connectionLost`.
  private func attemptFailed(_ error: GuestSessionError) {
    tracksConnection = false
    transportConnected = false
    awaitingHandshake = false
    helloTimerTask?.cancel()
    helloTimerTask = nil
    watchdogTask?.cancel()
    watchdogTask = nil
    switch connectionState {
    case .connecting:
      onError?(error)
      end(.connectFailed(error))
    case .connected, .reconnecting:
      if hasSeat {
        scheduleReconnect()
      } else {
        onError?(GuestSessionError.connectionLost)
        end(.connectFailed(.connectionLost))
      }
    case .idle, .ended:
      break
    }
  }

  private func connectionLost() {
    tracksConnection = false
    transport.disconnect()
    attemptFailed(.connectionLost)
  }

  private func markHandshakeComplete() {
    guard awaitingHandshake else { return }
    awaitingHandshake = false
    helloTimerTask?.cancel()
    helloTimerTask = nil
    reconnectAttempt = 0
    setTransportFailure(nil)
    setState(.connected)
    startWatchdog()
  }

  private func end(_ reason: GuestSessionEndReason) {
    guard !connectionState.isEnded else { return }
    tracksConnection = false
    transportConnected = false
    awaitingHandshake = false
    helloTimerTask?.cancel()
    helloTimerTask = nil
    watchdogTask?.cancel()
    watchdogTask = nil
    reconnectTask?.cancel()
    reconnectTask = nil
    for task in commandTimeoutTasks.values {
      task.cancel()
    }
    commandTimeoutTasks.removeAll()
    pendingCommands.removeAll()
    setState(.ended(reason))
    transport.disconnect()
    guestLog.info("Guest session ended: \(String(describing: reason), privacy: .public)")
    onSessionEnded?(reason)
  }

  private func setState(_ state: GuestConnectionState) {
    guard state != connectionState else { return }
    connectionState = state
    onConnectionStateChanged?(state)
  }

  private func setTransportFailure(_ failure: TransportFailure?) {
    guard failure != lastTransportFailure else { return }
    lastTransportFailure = failure
    onTransportFailureChanged?(failure)
  }

  // MARK: - Timers

  private func startHelloTimer() {
    helloTimerTask?.cancel()
    let timeout = timing.helloReplyTimeout
    helloTimerTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: SessionTiming.nanoseconds(timeout))
      guard !Task.isCancelled, let self else { return }
      self.helloReplyTimedOut()
    }
  }

  private func helloReplyTimedOut() {
    helloTimerTask = nil
    guard awaitingHandshake, tracksConnection else { return }
    guestLog.error("Host did not answer hello (older app version or not a v2 host?)")
    tracksConnection = false
    transport.disconnect()
    attemptFailed(.hostIncompatibleOrUnreachable)
  }

  private func startWatchdog() {
    watchdogTask?.cancel()
    let interval = timing.pingInterval
    watchdogTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: SessionTiming.nanoseconds(interval))
        guard !Task.isCancelled, let self else { return }
        self.checkLiveness()
      }
    }
  }

  private func commandTimedOut(_ commandID: UUID) {
    commandTimeoutTasks.removeValue(forKey: commandID)
    guard pendingCommands.removeValue(forKey: commandID) != nil else { return }
    guestLog.error("Guest command timed out")
    onCommandOutcome?(commandID, .timedOut)
  }

  // MARK: - Transport events

  private func handleTransportEvent(_ event: GuestTransportEvent) {
    guard !connectionState.isEnded else { return }
    switch event {
    case .waiting(let failure):
      guard tracksConnection else { return }
      setTransportFailure(failure)
      if failure == .localNetworkDenied, connectionState == .connecting {
        onError?(GuestSessionError.localNetworkDenied)
      }
    case .connected:
      guard tracksConnection, !transportConnected else { return }
      transportConnected = true
      setTransportFailure(nil)
      lastHeard = clock()
      sendHello()
      startHelloTimer()
    case .disconnected(let reason):
      handleDisconnect(reason)
    case .received(let envelope):
      guard tracksConnection, transportConnected else { return }
      lastHeard = clock()
      handleEnvelope(envelope)
    }
  }

  private func handleDisconnect(_ reason: TransportDisconnectReason) {
    // `.closedLocally` is always our own doing; whoever closed already moved on.
    guard reason != .closedLocally, tracksConnection else { return }
    let error: GuestSessionError
    if awaitingHandshake {
      switch reason {
      case .localNetworkDenied:
        error = .localNetworkDenied
      case .timedOut:
        error = lastTransportFailure == .localNetworkDenied ? .localNetworkDenied : .hostUnreachable
      case .protocolError:
        error = .hostIncompatibleOrUnreachable
      case .closedByPeer, .failed, .closedLocally:
        error = .hostUnreachable
      }
    } else {
      error = .connectionLost
    }
    guestLog.notice("Connection dropped: \(String(describing: reason), privacy: .public)")
    attemptFailed(error)
  }

  private func sendHello() {
    guard !hasSentHello else { return }
    hasSentHello = true
    guestLog.info("Sending hello for session code \(self.sessionCode, privacy: .public)")
    let hello = HelloMessage(sessionCode: sessionCode, guestToken: guestToken)
    do {
      try transport.send(WireEnvelope(payload: .hello(hello)))
    } catch {
      onError?(error)
    }
  }

  private func handleEnvelope(_ envelope: WireEnvelope) {
    guard envelope.version == WireProtocolVersion.current else {
      guestLog.error("Host speaks wire protocol v\(envelope.version)")
      if case .joinRejected = envelope.payload {
        onError?(GuestSessionError.joinRejected(.versionMismatch))
        end(.rejected(.versionMismatch))
      } else if awaitingHandshake {
        tracksConnection = false
        transport.disconnect()
        attemptFailed(.hostIncompatibleOrUnreachable)
      }
      return
    }

    switch envelope.payload {
    case .joinLobby(let lobby):
      handleLobby(lobby)
    case .claimAccepted(let accepted):
      guestToken = accepted.guestToken
      playerId = accepted.playerId
      playerName = accepted.playerName
      markHandshakeComplete()
      onSlotClaimed?()
    case .joinAccepted(let accepted):
      guestToken = accepted.guestToken
      playerId = accepted.playerId
      playerName = accepted.game.players.first(where: { $0.id == accepted.playerId })?.name ?? playerName
      revision = accepted.revision
      game = accepted.game
      markHandshakeComplete()
      onJoinAccepted?()
      onGameSnapshot?(accepted.game, accepted.revision)
    case .joinRejected(let rejected):
      handleJoinRejected(rejected)
    case .gameSnapshot(let snapshot):
      guard snapshot.revision >= revision else { return }
      revision = snapshot.revision
      game = snapshot.game
      if let playerId, let name = snapshot.game.players.first(where: { $0.id == playerId })?.name {
        playerName = name
      }
      onGameSnapshot?(snapshot.game, snapshot.revision)
    case .commandResult(let result):
      handleCommandResult(result)
    case .sessionEnded(let ended):
      handleSessionEnded(ended)
    case .ping(let ping):
      try? transport.send(WireEnvelope(payload: .pong(PongMessage(nonce: ping.nonce))))
    case .pong:
      break
    case .hello, .claimPlayer, .guestCommand, .leaveSession:
      break
    }
  }

  private func handleLobby(_ lobby: JoinLobbyMessage) {
    lobbySlots = lobby.slots
    lobbyGameID = lobby.gameID
    lobbyGameName = lobby.gameName
    setupPlayers = lobby.slots.map { Player(id: $0.playerId, name: $0.name) }
    if let playerId, let mine = lobby.slots.first(where: { $0.playerId == playerId }) {
      playerName = mine.name
    }
    markHandshakeComplete()
    if playerId == nil {
      onJoinLobby?(lobby.slots)
    }
    onLobbyUpdated?(lobby.slots)
  }

  private func handleJoinRejected(_ rejected: JoinRejectedMessage) {
    guestLog.error("Join rejected: \(rejected.code.rawCode, privacy: .public) \(rejected.detail ?? "", privacy: .public)")
    if rejected.code == .tokenInvalid {
      // Our seat is gone. A session that held a seat ends; a fresh "rejoin" attempt continues with the lobby
      // the host sends next.
      let heldSeat = playerId != nil
      guestToken = nil
      playerId = nil
      playerName = nil
      onError?(GuestSessionError.joinRejected(.tokenInvalid))
      if heldSeat {
        end(.seatReleased)
      }
      return
    }
    onError?(GuestSessionError.joinRejected(rejected.code))
    if rejected.code.isFatalForJoin {
      end(.rejected(rejected.code))
    }
  }

  private func handleCommandResult(_ result: CommandResultMessage) {
    if let commandID = result.commandID, pendingCommands.removeValue(forKey: commandID) != nil {
      commandTimeoutTasks.removeValue(forKey: commandID)?.cancel()
      let outcome: GuestCommandOutcome = result.accepted ? .accepted : .rejected(result.code ?? .internalError)
      onCommandOutcome?(commandID, outcome)
    }
    onCommandResult?(result)
  }

  private func handleSessionEnded(_ message: SessionEndedMessage) {
    let reason: GuestSessionEndReason
    switch message.code {
    case .kicked:
      reason = .kicked
    case .sessionEnded(.gameFinished):
      reason = .gameFinished
    default:
      reason = .hostEnded
    }
    end(reason)
  }
}
