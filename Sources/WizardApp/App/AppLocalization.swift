import Foundation

enum AppLocalization {
  static func string(_ key: String, languageCode: String?) -> String {
    guard let languageCode, languageCode != AppLanguage.system.rawValue else {
      return NSLocalizedString(key, comment: "")
    }

    guard
      let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
      let languageBundle = Bundle(path: path)
    else {
      return NSLocalizedString(key, comment: "")
    }

    return NSLocalizedString(key, bundle: languageBundle, comment: "")
  }
}

