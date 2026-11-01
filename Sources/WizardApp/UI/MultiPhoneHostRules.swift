import Foundation
#if canImport(WizardDomain)
import WizardDomain
#endif
#if canImport(WizardNet)
import WizardNet
#endif

/// Pure decisions behind the multi-phone host screens: which rows the bulk entry sheets show, whom the host waits
/// for, the finalize error text, lobby seat edits and session health. No SwiftUI, so `WizardAppTests` cover them.
enum MultiPhoneHostRules {
  // MARK: - Entry in the open round (decision 4)

  enum EntryKind: Equatable, Sendable {
    case bets
    case wonTricks
  }

  /// What the host's primary action offers in the open round.
  enum EntryStep: Equatable {
    /// At least one seat without a phone still needs a value: open the bulk sheet.
    case enter(EntryKind)
    /// Only seats bound to a guest's phone are missing: show whom the host waits for (in betting order).
    case waiting(EntryKind, players: [Player])
    /// Every bet and won trick is in.
    case finalize
  }

  /// Rows of the host's bulk "Enter bets" / "Enter won tricks" sheet: every seat that is not bound to a guest device,
  /// in the given order. Device-bound seats are never listed, so the sheet never writes (or zeroes) their values.
  static func bulkEntryPlayers(_ orderedPlayers: [Player], boundPlayerIDs: Set<UUID>) -> [Player] {
    orderedPlayers.filter { !boundPlayerIDs.contains($0.id) }
  }

  /// Players (in `orderedPlayers` order) whose value of `kind` is still missing in `round`.
  static func missingPlayers(_ kind: EntryKind, in round: Round, orderedPlayers: [Player]) -> [Player] {
    orderedPlayers.filter { value(kind, of: $0.id, in: round) == nil }
  }

  static func entryStep(for round: Round, orderedPlayers: [Player], boundPlayerIDs: Set<UUID>) -> EntryStep {
    for kind in [EntryKind.bets, EntryKind.wonTricks] {
      let missing = missingPlayers(kind, in: round, orderedPlayers: orderedPlayers)
      guard !missing.isEmpty else { continue }
      if missing.contains(where: { !boundPlayerIDs.contains($0.id) }) {
        return .enter(kind)
      }
      return .waiting(kind, players: missing)
    }
    return .finalize
  }

  /// Sum of the entered values of `playerIDs` (missing values count as 0).
  static func enteredSum(_ kind: EntryKind, in round: Round, playerIDs: Set<UUID>) -> Int {
    playerIDs.reduce(0) { partial, playerId in
      partial + (value(kind, of: playerId, in: round) ?? 0)
    }
  }

  /// True when every player in `playerIDs` has a value of `kind` (also for an empty set).
  static func allEntered(_ kind: EntryKind, in round: Round, playerIDs: Set<UUID>) -> Bool {
    playerIDs.allSatisfy { value(kind, of: $0, in: round) != nil }
  }

  /// "Waiting for Anna" / "Waiting for 2 players: Anna, Ben".
  static func waitingTitle(for players: [Player], languageCode: String?) -> String {
    let names = players.map(\.name).joined(separator: ", ")
    if players.count == 1 {
      return AppLocalization.format(
        "UI.GameSession.Multiplayer.WaitingFor.One",
        languageCode: languageCode,
        fallback: "Waiting for %@",
        names
      )
    }
    return AppLocalization.format(
      "UI.GameSession.Multiplayer.WaitingFor.Many",
      languageCode: languageCode,
      fallback: "Waiting for %1$lld players: %2$@",
      players.count,
      names
    )
  }

  static func waitingHint(for kind: EntryKind, languageCode: String?) -> String {
    switch kind {
    case .bets:
      return AppLocalization.string(
        "UI.GameSession.Multiplayer.WaitingFor.Bets.Hint",
        languageCode: languageCode,
        fallback: "Guests enter their bets on their phones. Tap a bet to enter it for them."
      )
    case .wonTricks:
      return AppLocalization.string(
        "UI.GameSession.Multiplayer.WaitingFor.Won.Hint",
        languageCode: languageCode,
        fallback: "Guests enter their won tricks on their phones. Tap a value to enter it for them."
      )
    }
  }

