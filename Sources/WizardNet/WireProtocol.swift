import Foundation
#if canImport(WizardDomain)
import WizardDomain
#endif

public enum WireProtocolVersion {
  /// v2: typed reason codes, claiming a seat by id + name, heartbeat, leave/kick, snapshots only to joined guests.
  public static let current = 2
  /// App 1.1. Only used to answer a v1 `hello` with a v1-decodable `joinRejected` ("please update").
  public static let legacyV1 = 1
}

/// Wire-level details of protocol v1 (app 1.1) that a v2 host still has to speak once.
public enum LegacyWireV1 {
  /// Sent to v1 guests. v1 cannot localize it, hence English and German in one text.
  public static let updateRequiredReason =
    "Please update Wizard Block of Truth to the latest version to join this game. "
    + "– Bitte aktualisiere Wizard Block of Truth auf die neueste Version, um diesem Spiel beizutreten."

  /// Exactly v1's `{"type":"joinRejected","joinRejected":{"reason":"…"}}` payload.
  struct JoinRejectedPayload: Codable, Equatable {
    struct Body: Codable, Equatable {
      var reason: String
    }

    var type: String
    var joinRejected: Body

    init(reason: String) {
      self.type = "joinRejected"
      self.joinRejected = Body(reason: reason)
    }
  }
}

public struct WireEnvelope: Sendable, Equatable {
  public var version: Int
  public var payload: WirePayload

  public init(version: Int = WireProtocolVersion.current, payload: WirePayload) {
    self.version = version
    self.payload = payload
  }
}

extension WireEnvelope: Codable {
  private enum CodingKeys: String, CodingKey {
    case version
    case payload
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    if version == WireProtocolVersion.legacyV1,
       let legacy = try? container.decode(LegacyWireV1.JoinRejectedPayload.self, forKey: .payload),
       legacy.type == "joinRejected" {
      self.init(
        version: version,
        payload: .joinRejected(JoinRejectedMessage(code: .versionMismatch, detail: legacy.joinRejected.reason))
      )
      return
    }
    // v1 `hello` has the same shape as v2, so a v1 guest's hello decodes and gets a versioned rejection.
    self.init(version: version, payload: try container.decode(WirePayload.self, forKey: .payload))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    if version == WireProtocolVersion.legacyV1, case .joinRejected(let message) = payload {
      let reason = message.detail ?? LegacyWireV1.updateRequiredReason
      try container.encode(LegacyWireV1.JoinRejectedPayload(reason: reason), forKey: .payload)
      return
    }
    try container.encode(payload, forKey: .payload)
  }
}

public enum WirePayload: Sendable, Equatable {
  /// Guest → host, first message on every connection (also on reconnect, with the token).
  case hello(HelloMessage)
  /// Host → guests that said hello and have no seat yet, and (before the start) to all joined guests.
  case joinLobby(JoinLobbyMessage)
  /// Guest → host: take a seat (by id) with a display name.
  case claimPlayer(ClaimPlayerMessage)
  /// Host → guest: seat taken before the start; carries the rejoin token and the accepted name.
  case claimAccepted(ClaimAcceptedMessage)
  /// Host → guest: seat taken in a started game (on claim, rejoin or game start); carries the full game.
  case joinAccepted(JoinAcceptedMessage)
  case joinRejected(JoinRejectedMessage)
  /// Host → joined guests after every accepted change.
  case gameSnapshot(GameSnapshotMessage)
  case guestCommand(GuestCommandMessage)
  case commandResult(CommandResultMessage)
  /// Host → guests: session over (`hostEnded`, `gameFinished`) or this guest was removed (`kicked`).
  case sessionEnded(SessionEndedMessage)
  /// Guest → host: the guest leaves for good; the host releases the seat.
  case leaveSession(LeaveSessionMessage)
  case ping(PingMessage)
  case pong(PongMessage)
}

