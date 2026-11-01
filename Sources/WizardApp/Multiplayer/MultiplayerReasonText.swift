import Foundation
#if canImport(WizardNet)
import WizardNet
#endif

/// A host's rejection as an `Error` (e.g. in `lastError`); its description is the localized reason.
struct MultiplayerReasonError: LocalizedError, Equatable {
  let code: MultiplayerReasonCode

  var errorDescription: String? {
    MultiplayerReasonText.message(for: code, languageCode: AppLanguage.catalogLookupLanguageCode)
  }
}

/// Localized texts for multi-phone reason codes, connection problems and session ends.
///
/// The wire only carries typed codes (`MultiplayerReasonCode`); this is the one place that turns them into text.
/// `AppErrorMessage.presentableMessage(for:languageCode:)` routes multiplayer errors here.
enum MultiplayerReasonText {
  static func message(for code: MultiplayerReasonCode, languageCode: String?) -> String {
    switch code {
    case .versionMismatch:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.VersionMismatch",
        languageCode: languageCode,
        fallback: "The host uses a different app version. Please update the app on both devices."
      )
    case .sessionNotFound:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.SessionNotFound",
        languageCode: languageCode,
        fallback: "This session is no longer available. Pick it again from the list."
      )
    case .seatTaken:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.SeatTaken",
        languageCode: languageCode,
        fallback: "This seat is already taken. Pick another one."
      )
    case .seatNotFound:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.SeatNotFound",
        languageCode: languageCode,
        fallback: "This seat no longer exists. Pick another one."
      )
    case .nameInvalid:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.NameInvalid",
        languageCode: languageCode,
        fallback: "Enter a name with 1 to 24 characters."
      )
    case .nameTaken:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.NameTaken",
        languageCode: languageCode,
        fallback: "Another player already uses this name. Choose a different one."
      )
    case .tokenInvalid:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.TokenInvalid",
        languageCode: languageCode,
        fallback: "Your seat is no longer reserved. Pick a seat again."
      )
    case .notYourSeat:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.NotYourSeat",
        languageCode: languageCode,
        fallback: "You can only enter values for your own player."
      )
    case .notCurrentRound:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.NotCurrentRound",
        languageCode: languageCode,
        fallback: "This round is no longer active."
      )
    case .roundFinalized:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.RoundFinalized",
        languageCode: languageCode,
        fallback: "The host has already finished this round."
      )
    case .betsComplete:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.BetsComplete",
        languageCode: languageCode,
        fallback: "All bets are in – bets can no longer be changed."
      )
    case .betsIncomplete:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.BetsIncomplete",
        languageCode: languageCode,
        fallback: "You can enter your won tricks once all bets are in."
      )
    case .betSumEqualsHandSize(let handSize):
      return AppLocalization.format(
        "Error.Multiplayer.Reason.BetSumEqualsHandSize",
        languageCode: languageCode,
        fallback: "Bets may not add up to %lld – choose another value.",
        handSize
      )
    case .invalidValue:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.InvalidValue",
        languageCode: languageCode,
        fallback: "This value is not allowed."
      )
    case .gameNotStarted:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.GameNotStarted",
        languageCode: languageCode,
        fallback: "The game has not started yet."
      )
    case .notAuthorized:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.NotAuthorized",
        languageCode: languageCode,
        fallback: "Only the host can do that."
      )
    case .sessionEnded(let reason):
      return message(for: reason, languageCode: languageCode)
    case .kicked:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.Kicked",
        languageCode: languageCode,
        fallback: "The host removed you from your seat."
      )
    case .internalError:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.Internal",
        languageCode: languageCode,
        fallback: "Something went wrong on the host. Please try again."
      )
    case .unknown:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.Unknown",
        languageCode: languageCode,
        fallback: "The host sent an unknown answer. Please update the app on both devices."
      )
    }
  }

  static func message(for reason: SessionEndReason, languageCode: String?) -> String {
    switch reason {
    case .hostEnded:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.HostEnded",
        languageCode: languageCode,
        fallback: "The host ended the session."
      )
    case .gameFinished:
      return AppLocalization.string(
        "Error.Multiplayer.Reason.GameFinished",
        languageCode: languageCode,
        fallback: "The game is over. The final scoreboard was saved in your game list."
      )
    }
  }

  /// Text for a guest's "session ended" banner.
  static func message(for reason: GuestSessionEndReason, languageCode: String?) -> String {
    switch reason {
    case .hostEnded:
      return message(for: SessionEndReason.hostEnded, languageCode: languageCode)
    case .gameFinished:
      return message(for: SessionEndReason.gameFinished, languageCode: languageCode)
    case .kicked:
      return message(for: MultiplayerReasonCode.kicked, languageCode: languageCode)
    case .seatReleased:
      return message(for: MultiplayerReasonCode.tokenInvalid, languageCode: languageCode)
    case .left:
      return AppLocalization.string(
        "Error.Multiplayer.Session.Left",
        languageCode: languageCode,
        fallback: "You left the session."
      )
    case .rejected(let code):
      return message(for: code, languageCode: languageCode)
    case .connectFailed(let error):
      return message(for: error, languageCode: languageCode)
    }
  }

  static func message(for error: GuestSessionError, languageCode: String?) -> String {
    switch error {
    case .notConnected:
      return AppLocalization.string(
        "Error.Multiplayer.Connection.NotConnected",
        languageCode: languageCode,
        fallback: "Not connected to the host right now. Reconnecting…"
      )
    case .notJoined:
      return AppLocalization.string(
        "Error.Multiplayer.Connection.NotJoined",
        languageCode: languageCode,
        fallback: "You haven’t taken a seat yet."
      )
    case .joinRejected(let code):
      return message(for: code, languageCode: languageCode)
    case .localNetworkDenied:
      return message(for: TransportFailure.localNetworkDenied, languageCode: languageCode)
    case .hostUnreachable:
      return AppLocalization.string(
        "Error.Multiplayer.Connection.HostUnreachable",
        languageCode: languageCode,
        fallback: "Couldn’t reach the host. Make sure both devices are on the same Wi-Fi and the host has the session open."
      )
    case .hostIncompatibleOrUnreachable:
      return AppLocalization.string(
        "Error.Multiplayer.Connection.HostIncompatible",
        languageCode: languageCode,
        fallback: "The host doesn’t answer. It may be using an older app version – update both devices."
      )
    case .connectionLost:
      return AppLocalization.string(
        "Error.Multiplayer.Connection.Lost",
        languageCode: languageCode,
        fallback: "The connection to the host was lost."
      )
    case .commandTimedOut:
      return AppLocalization.string(
        "Error.Multiplayer.Connection.CommandTimedOut",
        languageCode: languageCode,
        fallback: "The host didn’t answer in time. Check the scoreboard and try again."
      )
    }
  }

  static func message(for failure: TransportFailure, languageCode: String?) -> String {
    switch failure {
    case .localNetworkDenied:
      return AppLocalization.string(
        "Error.Multiplayer.Connection.LocalNetworkDenied",
        languageCode: languageCode,
        fallback: "Local network access is off. Allow it in Settings › Privacy & Security › Local Network, then try again."
      )
    case .network:
      return message(for: GuestSessionError.hostUnreachable, languageCode: languageCode)
    }
  }

  static func message(for error: HostSessionError, languageCode: String?) -> String {
    switch error {
    case .gameAlreadyStarted:
      return AppLocalization.string(
        "Error.Domain.GameAlreadyStarted",
        languageCode: languageCode,
        fallback: "Game already started."
      )
    case .gameNotInSetup:
      return AppLocalization.string(
        "Error.Multiplayer.Host.NotInSetup",
        languageCode: languageCode,
        fallback: "This is only possible before the game starts."
      )
    case .seatNotFound:
      return message(for: MultiplayerReasonCode.seatNotFound, languageCode: languageCode)
    case .nameInvalid:
      return message(for: MultiplayerReasonCode.nameInvalid, languageCode: languageCode)
    case .nameTaken:
      return message(for: MultiplayerReasonCode.nameTaken, languageCode: languageCode)
    case .seatBoundToDevice:
      return AppLocalization.string(
        "Error.Multiplayer.Host.SeatBoundToDevice",
        languageCode: languageCode,
        fallback: "This seat belongs to a guest’s phone. Remove the guest first."
      )
    case .invalidSeatOrder:
      return AppLocalization.string(
        "Error.Multiplayer.Host.InvalidSeatOrder",
        languageCode: languageCode,
        fallback: "The seat order is invalid."
      )
    case .sessionEnded:
      return AppLocalization.string(
        "Error.Multiplayer.Host.SessionEnded",
        languageCode: languageCode,
        fallback: "This session has already ended."
      )
    case .invalidGuest, .invalidToken, .unauthorizedCommand:
      return message(for: MultiplayerReasonCode.notAuthorized, languageCode: languageCode)
    }
  }

  static func message(for error: MultiplayerCoordinatorError, languageCode: String?) -> String {
    switch error {
    case .anotherSessionActive(_, let gameName):
      return AppLocalization.format(
        "Error.Multiplayer.Host.AnotherSessionActive",
        languageCode: languageCode,
        fallback: "A multi-phone session for “%@” is still running. End it first.",
        gameName
      )
    case .gameNotFound:
      return AppLocalization.string(
        "Error.Multiplayer.Host.GameNotFound",
        languageCode: languageCode,
        fallback: "The game couldn’t be loaded for hosting."
      )
    case .noActiveHostSession:
      return AppLocalization.string(
        "Error.Multiplayer.Host.NoActiveSession",
        languageCode: languageCode,
        fallback: "There is no active multi-phone session."
      )
    }
  }

  /// Localized text for any multiplayer error, `nil` for other errors.
  static func message(forError error: Error, languageCode: String?) -> String? {
    if let error = error as? GuestSessionError {
      return message(for: error, languageCode: languageCode)
    }
    if let error = error as? MultiplayerReasonError {
      return message(for: error.code, languageCode: languageCode)
    }
    if let error = error as? HostSessionError {
      return message(for: error, languageCode: languageCode)
    }
    if let error = error as? MultiplayerCoordinatorError {
      return message(for: error, languageCode: languageCode)
    }
    return nil
  }
}
