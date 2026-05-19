import Foundation
import SwiftData
#if canImport(WizardDomain)
import WizardDomain
#endif

@MainActor
final class GameStore: ObservableObject, GameStoring {
  @Published private(set) var currentGame: Game?
  @Published var lastError: Error?
  @Published private(set) var didAttemptLoad: Bool = false

  private let modelContext: ModelContext

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  func loadGame(id: UUID) {
    didAttemptLoad = false
    defer { didAttemptLoad = true }
    do {
      let descriptor = FetchDescriptor<GameSnapshotEntity>(
        predicate: #Predicate { $0.id == id }
      )
      guard let entity = try modelContext.fetch(descriptor).first else {
        currentGame = nil
        let lang = AppLanguage.catalogLookupLanguageCode
        lastError = NSError(
          domain: "WizardApp",
          code: 404,
          userInfo: [
            NSLocalizedDescriptionKey: AppLocalization.format(
              "Error.GameStore.NotFound",
              languageCode: lang,
              fallback: "Game not found (id: %@).",
              id.uuidString
            ),
          ]
        )
        return
      }
      currentGame = try GameCodec.decode(entity.gameJSON)
      lastError = nil
    } catch {
      lastError = error
    }
  }

  func createGame(
    name: String,
    mode: GameMode,
    players: [Player],
    playWithSpecialCards: Bool = true,
    gameConstraints: [Constraint.GameConstraint] = [.betSumNotEqualHandSize]
  ) {
    do {
      let game = try Game(
        id: UUID(),
        name: name,
        mode: mode,
        playWithSpecialCards: playWithSpecialCards,
        players: players,
        gameConstraints: gameConstraints
      )
      currentGame = game
      try upsert(game: game)
    } catch {
      lastError = error
    }
  }

  func replaceCurrentGame(_ game: Game) {
    currentGame = game
    do {
      try upsert(game: game)
      lastError = nil
    } catch {
      lastError = error
    }
  }

  func apply(_ command: GameCommand) {
    guard var game = currentGame else { return }
    do {
      try game.apply(command)
      currentGame = game
      try upsert(game: game)
    } catch {
      lastError = error
    }
  }

  /// Applies multiple commands atomically.
  ///
  /// If any command (or `validate`) fails, no changes are persisted to `currentGame`.
  @discardableResult
  func applyBatch(_ commands: [GameCommand], validate: ((Game) throws -> Void)? = nil) -> Error? {
    guard var game = currentGame else {
      let lang = AppLanguage.catalogLookupLanguageCode
      let err = NSError(
        domain: "WizardApp",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: AppLocalization.string(
            "Error.GameStore.NoGameLoaded",
            languageCode: lang,
            fallback: "No game loaded."
          ),
        ]
      )
      lastError = err
      return err
    }
    do {
      for cmd in commands {
        try game.apply(cmd)
      }
      try validate?(game)
      currentGame = game
      lastError = nil
      try upsert(game: game)
      return nil
    } catch {
      lastError = error
      return error
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