extension WirePayload: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case hello
    case joinLobby
    case claimPlayer
    case claimAccepted
    case joinAccepted
    case joinRejected
    case gameSnapshot
    case guestCommand
    case commandResult
    case sessionEnded
    case leaveSession
    case ping
    case pong
  }

  private enum PayloadType: String, Codable {
    case hello
    case joinLobby
    case claimPlayer
    case claimAccepted
    case joinAccepted
    case joinRejected
    case gameSnapshot
    case guestCommand
    case commandResult
    case sessionEnded
    case leaveSession
    case ping
    case pong
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(PayloadType.self, forKey: .type)
    switch type {
    case .hello:
      self = .hello(try container.decode(HelloMessage.self, forKey: .hello))
    case .joinLobby:
      self = .joinLobby(try container.decode(JoinLobbyMessage.self, forKey: .joinLobby))
    case .claimPlayer:
      self = .claimPlayer(try container.decode(ClaimPlayerMessage.self, forKey: .claimPlayer))
    case .claimAccepted:
      self = .claimAccepted(try container.decode(ClaimAcceptedMessage.self, forKey: .claimAccepted))
    case .joinAccepted:
      self = .joinAccepted(try container.decode(JoinAcceptedMessage.self, forKey: .joinAccepted))
    case .joinRejected:
      self = .joinRejected(try container.decode(JoinRejectedMessage.self, forKey: .joinRejected))
    case .gameSnapshot:
      self = .gameSnapshot(try container.decode(GameSnapshotMessage.self, forKey: .gameSnapshot))
    case .guestCommand:
      self = .guestCommand(try container.decode(GuestCommandMessage.self, forKey: .guestCommand))
    case .commandResult:
      self = .commandResult(try container.decode(CommandResultMessage.self, forKey: .commandResult))
    case .sessionEnded:
      self = .sessionEnded(try container.decode(SessionEndedMessage.self, forKey: .sessionEnded))
    case .leaveSession:
      self = .leaveSession(try container.decode(LeaveSessionMessage.self, forKey: .leaveSession))
    case .ping:
      self = .ping(try container.decode(PingMessage.self, forKey: .ping))
    case .pong:
      self = .pong(try container.decode(PongMessage.self, forKey: .pong))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .hello(let message):
      try container.encode(PayloadType.hello, forKey: .type)
      try container.encode(message, forKey: .hello)
    case .joinLobby(let message):
      try container.encode(PayloadType.joinLobby, forKey: .type)
      try container.encode(message, forKey: .joinLobby)
    case .claimPlayer(let message):
      try container.encode(PayloadType.claimPlayer, forKey: .type)
      try container.encode(message, forKey: .claimPlayer)
    case .claimAccepted(let message):
      try container.encode(PayloadType.claimAccepted, forKey: .type)
      try container.encode(message, forKey: .claimAccepted)
    case .joinAccepted(let message):
      try container.encode(PayloadType.joinAccepted, forKey: .type)
      try container.encode(message, forKey: .joinAccepted)
    case .joinRejected(let message):
      try container.encode(PayloadType.joinRejected, forKey: .type)
      try container.encode(message, forKey: .joinRejected)
    case .gameSnapshot(let message):
      try container.encode(PayloadType.gameSnapshot, forKey: .type)
      try container.encode(message, forKey: .gameSnapshot)
    case .guestCommand(let message):
      try container.encode(PayloadType.guestCommand, forKey: .type)
      try container.encode(message, forKey: .guestCommand)
    case .commandResult(let message):
      try container.encode(PayloadType.commandResult, forKey: .type)
      try container.encode(message, forKey: .commandResult)
    case .sessionEnded(let message):
      try container.encode(PayloadType.sessionEnded, forKey: .type)
      try container.encode(message, forKey: .sessionEnded)
    case .leaveSession(let message):
      try container.encode(PayloadType.leaveSession, forKey: .type)
      try container.encode(message, forKey: .leaveSession)
    case .ping(let message):
      try container.encode(PayloadType.ping, forKey: .type)
      try container.encode(message, forKey: .ping)
    case .pong(let message):
      try container.encode(PayloadType.pong, forKey: .type)
      try container.encode(message, forKey: .pong)
    }
  }
}

public struct HelloMessage: Codable, Sendable, Equatable {
  public var sessionCode: String
  /// Rejoin token from an earlier `claimAccepted` / `joinAccepted`.
  public var guestToken: String?

  public init(sessionCode: String, guestToken: String? = nil) {
    self.sessionCode = sessionCode
    self.guestToken = guestToken
  }
}

/// One seat as shown in the lobby.
public struct LobbyPlayerSlot: Codable, Sendable, Equatable, Hashable {
  public var playerId: UUID
  public var name: String
  /// The host plays this seat.
  public var isHost: Bool
  /// A guest device holds a token for this seat (connected or not). Cleared when the host unassigns it.
  public var isBoundToDevice: Bool
  /// A guest device is connected for this seat right now.
  public var isConnected: Bool
  /// The name is still the default "Player N" / "Spieler N".
  public var isPlaceholderName: Bool

