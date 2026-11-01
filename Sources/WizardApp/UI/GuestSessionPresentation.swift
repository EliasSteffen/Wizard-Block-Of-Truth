import Foundation
#if canImport(WizardDomain)
import WizardDomain
#endif
#if canImport(WizardNet)
import WizardNet
#endif

// Pure presentation logic of the guest's multi-phone screens (join, waiting, game) and the game list's
// "active session" row. Kept free of SwiftUI so it can be unit-tested.

// MARK: - Localized text helpers

/// Catalog lookups in the language chosen in Settings (like `AppErrorMessage`).
enum GuestText {
  static func string(_ key: String, fallback: String) -> String {
    AppLocalization.string(key, languageCode: AppLanguage.catalogLookupLanguageCode, fallback: fallback)
  }

  static func format(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
    let languageCode = AppLanguage.catalogLookupLanguageCode
    let template = AppLocalization.string(key, languageCode: languageCode, fallback: fallback)
    let locale = languageCode.map { Locale(identifier: $0) } ?? .current
    return String(format: template, locale: locale, arguments: arguments)
  }
}

// MARK: - Join target

/// A host session the join screen should connect to: a tapped discovery result, a saved session ("Rejoin") or
/// the host of a session that just ended ("Pick a seat again").
struct GuestJoinTarget: Equatable, Hashable, Identifiable {
  /// Host's Bonjour service name (`nil` for sessions saved by app 1.1).
  var serviceName: String?
  var sessionCode: String
  var gameName: String
  /// Rejoin token of a saved seat (`nil` = pick a seat).
  var guestToken: String?
  /// Name of the saved seat (shown as "Rejoin … as <name>").
  var playerName: String?

  var id: String { serviceName ?? sessionCode }

  init(
    serviceName: String?,
    sessionCode: String,
    gameName: String,
    guestToken: String? = nil,
    playerName: String? = nil
  ) {
    self.serviceName = serviceName
    self.sessionCode = sessionCode
    self.gameName = gameName
    self.guestToken = guestToken
    self.playerName = playerName
  }

  init(discovered session: DiscoveredSession, guestToken: String? = nil, playerName: String? = nil) {
    self.init(
      serviceName: session.serviceName,
      sessionCode: session.code,
      gameName: session.displayName,
      guestToken: guestToken,
      playerName: playerName
    )
  }

  init(saved: SavedGuestSession) {
    let parsedName = saved.serviceName.map { BonjourServiceDescriptor.parse(serviceName: $0).displayName }
    self.init(
      serviceName: saved.serviceName,
      sessionCode: saved.sessionCode,
      gameName: saved.gameName ?? parsedName ?? saved.sessionCode,
      guestToken: saved.guestToken,
      playerName: saved.playerName
    )
  }

  /// The discovered session of this host (same Bonjour name, or the same session code).
  func match(in sessions: [DiscoveredSession]) -> DiscoveredSession? {
    if let serviceName, let exact = sessions.first(where: { $0.serviceName == serviceName }) {
      return exact
    }
    return sessions.first { Self.codesMatch($0.code, sessionCode) }
  }

  static func codesMatch(_ lhs: String, _ rhs: String) -> Bool {
    let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
    let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !left.isEmpty else { return false }
    return left.caseInsensitiveCompare(right) == .orderedSame
  }
}

// MARK: - Join failures

/// How the join screen presents a `GuestSessionError`.
enum JoinFailureKind: Equatable {
  /// Local Network permission is off: explain + "Open Settings".
  case localNetworkDenied
  /// Other app version on the host (or no answer to `hello`): explain + App Store link.
  case incompatibleHost
  /// The saved seat is gone; the lobby follows, the guest picks again (informational).
  case seatReleased
  /// The name was refused: show it at the name field.
  case name
  /// The seat was refused: show it at the seat list.
  case seat
  /// Anything else: show the localized reason.
  case general

