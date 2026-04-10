import Foundation
import XCTest

/// Validates `WizardMobileApp/Localizable.xcstrings`: every real entry has English and German,
/// format placeholders stay consistent across locales, and keys referenced in source exist in the catalog.
final class LocalizationCatalogTests: XCTestCase {
  private static let requiredLocales = ["en", "de"]

  private static var repoRootURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // WizardAppTests
      .deletingLastPathComponent() // Tests
      .deletingLastPathComponent() // repo root
  }

  private static var catalogURL: URL {
    repoRootURL.appendingPathComponent("WizardMobileApp/Localizable.xcstrings")
  }

  func testCatalogFileExists() {
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: Self.catalogURL.path),
      "Expected string catalog at \(Self.catalogURL.path)"
    )
  }

  func testEveryNonEmptyCatalogEntryHasEnglishAndGerman() throws {
    let data = try Data(contentsOf: Self.catalogURL)
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let strings = try XCTUnwrap(root?["strings"] as? [String: Any])

    var failures: [String] = []

    for (key, value) in strings.sorted(by: { $0.key < $1.key }) {
      guard let entry = value as? [String: Any] else { continue }
      let localizations = entry["localizations"] as? [String: Any]

      // Skip Xcode extraction leftovers with no localizations (e.g. "%@").
      guard let localizations, !localizations.isEmpty else { continue }

      for locale in Self.requiredLocales {
        guard let loc = localizations[locale] as? [String: Any] else {
          failures.append("Key \"\(key)\": missing \"\(locale)\" localization")
          continue
        }
        guard let unit = loc["stringUnit"] as? [String: Any] else {
          failures.append("Key \"\(key)\": \"\(locale)\" has no stringUnit")
          continue
        }
        let state = unit["state"] as? String
        if state != "translated" {
          failures.append("Key \"\(key)\": \"\(locale)\" state is \(state ?? "nil"), expected translated")
        }
        let text = (unit["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
          failures.append("Key \"\(key)\": \"\(locale)\" value is empty")
        }
      }
    }

    if !failures.isEmpty {
      XCTFail(
        "\(failures.count) localization issue(s):\n" + failures.joined(separator: "\n")
      )
    }
  }

  func testEverySourceLocalizationKeyExistsInCatalog() throws {
    let data = try Data(contentsOf: Self.catalogURL)
    let rootObj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let catalogStrings = try XCTUnwrap(rootObj?["strings"] as? [String: Any])

    var referencedKeys = Set<String>()
    let sourceRoots = [
      Self.repoRootURL.appendingPathComponent("Sources/WizardApp"),
      Self.repoRootURL.appendingPathComponent("Sources/WizardDomain"),
    ]
    for dir in sourceRoots {
      let enumerator = FileManager.default.enumerator(
        at: dir,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
      while let fileURL = enumerator?.nextObject() as? URL {
        guard fileURL.pathExtension == "swift" else { continue }
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        for key in Self.localizationKeys(in: source) {
          referencedKeys.insert(key)
        }
      }
    }

    var missing: [String] = []
    for key in referencedKeys.sorted() {
      guard catalogStrings[key] != nil else {
        missing.append(key)
        continue
      }
    }

    if !missing.isEmpty {
      XCTFail(
        "\(missing.count) key(s) used in Sources but missing from Localizable.xcstrings:\n"
          + missing.joined(separator: "\n")
      )
    }
  }

  func testFormatPlaceholderCountsMatchBetweenEnglishAndGerman() throws {
    let data = try Data(contentsOf: Self.catalogURL)
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let strings = try XCTUnwrap(root?["strings"] as? [String: Any])

    var failures: [String] = []

    for (key, value) in strings.sorted(by: { $0.key < $1.key }) {
      guard let entry = value as? [String: Any],
            let localizations = entry["localizations"] as? [String: Any],
            !localizations.isEmpty
      else { continue }

      guard let enValue = stringValue(from: localizations, locale: "en"),
            let deValue = stringValue(from: localizations, locale: "de")
      else { continue }

      let enCount = Self.formatSpecifierCount(enValue)
      let deCount = Self.formatSpecifierCount(deValue)
      if enCount != deCount {
        failures.append(
          "Key \"\(key)\": format specifier count en=\(enCount) de=\(deCount)\n  en: \(enValue)\n  de: \(deValue)"
        )
      }
    }

    if !failures.isEmpty {
      XCTFail(
        "\(failures.count) format mismatch(es):\n" + failures.joined(separator: "\n")
      )
    }
  }

  /// `"UI.Foo.Bar"` / `String(localized: "Error....")` / `return "Domain...."` style literals.
  private static func localizationKeys(in source: String) -> [String] {
    let pattern = #""((?:UI|Error|Domain)\.[A-Za-z0-9.]+)""#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let full = NSRange(source.startIndex..., in: source)
    return regex.matches(in: source, range: full).compactMap { match in
      guard match.numberOfRanges >= 2,
            let r = Range(match.range(at: 1), in: source)
      else { return nil }
      return String(source[r])
    }
  }

  private func stringValue(from localizations: [String: Any], locale: String) -> String? {
    guard let loc = localizations[locale] as? [String: Any],
          let unit = loc["stringUnit"] as? [String: Any],
          let value = unit["value"] as? String
    else { return nil }
    return value
  }

  /// Counts format tokens (`%@`, `%lld`, etc.), treating `%%` as a literal percent (not a specifier).
  private static func formatSpecifierCount(_ s: String) -> Int {
    var count = 0
    var i = s.startIndex
    while i < s.endIndex {
      if s[i] == "%" {
        let afterPercent = s.index(after: i)
        if afterPercent < s.endIndex, s[afterPercent] == "%" {
          i = s.index(after: afterPercent)
          continue
        }
        count += 1
      }
      i = s.index(after: i)
    }
    return count
  }
}