  public init(
    playerId: UUID,
    name: String,
    isHost: Bool,
    isBoundToDevice: Bool,
    isConnected: Bool,
    isPlaceholderName: Bool
  ) {
    self.playerId = playerId
    self.name = name
    self.isHost = isHost
    self.isBoundToDevice = isBoundToDevice
    self.isConnected = isConnected
    self.isPlaceholderName = isPlaceholderName
  }

  /// A guest may claim this seat (incl. host-named phone-less seats).
  public var isClaimable: Bool { !isHost && !isBoundToDevice }
  /// Not claimable (host seat or bound to a guest device).
  public var isClaimed: Bool { !isClaimable }
}

public struct JoinLobbyMessage: Codable, Sendable, Equatable {
  public var gameID: UUID
  public var gameName: String
  public var hasStarted: Bool
  /// Seats in table order (drives dealer rotation and betting order).
  public var slots: [LobbyPlayerSlot]

  public init(gameID: UUID, gameName: String, hasStarted: Bool, slots: [LobbyPlayerSlot]) {
    self.gameID = gameID
    self.gameName = gameName
    self.hasStarted = hasStarted
    self.slots = slots
  }
}

public struct ClaimPlayerMessage: Codable, Sendable, Equatable {
  /// The seat to take; `nil` = first open seat (placeholder-named seats first).
  public var playerId: UUID?
  public var displayName: String

  public init(playerId: UUID?, displayName: String) {
    self.playerId = playerId
    self.displayName = displayName
  }
}

public struct ClaimAcceptedMessage: Codable, Sendable, Equatable {
  public var guestToken: String
  public var playerId: UUID
  /// The accepted (trimmed) name.
  public var playerName: String

  public init(guestToken: String, playerId: UUID, playerName: String) {
    self.guestToken = guestToken
    self.playerId = playerId
    self.playerName = playerName
  }
}

public struct JoinAcceptedMessage: Codable, Sendable, Equatable {
  public var guestToken: String
  public var playerId: UUID
  public var revision: Int
  public var game: Game

  public init(guestToken: String, playerId: UUID, revision: Int, game: Game) {
    self.guestToken = guestToken
    self.playerId = playerId
    self.revision = revision
    self.game = game
  }
}

public struct JoinRejectedMessage: Codable, Sendable, Equatable {
  public var code: MultiplayerReasonCode
  /// Free text for logs only (never shown; the app localizes `code`).
  public var detail: String?

  public init(code: MultiplayerReasonCode, detail: String? = nil) {
    self.code = code
    self.detail = detail
  }
}

public struct GameSnapshotMessage: Codable, Sendable, Equatable {
  public var revision: Int
  public var game: Game

  public init(revision: Int, game: Game) {
    self.revision = revision
    self.game = game
  }
}

public struct GuestCommandMessage: Codable, Sendable, Equatable {
  public var guestToken: String
  /// Echoed in `CommandResultMessage.commandID`.
  public var commandID: UUID
  public var command: GameCommand

  public init(guestToken: String, command: GameCommand, commandID: UUID = UUID()) {
    self.guestToken = guestToken
    self.command = command
    self.commandID = commandID
  }
}

public struct CommandResultMessage: Codable, Sendable, Equatable {
  public var commandID: UUID?
  public var accepted: Bool
  /// Set when `accepted == false`.
  public var code: MultiplayerReasonCode?
  /// Free text for logs only.
  public var detail: String?
  public var revision: Int?

  public init(
    commandID: UUID? = nil,
    accepted: Bool,
    code: MultiplayerReasonCode? = nil,
    detail: String? = nil,
    revision: Int? = nil
  ) {
    self.commandID = commandID
    self.accepted = accepted
    self.code = code
    self.detail = detail
    self.revision = revision
  }
}

public struct SessionEndedMessage: Codable, Sendable, Equatable {
  /// `.sessionEnded(.hostEnded)`, `.sessionEnded(.gameFinished)` or `.kicked`.
  public var code: MultiplayerReasonCode
  /// Free text for logs only.
  public var detail: String?

  public init(code: MultiplayerReasonCode, detail: String? = nil) {
    self.code = code
    self.detail = detail
  }
}

public struct LeaveSessionMessage: Codable, Sendable, Equatable {
  public var guestToken: String

  public init(guestToken: String) {
    self.guestToken = guestToken
  }
}

public struct PingMessage: Codable, Sendable, Equatable {
  public var nonce: UInt64

  public init(nonce: UInt64) {
    self.nonce = nonce
  }
}

public struct PongMessage: Codable, Sendable, Equatable {
  public var nonce: UInt64

  public init(nonce: UInt64) {
    self.nonce = nonce
  }
}
