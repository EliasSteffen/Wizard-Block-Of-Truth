import Foundation
#if canImport(WizardNet)
import WizardNet
#endif

/// What a host needs to resume a multi-phone session after an app relaunch (same code → same Bonjour name, so
/// guests reconnect with their tokens). Stored per game in UserDefaults; the game itself lives in SwiftData.
struct HostSessionRecord: Codable, Equatable {
  var gameID: UUID
  var sessionCode: String
  var hostPlayerId: UUID
  var hostDisplayName: String
  /// Guest token → seat.
  var guestRegistry: [String: RegisteredGuest]
  var revision: Int
}

enum HostSessionPersistence {
  private static let keyPrefix = "multiplayer.hostSession."

  static func load(gameID: UUID, defaults: UserDefaults = .standard) -> HostSessionRecord? {
    guard let data = defaults.data(forKey: key(for: gameID)) else { return nil }
    return try? JSONDecoder().decode(HostSessionRecord.self, from: data)
  }

  static func save(_ record: HostSessionRecord, defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(record) else { return }
    defaults.set(data, forKey: key(for: record.gameID))
  }

  static func clear(gameID: UUID, defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: key(for: gameID))
  }

  private static func key(for gameID: UUID) -> String {
    keyPrefix + gameID.uuidString
  }
}

/// Ids of finished games a guest saved locally from a host's final snapshot. Open them read-only.
enum GuestFinishedGames {
  private static let storageKey = "multiplayer.guestFinishedGames"

  static func all(defaults: UserDefaults = .standard) -> Set<UUID> {
    let raw = defaults.stringArray(forKey: storageKey) ?? []
    return Set(raw.compactMap(UUID.init(uuidString:)))
  }

  static func contains(_ gameID: UUID, defaults: UserDefaults = .standard) -> Bool {
    all(defaults: defaults).contains(gameID)
  }

  static func insert(_ gameID: UUID, defaults: UserDefaults = .standard) {
    var ids = all(defaults: defaults)
    ids.insert(gameID)
    defaults.set(ids.map(\.uuidString).sorted(), forKey: storageKey)
  }

  static func remove(_ gameID: UUID, defaults: UserDefaults = .standard) {
    var ids = all(defaults: defaults)
    guard ids.remove(gameID) != nil else { return }
    defaults.set(ids.map(\.uuidString).sorted(), forKey: storageKey)
  }
}
