import XCTest
@testable import WizardDomain

final class ScoringTests: XCTestCase {
  func testClassicScoring_exactMatch() throws {
    XCTAssertEqual(try RoundEntry(bet: 0, got: 0).pointsDelta(), 20)
    XCTAssertEqual(try RoundEntry(bet: 3, got: 3).pointsDelta(), 50)
  }

  func testClassicScoring_miss() throws {
    XCTAssertEqual(try RoundEntry(bet: 3, got: 1).pointsDelta(), -20)
    XCTAssertEqual(try RoundEntry(bet: 0, got: 2).pointsDelta(), -20)
  }
}

