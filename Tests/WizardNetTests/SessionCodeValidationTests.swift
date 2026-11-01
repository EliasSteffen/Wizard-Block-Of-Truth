import XCTest
@testable import WizardNet
@testable import WizardDomain

@MainActor
final class SessionCodeValidationTests: XCTestCase {
  func testBonjourServiceNameParsesCodeAndDisplayName() {
    let parsed = BonjourServiceDescriptor.parse(serviceName: "ABCD12-Friday Night")
    XCTAssertEqual(parsed.code, "ABCD12")
    XCTAssertEqual(parsed.displayName, "Friday Night")
  }

  func testBonjourServiceNameKeepsHyphensInDisplayName() {
    let parsed = BonjourServiceDescriptor.parse(serviceName: "XYZ789-My-Cool-Game")
    XCTAssertEqual(parsed.code, "XYZ789")
    XCTAssertEqual(parsed.displayName, "My-Cool-Game")
  }

  func testBonjourServiceNameWithoutSeparatorUsesPlaceholderCode() {
    let parsed = BonjourServiceDescriptor.parse(serviceName: "Malformed")
    XCTAssertEqual(parsed.code, "------")
    XCTAssertEqual(parsed.displayName, "Malformed")
  }

  func testServiceNameIsTruncatedToBonjourLimitOnCharacterBoundary() {
    let name = BonjourAdvertiser.serviceName(sessionCode: "ABCD12", gameName: String(repeating: "ä", count: 40))
    // "ABCD12-" (7 bytes) + 28 × "ä" (2 bytes each) = 63 bytes.
    XCTAssertEqual(name.utf8.count, 63)
    XCTAssertEqual(name, "ABCD12-" + String(repeating: "ä", count: 28))
    XCTAssertEqual(BonjourServiceDescriptor.parse(serviceName: name).code, "ABCD12")

    let emoji = BonjourAdvertiser.serviceName(sessionCode: "ABCD12", gameName: String(repeating: "👨‍👩‍👧", count: 10))
    XCTAssertLessThanOrEqual(emoji.utf8.count, 63)
    XCTAssertTrue(emoji.hasPrefix("ABCD12-👨‍👩‍👧"))
  }

  func testServiceNameIsStableForSameCodeAndGame() {
    XCTAssertEqual(
      BonjourAdvertiser.serviceName(sessionCode: "ABCD12", gameName: " Friday "),
      BonjourAdvertiser.serviceName(sessionCode: "ABCD12", gameName: "Friday")
    )
    XCTAssertEqual(BonjourAdvertiser.serviceName(sessionCode: "ABCD12", gameName: "  "), "ABCD12-Wizard")
  }

  func testSessionCodeMatchIsCaseInsensitive() throws {
    let hostTransport = MockHostTransport()
    let host = HostSessionService(
      initialGame: try makeSetupGame(),
      sessionCode: "ABCD12",
      transport: hostTransport
    )
    try host.start()

    let guest = GuestSessionService(sessionCode: " abcd12 ", transport: MockGuestTransport(host: hostTransport))
    let lobby = expectation(description: "lobby")
    guest.onJoinLobby = { _ in lobby.fulfill() }
    try guest.connect()
    wait(for: [lobby], timeout: 1.0)
  }

  func testPartialSessionCodeIsRejected() throws {
    let hostTransport = MockHostTransport()
    let host = HostSessionService(
      initialGame: try makeSetupGame(),
      sessionCode: "ABCD12",
      transport: hostTransport
    )
    try host.start()

    let guest = GuestSessionService(sessionCode: "C", transport: MockGuestTransport(host: hostTransport))
    let rejected = expectation(description: "join rejected")
    guest.onError = { error in
      if case GuestSessionError.joinRejected = error {
        rejected.fulfill()
      }
    }
    try guest.connect()
    wait(for: [rejected], timeout: 1.0)
  }

  private func makeSetupGame() throws -> Game {
    let players = (0..<3).map { idx in
      Player(
        id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idx + 1))!,
        name: "P\(idx + 1)"
      )
    }
    return try Game(id: UUID(), name: "Multi Phone", mode: .multiPhone, players: players)
  }
}
