import Foundation

enum GameCodec {
  static func encode(_ game: Game) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(game)
  }

  static func decode(_ data: Data) throws -> Game {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Game.self, from: data)
  }
}

