import Foundation
import Combine

/// A newer App Store release than the running app.
struct AvailableAppUpdate: Equatable, Sendable {
  let version: String
  let storeURL: URL
}

/// iTunes Search API lookup (`https://itunes.apple.com/lookup?id=…`): response decoding and the live request.
enum AppStoreLookup {
  struct Release: Equatable, Sendable {
    let version: String
    let trackViewURL: URL?
  }

  struct Response: Decodable, Sendable {
    let results: [Entry]?
  }

  struct Entry: Decodable, Sendable {
    let version: String?
    let trackViewUrl: String?
  }

  /// Returns the first result's release, or `nil` when the lookup has no (usable) result.
  /// Throws when `data` is not a lookup response.
  static func parseRelease(from data: Data) throws -> Release? {
    let response = try JSONDecoder().decode(Response.self, from: data)
    guard let entry = response.results?.first,
          let version = entry.version?.trimmingCharacters(in: .whitespacesAndNewlines),
          !version.isEmpty
    else { return nil }

    var trackViewURL: URL?
    if let urlString = entry.trackViewUrl,
       let url = URL(string: urlString),
       url.scheme?.lowercased() == "https" {
      trackViewURL = url
    }
    return Release(version: version, trackViewURL: trackViewURL)
  }

  /// Lower-cased two-letter storefront code for a region identifier (`"DE"` → `"de"`); `nil` otherwise
  /// (e.g. numeric UN M.49 regions such as `"419"`).
  static func storefrontCountryCode(fromRegion region: String?) -> String? {
    guard let region else { return nil }
    let code = region.lowercased()
    guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
    return code
  }

  static func fetchData(from url: URL) async throws -> Data {
    let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
          (200..<300).contains(httpResponse.statusCode)
    else { throw URLError(.badServerResponse) }
    return data
  }
}

/// Checks the App Store for a newer version on launch / when returning to the foreground, at most once per
/// `checkInterval`. Never blocks the app and stays silent on any network or parse error.
@MainActor
final class AppUpdateChecker: ObservableObject {
  typealias FetchData = @Sendable (URL) async throws -> Data

  static let checkInterval: TimeInterval = 24 * 60 * 60

  enum DefaultsKey {
    static let lastCheckDate = "updateCheck.lastCheckDate"
    static let skippedVersion = "updateCheck.skippedVersion"
  }

  /// Non-nil while the "Update available" alert should be shown.
  @Published private(set) var availableUpdate: AvailableAppUpdate?

  private let defaults: UserDefaults
  private let currentVersion: String?
  private let regionCode: String?
  private let now: () -> Date
  private let fetchData: FetchData
  private var isChecking = false

  init(
    defaults: UserDefaults = .standard,
    currentVersion: String? = AppStoreInfo.currentAppVersion,
    regionCode: String? = Locale.current.region?.identifier,
    now: @escaping () -> Date = { Date() },
    fetchData: @escaping FetchData = { url in try await AppStoreLookup.fetchData(from: url) }
  ) {
    self.defaults = defaults
    self.currentVersion = currentVersion
    self.regionCode = regionCode
    self.now = now
    self.fetchData = fetchData
  }

  /// Queries the App Store unless a check happened within `checkInterval`; publishes `availableUpdate` when the
  /// store version is newer than the running one and was not skipped.
  func checkIfNeeded() async {
    guard !isChecking, availableUpdate == nil else { return }
    guard let currentVersion, let installedVersion = AppVersion(currentVersion) else { return }

    let checkDate = now()
    if let lastCheck = defaults.object(forKey: DefaultsKey.lastCheckDate) as? Date {
      let elapsed = checkDate.timeIntervalSince(lastCheck)
      // A negative interval means the clock was moved back; check again rather than waiting.
      if elapsed >= 0, elapsed < Self.checkInterval { return }
    }

    // Record the attempt before going to the network so concurrent triggers (launch + `.active`) and
    // failing requests still query at most once per interval.
    defaults.set(checkDate, forKey: DefaultsKey.lastCheckDate)
    isChecking = true
    defer { isChecking = false }

    guard let release = await fetchLatestRelease(),
          let storeVersion = AppVersion(release.version),
          storeVersion > installedVersion
    else { return }

    if let skipped = defaults.string(forKey: DefaultsKey.skippedVersion).flatMap({ AppVersion($0) }),
       storeVersion <= skipped {
      return
    }

    availableUpdate = AvailableAppUpdate(
      version: release.version,
      storeURL: release.trackViewURL ?? AppStoreInfo.appStoreURL
    )
  }

  /// "Later": hide the alert; the next check after `checkInterval` may show it again.
  func dismissUpdate() {
    availableUpdate = nil
  }

  /// "Skip this version": never ask again for `update.version` (later versions are still offered).
  func skipVersion(of update: AvailableAppUpdate) {
    defaults.set(update.version, forKey: DefaultsKey.skippedVersion)
    availableUpdate = nil
  }

  /// Storefront lookup first; when that storefront has no result, retry once without `country`.
  private func fetchLatestRelease() async -> AppStoreLookup.Release? {
    do {
      if let country = AppStoreLookup.storefrontCountryCode(fromRegion: regionCode) {
        let data = try await fetchData(AppStoreInfo.lookupURL(countryCode: country))
        if let release = try AppStoreLookup.parseRelease(from: data) {
          return release
        }
      }
      let data = try await fetchData(AppStoreInfo.lookupURL(countryCode: nil))
      return try AppStoreLookup.parseRelease(from: data)
    } catch {
      return nil
    }
  }
}
