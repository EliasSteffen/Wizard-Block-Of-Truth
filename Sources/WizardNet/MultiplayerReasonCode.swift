import Foundation

/// Why the host ended a multi-phone session.
public enum SessionEndReason: String, Codable, Sendable, Equatable, CaseIterable {
  /// The host ended the session (or hosting stopped).
  case hostEnded
  /// The final round was finalized; the last snapshot before `sessionEnded` is the final scoreboard.
  case gameFinished
}

/// Typed reason codes on `joinRejected`, `commandResult` and `sessionEnded` (wire protocol v2).
///
/// The app maps each code to a localized message (`MultiplayerReasonText` in WizardApp); free text on the wire is
/// for logs only. Codes this build does not know decode as `.unknown(rawCode)` instead of failing the frame.
public enum MultiplayerReasonCode: Sendable, Equatable, Hashable {
  // MARK: Joining
  /// The peer speaks another wire protocol version ("please update the app").
  case versionMismatch
  /// Wrong session code: this host runs another session.
  case sessionNotFound
  /// The seat is the host's seat or already bound to another guest's device (or no seat is open).
  case seatTaken
  case seatNotFound
  /// Name is empty or longer than `SeatNameRules.maxLength` characters (after trimming).
  case nameInvalid
  /// Another seat already uses this name (case-insensitive).
  case nameTaken
  /// The rejoin token is unknown (seat was released). The host follows up with the lobby.
  case tokenInvalid

  // MARK: Guest commands
  case notYourSeat
  case notCurrentRound
  case roundFinalized
  /// All bets of the round are in (or the Cloud card was played): bets can no longer be changed.
  case betsComplete
  /// Won tricks can only be entered once every bet is in.
  case betsIncomplete
  /// The bet would make the sum of all bets equal the hand size while that house rule applies.
  case betSumEqualsHandSize(handSize: Int)
  /// Value outside `0...handSize` (or otherwise rejected by the game rules).
  case invalidValue
  case gameNotStarted
  /// Host-only command, or the connection has not joined a seat.
  case notAuthorized

  // MARK: Session lifetime
  case sessionEnded(SessionEndReason)
  /// The host unassigned this guest's seat.
  case kicked

  // MARK: Fallbacks
  case internalError
  case unknown(String)

  /// Join rejections after which the host closes the connection (retrying with the same data cannot work).
  public var isFatalForJoin: Bool {
    switch self {
    case .versionMismatch, .sessionNotFound:
      return true
    default:
      return false
    }
  }

  /// Stable string on the wire.
  public var rawCode: String {
    switch self {
    case .versionMismatch: return "versionMismatch"
    case .sessionNotFound: return "sessionNotFound"
    case .seatTaken: return "seatTaken"
    case .seatNotFound: return "seatNotFound"
    case .nameInvalid: return "nameInvalid"
    case .nameTaken: return "nameTaken"
    case .tokenInvalid: return "tokenInvalid"
    case .notYourSeat: return "notYourSeat"
    case .notCurrentRound: return "notCurrentRound"
    case .roundFinalized: return "roundFinalized"
    case .betsComplete: return "betsComplete"
    case .betsIncomplete: return "betsIncomplete"
    case .betSumEqualsHandSize: return "betSumEqualsHandSize"
    case .invalidValue: return "invalidValue"
    case .gameNotStarted: return "gameNotStarted"
    case .notAuthorized: return "notAuthorized"
    case .sessionEnded: return "sessionEnded"
    case .kicked: return "kicked"
    case .internalError: return "internalError"
    case .unknown(let raw): return raw
    }
  }
}

extension MultiplayerReasonCode: Codable {
  private enum CodingKeys: String, CodingKey {
    case code
    case handSize
    case endReason
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let code = try container.decode(String.self, forKey: .code)
    switch code {
    case "versionMismatch": self = .versionMismatch
    case "sessionNotFound": self = .sessionNotFound
    case "seatTaken": self = .seatTaken
    case "seatNotFound": self = .seatNotFound
    case "nameInvalid": self = .nameInvalid
    case "nameTaken": self = .nameTaken
    case "tokenInvalid": self = .tokenInvalid
    case "notYourSeat": self = .notYourSeat
    case "notCurrentRound": self = .notCurrentRound
    case "roundFinalized": self = .roundFinalized
    case "betsComplete": self = .betsComplete
    case "betsIncomplete": self = .betsIncomplete
    case "betSumEqualsHandSize":
      self = .betSumEqualsHandSize(handSize: try container.decode(Int.self, forKey: .handSize))
    case "invalidValue": self = .invalidValue
    case "gameNotStarted": self = .gameNotStarted
    case "notAuthorized": self = .notAuthorized
    case "sessionEnded":
      let raw = try container.decodeIfPresent(String.self, forKey: .endReason)
      self = .sessionEnded(raw.flatMap(SessionEndReason.init(rawValue:)) ?? .hostEnded)
    case "kicked": self = .kicked
    case "internalError": self = .internalError
    default: self = .unknown(code)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(rawCode, forKey: .code)
    switch self {
    case .betSumEqualsHandSize(let handSize):
      try container.encode(handSize, forKey: .handSize)
    case .sessionEnded(let reason):
      try container.encode(reason.rawValue, forKey: .endReason)
    default:
      break
    }
  }
}