  static func classify(_ error: Error) -> JoinFailureKind {
    guard let error = error as? GuestSessionError else { return .general }
    switch error {
    case .localNetworkDenied:
      return .localNetworkDenied
    case .hostIncompatibleOrUnreachable:
      return .incompatibleHost
    case .joinRejected(let code):
      switch code {
      case .versionMismatch, .unknown:
        return .incompatibleHost
      case .tokenInvalid:
        return .seatReleased
      case .nameInvalid, .nameTaken:
        return .name
      case .seatTaken, .seatNotFound:
        return .seat
      case .sessionNotFound, .notYourSeat, .notCurrentRound, .roundFinalized, .betsComplete, .betsIncomplete,
           .betSumEqualsHandSize, .invalidValue, .gameNotStarted, .notAuthorized, .sessionEnded, .kicked,
           .internalError:
        return .general
      }
    case .notConnected, .notJoined, .hostUnreachable, .connectionLost, .commandTimedOut:
      return .general
    }
  }
}

// MARK: - Connection banner

/// What the guest's waiting/game screen shows about the connection (`nil` = connected, nothing to show).
enum GuestConnectionBanner: Equatable {
  case connecting
  case reconnecting(attempt: Int, localNetworkDenied: Bool)
  /// Session over. `canPickSeatAgain`: the host still runs the session, only this seat is gone.
  case ended(GuestSessionEndReason, canPickSeatAgain: Bool)

  static func make(state: GuestConnectionState, transportFailure: TransportFailure?) -> GuestConnectionBanner? {
    switch state {
    case .idle, .connected:
      return nil
    case .connecting:
      return .connecting
    case .reconnecting(let attempt):
      return .reconnecting(attempt: attempt, localNetworkDenied: transportFailure == .localNetworkDenied)
    case .ended(let reason):
      // The finished game explains itself (final scoreboard + "saved to your game list").
      guard reason != .gameFinished else { return nil }
      return .ended(reason, canPickSeatAgain: canPickSeatAgain(after: reason))
    }
  }

  /// After these the host session still runs and has an open seat: the guest may join again.
  static func canPickSeatAgain(after reason: GuestSessionEndReason) -> Bool {
    switch reason {
    case .kicked, .seatReleased, .connectFailed:
      return true
    case .hostEnded, .gameFinished, .left, .rejected:
      return false
    }
  }
}

// MARK: - Command feedback

enum GuestCommandFeedback {
  /// Inline text under the entry panel for the last command's outcome (`nil` = nothing to show).
  static func message(for outcome: GuestCommandOutcome?) -> String? {
    guard let outcome else { return nil }
    switch outcome {
    case .accepted:
      return nil
    case .rejected(let code):
      return rejectionMessage(for: code)
    case .timedOut:
      return MultiplayerReasonText.message(
        for: GuestSessionError.commandTimedOut,
        languageCode: AppLanguage.catalogLookupLanguageCode
      )
    }
  }

  static func rejectionMessage(for code: MultiplayerReasonCode) -> String {
    switch code {
    case .betSumEqualsHandSize(let handSize):
      return GuestText.format(
        "UI.GuestSession.Rejection.BetSum",
        fallback: "The bets may not add up to %lld – choose another number.",
        handSize
      )
    default:
      return MultiplayerReasonText.message(for: code, languageCode: AppLanguage.catalogLookupLanguageCode)
    }
  }
}

// MARK: - Bomb / Cloud

/// Special cards the host declared, for the guest's read-only indicator.
struct GuestSpecialCardsSummary: Equatable {
  var bombThisRound: Bool
  var cloudThisRound: Bool
  /// 1-based number of the last finalized round, when the Bomb or the Cloud was played in it.
  var previousRoundNumber: Int?
  var bombPreviousRound: Bool
  var cloudPreviousRound: Bool

  var isEmpty: Bool {
    !bombThisRound && !cloudThisRound && !bombPreviousRound && !cloudPreviousRound
  }

  static func make(game: Game) -> GuestSpecialCardsSummary {
    var summary = GuestSpecialCardsSummary(
      bombThisRound: false,
      cloudThisRound: false,
      previousRoundNumber: nil,
      bombPreviousRound: false,
      cloudPreviousRound: false
    )
    guard game.playWithSpecialCards, game.rounds.indices.contains(game.currentRoundIndex) else { return summary }
    let current = game.rounds[game.currentRoundIndex]
    summary.bombThisRound = current.bombPlayed
    summary.cloudThisRound = current.cloudCardResolved

    // The round before the open one (the current round itself once the game is over).
    let previousIndex = current.isFinalized ? nil : game.currentRoundIndex - 1
    if let previousIndex, game.rounds.indices.contains(previousIndex) {
      let previous = game.rounds[previousIndex]
      if previous.isFinalized, previous.inferredBombPlayed || previous.cloudCardResolved {
        summary.previousRoundNumber = previousIndex + 1
        summary.bombPreviousRound = previous.inferredBombPlayed
        summary.cloudPreviousRound = previous.cloudCardResolved
      }
    }
    return summary
  }
}

