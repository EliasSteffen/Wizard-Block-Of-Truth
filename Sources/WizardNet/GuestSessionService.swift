import Foundation
import os
#if canImport(WizardDomain)
import WizardDomain
#endif

private let guestLog = Logger(subsystem: "WizardBlockOfTruth", category: "GuestSession")

public enum GuestSessionError: Error, Equatable {
  case notConnected
  case notJoined
  case joinRejected(String)
}

@MainActor
public final class GuestSessionService {
  public let sessionCode: String

  public private(set) var playerId: UUID?
  public private(set) var playerName: String?
  public private(set) var game: Game?
  public private(set) var revision: Int = -1
  public private(set) var guestToken: String?
  public private(set) var setupPlayers: [Player] = []

  public var onJoinLobby: (([LobbyPlayerSlot]) -> Void)?
  public var onSlotClaimed: (() -> Void)?
  public var onJoinAccepted: (() -> Void)?
  public var onGameSnapshot: ((Game, Int) -> Void)?
  public var onCommandResult: ((CommandResultMessage) -> Void)?
  public var onSessionEnded: ((String) -> Void)?
  public var onError: ((Error) -> Void)?

  private let transport: GuestSessionTransport
  private var hasSentHello = false

  public init(
    sessionCode: String,
    guestToken: String? = nil,
    transport: GuestSessionTransport
  ) {
    self.sessionCode = sessionCode
    self.guestToken = guestToken
    self.transport = transport
    self.transport.onEvent = { [weak self] event in
      guard let self else { return }
      Task { @MainActor [weak self] in
        self?.handleTransportEvent(event)
      }
    }
  }

  public func connect() throws {
    try transport.connect()
  }

  private func sendHelloIfNeeded() throws {
    guard !hasSentHello else { return }
    hasSentHello = true
    guestLog.info("Sending hello for session code \(self.sessionCode, privacy: .public)")
    let hello = HelloMessage(sessionCode: sessionCode, guestToken: guestToken)
    try transport.send(WireEnvelope(payload: .hello(hello)))
  }

  public func claimPlayer(playerId: UUID?, displayName: String) throws {
    let claim = ClaimPlayerMessage(playerId: playerId, displayName: displayName)
    try transport.send(WireEnvelope(payload: .claimPlayer(claim)))
  }

  public func disconnect() {
    transport.disconnect()
  }

  public func submitGuestCommand(_ command: GameCommand) throws {
    guard let guestToken, playerId != nil else {
      throw GuestSessionError.notJoined
    }
    let message = GuestCommandMessage(guestToken: guestToken, command: command)
    try transport.send(WireEnvelope(payload: .guestCommand(message)))
  }

  private func handleTransportEvent(_ event: GuestTransportEvent) {
    switch event {
    case .connected:
      do {
        try sendHelloIfNeeded()
      } catch {
        onError?(error)
      }
    case .disconnected:
      onSessionEnded?("Disconnected.")
    case .received(let envelope):
      handleEnvelope(envelope)
    }
  }

  private func applyLobbySlots(_ slots: [LobbyPlayerSlot]) {
    setupPlayers = slots.map { Player(id: $0.playerId, name: $0.name) }
    guard var current = game else { return }
    for slot in slots {
      if let idx = current.players.firstIndex(where: { $0.id == slot.playerId }) {
        current.players[idx].name = slot.name
      }
    }
    game = current
    onGameSnapshot?(current, revision)
  }

  private func refreshSetupPlayers(from slots: [LobbyPlayerSlot]) {
    setupPlayers = slots.map { Player(id: $0.playerId, name: $0.name) }
  }

  private func handleEnvelope(_ envelope: WireEnvelope) {
    guard envelope.version == WireProtocolVersion.current else { return }
    switch envelope.payload {
    case .joinLobby(let lobby):
      let slots = lobby.slots
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.refreshSetupPlayers(from: slots)
        if self.playerId != nil {
          self.applyLobbySlots(slots)
        } else {
          self.onJoinLobby?(slots)
        }
      }
    case .claimAccepted(let accepted):
      guestToken = accepted.guestToken
      playerId = accepted.playerId
      if let matched = setupPlayers.first(where: { $0.id == accepted.playerId }) {
        playerName = matched.name
      }
      onSlotClaimed?()
    case .joinAccepted(let accepted):
      guestToken = accepted.guestToken
      playerId = accepted.playerId
      if let matched = accepted.game.players.first(where: { $0.id == accepted.playerId }) {
        playerName = matched.name
      }
      revision = accepted.revision
      game = accepted.game
      onJoinAccepted?()
      onGameSnapshot?(accepted.game, accepted.revision)
    case .joinRejected(let rejected):
      guestLog.error("Join rejected: \(rejected.reason, privacy: .public)")
      onError?(GuestSessionError.joinRejected(rejected.reason))
    case .gameSnapshot(let snapshot):
      if snapshot.revision >= revision {
        revision = snapshot.revision
        game = snapshot.game
        onGameSnapshot?(snapshot.game, snapshot.revision)
      }
    case .commandResult(let result):
      onCommandResult?(result)
    case .sessionEnded(let ended):
      onSessionEnded?(ended.reason)
      transport.disconnect()
    case .ping(let ping):
      do {
        try transport.send(WireEnvelope(payload: .pong(PongMessage(nonce: ping.nonce))))
      } catch {
        onError?(error)
      }
    case .pong, .hello, .claimPlayer, .guestCommand:
      break
    }
  }
}
