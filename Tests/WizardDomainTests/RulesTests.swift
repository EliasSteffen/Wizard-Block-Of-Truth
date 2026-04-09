import XCTest
@testable import WizardDomain

final class RulesTests: XCTestCase {
  func testMaxHandSizeClassic() throws {
    XCTAssertEqual(Rules.maxHandSize(deckSize: 60, playerCount: 2), 30)
    XCTAssertEqual(Rules.maxHandSize(deckSize: 60, playerCount: 6), 10)
  }

  func testNextDealerWrapsAround() throws {
    let players = TestSupport.makePlayers(3)
    XCTAssertEqual(try Rules.nextDealer(players: players, currentDealer: players[0].id), players[1].id)
    XCTAssertEqual(try Rules.nextDealer(players: players, currentDealer: players[1].id), players[2].id)
    XCTAssertEqual(try Rules.nextDealer(players: players, currentDealer: players[2].id), players[0].id)
  }

  func testNextDealerRejectsUnknownDealer() throws {
    let players = TestSupport.makePlayers(3)
    let unknown = UUID()
    XCTAssertThrowsError(try Rules.nextDealer(players: players, currentDealer: unknown)) { err in
      XCTAssertEqual(err as? DomainError, .unknownPlayerId(unknown))
    }
  }
}

