import Foundation

enum AppLocalization {
  static func string(_ key: String, languageCode: String?) -> String {
    string(key, languageCode: languageCode, fallback: key)
  }

  static func string(_ key: String, languageCode: String?, fallback: String) -> String {
    guard let languageCode, languageCode != AppLanguage.system.rawValue else {
      let localized = NSLocalizedString(key, comment: "")
      return localized == key ? fallback : localized
    }

    guard
      let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
      let languageBundle = Bundle(path: path)
    else {
      let localized = NSLocalizedString(key, comment: "")
      return localized == key ? fallback : localized
    }

    let localized = NSLocalizedString(key, bundle: languageBundle, comment: "")
    return localized == key ? fallback : localized
  }

  static func format(_ key: String, languageCode: String?, fallback: String, _ arguments: CVarArg...) -> String {
    let template = string(key, languageCode: languageCode, fallback: fallback)
    let locale = languageCode.map { Locale(identifier: $0) } ?? .current
    return String(format: template, locale: locale, arguments)
  }
}