  private static func value(_ kind: EntryKind, of playerId: UUID, in round: Round) -> Int? {
    switch kind {
    case .bets:
      return round.entries[playerId]?.bet
    case .wonTricks:
      return round.entries[playerId]?.got
    }
  }

  // MARK: - Finalize (won tricks must add up)

  struct TrickSumMismatch: Equatable {
    let handSize: Int
    /// The round was declared with the Bomb (sum must be `handSize - 1`).
    let bombPlayed: Bool
    /// The game plays with special cards (the Bomb could be turned on).
    let bombAvailable: Bool
    let expected: Int
    let actual: Int
  }

  /// Sum the won tricks must reach: the hand size, or one less with the Bomb.
  static func expectedWonTricksSum(handSize: Int, bombPlayed: Bool) -> Int {
    bombPlayed ? max(0, handSize - 1) : handSize
  }

  /// Round constraints for finalizing `round` (the declared Bomb only counts with special cards).
  static func finalizeConstraints(for round: Round, playWithSpecialCards: Bool) -> [Constraint.RoundConstraint] {
    [playWithSpecialCards && round.bombPlayed ? .gotSumEqualsHandSizeMinusOne : .gotSumEqualsHandSize]
  }

  /// Why finalizing `round` fails on the won-tricks sum, or `nil` when it adds up (or values are still missing).
  static func trickSumMismatch(in round: Round, playWithSpecialCards: Bool) -> TrickSumMismatch? {
    guard !round.entries.isEmpty, round.entries.values.allSatisfy({ $0.got != nil }) else { return nil }
    let bombPlayed = playWithSpecialCards && round.bombPlayed
    let expected = expectedWonTricksSum(handSize: round.handSize, bombPlayed: bombPlayed)
    let actual = round.entries.values.reduce(0) { $0 + ($1.got ?? 0) }
    guard actual != expected else { return nil }
    return TrickSumMismatch(
      handSize: round.handSize,
      bombPlayed: bombPlayed,
      bombAvailable: playWithSpecialCards,
      expected: expected,
      actual: actual
    )
  }

  /// Fix-it text for a failed finalize: expected vs. entered sum (and the Bomb, when it may explain the gap).
  static func trickSumMismatchMessage(_ mismatch: TrickSumMismatch, languageCode: String?) -> String {
    if mismatch.bombPlayed {
      return AppLocalization.format(
        "UI.GameSession.FinalizeError.Message.Bomb",
        languageCode: languageCode,
        fallback: "The won tricks add up to %1$lld, but with the Bomb this round needs %2$lld (hand size %3$lld − 1). Correct the values or turn off the Bomb, then finalize the round.",
        mismatch.actual,
        mismatch.expected,
        mismatch.handSize
      )
    }
    let message = AppLocalization.format(
      "UI.GameSession.FinalizeError.Message",
      languageCode: languageCode,
      fallback: "The won tricks add up to %1$lld, but this round has %2$lld tricks. Tap a value on the scoreboard to correct it, then finalize the round.",
      mismatch.actual,
      mismatch.expected
    )
    guard mismatch.bombAvailable, mismatch.actual == mismatch.handSize - 1 else { return message }
    let hint = AppLocalization.string(
      "UI.GameSession.FinalizeError.BombHint",
      languageCode: languageCode,
      fallback: "Was the Bomb played? Turn it on, then the won tricks add up."
    )
    return message + "\n\n" + hint
  }

  // MARK: - Lobby seats (decision 3)

  enum SeatDeviceStatus: Equatable, Sendable {
    case host
    case phoneConnected
    case phoneOffline
    case noPhone
  }

  static func deviceStatus(of slot: LobbyPlayerSlot) -> SeatDeviceStatus {
    if slot.isHost { return .host }
    guard slot.isBoundToDevice else { return .noPhone }
    return slot.isConnected ? .phoneConnected : .phoneOffline
  }

  /// The host may rename seats without a phone and their own seat; a guest's seat keeps the guest's name.
  static func isNameEditableByHost(_ slot: LobbyPlayerSlot) -> Bool {
    slot.isHost || !slot.isBoundToDevice
  }

  /// Seats the host may pick for themselves: their own and every seat not bound to a guest's phone.
  static func hostSeatOptions(_ slots: [LobbyPlayerSlot]) -> [LobbyPlayerSlot] {
    slots.filter { $0.isHost || !$0.isBoundToDevice }
  }

