---
name: wizard-multiplayer
description: >-
  Documents local-network multiplayer for Wizard Block of Truth: host authority,
  guest permissions, CommandAuthorizer, wire protocol v2, seats/lobby, heartbeat,
  reconnects, session lifetime and snapshots. Use when changing multiplayer,
  lobby, Bonjour, guest bet/got, rejoin, or HostSessionService / GuestSessionService.
disable-model-invocation: true
---

# Wizard Multiplayer

Multi-phone mode (`.multiPhone`) uses **local network only** (Bonjour `_wizardbot._tcp` + TCP). The **host device is
the source of truth** for `Game` state. Wire protocol **v2** (`WireProtocolVersion.current == 2`).

## Product rules (must not violate)

### Host

- One hosted session per device at a time (`MultiplayerCoordinatorError.anotherSessionActive` → UI asks
  "End session for X?").
- Lobby: host names phone-less seats, reorders seats (before start; order = dealer rotation and betting order),
  unassigns (kicks) a guest's seat; sets dealer and rules; starts without requiring every seat to have a device.
- Applies any valid `GameCommand` (incl. bets/gots of any player — host overrides guests). Bulk entry sheets only
  cover phone-less players (`MultiplayerGameStore.isPlayerBoundToGuestDevice`), single values can always be corrected.
- Bomb / Cloud card are host-only, declared on the host's game screen: `GameCommand.setBombPlayed` persists the Bomb on
  the open round (guests see `Round.bombPlayed` in snapshots); Cloud via `markCloudCardResolved` + bet adjustment.
- Ends the session ("End session"); it also ends automatically when the game is finished.
- The session survives an app relaunch / screen lock: same code (persisted per game), listener restarted on
  foreground, guests reconnect with their tokens.

### Guest

- Joins by tapping a discovered session (no code typing; the code only identifies the session), picks an open seat
  (any seat not bound to a device, incl. host-named ones) and types a name (trimmed, 1…24 characters,
  case-insensitive unique).
- Read-only scoreboard. May only submit `submitBet` / `submitGot` for **their own seat** in the **current, not
  finalized** round:
  - `submitBet` only while at least one bet of the round is missing (before this command) and no Cloud card was
    played; a bet that makes the bet sum equal the hand size (bet-sum rule) is rejected
    (`betSumEqualsHandSize(handSize)`).
  - `submitGot` only once all bets are in; may be corrected until the host finalizes.
- Connection lost ≠ session ended: auto-reconnect with the saved token (`SavedGuestSession`); the seat stays bound on
  the host until the host unassigns it. Session end (host ended / game finished / kicked / seat released / left)
  clears the saved session (only the token that saved it can clear it).
- Keeps a read-only copy of the final game (`GuestFinishedGames`).

## Enforcement

`CommandAuthorizer` (`Sources/WizardNet/CommandAuthorizer.swift`):

- `isAllowedGuestCommand` — allow-list of command kinds (own seat, current round). Everything else (incl. commands
  added later) is host-only.
- `guestCommandRejection(_:guestPlayerId:game:)` — full rule set above → `MultiplayerReasonCode?`.
- `betSumViolation(in:roundIndex:)` — checked by the host **after** applying a guest bet on a copy; on violation the
  copy is discarded (rollback) and the guest gets the reason.
- `applicableGameConstraints(for:roundIndex:)` — the single place deriving bidding constraints
  (`TODO(merge): use Game.gameConstraints(forRoundAt:)`).

Any new guest capability **must** update `CommandAuthorizer` and add tests in `Tests/WizardNetTests/`.

## Architecture

```
MultiplayerCoordinator (App, @MainActor) — one hosted session + guest sessions, persistence, scene phase
  ├── Host: HostSessionService (game = source of truth) + TCPHostTransport (NWListener + NWConnections)
  │         MultiplayerGameStore(.host): apply/applyBatch → HostSessionService.applyHostCommands (atomic)
  │         every commit → onGameSnapshot → GameStore.replaceCurrentGame (SwiftData, synchronous) → broadcast once
  └── Guest: GuestSessionService + TCPGuestTransport (connects by Bonjour service *name*)
            MultiplayerGameStore(.guest): connectionState, pendingCommand, lastRejection, lobbySlots
```

- Transports deliver events serially from their queue; services hop to the main actor with one ordered
  `DispatchQueue.main` hop per event (`MainActorEventInbox`) — no per-event `Task`s.
- TCP: `noDelay`, keepalive, 10 s connect timeout, `.waiting` surfaced (Local Network denied → distinct error),
  exactly one `disconnected` per connection, send-then-close (`close(connectionID:)`, `stop()`).
- Heartbeat: host pings every connection that said hello every 5 s; both sides treat 15 s of silence as connection
  lost (`SessionTiming`).
- Snapshots only go to joined (authenticated) connections; rejected/replaced sockets are closed.

## Lifecycle (host)

`startHosting` → lobby (`renameSeat`, `reorderSeats`, `unassignSeat`, `updateHostSlot`) → `startHostedGame` →
commands → `endSession` (guests get `sessionEnded(hostEnded)` before the sockets close) or automatic end after the
final round (`sessionEnded(gameFinished)` after the final snapshot). `resumeHosting` restores code + token registry
after a relaunch (UserDefaults, `HostSessionPersistence`). `handleScenePhase(.active)` restarts a failed listener.

## Implementation checklist

1. Decide host-only vs guest-allowed (update `CommandAuthorizer` + tests if guest).
2. Apply host changes via `HostSessionService.applyHostCommands` (through `MultiplayerGameStore`) — never patch the
   session game wholesale.
3. New wire message → `WirePayload` case + `Codable` + round-trip sample in `WireProtocolTests`.
4. New reason → `MultiplayerReasonCode` case (+ `rawCode`/decoder) + text in `MultiplayerReasonText` + catalog keys.
5. Guest UI: never apply guest commands locally; show `pendingCommand`, `lastRejection`, `connectionState`.

## Key files

| File | Role |
|------|------|
| `MultiplayerCoordinator.swift` | One hosted session, guest stores, resume, scene phase |
| `MultiplayerGameStore.swift` | `GameStoring` for host (session-backed) and guest (mirror + pending commands) |
| `MultiplayerPersistence.swift` | `HostSessionRecord` (code, host seat, token registry), `GuestFinishedGames` |
| `MultiplayerReasonText.swift` | Reason codes / errors → localized text |
| `SavedGuestSession.swift` | Guest rejoin data (token-keyed clearing) |
| `HostSessionService.swift` | Authoritative session, seats, heartbeat, auto-end |
| `GuestSessionService.swift` | Join, claim, snapshots, commands, watchdog, reconnect |
| `CommandAuthorizer.swift` | Guest permissions |
| `WireProtocol.swift` / `MultiplayerReasonCode.swift` | Messages, reason codes, v1 compatibility |
| `TCPNetworkTransport.swift` / `MockTransport.swift` | Network.framework / in-memory transports |

Wire message table: [reference.md](reference.md).
