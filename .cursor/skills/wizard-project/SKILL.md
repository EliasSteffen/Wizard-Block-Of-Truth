---
name: wizard-project
description: >-
  Describes Wizard-Block-Of-Truth module layout, dependency rules, dual SPM/Xcode
  build, and where to place changes. Use when starting work in this repo, adding a
  feature, asking where code belongs, or how to build and run the app.
disable-model-invocation: true
---

# Wizard Block of Truth — Project Overview

Read this skill first when working in this repository.

## Modules

Defined in `Package.swift`:

| Module | Path | Responsibility |
|--------|------|----------------|
| **WizardDomain** | `Sources/WizardDomain/` | Pure game logic: models, rules, `GameCommand`, scoring, constraints. No UI, network, or persistence. |
| **WizardNet** | `Sources/WizardNet/` | Local multiplayer: TCP transport, Bonjour, wire protocol, host/guest session services. Depends on WizardDomain only. |
| **WizardApp** | `Sources/WizardApp/` | SwiftUI app, SwiftData persistence, coordinators, UI. Depends on WizardDomain and WizardNet. |

**Dependency rules (do not violate):**

- WizardDomain imports nothing from App or Net.
- WizardNet must not import WizardApp.
- Game rules belong in WizardDomain, not in views or network layers.

## Dual build layout

- **Swift sources:** `Sources/<Module>/` — single source of truth for code.
- **Xcode app target:** `Wizard-Block-Of-Truth.xcodeproj` references those paths via `SOURCE_ROOT` (not a duplicate tree).
- **App bundle assets:** `Wizard-Block-Of-Truth/` — `Assets.xcassets`, `Localizable.xcstrings`, `Info.plist`.

**Platforms:** iOS 18+, macOS 15+, Swift 6.

## Import pattern

Many App/Net files use conditional imports:

```swift
#if canImport(WizardDomain)
import WizardDomain
#endif
```

Preserve this when adding cross-module imports so both SPM and Xcode targets keep building.

## Which skill to use next

| Task | Skill |
|------|--------|
| Rounds, bets, scoring, `GameCommand`, constraints | `wizard-domain` |
| Host/guest, lobby, join code, snapshots | `wizard-multiplayer` |
| SwiftUI screens, strings, theming | `wizard-ui-localization` |
| Unit tests, `swift test` | `wizard-testing` |

## Build and run

- **Tests (CLI):** from repo root, `swift test` (see `wizard-testing`).
- **App (UI):** open `Wizard-Block-Of-Truth.xcodeproj` in Xcode and run the app target.

## Conventions

- Minimize scope: change only what the task requires.
- Match existing naming and patterns in the touched module.
- Product roadmap notes live in `todos.md`; multiplayer product rules are summarized in `wizard-multiplayer`.

## Additional resources

- Directory map and out-of-scope paths: [reference.md](reference.md)
- Localization baseline: [localization.md](../../../localization.md) (repo root)
