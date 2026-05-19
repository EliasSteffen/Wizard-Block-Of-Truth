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

  func testPlayersInBettingOrderStartsAfterDealer() throws {
    let players = TestSupport.makePlayers(3)
    let ordered = Rules.playersInBettingOrder(players: players, dealerId: players[1].id)
    XCTAssertEqual(ordered.map(\.id), [players[2].id, players[0].id, players[1].id])
  }

  func testPlayersInBettingOrderDealerLastWhenDealerIsLastInArray() throws {
    let players = TestSupport.makePlayers(3)
    let ordered = Rules.playersInBettingOrder(players: players, dealerId: players[2].id)
    XCTAssertEqual(ordered.map(\.id), players.map(\.id))
  }

  func testPlayersInBettingOrderUnknownDealerReturnsOriginalOrder() throws {
    let players = TestSupport.makePlayers(3)
    let unknown = UUID()
    let ordered = Rules.playersInBettingOrder(players: players, dealerId: unknown)
    XCTAssertEqual(ordered.map(\.id), players.map(\.id))
  }

  func testBetSumNotEqualHandSizeAllowsSumAfterCloudResolved() throws {
    let players = TestSupport.makePlayers(3)
    let id0 = players[0].id
    let id1 = players[1].id
    let id2 = players[2].id
    let entriesAfterCloud = [
      id0: RoundEntry(bet: 1, got: nil),
      id1: RoundEntry(bet: 1, got: nil),
      id2: RoundEntry(bet: 1, got: nil),
    ]
    let beforeCloud = Round(
      handSize: 3,
      dealer: id0,
      entries: entriesAfterCloud,
      isFinalized: false,
      cloudCardResolved: false
    )
    XCTAssertFalse(Constraint.GameConstraint.betSumNotEqualHandSize.isSatisfied(round: beforeCloud, players: players))

    let afterCloud = Round(
      handSize: 3,
      dealer: id0,
      entries: entriesAfterCloud,
      isFinalized: false,
      cloudCardResolved: true
    )
    XCTAssertTrue(Constraint.GameConstraint.betSumNotEqualHandSize.isSatisfied(round: afterCloud, players: players))
  }
}

