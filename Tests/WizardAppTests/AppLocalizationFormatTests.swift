import XCTest
@testable import WizardApp

/// Regression: `AppLocalization.format` used to forward its variadic arguments as one array argument, so messages
/// rendered as "Waiting for (\n    Anna\n)" or with garbage numbers.
final class AppLocalizationFormatTests: XCTestCase {
  func testFormatForwardsEachArgumentSeparately() {
    let message = AppLocalization.format(
      "Test.AppLocalizationFormat.MissingKey",
      languageCode: nil,
      fallback: "Waiting for %lld players: %@",
      Int64(2),
      "Anna, Ben"
    )
    XCTAssertEqual(message, "Waiting for 2 players: Anna, Ben")
  }

  func testFormatWithSingleStringArgument() {
    let message = AppLocalization.format(
      "Test.AppLocalizationFormat.MissingKey",
      languageCode: nil,
      fallback: "Version %@ is available.",
      "1.3"
    )
    XCTAssertEqual(message, "Version 1.3 is available.")
  }
}
