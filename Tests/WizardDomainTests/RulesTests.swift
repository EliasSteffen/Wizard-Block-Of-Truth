import XCTest
@testable import WizardDomain

final class RulesTests: XCTestCase {
  func testMaxHandSizeClassic() throws {
    XCTAssertEqual(Rules.maxHandSize(deckSize: 60, playerCount: 2), 30)
    XCTAssertEqual(Rules.maxHandSize(deckSize: 60, playerCount: 6), 10)
  }
}

