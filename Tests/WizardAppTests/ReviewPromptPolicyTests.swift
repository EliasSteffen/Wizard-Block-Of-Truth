import XCTest
@testable import WizardApp

final class ReviewPromptPolicyTests: XCTestCase {
  private let gameA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
  private let gameB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
  private let gameC = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
  private let gameD = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!

  private func makeDefaults() -> UserDefaults {
    let suiteName = "ReviewPromptPolicyTests.\(UUID().uuidString)"
    addTeardownBlock {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    return UserDefaults(suiteName: suiteName)!
  }

  func testFirstFinishedGameDoesNotRequestReview() {
    let policy = ReviewPromptPolicy(defaults: makeDefaults(), appVersion: "1.1")

    XCTAssertFalse(policy.recordFinishedGame(gameA))
    XCTAssertEqual(policy.finishedGameCount, 1)
  }

  func testSecondDistinctFinishedGameRequestsReview() {
    let policy = ReviewPromptPolicy(defaults: makeDefaults(), appVersion: "1.1")

    XCTAssertFalse(policy.recordFinishedGame(gameA))
    XCTAssertTrue(policy.recordFinishedGame(gameB))
    XCTAssertEqual(policy.finishedGameCount, 2)
  }

  func testSameGameIsCountedOnlyOnce() {
    let policy = ReviewPromptPolicy(defaults: makeDefaults(), appVersion: "1.1")

    XCTAssertFalse(policy.recordFinishedGame(gameA))
    XCTAssertFalse(policy.recordFinishedGame(gameA))
    XCTAssertEqual(policy.finishedGameCount, 1)

    XCTAssertTrue(policy.recordFinishedGame(gameB))
  }

  func testRequestsAtMostOncePerAppVersion() {
    let defaults = makeDefaults()
    let v11 = ReviewPromptPolicy(defaults: defaults, appVersion: "1.1")

    XCTAssertFalse(v11.recordFinishedGame(gameA))
    XCTAssertTrue(v11.recordFinishedGame(gameB))
    XCTAssertFalse(v11.recordFinishedGame(gameC))
    XCTAssertEqual(v11.finishedGameCount, 3)

    let v12 = ReviewPromptPolicy(defaults: defaults, appVersion: "1.2")
    XCTAssertTrue(v12.recordFinishedGame(gameD))
  }

  func testRefinishedGameDoesNotRequestReviewInNewVersion() {
    let defaults = makeDefaults()
    let v11 = ReviewPromptPolicy(defaults: defaults, appVersion: "1.1")
    XCTAssertFalse(v11.recordFinishedGame(gameA))
    XCTAssertTrue(v11.recordFinishedGame(gameB))

    let v12 = ReviewPromptPolicy(defaults: defaults, appVersion: "1.2")
    XCTAssertFalse(v12.recordFinishedGame(gameA))
    XCTAssertEqual(v12.finishedGameCount, 2)
    XCTAssertTrue(v12.recordFinishedGame(gameC))
  }

  func testCountsPersistAcrossInstances() {
    let defaults = makeDefaults()

    XCTAssertFalse(ReviewPromptPolicy(defaults: defaults, appVersion: "1.1").recordFinishedGame(gameA))
    XCTAssertTrue(ReviewPromptPolicy(defaults: defaults, appVersion: "1.1").recordFinishedGame(gameB))
  }

  func testDoesNotRequestReviewWithoutAppVersionButStillCounts() {
    let defaults = makeDefaults()
    let unversioned = ReviewPromptPolicy(defaults: defaults, appVersion: nil)

    XCTAssertFalse(unversioned.recordFinishedGame(gameA))
    XCTAssertFalse(unversioned.recordFinishedGame(gameB))
    XCTAssertEqual(unversioned.finishedGameCount, 2)

    let versioned = ReviewPromptPolicy(defaults: defaults, appVersion: "1.1")
    XCTAssertTrue(versioned.recordFinishedGame(gameC))
  }
}
