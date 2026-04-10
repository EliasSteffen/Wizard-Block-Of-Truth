import SwiftUI

enum AppColorScheme: String, CaseIterable, Codable, Hashable {
  case system
  case light
  case dark

  var titleKey: String {
    switch self {
    case .system: return "UI.Settings.Appearance.Option.System"
    case .light: return "UI.Settings.Appearance.Option.Light"
    case .dark: return "UI.Settings.Appearance.Option.Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: return nil
    case .light: return .light
    case .dark: return .dark
    }
  }
}

