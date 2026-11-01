import Foundation

/// Decides when to ask for an App Store rating after a game finishes.
///
/// Rules: every game counts at most once (finished game ids are persisted), a review is requested only once
/// at least `minimumFinishedGames` distinct games were finished on this device, and at most once per app
/// version (`CFBundleShortVersionString`). iOS applies its own rate limit on top of that.
struct ReviewPromptPolicy {
  static let minimumFinishedGames = 2

  /// Delay between the final scoreboard appearing and the system review prompt.
  static let requestDelay: Duration = .milliseconds(1500)

  enum DefaultsKey {
    static let finishedGameIDs = "reviewPrompt.finishedGameIDs"
    static let lastPromptedVersion = "reviewPrompt.lastPromptedVersion"
  }

  private let defaults: UserDefaults
  private let appVersion: String?

  init(defaults: UserDefaults = .standard, appVersion: String? = AppStoreInfo.currentAppVersion) {
    self.defaults = defaults
    self.appVersion = appVersion
  }

  /// Number of distinct games recorded as finished on this device.
  var finishedGameCount: Int {
    finishedGameIDs.count
  }

  /// Records `gameId` as finished (only the first time) and returns whether a review should be requested now.
  /// When `true` is returned, the current app version is marked as prompted.
  @discardableResult
  func recordFinishedGame(_ gameId: UUID) -> Bool {
    var ids = finishedGameIDs
    let idString = gameId.uuidString
    guard !ids.contains(idString) else { return false }
    ids.append(idString)
    defaults.set(ids, forKey: DefaultsKey.finishedGameIDs)

    guard ids.count >= Self.minimumFinishedGames else { return false }
    guard let appVersion, !appVersion.isEmpty else { return false }
    guard defaults.string(forKey: DefaultsKey.lastPromptedVersion) != appVersion else { return false }

    defaults.set(appVersion, forKey: DefaultsKey.lastPromptedVersion)
    return true
  }

  private var finishedGameIDs: [String] {
    defaults.stringArray(forKey: DefaultsKey.finishedGameIDs) ?? []
  }
}
