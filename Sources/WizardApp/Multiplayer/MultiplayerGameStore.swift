import Foundation
import Combine
#if canImport(WizardDomain)
import WizardDomain
#endif
#if canImport(WizardNet)
import WizardNet
#endif

@MainActor
final class MultiplayerGameStore: ObservableObject, GameStoring {
  enum Role: Equatable {
    case host
    case guest(playerId: UUID)
  }

  @Published private(set) var currentGame: Game?
  @Published var lastError: Error?
  @Published private(set) var didAttemptLoad: Bool

  let role: Role
  let sessionID: UUID

  private let hostBackingStore: GameStore?
  private let hostSession: HostSessionService?
  private let guestSession: GuestSessionService?
  private var cancellable: AnyCancellable?

  init(sessionID: UUID, hostBackingStore: GameStore, hostSession: HostSessionService) {
    self.sessionID = sessionID
    self.role = .host
    self.hostBackingStore = hostBackingStore
    self.hostSession = hostSession
    self.guestSession = nil
    self.currentGame = hostBackingStore.currentGame
    self.lastError = hostBackingStore.lastError
    self.didAttemptLoad = hostBackingStore.didAttemptLoad

    cancellable = hostBackingStore.objectWillChange.sink { [weak self] _ in
      guard let self else { return }
      self.currentGame = hostBackingStore.currentGame
      self.lastError = hostBackingStore.lastError
      self.didAttemptLoad = hostBackingStore.didAttemptLoad
      self.objectWillChange.send()
    }

    hostSession.onError = { [weak self] error in
      Task { @MainActor [weak self] in
        self?.lastError = error
      }
    }
  }

  init(sessionID: UUID, guestSession: GuestSessionService, playerId: UUID, setupPlayers: [Player]) {
    self.sessionID = sessionID
    self.role = .guest(playerId: playerId)
    self.hostBackingStore = nil
    self.hostSession = nil
    self.guestSession = guestSession
    self.currentGame = guestSession.game ?? Self.makeSetupGame(players: setupPlayers)
    self.lastError = nil
    self.didAttemptLoad = true

    guestSession.onGameSnapshot = { [weak self] game, _ in
      Task { @MainActor [weak self] in
        self?.currentGame = game
      }
    }
    guestSession.onJoinAccepted = { [weak self] in
      Task { @MainActor [weak self] in
        self?.currentGame = guestSession.game
      }
    }
    guestSession.onCommandResult = { [weak self] result in
      Task { @MainActor [weak self] in
        if result.accepted {
          self?.lastError = nil
        } else {
          self?.lastError = NSError(domain: "WizardNet", code: 1, userInfo: [
            NSLocalizedDescriptionKey: result.reason ?? "Command rejected."
          ])
        }
      }
    }
    guestSession.onSessionEnded = { [weak self] reason in
      Task { @MainActor [weak self] in
        SavedGuestSession.clear()
        self?.lastError = NSError(domain: "WizardNet", code: 2, userInfo: [
          NSLocalizedDescriptionKey: reason
        ])
      }
    }
    guestSession.onError = { [weak self] error in
      Task { @MainActor [weak self] in
        self?.lastError = error
      }
    }
  }

  func syncHostGameFromNetwork(_ game: Game) {
    guard case .host = role, let hostBackingStore else { return }
    hostBackingStore.replaceCurrentGame(game)
    currentGame = game
  }

  func loadGame(id: UUID) {
    if let hostBackingStore {
      hostBackingStore.loadGame(id: id)
      currentGame = hostBackingStore.currentGame
      lastError = hostBackingStore.lastError
      didAttemptLoad = hostBackingStore.didAttemptLoad
      if lastError == nil, let game = currentGame {
        hostSession?.replaceGame(game, revision: (hostSession?.revision ?? 0) + 1)
      }
    }
  }

  func apply(_ command: GameCommand) {
    switch role {
    case .host:
      guard let hostBackingStore else { return }
      hostBackingStore.apply(command)
      currentGame = hostBackingStore.currentGame
      lastError = hostBackingStore.lastError
      if lastError == nil, let game = currentGame {
        hostSession?.replaceGame(game, revision: (hostSession?.revision ?? 0) + 1)
      }
    case .guest:
      do {
        try guestSession?.submitGuestCommand(command)
      } catch {
        lastError = error
      }
    }
  }

  @discardableResult
  func applyBatch(_ commands: [GameCommand], validate: ((Game) throws -> Void)? = nil) -> Error? {
    switch role {
    case .host:
      guard let hostBackingStore else { return nil }
      let error = hostBackingStore.applyBatch(commands, validate: validate)
      currentGame = hostBackingStore.currentGame
      lastError = hostBackingStore.lastError
      if error == nil, let game = currentGame {
        hostSession?.replaceGame(game, revision: (hostSession?.revision ?? 0) + 1)
      }
      return error
    case .guest:
      for command in commands {
        do {
          try guestSession?.submitGuestCommand(command)
        } catch {
          lastError = error
          return error
        }
      }
      return nil
    }
  }

  private static func makeSetupGame(players: [Player]) -> Game? {
    guard players.count >= 2 else { return nil }
    return try? Game(
      id: UUID(),
      name: String(localized: "UI.GameSession.NavigationFallback", defaultValue: "Game"),
      mode: .multiPhone,
      players: players
    )
  }
}
