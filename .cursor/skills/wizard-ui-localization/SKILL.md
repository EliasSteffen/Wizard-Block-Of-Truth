---
name: wizard-ui-localization
description: >-
  Guides SwiftUI UI work and localization for Wizard Block of Truth: views under
  WizardApp/UI, GameStore patterns, Localizable.xcstrings keys, AppLocalization,
  and user-facing errors. Use when adding screens, Text labels, settings, theming,
  or translating strings.
disable-model-invocation: true
---

# Wizard UI and Localization

## UI code location

- Views: `Sources/WizardApp/UI/`
- App entry: `Sources/WizardApp/WizardApp.swift` — root `GameListView`, `MultiplayerCoordinator` environment, SwiftData container
- Shared chrome: e.g. `WizardBackground.swift`

Follow existing view structure (sheets, navigation, environment objects) in neighboring files before introducing new patterns.

## State and stores

- **`GameStore`** (`@MainActor`, `ObservableObject`) — single-phone games; loads/saves via SwiftData `GameSnapshotEntity`, applies `GameCommand`.
- **`MultiplayerGameStore`** — guest or host-attached multiplayer session view of `currentGame`.
- Prefer **`GameStoring`** protocol when injecting stores for tests.

Surface errors via `lastError` / `AppErrorMessage`; do not swallow domain failures silently.

## Theming and language

- Color scheme: `@AppStorage("app.colorScheme")` + `AppColorScheme` → `preferredColorScheme`
- Language: `@AppStorage("app.language")` + `AppLanguage` → `environment(\.locale, ...)`
- Language changes apply immediately (no app restart).

## Localization

Full baseline: [localization.md](../../../localization.md) (repo root).

| Topic | Rule |
|-------|------|
| Catalog | `Wizard-Block-Of-Truth/Localizable.xcstrings` |
| Dev language | English (`en`); also maintain **German (`de`)** for every real key |
| Key format | Dot-separated namespaces: `settings.appearance.title`, `error.domain.invalidPlayerCount` |
| Static UI | `Text("key")` |
| Dynamic / NSError | `String(localized:)` or `AppLocalization.format(_:languageCode:fallback:)` |
| Format args | One key with placeholders—no string concatenation |

`DomainError` already uses localized keys in `Errors.swift`. App-layer errors should use `AppErrorMessage` / catalog keys, not hardcoded English in production paths.

## After adding or changing keys

`Tests/WizardAppTests/LocalizationCatalogTests.swift` verifies:

- Catalog file exists
- Non-empty entries have **en** and **de**
- Placeholder consistency across locales
- Keys referenced from source exist in the catalog

Run `swift test --filter LocalizationCatalogTests` after string changes.

## Multiplayer UI

Host lobby / join flows: `MultiplayerLobbyView`, `JoinGameView`, `GuestWaitingView`, `GuestGameSessionView`. Respect host vs guest capabilities from `wizard-multiplayer`—disable or hide controls guests must not use.

## Persistence

Game JSON stored on `GameSnapshotEntity` via `GameCodec`. UI should call store methods (`createGame`, `apply`, `replaceCurrentGame`) rather than writing entities directly.
