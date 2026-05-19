---
name: wizard-multiplayer
description: >-
  Documents local-network multiplayer for Wizard Block of Truth: host authority,
  guest permissions, CommandAuthorizer, wire protocol, lobby flow, and snapshots.
  Use when changing multiplayer, lobby, join codes, Bonjour, guest bet/got,
  rejoin, or HostSessionService / GuestSessionService.
disable-model-invocation: true
---

# Wizard Multiplayer

Multi-phone mode (`.multiPhone`) uses **local network only**. The **host device is the source of truth** for `Game` state.

## Product rules (must not violate)

### Host capabilities

- Create/select game and manage players
- Start and end a multiplayer session (guests join this session)
- Advance rounds, finalize rounds, edit/undo host-side inputs
- Apply any valid `GameCommand` on the authoritative game
- **Broadcast** the latest `currentGame` snapshot to all guests after every **accepted** command

### Guest capabilities

- **Read-only** view of game state and scoreboard
- Submit only:
  - own `submitBet` for the **current** round
  - own `submitGot` for the **current** round
- **Cannot:** create/select games, change players, change dealer, edit others’ bets/gots, or perform host-only commands
- On disconnect: may re-join and receive the latest `gameSnapshot`

### Planned multi-phone setup order (`todos.md`)

1. Host creates game with player slots
2. Guests join (local discovery + session code) and set their names
3. Host sets dealer and final rule tweaks
4. Host starts the game

When implementing lobby/UI flow, preserve this ordering intent even if not fully built yet.

## Enforcement

`CommandAuthorizer.isAllowedGuestCommand` (`Sources/WizardNet/CommandAuthorizer.swift`) allows only:

- `submitBet` / `submitGot` where `playerId == guestPlayerId` and `roundIndex == currentRoundIndex`

Any new guest capability **must** update `CommandAuthorizer` and add tests in `Tests/WizardNetTests/`.

## Architecture

```
MultiplayerCoordinator (App, @MainActor)
  ├── Host: GameStore + HostSessionService + BonjourAdvertiser + TCPHostTransport
  └── Guest: GuestSessionService + MultiplayerGameStore (read-only + submit)
```

- **Host path:** `HostSessionService` holds authoritative `Game`, applies commands, sends `gameSnapshot` via `WireEnvelope`.
- **Guest path:** `MultiplayerGameStore` mirrors snapshots; sends `guestCommand`; applies local state only when `commandResult` indicates success.
- **Wire types:** `Sources/WizardNet/WireProtocol.swift` — versioned `WireEnvelope` + tagged `WirePayload`.

Framing: `FrameCodec` over `TCPNetworkTransport`. Session codes: validated in net tests.

## Implementation checklist

When adding a multiplayer feature:

1. Decide host-only vs guest-allowed (update `CommandAuthorizer` if guest).
2. Apply state on host via `GameCommand` / `GameStore` (same domain rules as single-phone).
3. Broadcast snapshot after successful apply.
4. Guest UI: disable controls that violate read-only rules; never apply guest commands locally without host ack.
5. Add or extend `WizardNetTests` (authorizer, session sync).

## Key files

| File | Role |
|------|------|
| `MultiplayerCoordinator.swift` | Host lobby, session lifecycle, store lookup |
| `MultiplayerGameStore.swift` | Guest-facing store wrapping host snapshots |
| `HostSessionService.swift` | Authoritative session on host |
| `GuestSessionService.swift` | Join, claim player, receive snapshots |
| `CommandAuthorizer.swift` | Guest command allow-list |
| `WireProtocol.swift` | Message types |

Wire message table: [reference.md](reference.md).
