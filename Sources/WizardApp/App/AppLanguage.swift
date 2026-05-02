import Foundation

enum AppLanguage: String, CaseIterable, Codable, Hashable {
  case system
  case english = "en"
  case german = "de"

  var titleKey: String {
    switch self {
    case .system:
      return "UI.Settings.Language.Option.System"
    case .english:
      return "UI.Settings.Language.Option.English"
    case .german:
      return "UI.Settings.Language.Option.German"
    }
  }

  var locale: Locale {
    switch self {
    case .system:
      return .autoupdatingCurrent
    case .english:
      return Locale(identifier: rawValue)
    case .german:
      return Locale(identifier: rawValue)
    }
  }

  /// Matches Settings → Language for explicit `en`/`de` string catalog lookups (`nil` = follow system bundles).
  static var catalogLookupLanguageCode: String? {
    let raw = UserDefaults.standard.string(forKey: "app.language") ?? AppLanguage.system.rawValue
    let selected = AppLanguage(rawValue: raw) ?? .system
    return selected == .system ? nil : selected.rawValue
  }
}

