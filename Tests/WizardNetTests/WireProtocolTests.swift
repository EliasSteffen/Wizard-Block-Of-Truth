import XCTest
@testable import WizardNet
@testable import WizardDomain

final class FrameDecoderTests: XCTestCase {
  private func ping(_ nonce: UInt64) -> WireEnvelope {
    WireEnvelope(payload: .ping(PingMessage(nonce: nonce)))
  }

  func testPartialHeaderWaitsForMoreBytes() throws {
    let frame = try FrameCodec.encode(ping(1))
    var decoder = FrameDecoder()
    decoder.append(frame.prefix(2))
    XCTAssertNil(try decoder.nextEnvelope())
    decoder.append(frame.dropFirst(2))
    XCTAssertEqual(try decoder.nextEnvelope(), ping(1))
    XCTAssertNil(try decoder.nextEnvelope())
  }

  func testSplitPayloadIsReassembled() throws {
    let frame = try FrameCodec.encode(ping(2))
    let cut = FrameCodec.headerSize + 3
    var decoder = FrameDecoder()
    decoder.append(frame.prefix(cut))
    XCTAssertNil(try decoder.nextEnvelope())
    decoder.append(frame.dropFirst(cut))
    XCTAssertEqual(try decoder.nextEnvelope(), ping(2))
  }

  func testManyFramesInOneChunk() throws {
    // Frames of different (odd) lengths put later headers at unaligned offsets.
    let envelopes = [
      ping(1),
      WireEnvelope(payload: .hello(HelloMessage(sessionCode: "ABC", guestToken: "t"))),
      ping(123_456_789),
      WireEnvelope(payload: .leaveSession(LeaveSessionMessage(guestToken: "xyz"))),
    ]
    var chunk = Data()
    for envelope in envelopes {
      chunk.append(try FrameCodec.encode(envelope))
    }
    var decoder = FrameDecoder()
    decoder.append(chunk)
    var decoded: [WireEnvelope] = []
    while let next = try decoder.nextEnvelope() {
      decoded.append(next)
    }
    XCTAssertEqual(decoded, envelopes)
    XCTAssertTrue(decoder.buffer.isEmpty)
  }

  func testByteByByteDelivery() throws {
    var stream = try FrameCodec.encode(ping(7))
    stream.append(try FrameCodec.encode(ping(8)))
    var decoder = FrameDecoder()
    var decoded: [WireEnvelope] = []
    for byte in stream {
      decoder.append(Data([byte]))
      while let next = try decoder.nextEnvelope() {
        decoded.append(next)
      }
    }
    XCTAssertEqual(decoded, [ping(7), ping(8)])
  }

  func testZeroLengthPrefixThrows() {
    var decoder = FrameDecoder()
    decoder.append(Data([0, 0, 0, 0]))
    XCTAssertThrowsError(try decoder.nextEnvelope()) { error in
      XCTAssertEqual(error as? FrameCodecError, .invalidLengthPrefix)
    }
  }

  func testOversizedLengthPrefixThrowsBeforePayloadArrives() {
    var decoder = FrameDecoder(maxFrameSize: 16)
    decoder.append(Data([0, 0, 0, 17]))
    XCTAssertThrowsError(try decoder.nextEnvelope()) { error in
      XCTAssertEqual(error as? FrameCodecError, .frameTooLarge(17))
    }
  }

  func testInvalidJSONThrowsDecodingError() {
    var decoder = FrameDecoder()
    decoder.append(FrameCodec.frame(payload: Data("not json".utf8)))
    XCTAssertThrowsError(try decoder.nextEnvelope()) { error in
      XCTAssertEqual(error as? FrameCodecError, .payloadDecodingFailed)
    }
  }

  func testUnknownPayloadTypeThrowsDecodingError() {
    let json = #"{"version":2,"payload":{"type":"somethingNew","somethingNew":{}}}"#
    var decoder = FrameDecoder()
    decoder.append(FrameCodec.frame(payload: Data(json.utf8)))
    XCTAssertThrowsError(try decoder.nextEnvelope()) { error in
      XCTAssertEqual(error as? FrameCodecError, .payloadDecodingFailed)
    }
  }
}

final class WireProtocolTests: XCTestCase {
  func testCurrentVersionIsTwo() {
    XCTAssertEqual(WireProtocolVersion.current, 2)
    XCTAssertEqual(WireEnvelope(payload: .ping(PingMessage(nonce: 1))).version, 2)
  }

