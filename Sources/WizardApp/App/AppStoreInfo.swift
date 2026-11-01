import Foundation

/// App Store identity of Wizard Block of Truth, shared by the review prompt, the Settings "Rate the app"
/// row, and the update check.
enum AppStoreInfo {
  static let appID = "6761933762"

  /// Product page; fallback target for "Update" when the lookup returns no `trackViewUrl`.
  static let appStoreURL = URL(string: "https://apps.apple.com/app/id\(appID)")!

  /// Opens the App Store directly on the "Write a Review" sheet.
  static let writeReviewURL = URL(string: "https://apps.apple.com/app/id\(appID)?action=write-review")!

  /// Public iTunes Search API lookup for this app (no user data is sent besides the optional storefront).
  static func lookupURL(countryCode: String?) -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "itunes.apple.com"
    components.path = "/lookup"
    var queryItems = [URLQueryItem(name: "id", value: appID)]
    if let countryCode {
      queryItems.append(URLQueryItem(name: "country", value: countryCode))
    }
    components.queryItems = queryItems
    return components.url ?? URL(string: "https://itunes.apple.com/lookup?id=\(appID)")!
  }

  /// `CFBundleShortVersionString` of the running app; `nil` when the bundle has none (e.g. under `swift test`).
  static var currentAppVersion: String? {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    guard let version, !version.isEmpty else { return nil }
    return version
  }
}
