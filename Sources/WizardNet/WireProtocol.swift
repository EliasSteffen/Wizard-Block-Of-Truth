import Foundation
#if canImport(WizardDomain)
import WizardDomain
#endif

public enum WireProtocolVersion {
  public static let current = 1
}

public struct WireEnvelope: Codable, Sendable, Equatable {
  public var version: Int
  public var payload: WirePayload

  public init(version: Int = WireProtocolVersion.current, payload: WirePayload) {
    self.version = version
    self.payload = payload
  }
}

public enum WirePayload: Sendable, Equatable {
  case hello(HelloMessage)
  case joinLobby(JoinLobbyMessage)
  case claimPlayer(ClaimPlayerMessage)
  case claimAccepted(ClaimAcceptedMessage)
  case joinAccepted(JoinAcceptedMessage)
  case joinRejected(JoinRejectedMessage)
  case gameSnapshot(GameSnapshotMessage)
  case guestCommand(GuestCommandMessage)
  case commandResult(CommandResultMessage)
  case sessionEnded(SessionEndedMessage)
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
  public var guestToken: String?

  public init(sessionCode: String, guestToken: String? = nil) {
    self.sessionCode = sessionCode
    self.guestToken = guestToken
  }
}

public struct LobbyPlayerSlot: Codable, Sendable, Equatable {
  public var playerId: UUID
  public var name: String
  public var isClaimed: Bool

  public init(playerId: UUID, name: String, isClaimed: Bool) {
    self.playerId = playerId
    self.name = name
    self.isClaimed = isClaimed
  }
}

public struct JoinLobbyMessage: Codable, Sendable, Equatable {
  public var slots: [LobbyPlayerSlot]

  public init(slots: [LobbyPlayerSlot]) {
    self.slots = slots
  }
}

public struct ClaimPlayerMessage: Codable, Sendable, Equatable {
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

  public init(guestToken: String, playerId: UUID) {
    self.guestToken = guestToken
    self.playerId = playerId
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
  public var reason: String

  public init(reason: String) {
    self.reason = reason
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
  public var command: GameCommand

  public init(guestToken: String, command: GameCommand) {
    self.guestToken = guestToken
    self.command = command
  }
}

public struct CommandResultMessage: Codable, Sendable, Equatable {
  public var accepted: Bool
  public var reason: String?
  public var revision: Int?

  public init(accepted: Bool, reason: String? = nil, revision: Int? = nil) {
    self.accepted = accepted
    self.reason = reason
    self.revision = revision
  }
}

public struct SessionEndedMessage: Codable, Sendable, Equatable {
  public var reason: String

  public init(reason: String) {
    self.reason = reason
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
