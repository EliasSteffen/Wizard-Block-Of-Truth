# Wizard Project — Reference

## Directory map (key paths)

```
Sources/WizardDomain/
  Game/Game.swift          — Game aggregate, apply(command)
  Game/Commands.swift     — GameCommand enum + apply(to:)
  Models/Models.swift       — Player, Round, RoundEntry, GameMode
  Models/Card.swift         — Special cards
  Rules/Constraints.swift   — GameConstraint, RoundConstraint
  Rules/Rules.swift         — Validation helpers
  Support/Errors.swift      — DomainError

Sources/WizardNet/
  WireProtocol.swift        — WireEnvelope, WirePayload
  HostSessionService.swift  — Host session + snapshots
  GuestSessionService.swift — Guest client
  CommandAuthorizer.swift   — Guest command allow-list
  TCPNetworkTransport.swift — TCP + Bonjour
  FrameCodec.swift          — Framing over TCP

Sources/WizardApp/
  WizardApp.swift           — @main, model container, coordinator env
  App/GameStore.swift       — Single-phone persistence + commands
  App/GameCodec.swift       — Game JSON encode/decode for SwiftData
  Multiplayer/              — Coordinator, MultiplayerGameStore, lobby
  UI/                       — SwiftUI views
  Persistence/              — GameSnapshotEntity

Wizard-Block-Of-Truth/
  Localizable.xcstrings     — String catalog (en + de)
  Assets.xcassets
  Info.plist

Tests/
  WizardDomainTests/
  WizardNetTests/
  WizardAppTests/
```

## Out of scope unless asked

| Path | Purpose |
|------|---------|
| `site/` | Astro marketing / support / privacy site (builds to GitHub Pages) |
| `.github/workflows/` | CI: `pages.yml` deploys `site/`; `ios.yml` runs `swift test` + an unsigned iOS Simulator build on every push/PR and, on every push to `main`, archives, uploads to TestFlight and syncs the App Store texts (README → Release pipeline) |
| `scripts/asc-*.ts`, `ci/ExportOptions.plist` | Release pipeline: App Store Connect pre-flight, upload and metadata sync (Node, run directly with `node`), signed export options |
| `fastlane/metadata/<locale>/` | App Store texts (description, promotional text, release notes) synced by `ios.yml`; fastlane itself is not used |
| `Assets/icon.png` | App icon source asset |

## Docs in repo

- `localization.md` — string catalog rules and key naming
- `todos.md` — roadmap (multi-phone flow, planned features)
