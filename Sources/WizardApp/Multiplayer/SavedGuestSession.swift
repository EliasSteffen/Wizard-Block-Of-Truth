import Foundation

struct SavedGuestSession: Codable, Equatable {
  var guestToken: String
  var sessionCode: String
  var playerId: UUID
  var playerName: String
  var hostDisplayName: String?

  private static let storageKey = "multiplayer.savedGuestSession"

  static func load() -> SavedGuestSession? {
    guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
    return try? JSONDecoder().decode(SavedGuestSession.self, from: data)
  }

  static func save(_ session: SavedGuestSession) {
    guard let data = try? JSONEncoder().encode(session) else { return }
    UserDefaults.standard.set(data, forKey: storageKey)
  }

  static func clear() {
    UserDefaults.standard.removeObject(forKey: storageKey)
  }
}
