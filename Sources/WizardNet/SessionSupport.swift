import Foundation
#if canImport(WizardDomain)
import WizardDomain
#endif

/// Timing knobs of a multi-phone session. Tests use short intervals; the app uses `.standard`.
public struct SessionTiming: Sendable, Equatable {
  /// Host pings every connection that said hello this often; the guest checks for silence at the same rate.
  public var pingInterval: TimeInterval
  /// No message for this long means the connection is lost (both sides).
  public var silenceTimeout: TimeInterval
  /// A guest whose `hello` gets no reply for this long gives up (`hostIncompatibleOrUnreachable` on the first
  /// connect; a failed attempt while reconnecting).
  public var helloReplyTimeout: TimeInterval
  /// A guest command without `commandResult` for this long is reported as timed out.
  public var commandTimeout: TimeInterval
  /// Delays between guest reconnect attempts; the last value repeats until the guest leaves.
  public var reconnectDelays: [TimeInterval]
  /// Host: base delay before re-creating a failed listener (multiplied by the attempt number).
  public var listenerRestartDelay: TimeInterval
  /// Host: automatic listener restarts before waiting for the app to become active again.
  public var maxListenerRestartAttempts: Int

  public init(
    pingInterval: TimeInterval = 5,
    silenceTimeout: TimeInterval = 15,
    helloReplyTimeout: TimeInterval = 8,
    commandTimeout: TimeInterval = 8,
    reconnectDelays: [TimeInterval] = [0.5, 1, 2, 4, 8],
    listenerRestartDelay: TimeInterval = 1,
    maxListenerRestartAttempts: Int = 5
  ) {
    self.pingInterval = pingInterval
    self.silenceTimeout = silenceTimeout
    self.helloReplyTimeout = helloReplyTimeout
    self.commandTimeout = commandTimeout
    self.reconnectDelays = reconnectDelays
    self.listenerRestartDelay = listenerRestartDelay
    self.maxListenerRestartAttempts = maxListenerRestartAttempts
  }

  public static let standard = SessionTiming()

  static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
    UInt64(max(0, seconds) * 1_000_000_000)
  }

  func reconnectDelay(attempt: Int) -> TimeInterval {
    guard !reconnectDelays.isEmpty else { return 1 }
    return reconnectDelays[min(max(attempt, 1), reconnectDelays.count) - 1]
  }
}

/// Seat name rules shared by host validation and (in the app) pre-validation in the UI.
public enum SeatNameRules {
  public static let maxLength = 24

  /// The trimmed name if it has 1…24 characters, otherwise `nil` (→ `MultiplayerReasonCode.nameInvalid`).
  public static func normalized(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
    return trimmed
  }

  /// True when another seat (not in `excluding`) already uses `name`, compared case-insensitively.
  public static func isTaken(_ name: String, in players: [Player], excluding: Set<UUID> = []) -> Bool {
    let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return players.contains { player in
      !excluding.contains(player.id)
        && player.name.trimmingCharacters(in: .whitespacesAndNewlines)
          .caseInsensitiveCompare(candidate) == .orderedSame
    }
  }

  /// `nil` when `raw` is a valid, unique name for `seat`; otherwise the reason to show.
  public static func rejection(for raw: String, in players: [Player], seat: UUID) -> MultiplayerReasonCode? {
    guard let name = normalized(raw) else { return .nameInvalid }
    return isTaken(name, in: players, excluding: [seat]) ? .nameTaken : nil
  }
}

/// Hands transport events (delivered serially on a transport queue) to a main-actor handler in arrival order.
///
/// One `DispatchQueue.main` hop per event keeps FIFO order end to end (no per-event `Task`, which may reorder).
final class MainActorEventInbox<Event: Sendable>: Sendable {
  private let handler: @MainActor @Sendable (Event) -> Void

  init(handler: @escaping @MainActor @Sendable (Event) -> Void) {
    self.handler = handler
  }

  func post(_ event: Event) {
    let handler = self.handler
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        handler(event)
      }
    }
  }
}
