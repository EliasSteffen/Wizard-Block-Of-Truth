import XCTest
@testable import WizardApp

final class AppVersionTests: XCTestCase {
  private func version(_ string: String, file: StaticString = #filePath, line: UInt = #line) -> AppVersion {
    guard let parsed = AppVersion(string) else {
      XCTFail("Expected \"\(string)\" to parse as a version", file: file, line: line)
      return AppVersion("0")!
    }
    return parsed
  }

  func testParsesDottedNumericVersions() {
    XCTAssertEqual(AppVersion("1.2.3")?.components, [1, 2, 3])
    XCTAssertEqual(AppVersion("7")?.components, [7])
    XCTAssertEqual(AppVersion(" 2.0 ")?.components, [2, 0])
    XCTAssertEqual(AppVersion("01.2")?.description, "1.2")
  }

  func testRejectsNonNumericVersions() {
    for invalid in ["", " ", "1..2", "1.", ".1", "1.a", "abc", "-1", "+1", "1.2-beta", "1 .2"] {
      XCTAssertNil(AppVersion(invalid), "Expected \"\(invalid)\" to be rejected")
    }
  }

  func testComparesComponentsNumerically() {
    XCTAssertGreaterThan(version("1.10"), version("1.9"))
    XCTAssertLessThan(version("1.9"), version("1.10"))
    XCTAssertGreaterThan(version("2.0"), version("1.99.99"))
    XCTAssertLessThan(version("0.9"), version("1.0"))
    XCTAssertLessThan(version("1.2"), version("1.3"))
  }

  func testMissingTrailingComponentsCountAsZero() {
    XCTAssertEqual(version("1.2"), version("1.2.0"))
    XCTAssertEqual(version("1"), version("1.0.0"))
    XCTAssertFalse(version("1.2") < version("1.2.0"))
    XCTAssertFalse(version("1.2.0") < version("1.2"))
    XCTAssertGreaterThan(version("1.2.1"), version("1.2"))
    XCTAssertLessThan(version("1.2"), version("1.2.1"))
  }
}