// MARK: - Active session (game list)

/// Status of a live multi-phone session shown at the top of the game list.
enum ActiveSessionStatus: Equatable {
  case connecting
  case lobby
  case playing(round: Int, totalRounds: Int)
  case reconnecting(attempt: Int)
  case finished
  case ended(GuestSessionEndReason)

  static func guest(game: Game?, connectionState: GuestConnectionState) -> ActiveSessionStatus {
    switch connectionState {
    case .ended(.gameFinished):
      return .finished
    case .ended(let reason):
      return .ended(reason)
    case .reconnecting(let attempt):
      return .reconnecting(attempt: attempt)
    case .idle, .connecting:
      return .connecting
    case .connected:
      return gameStatus(game)
    }
  }

  static func host(game: Game?) -> ActiveSessionStatus {
    gameStatus(game)
  }

  private static func gameStatus(_ game: Game?) -> ActiveSessionStatus {
    guard let game, game.hasStarted else { return .lobby }
    if GuestEntryPhaseResolver.isGameFinished(game) {
      return .finished
    }
    let total = game.totalRoundsPlanned
    return .playing(round: min(game.currentRoundIndex + 1, total), totalRounds: total)
  }

  /// The session is over; the row only stays until the user navigates again.
  var isEnded: Bool {
    switch self {
    case .ended:
      return true
    case .finished, .connecting, .lobby, .playing, .reconnecting:
      return false
    }
  }

  var localizedText: String {
    switch self {
    case .connecting:
      return GuestText.string("UI.GameList.ActiveSession.Status.Connecting", fallback: "Connecting…")
    case .lobby:
      return GuestText.string("UI.GameList.ActiveSession.Status.Lobby", fallback: "Lobby – waiting for the start")
    case .playing(let round, let totalRounds):
      return GuestText.format(
        "UI.GameList.ActiveSession.Status.Round",
        fallback: "Round %1$lld of %2$lld",
        round,
        totalRounds
      )
    case .reconnecting:
      return GuestText.string("UI.GameList.ActiveSession.Status.Reconnecting", fallback: "Reconnecting…")
    case .finished:
      return GuestText.string("UI.GameList.ActiveSession.Status.Finished", fallback: "Game over")
    case .ended:
      return GuestText.string("UI.GameList.ActiveSession.Status.Ended", fallback: "Session ended")
    }
  }
}

// MARK: - Waiting room seats

/// One seat in the guest's waiting room (table order = dealer rotation and betting order).
struct GuestWaitingSeat: Equatable, Identifiable {
  enum Device: Equatable {
    /// A guest's phone is connected for this seat.
    case connected
    /// Bound to a guest's phone that is offline right now (the seat stays reserved).
    case offline
    /// No phone: the host enters this player's values (or a guest can still take the seat).
    case noPhone
  }

  var id: UUID
  /// 1-based seat number.
  var number: Int
  var name: String
  var isYou: Bool
  var isHost: Bool
  var device: Device

  /// Seats from the live lobby; falls back to the game's players when no lobby arrived yet.
  static func make(slots: [LobbyPlayerSlot], players: [Player], guestPlayerID: UUID?) -> [GuestWaitingSeat] {
    if !slots.isEmpty {
      return slots.enumerated().map { index, slot in
        let device: Device
        if slot.isHost {
          device = .noPhone
        } else if slot.isBoundToDevice {
          device = slot.isConnected || slot.playerId == guestPlayerID ? .connected : .offline
        } else {
          device = .noPhone
        }
        return GuestWaitingSeat(
          id: slot.playerId,
          number: index + 1,
          name: slot.name,
          isYou: slot.playerId == guestPlayerID,
          isHost: slot.isHost,
          device: device
        )
      }
    }
    return players.enumerated().map { index, player in
      GuestWaitingSeat(
        id: player.id,
        number: index + 1,
        name: player.name,
        isYou: player.id == guestPlayerID,
        isHost: false,
        device: player.id == guestPlayerID ? .connected : .noPhone
      )
    }
  }
}
