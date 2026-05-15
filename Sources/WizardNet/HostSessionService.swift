import Foundation
#if canImport(WizardDomain)
import WizardDomain
#endif

public enum HostSessionError: Error, Equatable {
  case invalidGuest(String)
  case invalidToken
  case unauthorizedCommand
  case gameAlreadyStarted
  case gameNotInSetup
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

@MainActor
public final class HostSessionService {
  public private(set) var game: Game
  public private(set) var revision: Int
  public private(set) var guestsByConnection: [UUID: ConnectedGuest] = [:]
  public private(set) var hostReservedPlayerId: UUID?

  public var onGameSnapshot: ((Game, Int) -> Void)?
  public var onError: ((Error) -> Void)?
  public var onGuestsChanged: (([ConnectedGuest]) -> Void)?
  public var onLobbyUpdated: (([LobbyPlayerSlot]) -> Void)?

  private let sessionCode: String
  private let transport: HostSessionTransport
  private var pendingConnectionIDs: Set<UUID> = []

  public var isInSetup: Bool { !game.hasStarted }

  public init(
    initialGame: Game,
    sessionCode: String,
    transport: HostSessionTransport,
    initialRevision: Int = 0,
    hostReservedPlayerId: UUID? = nil
  ) {
    self.game = initialGame
    self.sessionCode = sessionCode
    self.transport = transport
    self.revision = initialRevision
    self.hostReservedPlayerId = hostReservedPlayerId
    self.transport.onEvent = { [weak self] event in
      guard let self else { return }
      Task { @MainActor [weak self] in
        self?.handleTransportEvent(event)
      }
    }
  }

  public func start() throws {
    try transport.start()
  }

  public func stop(reason: String = "Host ended session") {
    let ended = WireEnvelope(payload: .sessionEnded(SessionEndedMessage(reason: reason)))
    try? transport.broadcast(ended)
    transport.stop()
  }

  public func reserveHostSlot(playerId: UUID, displayName: String) {
    let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, game.players.contains(where: { $0.id == playerId }) else { return }
    hostReservedPlayerId = playerId
    if let idx = game.players.firstIndex(where: { $0.id == playerId }) {
      game.players[idx].name = trimmed
    }
    if isInSetup {
      broadcastLobbyUpdate()
    } else {
      revision += 1
      broadcastSnapshot()
    }
    onGuestsChanged?(guestsByConnection.values.sorted(by: { $0.playerName < $1.playerName }))
  }

  public func startGame(
    startingDealer: UUID,
    gameConstraints: [Constraint.GameConstraint],
    playWithSpecialCards: Bool
  ) throws {
    guard isInSetup else { throw HostSessionError.gameAlreadyStarted }
    guard game.players.contains(where: { $0.id == startingDealer }) else {
      throw DomainError.unknownPlayerId(startingDealer)
    }
    try game.setGameConstraints(gameConstraints)
    game.playWithSpecialCards = playWithSpecialCards
    try game.apply(.startNewGame(startingDealer: startingDealer))
    revision += 1

    for (connectionID, guest) in guestsByConnection {
      sendJoinAccepted(to: connectionID, guest: guest)
    }
    broadcastSnapshot()
  }

  @discardableResult
  public func applyHostCommand(_ command: GameCommand) -> Error? {
    do {
      try game.apply(command)
      revision += 1
      broadcastSnapshot()
      return nil
    } catch {
      onError?(error)
      return error
    }
  }

  public func replaceGame(_ game: Game, revision: Int) {
    self.game = game
    self.revision = revision
    if game.hasStarted {
      broadcastSnapshot()
    } else {
      broadcastLobbyUpdate()
    }
  }

  private func handleTransportEvent(_ event: HostTransportEvent) {
    switch event {
    case .connected:
      break
    case .disconnected(let connectionID):
      pendingConnectionIDs.remove(connectionID)
      guestsByConnection.removeValue(forKey: connectionID)
      onGuestsChanged?(guestsByConnection.values.sorted(by: { $0.playerName < $1.playerName }))
      if isInSetup {
        broadcastLobbyUpdate()
      }
    case .received(let connectionID, let envelope):
      handleEnvelope(envelope, connectionID: connectionID)
    }
  }

