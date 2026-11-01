---
name: wizard-domain
description: >-
  Implements Wizard card game rules via GameCommand, Game, Round, constraints, and
  DomainError in WizardDomain. Use when changing rounds, bets, gots, scoring, dealer
  flow, cloud card flags, game constraints, or DomainError.
disable-model-invocation: true
---

# Wizard Domain — Game Logic

All authoritative game state changes live in **WizardDomain**. UI and network layers call commands; they do not mutate `Game` fields directly.

## State model

- **`Game`** — players, rounds, `currentRoundIndex`, `gameConstraints`, `firstRoundBetSumMayEqualHandSize`, `playWithSpecialCards`, `mode` (`.singlePhone` / `.multiPhone`).
- **`Round`** — `handSize`, `dealer`, `entries` per player, `isFinalized`, `cloudCardResolved`, `bombPlayed` (set by `finalizeCurrentRound` when `.gotSumEqualsHandSizeMinusOne` was used). Read the Bomb via `round.inferredBombPlayed`, which also infers it for legacy finalized rounds (won-tricks sum == `handSize - 1`).
- **`RoundEntry`** — optional `bet` and `got`; scoring via `pointsDelta()`.
- **`Player`** — `id`, `name`.

Files: `Sources/WizardDomain/Models/`, `Sources/WizardDomain/Game/Game.swift`.

## Mutation pattern

Use **`GameCommand`** only:

```swift
try game.apply(.submitBet(playerId: id, roundIndex: 0, bet: 1))
```

Implementation: `Sources/WizardDomain/Game/Commands.swift` (`GameCommand.apply(to:)`).

Never patch `game.rounds[...].entries[...]` from WizardApp or WizardNet except through `apply` / host command pipeline.

## Commands

| Command | When valid |
|---------|------------|
| `startNewGame(startingDealer:)` | No rounds yet; dealer must be a known player. Creates round 1 with `handSize == 1`. |
| `submitBet(playerId:roundIndex:bet:)` | Round not finalized; bet in `0...handSize`. |
| `submitGot(playerId:roundIndex:got:)` | Round not finalized; got in `0...handSize`. |
| `markCloudCardResolved(roundIndex:)` | Round not finalized; sets `cloudCardResolved` (one cloud adjustment per round). |
| `finalizeCurrentRound(roundConstraints:)` | All bets and gots set; runs round constraint validation; marks round finalized; may append next round (hand size up/down per game rules). |
| `editFinalizedRound(roundIndex:entries:bombPlayed:cloudCardPlayed:)` | Host / single-phone only (guests denied by `CommandAuthorizer`). Round must exist (`invalidRoundIndex`) and be finalized (`roundNotFinalized`); Bomb/Cloud need `playWithSpecialCards` (`specialCardsNotEnabled`); `entries` must cover exactly the players (`entriesDoNotMatchPlayers`) with every bet/got set (`missingInputs`) and in `0...handSize`; won tricks sum to `handSize - 1` with Bomb else `handSize`; bet-sum rule from `gameConstraints(forRoundAt:)` unless `cloudCardPlayed`. Atomic: validated on a copy, then replaces `entries`, `bombPlayed`, `cloudCardResolved` (keeps `handSize`, `dealer`, `isFinalized`, other rounds, `currentRoundIndex`). Totals recompute from finalized rounds. |

`finalizeCurrentRound` defaults `roundConstraints` to `[.gotSumEqualsHandSize]` when nil. Game constraints (e.g. bet sum ≠ hand size) apply during bidding, not necessarily at finalize—see comments in `Commands.swift`.

## Constraints

- **Game:** `Constraint.GameConstraint` — e.g. `.betSumNotEqualHandSize` (sum of bets must not equal hand size).
- **Round:** `Constraint.RoundConstraint` — e.g. `.gotSumEqualsHandSize`, `.gotSumEqualsHandSizeMinusOne` (bomb card).

Defined in `Sources/WizardDomain/Rules/Constraints.swift`. New games default to `gameConstraints: [.betSumNotEqualHandSize]` in `GameStore.createGame`.

Validate with `round.validateConstraints(players:gameConstraints:roundConstraints:)`.

**Which game constraints apply to a round:** always ask `game.gameConstraints(forRoundAt: roundIndex)` (never `game.gameConstraints` directly) when validating bets. With the house rule `firstRoundBetSumMayEqualHandSize` ("Erste Runde darf aufgehen", default off, set at creation via `GameStore.createGame` / `HostSessionService.startGame`) it drops `.betSumNotEqualHandSize` for round 1 (index 0). Change it only via `setFirstRoundBetSumMayEqualHandSize(_:)`, which—like `setGameConstraints(_:)`—throws `constraintsLocked` after the first finalized round.

## Errors

Throw and compare **`DomainError`** (`Sources/WizardDomain/Support/Errors.swift`). Cases include `missingInputs`, `roundAlreadyFinalized`, `roundNotFinalized`, `specialCardsNotEnabled`, `invalidBet`, `constraintNotSatisfied`, etc.

`DomainError` conforms to `LocalizedError` with catalog keys—add matching keys in `Localizable.xcstrings` when exposing new cases to users.
New cases also need a branch in `AppErrorMessage.domainMessage` (exhaustive switch in WizardApp).

## App-only: cloud card UI

Bet/got adjustment when the cloud card is played is orchestrated in `Sources/WizardApp/UI/CloudCardAdjustmentRules.swift`. Persist outcomes via `GameCommand` (`markCloudCardResolved`, bet/got submits, finalize)—domain state remains the source of truth.

## App-only: round editor

Finalized rounds are corrected in `Sources/WizardApp/UI/RoundEditorView.swift`, opened by tapping a finalized row in `PlayerRoundHistorySheet` (only when it gets an `applyRoundEdit` closure: `GameSessionView` passes one for single-phone and the multi-phone host; guest views pass none). Saving sends `.editFinalizedRound` through `store.applyBatch([command])` (on the host, `MultiplayerGameStore` persists it and broadcasts the snapshot).

## Tests

Add cases under `Tests/WizardDomainTests/`. Use `TestSupport.makePlayers(_:)` and `XCTAssertEqual(err as? DomainError, ...)`.

Command cheat sheet and scoring: [reference.md](reference.md).
