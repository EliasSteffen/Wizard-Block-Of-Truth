import Foundation
#if canImport(WizardDomain)
import WizardDomain
#endif
#if canImport(WizardNet)
import WizardNet
#endif

/// The value a guest enters for their own seat.
enum GuestEntryKind: Equatable, Sendable {
  case bet
  case got
}

/// What the guest's entry panel shows for the current round (decision 4: guests own their values).
enum GuestEntryPhase: Equatable {
  /// The own value of this kind is missing and may be entered now.
  case enter(GuestEntryKind)
  /// The own value of this kind was entered and can still be changed (bet: until all bets are in; won tricks:
  /// until the host finalizes the round).
  case review(GuestEntryKind, value: Int)
  /// Nothing the guest may enter right now (e.g. the host has to finish something first).
  case waiting
  case gameFinished

  /// The kind the guest may submit in this phase, if any.
  var editableKind: GuestEntryKind? {
    switch self {
    case .enter(let kind), .review(let kind, _):
      return kind
    case .waiting, .gameFinished:
      return nil
    }
  }
}

/// Everything the entry panel needs to know about the current round. It is also the identity used to reseed the
/// stepper (L8): a new round, another phase or a changed own value starts from a fresh draft.
struct GuestEntryContext: Equatable {
  var roundIndex: Int
  var handSize: Int
  var phase: GuestEntryPhase
  var ownBet: Int?
  var ownGot: Int?
  /// A bet the guest may not choose because the bets would add up to the hand size (bet-sum rule). Only known
  /// when every other bet is in; the host enforces the rule anyway.
  var forbiddenBet: Int?

  var valueRange: ClosedRange<Int> { 0...max(0, handSize) }

  /// Own value of `kind` (nil = not entered yet).
  func ownValue(of kind: GuestEntryKind) -> Int? {
    switch kind {
    case .bet:
      return ownBet
    case .got:
      return ownGot
    }
  }

  /// Changes exactly when the stepper has to start over: another round, another kind to enter (e.g. bets
  /// complete → won tricks), or the own value changed (accepted, or corrected by the host). Other players'
  /// entries do not reset a draft in progress.
  struct DraftSeedKey: Equatable {
    var roundIndex: Int
    var kind: GuestEntryKind?
    var ownValue: Int?
  }

  var draftSeedKey: DraftSeedKey {
    let kind = phase.editableKind
    return DraftSeedKey(roundIndex: roundIndex, kind: kind, ownValue: kind.flatMap { ownValue(of: $0) })
  }
}

/// Client-side mirror of the host's guest permissions (`CommandAuthorizer`), used to decide which controls to show.
enum GuestEntryPhaseResolver {
  static func context(game: Game, guestPlayerID: UUID) -> GuestEntryContext? {
    guard let round = game.currentRound else { return nil }
    let entry = round.entries[guestPlayerID]
    return GuestEntryContext(
      roundIndex: game.currentRoundIndex,
      handSize: round.handSize,
      phase: phase(game: game, guestPlayerID: guestPlayerID),
      ownBet: entry?.bet,
      ownGot: entry?.got,
      forbiddenBet: forbiddenBet(game: game, guestPlayerID: guestPlayerID)
    )
  }

  static func phase(game: Game, guestPlayerID: UUID) -> GuestEntryPhase {
    guard !isGameFinished(game) else { return .gameFinished }
    guard let round = game.currentRound else { return .waiting }
    let entry = round.entries[guestPlayerID]

    if canSubmit(.bet, game: game, guestPlayerID: guestPlayerID) {
      if let bet = entry?.bet {
        return .review(.bet, value: bet)
      }
      return .enter(.bet)
    }
    if canSubmit(.got, game: game, guestPlayerID: guestPlayerID) {
      if let got = entry?.got {
        return .review(.got, value: got)
      }
      return .enter(.got)
    }
    return .waiting
  }

  /// Would the host accept a command of this kind from the guest right now (ignoring the value itself)?
  static func canSubmit(_ kind: GuestEntryKind, game: Game, guestPlayerID: UUID) -> Bool {
    let roundIndex = game.currentRoundIndex
    let command: GameCommand
    switch kind {
    case .bet:
      command = .submitBet(playerId: guestPlayerID, roundIndex: roundIndex, bet: 0)
    case .got:
      command = .submitGot(playerId: guestPlayerID, roundIndex: roundIndex, got: 0)
    }
    return CommandAuthorizer.guestCommandRejection(command, guestPlayerId: guestPlayerID, game: game) == nil
  }

  /// The bet that would make the bet sum equal the hand size, when the guest is the last one to bet and the
  /// bet-sum rule applies to this round (not after a Cloud card). `nil` otherwise.
  static func forbiddenBet(game: Game, guestPlayerID: UUID) -> Int? {
    guard let round = game.currentRound, !round.isFinalized, !round.cloudCardResolved else { return nil }
    let constraints = CommandAuthorizer.applicableGameConstraints(for: game, roundIndex: game.currentRoundIndex)
    guard constraints.contains(.betSumNotEqualHandSize) else { return nil }
    var othersSum = 0
    for (playerId, entry) in round.entries where playerId != guestPlayerID {
      guard let bet = entry.bet else { return nil }
      othersSum += bet
    }
    let forbidden = round.handSize - othersSum
    return (0...round.handSize).contains(forbidden) ? forbidden : nil
  }

  /// Where the stepper starts (L8): the own value when correcting it; for a first won-tricks entry the own bet
  /// (making one's bet is the most common outcome, so it is usually one tap); otherwise 0. Clamped to the hand.
  static func initialDraft(kind: GuestEntryKind, ownBet: Int?, ownGot: Int?, handSize: Int) -> Int {
    let proposal: Int
    switch kind {
    case .bet:
      proposal = ownBet ?? 0
    case .got:
      proposal = ownGot ?? ownBet ?? 0
    }
    return min(max(0, proposal), max(0, handSize))
  }

  static func isGameFinished(_ game: Game) -> Bool {
    guard !game.rounds.isEmpty else { return false }
    guard game.rounds.count >= game.totalRoundsPlanned else { return false }
    return game.rounds.last?.isFinalized == true
  }
}
