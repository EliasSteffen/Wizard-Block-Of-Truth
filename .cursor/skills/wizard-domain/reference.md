# Wizard Domain — Reference

## GameCommand cheat sheet

```swift
.startNewGame(startingDealer: UUID)
.submitBet(playerId: UUID, roundIndex: Int, bet: Int)
.submitGot(playerId: UUID, roundIndex: Int, got: Int)
.markCloudCardResolved(roundIndex: Int)
.finalizeCurrentRound(roundConstraints: [Constraint.RoundConstraint]? = nil)
```

`Game.apply(_:)` and `GameCommand.apply(to:)` are equivalent entry points.

## Scoring (`RoundEntry.pointsDelta()`)

Requires both `bet` and `got`; otherwise throws `DomainError.missingInputs`.

- **Exact match** (`bet == got`): `20 + 10 * bet`
- **Mismatch**: `-10 * abs(bet - got)`

## Constraint summary

| Constraint | Meaning |
|------------|---------|
| `.betSumNotEqualHandSize` (game) | Sum of all bets ≠ `handSize` |
| `.gotSumEqualsHandSize` (round) | Sum of all gots = `handSize` |
| `.gotSumEqualsHandSizeMinusOne` (round) | Sum of all gots = `handSize - 1` (bomb) |

## Player count

`Game` initializer validates player count (typically 2–6); violations throw `DomainError.invalidPlayerCount`.

## Legacy JSON

`Round` decoding tolerates missing `cloudCardResolved` (defaults to `false`). Preserve backward compatibility when changing `Codable` models—add tests like `testRoundDecodesLegacyJSONWithoutCloudCardResolved` in `GameFlowTests.swift`.
