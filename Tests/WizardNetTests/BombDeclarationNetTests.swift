import XCTest
@testable import WizardNet
@testable import WizardDomain

/// The Bomb is host-only (decision 5): guests cannot declare it, the host's declaration reaches every guest.
@MainActor
final class BombDeclarationNetTests: XCTestCase {
  private let players = NetTestSupport.players(["Ann", "Ben", "Cid"])
  private var guestSeat: UUID { players[1].id }

  func testAllowListDeniesBombDeclarationForGuests() throws {
    let game = try NetTestSupport.startedGame(players)
    for played in [true, false] {
      let command = GameCommand.setBombPlayed(roundIndex: 0, played: played)
      XCTAssertFalse(
        CommandAuthorizer.isAllowedGuestCommand(command, guestPlayerId: guestSeat, currentRoundIndex: 0)
      )
      XCTAssertEqual(
        CommandAuthorizer.guestCommandRejection(command, guestPlayerId: guestSeat, game: game),
        .notAuthorized
      )
    }
  }

  func testHostRejectsGuestBombAndBroadcastsTheHostsDeclaration() throws {
    let hostTransport = MockHostTransport()
    let host = HostSessionService(
      initialGame: try NetTestSupport.startedGame(players),
      sessionCode: NetTestSupport.sessionCode,
      transport: hostTransport,
      hostReservedPlayerId: players[0].id,
      timing: NetTestSupport.quietTiming
    )
    host.reserveHostSlot(playerId: players[0].id, displayName: players[0].name)
    try host.start()

    let guest = GuestSessionService(
      sessionCode: NetTestSupport.sessionCode,
      transport: MockGuestTransport(host: hostTransport),
      timing: NetTestSupport.quietTiming
    )
    try join(guest, seat: guestSeat, name: "Ben")

    // A guest's declaration is refused and changes nothing on the host.
    let gameBefore = host.game
    let outcome = try submit(.setBombPlayed(roundIndex: 0, played: true), as: guest)
    XCTAssertEqual(outcome, .rejected(.notAuthorized))
    XCTAssertEqual(host.game, gameBefore)
    XCTAssertFalse(host.game.rounds[0].bombPlayed)

    // The host's declaration is committed and reaches the guest in the next snapshot.
    let received = expectation(description: "guest sees the Bomb")
    received.assertForOverFulfill = false
    guest.onGameSnapshot = { game, _ in
      if game.rounds.first?.bombPlayed == true {
        received.fulfill()
      }
    }
    XCTAssertNil(host.applyHostCommands([.setBombPlayed(roundIndex: 0, played: true)]))
    XCTAssertTrue(host.game.rounds[0].bombPlayed)
    wait(for: [received], timeout: 2)
    XCTAssertEqual(guest.game?.rounds.first?.bombPlayed, true)
  }
}
