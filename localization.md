# Localization Baseline

This project uses Xcode String Catalogs for app localization.

## Runtime behavior

- Default language follows the system/app language.
- In-app language override uses `@AppStorage("app.language")`.
- Language changes apply immediately by updating SwiftUI `Locale` environment.
- The app does not require restart for language changes.

## Resource strategy

- Primary catalog: `Wizard-Block-Of-Truth/Localizable.xcstrings`
- Development language: English (`en`)
- Additional languages are added later by inserting language variants in the catalog.

## Key naming

- Use stable, dot-separated keys.
- Prefer namespaces by feature and purpose:
  - `settings.appearance.title`
  - `gameList.emptyState.title`
  - `error.domain.invalidPlayerCount`
- For dynamic values, keep one key and pass format arguments instead of string concatenation.

## Usage guidance

- Static UI labels: `Text("key")`
- Dynamic strings: `String(localized: "key")` or `String(localized: "key \(value)")` patterns with catalog support.
- User-facing errors should resolve through localization keys, not hardcoded English.