  /// Exhaustive on purpose: a new payload case must get a round-trip sample here.
  private func caseName(_ payload: WirePayload) -> String {
    switch payload {
    case .hello: return "hello"
    case .joinLobby: return "joinLobby"
    case .claimPlayer: return "claimPlayer"
    case .claimAccepted: return "claimAccepted"
    case .joinAccepted: return "joinAccepted"
    case .joinRejected: return "joinRejected"
    case .gameSnapshot: return "gameSnapshot"
    case .guestCommand: return "guestCommand"
    case .commandResult: return "commandResult"
    case .sessionEnded: return "sessionEnded"
    case .leaveSession: return "leaveSession"
    case .ping: return "ping"
    case .pong: return "pong"
    }
  }

  func testEveryPayloadRoundTripsThroughFraming() throws {
    let players = NetTestSupport.players(["Ann", "Ben", "Cid"])
    var game = try NetTestSupport.startedGame(players)
    try game.apply(.submitBet(playerId: players[1].id, roundIndex: 0, bet: 1))
    let slot = LobbyPlayerSlot(
      playerId: players[1].id,
      name: "Ben",
      isHost: false,
      isBoundToDevice: true,
      isConnected: false,
      isPlaceholderName: false
    )
    let commandID = UUID()
    let payloads: [WirePayload] = [
      .hello(HelloMessage(sessionCode: "ABCD12")),
      .hello(HelloMessage(sessionCode: "ABCD12", guestToken: "token")),
      .joinLobby(JoinLobbyMessage(gameID: game.id, gameName: game.name, hasStarted: true, slots: [slot])),
      .claimPlayer(ClaimPlayerMessage(playerId: players[1].id, displayName: "Ben")),
      .claimPlayer(ClaimPlayerMessage(playerId: nil, displayName: "Anyone")),
      .claimAccepted(ClaimAcceptedMessage(guestToken: "token", playerId: players[1].id, playerName: "Ben")),
      .joinAccepted(JoinAcceptedMessage(guestToken: "token", playerId: players[1].id, revision: 4, game: game)),
      .joinRejected(JoinRejectedMessage(code: .nameTaken, detail: "log only")),
      .joinRejected(JoinRejectedMessage(code: .versionMismatch)),
      .gameSnapshot(GameSnapshotMessage(revision: 5, game: game)),
      .guestCommand(
        GuestCommandMessage(
          guestToken: "token",
          command: .submitBet(playerId: players[1].id, roundIndex: 0, bet: 1),
          commandID: commandID
        )
      ),
      .guestCommand(
        GuestCommandMessage(guestToken: "token", command: .submitGot(playerId: players[1].id, roundIndex: 0, got: 0))
      ),
      .commandResult(CommandResultMessage(commandID: commandID, accepted: true, revision: 6)),
      .commandResult(
        CommandResultMessage(commandID: commandID, accepted: false, code: .betSumEqualsHandSize(handSize: 3), detail: "x")
      ),
      .sessionEnded(SessionEndedMessage(code: .sessionEnded(.gameFinished))),
      .sessionEnded(SessionEndedMessage(code: .kicked, detail: "bye")),
      .leaveSession(LeaveSessionMessage(guestToken: "token")),
      .ping(PingMessage(nonce: 42)),
      .pong(PongMessage(nonce: 42)),
    ]

    var covered = Set<String>()
    for payload in payloads {
      covered.insert(caseName(payload))
      let envelope = WireEnvelope(payload: payload)
      var decoder = FrameDecoder()
      decoder.append(try FrameCodec.encode(envelope))
      XCTAssertEqual(try decoder.nextEnvelope(), envelope, "round trip failed for \(caseName(payload))")
    }
    XCTAssertEqual(covered.count, 13, "every WirePayload case needs a round-trip sample")
  }

  func testReasonCodesRoundTrip() throws {
    let codes: [MultiplayerReasonCode] = [
      .versionMismatch, .sessionNotFound, .seatTaken, .seatNotFound, .nameInvalid, .nameTaken, .tokenInvalid,
      .notYourSeat, .notCurrentRound, .roundFinalized, .betsComplete, .betsIncomplete,
      .betSumEqualsHandSize(handSize: 3), .invalidValue, .gameNotStarted, .notAuthorized,
      .sessionEnded(.hostEnded), .sessionEnded(.gameFinished), .kicked, .internalError, .unknown("futureCode"),
    ]
    for code in codes {
      let data = try JSONEncoder().encode(code)
      XCTAssertEqual(try JSONDecoder().decode(MultiplayerReasonCode.self, from: data), code)
    }
  }

