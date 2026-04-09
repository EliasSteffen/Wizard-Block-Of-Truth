import Foundation
import SwiftData

@MainActor
final class GameStore: ObservableObject {
  @Published private(set) var currentGame: Game?
  @Published var lastError: DomainError?

  private let modelContext: ModelContext

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  func loadGame(id: UUID) {
    do {
      let descriptor = FetchDescriptor<GameSnapshotEntity>(
        predicate: #Predicate { $0.id == id }
      )
      guard let entity = try modelContext.fetch(descriptor).first else { return }
      currentGame = try GameCodec.decode(entity.gameJSON)
    } catch {
      // For now we only surface domain errors.
      lastError = error as? DomainError
    }
  }

  func createGame(name: String, mode: GameMode, players: [Player]) {
    do {
      let game = try Game(id: UUID(), name: name, mode: mode, players: players)
      currentGame = game
      try upsert(game: game)
    } catch {
      lastError = error as? DomainError
    }
  }

  func apply(_ command: GameCommand) {
    guard var game = currentGame else { return }
    do {
      try game.apply(command)
      currentGame = game
      try upsert(game: game)
    } catch {
      lastError = error as? DomainError
    }
  }

  private func upsert(game: Game) throws {
    let data = try GameCodec.encode(game)
    let descriptor = FetchDescriptor<GameSnapshotEntity>(
      predicate: #Predicate { $0.id == game.id }
    )
    if let existing = try modelContext.fetch(descriptor).first {
      existing.name = game.name
      existing.updatedAt = .now
      existing.gameJSON = data
    } else {
      modelContext.insert(
        GameSnapshotEntity(id: game.id, name: game.name, gameJSON: data)
      )
    }
    try modelContext.save()
  }
}

