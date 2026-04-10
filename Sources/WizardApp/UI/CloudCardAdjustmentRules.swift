import Foundation

enum CloudCardAdjustmentRules {
  static func changedPlayerId(
    playerIds: [UUID],
    baseBets: [UUID: Int],
    editedBets: [UUID: Int]
  ) -> UUID? {
    let changed = playerIds.filter { playerId in
      guard let base = baseBets[playerId], let edited = editedBets[playerId] else { return false }
      return base != edited
    }
    return changed.count == 1 ? changed[0] : nil
  }

  static func isPlayerLocked(
    playerId: UUID,
    playerIds: [UUID],
    baseBets: [UUID: Int],
    editedBets: [UUID: Int]
  ) -> Bool {
    guard let changed = changedPlayerId(playerIds: playerIds, baseBets: baseBets, editedBets: editedBets) else {
      return false
    }
    return changed != playerId
  }

  static func allowedRange(
    playerId: UUID,
    handSize: Int,
    playerIds: [UUID],
    baseBets: [UUID: Int],
    editedBets: [UUID: Int]
  ) -> ClosedRange<Int> {
    let currentEditedValue = editedBets[playerId] ?? 0
    if isPlayerLocked(
      playerId: playerId,
      playerIds: playerIds,
      baseBets: baseBets,
      editedBets: editedBets
    ) {
      return currentEditedValue...currentEditedValue
    }

    guard let base = baseBets[playerId] else { return 0...handSize }
    let lower = max(0, base - 1)
    let upper = min(handSize, base + 1)
    return lower...upper
  }
}
