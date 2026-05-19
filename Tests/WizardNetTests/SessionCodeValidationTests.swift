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
