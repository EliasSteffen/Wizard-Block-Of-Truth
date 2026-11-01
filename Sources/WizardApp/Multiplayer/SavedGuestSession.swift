import Foundation

/// Rejoin data of the guest's current multi-phone session (persisted at `claimAccepted`).
///
/// Cleared only when the session really ends (host ended / game finished / kicked / seat released / left) — and
/// only by the token that saved it, so an older session can never clear a newer one.
struct SavedGuestSession: Codable, Equatable {
  var guestToken: String
  var sessionCode: String
  var playerId: UUID
  var playerName: String
  var hostDisplayName: String?
  /// Host's Bonjour service name: rejoin connects by name, no browse result needed. `nil` for sessions saved by
  /// app 1.1.
  var serviceName: String?
  var gameName: String?

  private static let storageKey = "multiplayer.savedGuestSession"

  static func load(defaults: UserDefaults = .standard) -> SavedGuestSession? {
    guard let data = defaults.data(forKey: storageKey) else { return nil }
    return try? JSONDecoder().decode(SavedGuestSession.self, from: data)
  }

  static func save(_ session: SavedGuestSession, defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(session) else { return }
    defaults.set(data, forKey: storageKey)
  }

  /// Unconditionally forgets the saved session (user tapped "Forget").
  static func clear(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: storageKey)
  }

  /// Forgets the saved session only if it belongs to `token`.
  static func clear(token: String, defaults: UserDefaults = .standard) {
    guard load(defaults: defaults)?.guestToken == token else { return }
    clear(defaults: defaults)
  }
}
