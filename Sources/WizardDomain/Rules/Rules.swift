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
}

