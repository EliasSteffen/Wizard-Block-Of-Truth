import Foundation

public enum PlayerNaming {
  private static let supportedLanguageCodes = ["en", "de"]

  public static func placeholderName(playerNumber: Int, languageCode: String? = nil) -> String {
    let code = languageCode ?? "en"
    let locale = Locale(identifier: code)
    switch code {
    case "de":
      return String(
        localized: "UI.NewGame.Player.Placeholder",
        defaultValue: "Spieler \(playerNumber)",
        locale: locale
      )
    default:
      return String(
        localized: "UI.NewGame.Player.Placeholder",
        defaultValue: "Player \(playerNumber)",
        locale: locale
      )
    }
  }

  public static func isPlaceholderName(_ name: String, playerNumber: Int) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    return supportedLanguageCodes.contains { code in
      trimmed == placeholderName(playerNumber: playerNumber, languageCode: code)
    }
  }
}
