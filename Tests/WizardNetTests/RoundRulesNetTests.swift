import XCTest
@testable import WizardNet
@testable import WizardDomain

/// Host-side house rules and round-rule permissions in multi-phone sessions.
@MainActor
final class RoundRulesNetTests: XCTestCase {
  private let sessionCode = "ABCD12"

  private func makePlayers() -> [Player] {
    (0..<3).map { idx in
      Player(
        id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idx + 1))!,
        name: "P\(idx + 1)"
      )
    }
  }

  private func makeHost(players: [Player]) throws -> HostSessionService {
    let host = HostSessionService(
      initialGame: try Game(id: UUID(), name: "Multi Phone", mode: .multiPhone, players: players),
      sessionCode: sessionCode,
      transport: MockHostTransport(),
      hostReservedPlayerId: players[0].id
    )
    try host.start()
    return host
  }

  func testStartGameAppliesFirstRoundBetSumRule() throws {
    let players = makePlayers()
    let host = try makeHost(players: players)

    try host.startGame(
      startingDealer: players[0].id,
      gameConstraints: [.betSumNotEqualHandSize],
      playWithSpecialCards: true,
      firstRoundBetSumMayEqualHandSize: true
    )

    XCTAssertTrue(host.game.firstRoundBetSumMayEqualHandSize)
    XCTAssertEqual(host.game.gameConstraints(forRoundAt: 0), [])
    XCTAssertEqual(host.game.gameConstraints(forRoundAt: 1), [.betSumNotEqualHandSize])
  }

  func testStartGameDefaultsFirstRoundBetSumRuleToOff() throws {
    let players = makePlayers()
    let host = try makeHost(players: players)

    try host.startGame(
      startingDealer: players[0].id,
      gameConstraints: [.betSumNotEqualHandSize],
      playWithSpecialCards: true
    )

    XCTAssertFalse(host.game.firstRoundBetSumMayEqualHandSize)
    XCTAssertEqual(host.game.gameConstraints(forRoundAt: 0), [.betSumNotEqualHandSize])
  }
}