  private func handleEnvelope(_ envelope: WireEnvelope, connectionID: UUID) {
    guard envelope.version == WireProtocolVersion.current else { return }
    switch envelope.payload {
    case .hello(let hello):
      handleHello(hello, connectionID: connectionID)
    case .claimPlayer(let claim):
      handleClaimPlayer(claim, connectionID: connectionID)
    case .guestCommand(let guestCommand):
      handleGuestCommand(guestCommand, connectionID: connectionID)
    case .ping(let ping):
      send(.pong(PongMessage(nonce: ping.nonce)), to: connectionID)
    case .pong, .joinAccepted, .joinRejected, .joinLobby, .claimAccepted, .gameSnapshot, .commandResult, .sessionEnded:
      break
    }
  }

  private func handleHello(_ hello: HelloMessage, connectionID: UUID) {
    guard codesMatch(hello.sessionCode, sessionCode) else {
      send(.joinRejected(JoinRejectedMessage(reason: "Invalid session code.")), to: connectionID)
      return
    }

    if let token = hello.guestToken,
       let existing = guestsByConnection.values.first(where: { $0.guestToken == token }) {
      if existing.connectionID != connectionID {
        guestsByConnection.removeValue(forKey: existing.connectionID)
      }
      let reconnected = ConnectedGuest(
        connectionID: connectionID,
        playerId: existing.playerId,
        playerName: existing.playerName,
        guestToken: token
      )
      guestsByConnection[connectionID] = reconnected
      pendingConnectionIDs.remove(connectionID)
      onGuestsChanged?(guestsByConnection.values.sorted(by: { $0.playerName < $1.playerName }))

      if game.hasStarted {
        sendJoinAccepted(to: connectionID, guest: reconnected)
        sendSnapshot(to: connectionID)
      } else {
        send(.claimAccepted(ClaimAcceptedMessage(guestToken: token, playerId: existing.playerId)), to: connectionID)
        sendLobby(to: connectionID)
      }
      return
    }

    pendingConnectionIDs.insert(connectionID)
    sendLobby(to: connectionID)
  }

  private func handleClaimPlayer(_ claim: ClaimPlayerMessage, connectionID: UUID) {
    guard pendingConnectionIDs.contains(connectionID) || guestsByConnection[connectionID] != nil else {
      send(.joinRejected(JoinRejectedMessage(reason: "Send hello before claiming a player.")), to: connectionID)
      return
    }

    let displayName = claim.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !displayName.isEmpty else {
      send(.joinRejected(JoinRejectedMessage(reason: "Enter a display name.")), to: connectionID)
      return
    }

    let targetPlayerId: UUID
    if let requestedId = claim.playerId {
      guard game.players.contains(where: { $0.id == requestedId }) else {
        send(.joinRejected(JoinRejectedMessage(reason: "Unknown player.")), to: connectionID)
        return
      }
      guard !isPlayerClaimed(requestedId, excluding: connectionID) else {
        send(.joinRejected(JoinRejectedMessage(reason: "That player is already taken.")), to: connectionID)
        return
      }
      targetPlayerId = requestedId
    } else if let firstOpen = game.players.first(where: { !isPlayerClaimed($0.id, excluding: connectionID) }) {
      targetPlayerId = firstOpen.id
    } else {
      send(.joinRejected(JoinRejectedMessage(reason: "No open player slots.")), to: connectionID)
      return
    }

    if let idx = game.players.firstIndex(where: { $0.id == targetPlayerId }) {
      game.players[idx].name = displayName
    }

    let token = guestsByConnection[connectionID]?.guestToken ?? UUID().uuidString
    let connected = ConnectedGuest(
      connectionID: connectionID,
      playerId: targetPlayerId,
      playerName: displayName,
      guestToken: token
    )
    guestsByConnection[connectionID] = connected
    pendingConnectionIDs.remove(connectionID)
    onGuestsChanged?(guestsByConnection.values.sorted(by: { $0.playerName < $1.playerName }))

    if game.hasStarted {
      sendJoinAccepted(to: connectionID, guest: connected)
      broadcastSnapshot()
    } else {
      send(.claimAccepted(ClaimAcceptedMessage(guestToken: token, playerId: targetPlayerId)), to: connectionID)
      broadcastLobbyUpdate()
    }
  }

