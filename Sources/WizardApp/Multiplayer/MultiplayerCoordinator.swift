import Foundation
import SwiftData
#if canImport(WizardDomain)
import WizardDomain
#endif
#if canImport(WizardNet)
import WizardNet
#endif

struct HostLobbyState: Equatable {
  var gameID: UUID
  var gameName: String
  var sessionCode: String
  var players: [Player]
  var hostPlayerId: UUID
  var hostDisplayName: String
  var connectedGuestPlayerIDs: Set<UUID>
  var connectedGuestNames: [UUID: String]
  var hasStarted: Bool
}

@MainActor
final class MultiplayerCoordinator: ObservableObject {
  @Published private(set) var hostLobbyState: HostLobbyState?
  @Published var browser = BonjourBrowser()

  private var hostSessions: [UUID: HostSessionService] = [:]
  private var multiplayerStores: [UUID: MultiplayerGameStore] = [:]

  func store(for sessionID: UUID) -> MultiplayerGameStore? {
    multiplayerStores[sessionID]
  }

  @discardableResult
  func startHosting(
    gameID: UUID,
    modelContext: ModelContext,
    hostPlayerId: UUID,
    hostDisplayName: String
  ) throws -> HostLobbyState {
    if let existing = hostLobbyState, existing.gameID == gameID {
      return existing
    }

    let store = GameStore(modelContext: modelContext)
    store.loadGame(id: gameID)
    guard let game = store.currentGame else {
      throw NSError(domain: "WizardNet", code: 10, userInfo: [
        NSLocalizedDescriptionKey: "Unable to load game for hosting."
      ])
    }

    let trimmedHostName = hostDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    var setupGame = game
    if let idx = setupGame.players.firstIndex(where: { $0.id == hostPlayerId }), !trimmedHostName.isEmpty {
      setupGame.players[idx].name = trimmedHostName
    }
    store.replaceCurrentGame(setupGame)

    let code = SessionCode.random()
    let advertiser = BonjourAdvertiser(sessionCode: code, gameName: setupGame.name)
    let transport = try TCPHostTransport(advertiser: advertiser)
    let hostSession = HostSessionService(
      initialGame: setupGame,
      sessionCode: code,
      transport: transport,
      hostReservedPlayerId: hostPlayerId
    )
    hostSession.reserveHostSlot(playerId: hostPlayerId, displayName: trimmedHostName.isEmpty ? "Host" : trimmedHostName)
    try hostSession.start()

    let multiplayerStore = MultiplayerGameStore(sessionID: gameID, hostBackingStore: store, hostSession: hostSession)
    multiplayerStores[gameID] = multiplayerStore
    hostSessions[gameID] = hostSession

    let lobby = HostLobbyState(
      gameID: gameID,
      gameName: setupGame.name,
      sessionCode: code,
      players: hostSession.game.players,
      hostPlayerId: hostPlayerId,
      hostDisplayName: trimmedHostName.isEmpty ? "Host" : trimmedHostName,
      connectedGuestPlayerIDs: [],
      connectedGuestNames: [:],
      hasStarted: false
    )
    hostLobbyState = lobby

    hostSession.onGuestsChanged = { [weak self] guests in
      Task { @MainActor [weak self] in
        self?.refreshLobby(gameID: gameID, hostSession: hostSession, guests: guests)
      }
    }

    hostSession.onGameSnapshot = { [weak self] game, _ in
      Task { @MainActor [weak self] in
        guard let self, var lobby = self.hostLobbyState, lobby.gameID == gameID else { return }
        lobby.players = game.players
        lobby.hasStarted = game.hasStarted
        self.hostLobbyState = lobby
        self.multiplayerStores[gameID]?.syncHostGameFromNetwork(game)
      }
    }

    hostSession.onLobbyUpdated = { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.refreshLobby(gameID: gameID, hostSession: hostSession, guests: hostSession.guestsByConnection.values.sorted(by: { $0.playerName < $1.playerName }))
      }
    }

    return lobby
  }

  func updateHostSlot(gameID: UUID, playerId: UUID, displayName: String) {
    guard var lobby = hostLobbyState, lobby.gameID == gameID else { return }
    let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    hostSessions[gameID]?.reserveHostSlot(playerId: playerId, displayName: trimmed)
    lobby.hostPlayerId = playerId
    lobby.hostDisplayName = trimmed
    lobby.players = hostSessions[gameID]?.game.players ?? lobby.players
    hostLobbyState = lobby
    multiplayerStores[gameID]?.syncHostGameFromNetwork(hostSessions[gameID]!.game)
  }

  func startHostedGame(
    gameID: UUID,
    startingDealerId: UUID,
    gameConstraints: [Constraint.GameConstraint],
    playWithSpecialCards: Bool
  ) throws {
    guard let hostSession = hostSessions[gameID] else {
      throw NSError(domain: "WizardNet", code: 11, userInfo: [
        NSLocalizedDescriptionKey: "No active host session."
      ])
    }
    try hostSession.startGame(
      startingDealer: startingDealerId,
      gameConstraints: gameConstraints,
      playWithSpecialCards: playWithSpecialCards
    )
    multiplayerStores[gameID]?.syncHostGameFromNetwork(hostSession.game)
    if var lobby = hostLobbyState, lobby.gameID == gameID {
      lobby.players = hostSession.game.players
      lobby.hasStarted = true
      hostLobbyState = lobby
    }
  }

  private func refreshLobby(gameID: UUID, hostSession: HostSessionService, guests: [ConnectedGuest]) {
    guard var lobby = hostLobbyState, lobby.gameID == gameID else { return }
    lobby.players = hostSession.game.players
    lobby.connectedGuestPlayerIDs = Set(guests.map(\.playerId))
    lobby.connectedGuestNames = Dictionary(uniqueKeysWithValues: guests.map { ($0.playerId, $0.playerName) })
    hostLobbyState = lobby
    multiplayerStores[gameID]?.syncHostGameFromNetwork(hostSession.game)
  }

  func stopHosting(gameID: UUID) {
    hostSessions[gameID]?.stop()
    hostSessions.removeValue(forKey: gameID)
    if hostLobbyState?.gameID == gameID {
      hostLobbyState = nil
    }
  }

  func connectGuest(
    discoveredSession: DiscoveredSession,
    sessionCode: String,
    guestToken: String? = nil
  ) throws -> GuestSessionService {
    guard let transport = browser.makeGuestTransport(sessionID: discoveredSession.id) else {
      throw NSError(domain: "WizardNet", code: 20, userInfo: [
        NSLocalizedDescriptionKey: "Unable to connect to selected host."
      ])
    }

    return GuestSessionService(
      sessionCode: sessionCode,
      guestToken: guestToken,
      transport: transport
    )
  }

  func registerJoinedGuest(
    _ guestSession: GuestSessionService,
    playerId: UUID,
    setupPlayers: [Player]
  ) -> UUID {
    let sessionID = UUID()
    let multiplayerStore = MultiplayerGameStore(
      sessionID: sessionID,
      guestSession: guestSession,
      playerId: playerId,
      setupPlayers: setupPlayers
    )
    multiplayerStores[sessionID] = multiplayerStore
    return sessionID
  }
}
