import XCTest
@testable import WizardApp

final class CloudCardAdjustmentRulesTests: XCTestCase {
  private let p1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private let p2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  private let p3 = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

  func testAllowedRangeIsPlusMinusOneAroundBaseBet() {
    let base: [UUID: Int] = [p1: 3, p2: 2, p3: 1]
    let edited = base

    let range = CloudCardAdjustmentRules.allowedRange(
      playerId: p1,
      handSize: 8,
      playerIds: [p1, p2, p3],
      baseBets: base,
      editedBets: edited
    )

    XCTAssertEqual(range, 2...4)
  }

  func testAllowedRangeIsClampedToHandBounds() {
    let base: [UUID: Int] = [p1: 0, p2: 8, p3: 4]
    let edited = base

    let lowRange = CloudCardAdjustmentRules.allowedRange(
      playerId: p1,
      handSize: 8,
      playerIds: [p1, p2, p3],
      baseBets: base,
      editedBets: edited
    )
    let highRange = CloudCardAdjustmentRules.allowedRange(
      playerId: p2,
      handSize: 8,
      playerIds: [p1, p2, p3],
      baseBets: base,
      editedBets: edited
    )

    XCTAssertEqual(lowRange, 0...1)
    XCTAssertEqual(highRange, 7...8)
  }

  func testOnceOnePlayerChangedOthersAreLocked() {
    let base: [UUID: Int] = [p1: 3, p2: 2, p3: 1]
    let edited: [UUID: Int] = [p1: 4, p2: 2, p3: 1]

    XCTAssertFalse(
      CloudCardAdjustmentRules.isPlayerLocked(
        playerId: p1,
        playerIds: [p1, p2, p3],
        baseBets: base,
        editedBets: edited
      )
    )
    XCTAssertTrue(
      CloudCardAdjustmentRules.isPlayerLocked(
        playerId: p2,
        playerIds: [p1, p2, p3],
        baseBets: base,
        editedBets: edited
      )
    )
    XCTAssertTrue(
      CloudCardAdjustmentRules.isPlayerLocked(
        playerId: p3,
        playerIds: [p1, p2, p3],
        baseBets: base,
        editedBets: edited
      )
    )
  }

  func testLockedPlayerRangeCollapsesToCurrentValue() {
    let base: [UUID: Int] = [p1: 3, p2: 2, p3: 1]
    let edited: [UUID: Int] = [p1: 4, p2: 2, p3: 1]

    let lockedRange = CloudCardAdjustmentRules.allowedRange(
      playerId: p2,
      handSize: 8,
      playerIds: [p1, p2, p3],
      baseBets: base,
      editedBets: edited
    )

    XCTAssertEqual(lockedRange, 2...2)
  }
}
