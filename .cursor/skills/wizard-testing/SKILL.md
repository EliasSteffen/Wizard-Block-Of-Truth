---
name: wizard-testing
description: >-
  Explains how to run and write tests for Wizard Block of Truth: WizardDomainTests,
  WizardNetTests, WizardAppTests, swift test commands, and common XCTest patterns.
  Use when adding tests, fixing regressions, or verifying rule/net/UI helper changes.
disable-model-invocation: true
---

# Wizard Testing

## Target mapping

| Change type | Test target | Path |
|-------------|-------------|------|
| `Game`, `GameCommand`, constraints, scoring | `WizardDomainTests` | `Tests/WizardDomainTests/` |
| `CommandAuthorizer`, wire/session sync, session codes | `WizardNetTests` | `Tests/WizardNetTests/` |
| `GameStore`, localization catalog, cloud card UI rules | `WizardAppTests` | `Tests/WizardAppTests/` |

Put tests in the target that matches the **lowest layer** under test. Domain rules never belong only in App tests if they can be tested without SwiftData.

## Run tests

From repository root:

```bash
swift test
swift test --filter GameFlowTests
swift test --filter CommandAuthorizerTests
swift test --filter LocalizationCatalogTests
```

Requires Swift 6 toolchain and package resolution for `Package.swift`.

## Common patterns

**Domain:**

```swift
import XCTest
@testable import WizardDomain

let players = TestSupport.makePlayers(3)
var game = try Game(id: UUID(), name: "Test", mode: .singlePhone, players: players)
try game.apply(.startNewGame(startingDealer: players[0].id))
XCTAssertThrowsError(try game.apply(...)) { err in
  XCTAssertEqual(err as? DomainError, .gameAlreadyStarted)
}
```

**Net:** `@testable import WizardNet` — use `MockTransport` where possible.

**App / catalog:** `LocalizationCatalogTests` resolves catalog path from `#filePath` up to repo root; keep `Wizard-Block-Of-Truth/Localizable.xcstrings` in that relative location.

## When tests are required

| Change | Tests |
|--------|--------|
| New or altered `GameCommand` / domain rules | **Required** — `WizardDomainTests` |
| Guest permissions / wire behavior | **Required** — `WizardNetTests` |
| New localization keys used in code | **Required** — extend catalog + run `LocalizationCatalogTests` |
| Pure SwiftUI layout/styling | Optional unless requested |

## Legacy compatibility

When adding `Codable` fields to persisted models, add a decode test without the new key (see `testRoundDecodesLegacyJSONWithoutCloudCardResolved` in `GameFlowTests.swift`).

## Xcode

CLI `swift test` uses SPM targets from `Package.swift`. The Xcode project shares the same sources; prefer `swift test` for fast agent/CI feedback.

## Multiplayer manual E2E (iOS Simulator)

Protocol and lobby logic: `swift test --filter SessionSyncTests` and `CommandAuthorizerTests` (uses `MockTransport`, no Bonjour).

**Two simulators (host + guest):**

1. Boot two devices in Simulator.app (e.g. iPhone 16 + iPhone 16 Pro).
2. Run the app on simulator A from Xcode (⌘R) → **Multi Phone** game → note join code.
3. Change run destination to simulator B → Run again (second instance).
4. On B: **Join** → pick session under “Available Sessions” → Connect → claim slot.
5. On A: start game (works without every player having a device). Host enters bets/gots for offline players in `GameSessionView`.

Grant **Local Network** on both simulators when prompted (`NSBonjourServices`: `_wizardbot._tcp` in app `Info.plist`).

**More reliable:** host on simulator, guest on a physical iPhone on the same Wi‑Fi.

**Logs:** Console.app → filter `subsystem:WizardBlockOfTruth` or `category:WizardNet`.

Join requires Bonjour discovery (`JoinGameView`); there is no manual IP-only join in the current UI.