  func testUnknownReasonCodeDecodesAsUnknown() throws {
    let data = Data(#"{"code":"brandNewReason","extra":1}"#.utf8)
    XCTAssertEqual(try JSONDecoder().decode(MultiplayerReasonCode.self, from: data), .unknown("brandNewReason"))
  }

  func testLegacyV1RejectionUsesExactV1Format() throws {
    let rejection = WireEnvelope(
      version: WireProtocolVersion.legacyV1,
      payload: .joinRejected(JoinRejectedMessage(code: .versionMismatch, detail: LegacyWireV1.updateRequiredReason))
    )
    let frame = try FrameCodec.encode(rejection)

    // Decodable with the v1 types of app 1.1 …
    let v1 = try LegacyV1Mirror.decodeJoinRejected(frame: frame)
    XCTAssertEqual(v1.version, 1)
    XCTAssertEqual(v1.payload.type, .joinRejected)
    XCTAssertTrue(v1.payload.joinRejected.reason.contains("update"))
    XCTAssertTrue(v1.payload.joinRejected.reason.contains("aktualisiere"))

    // … and exactly v1's shape (no v2-only keys).
    var decoder = FrameDecoder()
    decoder.append(frame)
    let payloadData = try XCTUnwrap(try decoder.nextPayload())
    let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
    XCTAssertEqual(Set(root.keys), ["version", "payload"])
    let payload = try XCTUnwrap(root["payload"] as? [String: Any])
    XCTAssertEqual(Set(payload.keys), ["type", "joinRejected"])
    let body = try XCTUnwrap(payload["joinRejected"] as? [String: Any])
    XCTAssertEqual(Set(body.keys), ["reason"])

    // A v2 decoder understands it as a version mismatch.
    XCTAssertEqual(
      try FrameCodec.decode(payloadData),
      WireEnvelope(
        version: 1,
        payload: .joinRejected(JoinRejectedMessage(code: .versionMismatch, detail: LegacyWireV1.updateRequiredReason))
      )
    )
  }

  func testLegacyV1HelloDecodes() throws {
    var decoder = FrameDecoder()
    decoder.append(NetTestSupport.legacyV1HelloFrame(sessionCode: "ABCD12"))
    let envelope = try XCTUnwrap(try decoder.nextEnvelope())
    XCTAssertEqual(envelope.version, 1)
    XCTAssertEqual(envelope.payload, .hello(HelloMessage(sessionCode: "ABCD12")))
  }

  func testLobbySlotClaimability() {
    let id = UUID()
    let open = LobbyPlayerSlot(playerId: id, name: "A", isHost: false, isBoundToDevice: false, isConnected: false, isPlaceholderName: false)
    let host = LobbyPlayerSlot(playerId: id, name: "A", isHost: true, isBoundToDevice: false, isConnected: false, isPlaceholderName: false)
    let bound = LobbyPlayerSlot(playerId: id, name: "A", isHost: false, isBoundToDevice: true, isConnected: false, isPlaceholderName: false)
    XCTAssertTrue(open.isClaimable)
    XCTAssertFalse(host.isClaimable)
    XCTAssertFalse(bound.isClaimable)
    XCTAssertTrue(bound.isClaimed)
  }

  func testSeatNameRules() {
    let players = NetTestSupport.players(["Alice", "Bob"])
    XCTAssertEqual(SeatNameRules.normalized("  Dana  "), "Dana")
    XCTAssertNil(SeatNameRules.normalized("   "))
    XCTAssertNil(SeatNameRules.normalized(String(repeating: "x", count: 25)))
    XCTAssertEqual(SeatNameRules.normalized(String(repeating: "x", count: 24)), String(repeating: "x", count: 24))
    XCTAssertTrue(SeatNameRules.isTaken("alice", in: players))
    XCTAssertFalse(SeatNameRules.isTaken("alice", in: players, excluding: [players[0].id]))
    XCTAssertEqual(SeatNameRules.rejection(for: "BOB", in: players, seat: players[0].id), .nameTaken)
    XCTAssertEqual(SeatNameRules.rejection(for: "", in: players, seat: players[0].id), .nameInvalid)
    XCTAssertNil(SeatNameRules.rejection(for: "Bob", in: players, seat: players[1].id))
  }
}
