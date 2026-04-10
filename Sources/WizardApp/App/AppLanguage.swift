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
}