  /// What committing a name field (on submit / focus loss) should do.
  enum SeatNameCommit: Equatable {
    /// Nothing changed (or an empty field on a seat that still has its default name).
    case none
    /// The field was emptied on a named seat: show the current name again.
    case revert
    case rename(String)
    case rejected(MultiplayerReasonCode)
  }

  static func seatNameCommit(draft: String, slot: LobbyPlayerSlot, players: [Player]) -> SeatNameCommit {
    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return slot.isPlaceholderName ? .none : .revert
    }
    if trimmed == slot.name {
      return .none
    }
    if let rejection = SeatNameRules.rejection(for: trimmed, in: players, seat: slot.playerId) {
      return .rejected(rejection)
    }
    return .rename(SeatNameRules.normalized(trimmed) ?? trimmed)
  }

  /// Why the host can't move to `seat` with `hostName` (`nil` = allowed). Seats bound to a guest's phone are refused,
  /// and the host's name must stay unique (the old host seat gets its default name back).
  static func hostSeatChangeRejection(
    to seat: UUID,
    hostName: String,
    slots: [LobbyPlayerSlot],
    players: [Player]
  ) -> HostSessionError? {
    guard let target = slots.first(where: { $0.playerId == seat }) else { return .seatNotFound }
    if target.isHost { return nil }
    if target.isBoundToDevice { return .seatBoundToDevice }
    guard let name = SeatNameRules.normalized(hostName) else { return .nameInvalid }
    var excluded: Set<UUID> = [seat]
    if let current = slots.first(where: \.isHost) {
      excluded.insert(current.playerId)
    }
    return SeatNameRules.isTaken(name, in: players, excluding: excluded) ? .nameTaken : nil
  }

  /// `ids` after moving the elements at `source` to `destination` (same semantics as SwiftUI's `onMove`).
  static func movedIDs(_ ids: [UUID], fromOffsets source: IndexSet, toOffset destination: Int) -> [UUID] {
    let valid = source.filter { ids.indices.contains($0) }
    guard !valid.isEmpty else { return ids }
    let moving = valid.map { ids[$0] }
    var result = ids
    for index in valid.reversed() {
      result.remove(at: index)
    }
    let clamped = min(max(0, destination), ids.count)
    let insertAt = clamped - valid.filter { $0 < clamped }.count
    result.insert(contentsOf: moving, at: min(max(0, insertAt), result.count))
    return result
  }

  /// Moves one seat up (`-1`) or down (`+1`); `nil` when it is already at that end.
  static func movedIDs(_ ids: [UUID], moving id: UUID, by offset: Int) -> [UUID]? {
    guard let index = ids.firstIndex(of: id) else { return nil }
    let target = index + offset
    guard ids.indices.contains(target), target != index else { return nil }
    var result = ids
    result.swapAt(index, target)
    return result
  }

  /// The chosen dealer if that seat still exists, otherwise the first seat. Tracked by id, so reordering never changes it.
  static func resolvedDealerID(selected: UUID?, seatIDs: [UUID]) -> UUID? {
    if let selected, seatIDs.contains(selected) { return selected }
    return seatIDs.first
  }

  /// Seat for the host when (re)opening a lobby without a saved session: the seat that already carries the host's
  /// name, otherwise the first seat.
  static func defaultHostSeat(in players: [Player], preferredName: String) -> UUID? {
    let name = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty, let match = players.first(where: {
      $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame
    }) {
      return match.id
    }
    return players.first?.id
  }

  /// Devices in the session: the host's phone plus every connected guest phone.
  static func connectedDeviceCount(_ slots: [LobbyPlayerSlot]) -> Int {
    1 + slots.filter { !$0.isHost && $0.isConnected }.count
  }

  // MARK: - Session health

  enum SessionHealth: Equatable, Sendable {
    /// Local Network permission is off: guests can't find the session.
    case localNetworkDenied
    /// The listener is down or restarting.
    case unreachable
  }

  /// `nil` while the listener is fine (or still starting); a warning otherwise.
  static func sessionHealth(for listenerState: HostListenerState?) -> SessionHealth? {
    switch listenerState {
    case .waiting(let failure)?, .failed(let failure)?:
      return failure == .localNetworkDenied ? .localNetworkDenied : .unreachable
    case .ready?, .starting?, .stopped?, nil:
      return nil
    }
  }
}
