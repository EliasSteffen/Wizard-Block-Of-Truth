import Foundation

enum GuestJoinPreferences {
  static let displayNameKey = "multiplayer.guestDisplayName"
  static let hostDisplayNameKey = "multiplayer.hostDisplayName"

  static var displayName: String {
    get { UserDefaults.standard.string(forKey: displayNameKey) ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: displayNameKey) }
  }

  static var hostDisplayName: String {
    get { UserDefaults.standard.string(forKey: hostDisplayNameKey) ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: hostDisplayNameKey) }
  }
}