  private func sendJoinAccepted(to connectionID: UUID, guest: ConnectedGuest) {
    let accepted = JoinAcceptedMessage(
      guestToken: guest.guestToken,
      playerId: guest.playerId,
      revision: revision,
      game: game
    )
    send(.joinAccepted(accepted), to: connectionID)
  }

  private func sendSnapshot(to connectionID: UUID) {
    let snapshot = GameSnapshotMessage(revision: revision, game: game)
    send(.gameSnapshot(snapshot), to: connectionID)
  }

  private func sendLobby(to connectionID: UUID) {
    send(.joinLobby(JoinLobbyMessage(slots: lobbySlots())), to: connectionID)
  }

  private func lobbySlots() -> [LobbyPlayerSlot] {
    let claimedIds = Set(guestsByConnection.values.map(\.playerId))
    return game.players.map { player in
      let isHost = player.id == hostReservedPlayerId
      let isGuest = claimedIds.contains(player.id)
      return LobbyPlayerSlot(
        playerId: player.id,
        name: player.name,
        isClaimed: isHost || isGuest
      )
    }
  }

  private func broadcastLobbyUpdate() {
    let slots = lobbySlots()
    let message = JoinLobbyMessage(slots: slots)
    let envelope = WireEnvelope(payload: .joinLobby(message))
    do {
      try transport.broadcast(envelope)
    } catch {
      onError?(error)
    }
    onLobbyUpdated?(slots)
  }

  private func isPlayerClaimed(_ playerId: UUID, excluding connectionID: UUID) -> Bool {
    if playerId == hostReservedPlayerId { return true }
    return guestsByConnection.contains { $0.value.playerId == playerId && $0.key != connectionID }
  }

  private func codesMatch(_ lhs: String, _ rhs: String) -> Bool {
    lhs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      == rhs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }

  private func handleGuestCommand(_ guestCommand: GuestCommandMessage, connectionID: UUID) {
    guard game.hasStarted else {
      sendCommandResult(
        CommandResultMessage(accepted: false, reason: "Game has not started yet.", revision: revision),
        to: connectionID
      )
      return
    }
    guard let guest = guestsByConnection[connectionID] else {
      sendCommandResult(
        CommandResultMessage(accepted: false, reason: "Guest not joined.", revision: revision),
        to: connectionID
      )
      return
    }
    guard guest.guestToken == guestCommand.guestToken else {
      sendCommandResult(
        CommandResultMessage(accepted: false, reason: "Invalid guest token.", revision: revision),
        to: connectionID
      )
      return
    }
    let isAllowed = CommandAuthorizer.isAllowedGuestCommand(
      guestCommand.command,
      guestPlayerId: guest.playerId,
      currentRoundIndex: game.currentRoundIndex
    )
    guard isAllowed else {
      sendCommandResult(
        CommandResultMessage(accepted: false, reason: "Command not permitted.", revision: revision),
        to: connectionID
      )
      return
    }

    do {
      try game.apply(guestCommand.command)
      revision += 1
      sendCommandResult(
        CommandResultMessage(accepted: true, reason: nil, revision: revision),
        to: connectionID
      )
      broadcastSnapshot()
    } catch {
      sendCommandResult(
        CommandResultMessage(accepted: false, reason: error.localizedDescription, revision: revision),
        to: connectionID
      )
      onError?(error)
    }
  }

  private func broadcastSnapshot() {
    let snapshot = GameSnapshotMessage(revision: revision, game: game)
    do {
      try transport.broadcast(WireEnvelope(payload: .gameSnapshot(snapshot)))
    } catch {
      onError?(error)
    }
    onGameSnapshot?(game, revision)
  }

  private func send(_ payload: WirePayload, to connectionID: UUID) {
    do {
      try transport.send(WireEnvelope(payload: payload), to: connectionID)
    } catch {
      onError?(error)
    }
  }

  private func sendCommandResult(_ result: CommandResultMessage, to connectionID: UUID) {
    send(.commandResult(result), to: connectionID)
  }
}
