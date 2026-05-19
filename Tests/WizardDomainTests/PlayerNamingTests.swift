import XCTest
@testable import WizardDomain

final class PlayerNamingTests: XCTestCase {
  func testPlaceholderNameEnglish() {
    XCTAssertEqual(PlayerNaming.placeholderName(playerNumber: 1, languageCode: "en"), "Player 1")
    XCTAssertEqual(PlayerNaming.placeholderName(playerNumber: 3, languageCode: "en"), "Player 3")
  }

  func testPlaceholderNameGerman() {
    XCTAssertEqual(PlayerNaming.placeholderName(playerNumber: 1, languageCode: "de"), "Spieler 1")
    XCTAssertEqual(PlayerNaming.placeholderName(playerNumber: 2, languageCode: "de"), "Spieler 2")
  }

  func testIsPlaceholderNameMatchesEnglishAndGerman() {
    XCTAssertTrue(PlayerNaming.isPlaceholderName("Player 2", playerNumber: 2))
    XCTAssertTrue(PlayerNaming.isPlaceholderName("Spieler 2", playerNumber: 2))
    XCTAssertTrue(PlayerNaming.isPlaceholderName("  Player 2  ", playerNumber: 2))
  }

  func testIsPlaceholderNameRejectsCustomNames() {
    XCTAssertFalse(PlayerNaming.isPlaceholderName("Alice", playerNumber: 1))
    XCTAssertFalse(PlayerNaming.isPlaceholderName("Player 2", playerNumber: 1))
    XCTAssertFalse(PlayerNaming.isPlaceholderName("", playerNumber: 1))
  }
}
