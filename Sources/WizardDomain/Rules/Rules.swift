import Foundation

public enum Rules {
  public static func maxHandSize(deckSize: Int, playerCount: Int) -> Int {
    guard playerCount > 0 else { return 0 }
    return deckSize / playerCount
  }

  public static func nextDealer(players: [Player], currentDealer: UUID) throws -> UUID {
    guard let idx = players.firstIndex(where: { $0.id == currentDealer }) else {
      throw DomainError.unknownPlayerId(currentDealer)
    }
    let next = (idx + 1) % players.count
    return players[next].id
  }

  /// Seat order for bidding: first player after the dealer, dealer last.
  public static func playersInBettingOrder(players: [Player], dealerId: UUID) -> [Player] {
    guard !players.isEmpty,
          let dealerIdx = players.firstIndex(where: { $0.id == dealerId })
    else { return players }
    let start = (dealerIdx + 1) % players.count
    return Array(players[start...]) + Array(players[..<start])
  }
}

