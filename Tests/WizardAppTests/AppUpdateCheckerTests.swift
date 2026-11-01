import XCTest
@testable import WizardApp

/// Stand-in for the iTunes lookup request; never touches the network.
private actor FakeAppStoreLookup {
  typealias Responder = @Sendable (URL) throws -> Data

  private(set) var requestedURLs: [URL] = []
  private var responder: Responder

  init(responder: @escaping Responder) {
    self.responder = responder
  }

  func setResponder(_ responder: @escaping Responder) {
    self.responder = responder
  }

  func fetch(_ url: URL) throws -> Data {
    requestedURLs.append(url)
    return try responder(url)
  }
}

private final class TestClock {
  var now: Date

  init(_ now: Date) {
    self.now = now
  }
}

private enum LookupFixture {
  static let trackViewURL = "https://apps.apple.com/de/app/wizard-block-of-truth/id6761933762?uo=4"
  static let empty = Data(#"{"resultCount":0,"results":[]}"#.utf8)

  static func release(_ version: String, trackViewUrl: String? = LookupFixture.trackViewURL) -> Data {
    var fields = [#""version":"\#(version)""#, #""trackName":"Wizard Block of Truth""#]
    if let trackViewUrl {
      fields.append(#""trackViewUrl":"\#(trackViewUrl)""#)
    }
    let result = fields.joined(separator: ",")
    return Data(#"{"resultCount":1,"results":[{\#(result)}]}"#.utf8)
  }

  static func hasCountry(_ url: URL) -> Bool {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "country" } == true
  }
}

@MainActor
final class AppUpdateCheckerTests: XCTestCase {
  private var start: Date { Date(timeIntervalSince1970: 1_800_000_000) }
  private var hour: TimeInterval { 60 * 60 }

  private func makeDefaults() -> UserDefaults {
    let suiteName = "AppUpdateCheckerTests.\(UUID().uuidString)"
    addTeardownBlock {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    return UserDefaults(suiteName: suiteName)!
  }

  private func makeChecker(
    defaults: UserDefaults,
    currentVersion: String? = "1.2",
    regionCode: String? = nil,
    clock: TestClock,
    lookup: FakeAppStoreLookup
  ) -> AppUpdateChecker {
    AppUpdateChecker(
      defaults: defaults,
      currentVersion: currentVersion,
      regionCode: regionCode,
      now: { clock.now },
      fetchData: { url in try await lookup.fetch(url) }
    )
  }

  func testDoesNothingWithoutBundleVersion() async {
    let defaults = makeDefaults()
    let data = LookupFixture.release("9.9")
    let lookup = FakeAppStoreLookup { _ in data }
    let checker = makeChecker(defaults: defaults, currentVersion: nil, clock: TestClock(start), lookup: lookup)

    await checker.checkIfNeeded()

    XCTAssertNil(checker.availableUpdate)
    let requested = await lookup.requestedURLs
    XCTAssertTrue(requested.isEmpty)
    XCTAssertNil(defaults.object(forKey: AppUpdateChecker.DefaultsKey.lastCheckDate))
  }

  func testOffersNewerStoreVersionWithTrackViewURL() async {
    let data = LookupFixture.release("1.3")
    let lookup = FakeAppStoreLookup { _ in data }
    let checker = makeChecker(defaults: makeDefaults(), clock: TestClock(start), lookup: lookup)

    await checker.checkIfNeeded()

    XCTAssertEqual(
      checker.availableUpdate,
      AvailableAppUpdate(version: "1.3", storeURL: URL(string: LookupFixture.trackViewURL)!)
    )
    let requested = await lookup.requestedURLs
    XCTAssertEqual(requested, [AppStoreInfo.lookupURL(countryCode: nil)])
  }

  func testComparesVersionsNumerically() async {
    let newerData = LookupFixture.release("1.10")
    let newer = makeChecker(
      defaults: makeDefaults(),
      currentVersion: "1.9",
      clock: TestClock(start),
      lookup: FakeAppStoreLookup { _ in newerData }
    )
    await newer.checkIfNeeded()
    XCTAssertEqual(newer.availableUpdate?.version, "1.10")

    let olderData = LookupFixture.release("1.9")
    let older = makeChecker(
      defaults: makeDefaults(),
      currentVersion: "1.10",
      clock: TestClock(start),
      lookup: FakeAppStoreLookup { _ in olderData }
    )
    await older.checkIfNeeded()
    XCTAssertNil(older.availableUpdate)
  }

  func testSameVersionWithTrailingZeroIsNotAnUpdate() async {
    let data = LookupFixture.release("1.2.0")
    let checker = makeChecker(
      defaults: makeDefaults(),
      currentVersion: "1.2",
      clock: TestClock(start),
      lookup: FakeAppStoreLookup { _ in data }
    )

    await checker.checkIfNeeded()

    XCTAssertNil(checker.availableUpdate)
  }

  func testChecksAtMostOncePer24Hours() async {
    let clock = TestClock(start)
    let data = LookupFixture.release("1.2")
    let lookup = FakeAppStoreLookup { _ in data }
    let checker = makeChecker(defaults: makeDefaults(), clock: clock, lookup: lookup)

    await checker.checkIfNeeded()
    await checker.checkIfNeeded()
    clock.now = start.addingTimeInterval(23 * hour)
    await checker.checkIfNeeded()
    var requested = await lookup.requestedURLs
    XCTAssertEqual(requested.count, 1)

    clock.now = start.addingTimeInterval(24 * hour)
    await checker.checkIfNeeded()
    requested = await lookup.requestedURLs
    XCTAssertEqual(requested.count, 2)
  }

  func testThrottleIsSharedThroughUserDefaults() async {
    let defaults = makeDefaults()
    let clock = TestClock(start)
    let data = LookupFixture.release("1.2")
    let lookup = FakeAppStoreLookup { _ in data }

    await makeChecker(defaults: defaults, clock: clock, lookup: lookup).checkIfNeeded()
    clock.now = start.addingTimeInterval(hour)
    await makeChecker(defaults: defaults, clock: clock, lookup: lookup).checkIfNeeded()

    let requested = await lookup.requestedURLs
    XCTAssertEqual(requested.count, 1)
  }

  func testChecksAgainWhenClockMovedBackwards() async {
    let clock = TestClock(start)
    let data = LookupFixture.release("1.2")
    let lookup = FakeAppStoreLookup { _ in data }
    let checker = makeChecker(defaults: makeDefaults(), clock: clock, lookup: lookup)

    await checker.checkIfNeeded()
    clock.now = start.addingTimeInterval(-hour)
    await checker.checkIfNeeded()

    let requested = await lookup.requestedURLs
    XCTAssertEqual(requested.count, 2)
  }

  func testLaterOffersUpdateAgainAfterThrottle() async {
    let clock = TestClock(start)
    let data = LookupFixture.release("1.3")
    let lookup = FakeAppStoreLookup { _ in data }
    let checker = makeChecker(defaults: makeDefaults(), clock: clock, lookup: lookup)

    await checker.checkIfNeeded()
    XCTAssertEqual(checker.availableUpdate?.version, "1.3")

    checker.dismissUpdate()
    XCTAssertNil(checker.availableUpdate)

    clock.now = start.addingTimeInterval(hour)
    await checker.checkIfNeeded()
    XCTAssertNil(checker.availableUpdate)

    clock.now = start.addingTimeInterval(25 * hour)
    await checker.checkIfNeeded()
    XCTAssertEqual(checker.availableUpdate?.version, "1.3")
  }

  func testSkipThisVersionSuppressesOnlyThatVersion() async {
    let defaults = makeDefaults()
    let clock = TestClock(start)
    let data13 = LookupFixture.release("1.3")
    let lookup = FakeAppStoreLookup { _ in data13 }
    let checker = makeChecker(defaults: defaults, clock: clock, lookup: lookup)

    await checker.checkIfNeeded()
    guard let update = checker.availableUpdate else {
      return XCTFail("Expected version 1.3 to be offered")
    }
    XCTAssertEqual(update.version, "1.3")
    checker.skipVersion(of: update)
    XCTAssertNil(checker.availableUpdate)
    XCTAssertEqual(defaults.string(forKey: AppUpdateChecker.DefaultsKey.skippedVersion), "1.3")

    // Relaunch after the throttle: the skipped version stays hidden.
    clock.now = start.addingTimeInterval(25 * hour)
    let relaunched = makeChecker(defaults: defaults, clock: clock, lookup: lookup)
    await relaunched.checkIfNeeded()
    XCTAssertNil(relaunched.availableUpdate)
    var requested = await lookup.requestedURLs
    XCTAssertEqual(requested.count, 2)

    // A later release is offered again.
    let data14 = LookupFixture.release("1.4")
    await lookup.setResponder { _ in data14 }
    clock.now = start.addingTimeInterval(50 * hour)
    await relaunched.checkIfNeeded()
    XCTAssertEqual(relaunched.availableUpdate?.version, "1.4")
    requested = await lookup.requestedURLs
    XCTAssertEqual(requested.count, 3)
  }

  func testUsesStorefrontCountryFromRegion() async {
    let data = LookupFixture.release("1.3")
    let lookup = FakeAppStoreLookup { _ in data }
    let checker = makeChecker(defaults: makeDefaults(), regionCode: "DE", clock: TestClock(start), lookup: lookup)

    await checker.checkIfNeeded()

    XCTAssertEqual(checker.availableUpdate?.version, "1.3")
    let requested = await lookup.requestedURLs
    XCTAssertEqual(requested, [AppStoreInfo.lookupURL(countryCode: "de")])
    XCTAssertEqual(
      requested.first?.absoluteString,
      "https://itunes.apple.com/lookup?id=6761933762&country=de"
    )
  }

  func testRetriesWithoutCountryWhenStorefrontHasNoResult() async {
    let empty = LookupFixture.empty
    let release = LookupFixture.release("1.3")
    let lookup = FakeAppStoreLookup { url in
      LookupFixture.hasCountry(url) ? empty : release
    }
    let checker = makeChecker(defaults: makeDefaults(), regionCode: "DE", clock: TestClock(start), lookup: lookup)

    await checker.checkIfNeeded()

    XCTAssertEqual(checker.availableUpdate?.version, "1.3")
    let requested = await lookup.requestedURLs
    XCTAssertEqual(
      requested,
      [AppStoreInfo.lookupURL(countryCode: "de"), AppStoreInfo.lookupURL(countryCode: nil)]
    )
    XCTAssertEqual(requested.last?.absoluteString, "https://itunes.apple.com/lookup?id=6761933762")
  }

  func testIgnoresRegionsThatAreNotTwoLetterCodes() async {
    let data = LookupFixture.release("1.3")
    let lookup = FakeAppStoreLookup { _ in data }
    let checker = makeChecker(defaults: makeDefaults(), regionCode: "419", clock: TestClock(start), lookup: lookup)

    await checker.checkIfNeeded()

    let requested = await lookup.requestedURLs
    XCTAssertEqual(requested, [AppStoreInfo.lookupURL(countryCode: nil)])
  }

  func testSilentOnNetworkErrorAndStillThrottles() async {
    let defaults = makeDefaults()
    let clock = TestClock(start)
    let lookup = FakeAppStoreLookup { _ in throw URLError(.notConnectedToInternet) }
    let checker = makeChecker(defaults: defaults, regionCode: "DE", clock: clock, lookup: lookup)

    await checker.checkIfNeeded()

    XCTAssertNil(checker.availableUpdate)
    let requested = await lookup.requestedURLs
    XCTAssertEqual(requested.count, 1, "A failed storefront request must not fall back to another request")
    XCTAssertEqual(defaults.object(forKey: AppUpdateChecker.DefaultsKey.lastCheckDate) as? Date, start)
  }

  func testSilentOnMalformedResponse() async {
    let garbage = Data("<html>Service Unavailable</html>".utf8)
    let checker = makeChecker(
      defaults: makeDefaults(),
      clock: TestClock(start),
      lookup: FakeAppStoreLookup { _ in garbage }
    )

    await checker.checkIfNeeded()

    XCTAssertNil(checker.availableUpdate)
  }

  func testFallsBackToProductPageWithoutTrackViewURL() async {
    let data = LookupFixture.release("2.0", trackViewUrl: nil)
    let checker = makeChecker(
      defaults: makeDefaults(),
      clock: TestClock(start),
      lookup: FakeAppStoreLookup { _ in data }
    )

    await checker.checkIfNeeded()

    XCTAssertEqual(checker.availableUpdate, AvailableAppUpdate(version: "2.0", storeURL: AppStoreInfo.appStoreURL))
    XCTAssertEqual(AppStoreInfo.appStoreURL.absoluteString, "https://apps.apple.com/app/id6761933762")
  }

  func testParseReleaseReadsFirstResult() throws {
    let release = try AppStoreLookup.parseRelease(from: LookupFixture.release("1.5"))
    XCTAssertEqual(
      release,
      AppStoreLookup.Release(version: "1.5", trackViewURL: URL(string: LookupFixture.trackViewURL))
    )
    XCTAssertNil(try AppStoreLookup.parseRelease(from: LookupFixture.empty))
    XCTAssertThrowsError(try AppStoreLookup.parseRelease(from: Data("nope".utf8)))
  }
}
