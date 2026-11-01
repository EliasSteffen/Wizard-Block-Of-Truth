import Foundation
import XCTest
@testable import WizardNet
@testable import WizardDomain

enum NetTestSupport {
  static let sessionCode = "ABCD12"

  static func players(_ names: [String]) -> [Player] {
    names.enumerated().map { idx, name in
      Player(
        id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idx + 1))!,
        name: name
      )
    }
  }

  static func setupGame(_ players: [Player]) throws -> Game {
    try Game(id: UUID(), name: "Multi Phone", mode: .multiPhone, players: players)
  }

  static func startedGame(_ players: [Player], dealer: Int = 0) throws -> Game {
    var game = try setupGame(players)
    try game.apply(.startNewGame(startingDealer: players[dealer].id))
    return game
  }

  /// Short intervals for timer-driven tests.
  static func fastTiming(
    silenceTimeout: TimeInterval = 3600,
    helloReplyTimeout: TimeInterval = 2,
    commandTimeout: TimeInterval = 2,
    reconnectDelays: [TimeInterval] = [0.05],
    pingInterval: TimeInterval = 0.05
  ) -> SessionTiming {
    SessionTiming(
      pingInterval: pingInterval,
      silenceTimeout: silenceTimeout,
      helloReplyTimeout: helloReplyTimeout,
      commandTimeout: commandTimeout,
      reconnectDelays: reconnectDelays,
      listenerRestartDelay: 0.01,
      maxListenerRestartAttempts: 3
    )
  }

  /// Timing whose timers never fire during a test (heartbeat driven manually).
  static let quietTiming = SessionTiming(
    pingInterval: 3600,
    silenceTimeout: 3600,
    helloReplyTimeout: 3600,
    commandTimeout: 3600,
    reconnectDelays: [0.05]
  )

  /// A raw v1 (app 1.1) `hello` frame.
  static func legacyV1HelloFrame(sessionCode: String) -> Data {
    let json = #"{"version":1,"payload":{"type":"hello","hello":{"sessionCode":"\#(sessionCode)"}}}"#
    return FrameCodec.frame(payload: Data(json.utf8))
  }

  static func isSnapshot(_ envelope: WireEnvelope) -> Bool {
    if case .gameSnapshot = envelope.payload { return true }
    return false
  }

  static func isPing(_ envelope: WireEnvelope) -> Bool {
    if case .ping = envelope.payload { return true }
    return false
  }
}

/// Mirror of the v1 (app 1.1) decoding types: proves a frame is decodable by old guests.
enum LegacyV1Mirror {
  enum PayloadType: String, Decodable {
    case hello, joinLobby, claimPlayer, claimAccepted, joinAccepted, joinRejected
    case gameSnapshot, guestCommand, commandResult, sessionEnded, ping, pong
  }

  struct JoinRejectedMessage: Decodable {
    var reason: String
  }

  struct Payload: Decodable {
    var type: PayloadType
    var joinRejected: JoinRejectedMessage
  }

  struct Envelope: Decodable {
    var version: Int
    var payload: Payload
  }

  static func decodeJoinRejected(frame: Data) throws -> Envelope {
    var decoder = FrameDecoder()
    decoder.append(frame)
    let payload = try XCTUnwrap(try decoder.nextPayload())
    return try JSONDecoder().decode(Envelope.self, from: payload)
  }
}

final class TestClock {
  var now = Date(timeIntervalSince1970: 1_000_000)

  func advance(_ seconds: TimeInterval) {
    now = now.addingTimeInterval(seconds)
  }
}

extension XCTestCase {
  /// Lets queued main-queue work (transport deliveries, inbox hops, main-actor tasks) run for a moment.
  @MainActor
  func drainMainQueue(seconds: TimeInterval = 0.05) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
  }

  /// Connects `guest`, claims `seat` with `name` when the lobby arrives and waits for `claimAccepted` /
  /// `joinAccepted`.
  @MainActor
  func join(_ guest: GuestSessionService, seat: UUID?, name: String, file: StaticString = #filePath, line: UInt = #line) throws {
    let joined = expectation(description: "joined as \(name)")
    joined.assertForOverFulfill = false
    guest.onJoinLobby = { _ in
      try? guest.claimPlayer(playerId: seat, displayName: name)
    }
    guest.onSlotClaimed = { joined.fulfill() }
    guest.onJoinAccepted = { joined.fulfill() }
    try guest.connect()
    wait(for: [joined], timeout: 2)
    XCTAssertNotNil(guest.guestToken, file: file, line: line)
  }

  /// Sends a claim on an already connected guest and returns the rejection code (nil when accepted).
  @MainActor
  func claimResult(_ guest: GuestSessionService, seat: UUID?, name: String) throws -> MultiplayerReasonCode? {
    let answered = expectation(description: "claim answered")
    answered.assertForOverFulfill = false
    var rejection: MultiplayerReasonCode?
    guest.onError = { error in
      if case GuestSessionError.joinRejected(let code) = error {
        rejection = code
        answered.fulfill()
      }
    }
    guest.onSlotClaimed = { answered.fulfill() }
    guest.onJoinAccepted = { answered.fulfill() }
    try guest.claimPlayer(playerId: seat, displayName: name)
    wait(for: [answered], timeout: 2)
    return rejection
  }

  /// Submits a guest command and waits for its outcome.
  @MainActor
  func submit(_ command: GameCommand, as guest: GuestSessionService) throws -> GuestCommandOutcome? {
    let finished = expectation(description: "command answered")
    var outcome: GuestCommandOutcome?
    guest.onCommandOutcome = { _, result in
      outcome = result
      finished.fulfill()
    }
    try guest.submitGuestCommand(command)
    wait(for: [finished], timeout: 2)
    return outcome
  }
}
