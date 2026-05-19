import Foundation
#if canImport(WizardDomain)
import WizardDomain
#endif

enum GuestEntryPhase: Equatable {
  case enterBet
  case enterGot
  case waiting
  case gameFinished
}

enum GuestEntryPhaseResolver {
  static func phase(game: Game, guestPlayerID: UUID) -> GuestEntryPhase {
    guard !isGameFinished(game) else { return .gameFinished }
    guard let round = game.currentRound else { return .waiting }

    let entry = round.entries[guestPlayerID]
    let allBetsPresent = round.entries.values.allSatisfy { $0.bet != nil }

    if entry?.bet == nil {
      return .enterBet
    }
    if allBetsPresent, entry?.got == nil {
      return .enterGot
    }
    return .waiting
  }

  private static func isGameFinished(_ game: Game) -> Bool {
    guard !game.rounds.isEmpty else { return false }
    guard game.rounds.count >= game.totalRoundsPlanned else { return false }
    return game.rounds.last?.isFinalized == true
  }
}
