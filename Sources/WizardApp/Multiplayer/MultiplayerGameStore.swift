import Foundation
import Combine
import os
#if canImport(WizardDomain)
import WizardDomain
#endif
#if canImport(WizardNet)
import WizardNet
#endif

private let storeLog = Logger(subsystem: "WizardBlockOfTruth", category: "MultiplayerStore")

/// `GameStoring` for multi-phone sessions.
///
/// **Host:** `HostSessionService.game` is the single source of truth while the session is live. `apply` /
/// `applyBatch` go through `HostSessionService.applyHostCommands` (atomic); every committed change — host or
/// guest — arrives in `hostSessionDidCommit`, is saved to SwiftData synchronously and only then published.
/// `loadGame` never overwrites a live session. After the session ended the store behaves like a plain `GameStore`.
///
/// **Guest:** read-only mirror of the host's snapshots. `apply` sends a guest command and tracks it in
/// `pendingCommand` until it is accepted, rejected (`lastRejection`) or times out.
@MainActor
final class MultiplayerGameStore: ObservableObject, GameStoring {
  enum Role: Equatable {
    case host
    case guest(playerId: UUID)
  }

  @Published private(set) var currentGame: Game?
  @Published var lastError: Error?
  @Published private(set) var didAttemptLoad: Bool
  @Published private(set) var role: Role

  // MARK: Host state

  /// Seats bound to a guest device (connected or not). Host sheets must not overwrite these players' values.
  @Published private(set) var boundGuestPlayerIDs: Set<UUID> = []
  @Published private(set) var connectedGuestPlayerIDs: Set<UUID> = []
  @Published private(set) var hostListenerState: HostListenerState?

  // MARK: Guest state

  @Published private(set) var connectionState: GuestConnectionState = .connected
  /// The command sent last, until the host answered (or it timed out). Disable "Submit" while set.
  @Published private(set) var pendingCommand: PendingGuestCommand?
  @Published private(set) var lastCommandOutcome: GuestCommandOutcome?
  /// Why the host rejected the last command (localize with `MultiplayerReasonText`); cleared on the next submit.
  @Published private(set) var lastRejection: MultiplayerReasonCode?
  /// Live lobby (seats with host / bound / connected flags) while waiting for the start.
  @Published private(set) var lobbySlots: [LobbyPlayerSlot] = []
  /// E.g. `.localNetworkDenied` while reconnecting.
  @Published private(set) var lastTransportFailure: TransportFailure?

  let sessionID: UUID
  /// Guest: the host's Bonjour service name (used for reconnects and the saved session).
  let serviceName: String?

  /// Which screen to show changed (game started / session ended). The coordinator forwards it to SwiftUI.
  var onPresentationChanged: (() -> Void)?
  /// Guest: the session ended with `.gameFinished`; the argument is the final game.
  var onGuestGameFinished: ((Game) -> Void)?

  private let hostBackingStore: GameStore?
  private let hostSession: HostSessionService?
  private let guestSession: GuestSessionService?
  private let defaults: UserDefaults
  /// Guest token this store saved; only this token may clear the saved session.
  private var savedGuestToken: String?

  // MARK: - Host

  init(sessionID: UUID, hostBackingStore: GameStore, hostSession: HostSessionService) {
    self.sessionID = sessionID
    self.role = .host
    self.serviceName = nil
    self.hostBackingStore = hostBackingStore
    self.hostSession = hostSession
    self.guestSession = nil
    self.defaults = .standard
    self.currentGame = hostSession.game
    self.lastError = nil
    self.didAttemptLoad = true
    self.boundGuestPlayerIDs = hostSession.boundGuestPlayerIDs
    self.connectedGuestPlayerIDs = hostSession.connectedGuestPlayerIDs
    self.hostListenerState = hostSession.listenerState
  }

  /// Host: true while the hosted session is live (commands go through the session and reach the guests).
  var isHostSessionLive: Bool {
    hostSession?.isActive == true
  }

  /// Host: is this seat bound to a guest's phone? Bulk entry sheets lock/hide such rows (decision 4).
  func isPlayerBoundToGuestDevice(_ playerId: UUID) -> Bool {
    boundGuestPlayerIDs.contains(playerId)
  }

  /// Host: the session committed a change (host or guest command, lobby edit). Persist first, then publish.
  func hostSessionDidCommit(_ game: Game) {
    let wasStarted = currentGame?.hasStarted == true
    if let hostBackingStore {
      hostBackingStore.replaceCurrentGame(game)
      if let error = hostBackingStore.lastError {
        storeLog.error("Saving the hosted game failed: \(String(describing: error), privacy: .public)")
        lastError = error
      }
    }
    currentGame = game
    if wasStarted != game.hasStarted {
      onPresentationChanged?()
    }
  }

  /// Host: seats / connections / listener changed.
  func hostSessionStateDidChange() {
    guard let hostSession else { return }
    let bound = hostSession.boundGuestPlayerIDs
    if bound != boundGuestPlayerIDs { boundGuestPlayerIDs = bound }
    let connected = hostSession.connectedGuestPlayerIDs
    if connected != connectedGuestPlayerIDs { connectedGuestPlayerIDs = connected }
    let listener: HostListenerState? = hostSession.isActive ? hostSession.listenerState : nil
    if listener != hostListenerState { hostListenerState = listener }
    if !hostSession.isActive, currentGame != hostSession.game {
      currentGame = hostSession.game
    }
  }

  // MARK: - Guest

  init(
    sessionID: UUID,
    guestSession: GuestSessionService,
    playerId: UUID,
    setupPlayers: [Player],
    serviceName: String? = nil,
    defaults: UserDefaults = .standard
  ) {
    self.sessionID = sessionID
    self.role = .guest(playerId: playerId)
    self.serviceName = serviceName
    self.hostBackingStore = nil
    self.hostSession = nil
    self.guestSession = guestSession
    self.defaults = defaults
    self.currentGame = guestSession.game
      ?? Self.makeSetupGame(players: setupPlayers, gameID: guestSession.lobbyGameID, name: guestSession.lobbyGameName)
    self.lastError = nil
    self.didAttemptLoad = true
    self.connectionState = guestSession.connectionState
    self.lobbySlots = guestSession.lobbySlots
    self.lastTransportFailure = guestSession.lastTransportFailure
    wireGuestSession(guestSession)
    persistSavedGuestSession()
  }

  /// Guest: leave for good (the host releases the seat); forgets the saved session.
  func leave() {
    guestSession?.leave()
  }

  /// Guest: close the connection without telling the host (used when a newer session replaces this one).
  func closeGuestSessionLocally() {
    guestSession?.disconnect()
  }

  /// Guest: retry now while reconnecting.
  func reconnectNow() {
    guestSession?.reconnectNow()
  }

  func clearLastRejection() {
    lastRejection = nil
    lastCommandOutcome = nil
  }

  func handleAppDidBecomeActive() {
    guestSession?.handleAppDidBecomeActive()
  }

  func isBacked(by session: GuestSessionService) -> Bool {
    guestSession === session
  }

  var guestSessionCode: String? {
    guestSession?.sessionCode
  }

  private func wireGuestSession(_ session: GuestSessionService) {
    session.onJoinLobby = nil
    session.onCommandResult = nil
    session.onGameSnapshot = { [weak self] game, _ in
      self?.guestDidReceive(game)
    }
    session.onJoinAccepted = { [weak self] in
      self?.guestSeatDidChange()
    }
    session.onSlotClaimed = { [weak self] in
      self?.guestSeatDidChange()
    }
    session.onLobbyUpdated = { [weak self] slots in
      self?.guestLobbyDidChange(slots)
    }
    session.onCommandOutcome = { [weak self] commandID, outcome in
      self?.guestCommandDidFinish(commandID, outcome: outcome)
    }
    session.onConnectionStateChanged = { [weak self] state in
      self?.connectionState = state
    }
    session.onTransportFailureChanged = { [weak self] failure in
      self?.lastTransportFailure = failure
    }
    session.onSessionEnded = { [weak self] reason in
      self?.guestSessionDidEnd(reason)
    }
    session.onError = { [weak self] error in
      self?.lastError = error
    }
  }

  private func guestDidReceive(_ game: Game) {
    let wasStarted = currentGame?.hasStarted == true
    currentGame = game
    if !wasStarted && game.hasStarted {
      onPresentationChanged?()
    }
  }

  private func guestSeatDidChange() {
    guard let guestSession else { return }
    if let playerId = guestSession.playerId, role != .guest(playerId: playerId) {
      role = .guest(playerId: playerId)
    }
    if let game = guestSession.game {
      guestDidReceive(game)
    }
    persistSavedGuestSession()
  }

  private func guestLobbyDidChange(_ slots: [LobbyPlayerSlot]) {
    lobbySlots = slots
    guard currentGame?.hasStarted != true else { return }
    // Before the start the lobby *is* the game for the waiting screen: keep names and seat order live.
    let players = slots.map { Player(id: $0.playerId, name: $0.name) }
    if let setup = Self.makeSetupGame(
      players: players,
      gameID: guestSession?.lobbyGameID ?? currentGame?.id,
      name: guestSession?.lobbyGameName ?? currentGame?.name
    ), setup != currentGame {
      currentGame = setup
    }
  }

  private func guestCommandDidFinish(_ commandID: UUID, outcome: GuestCommandOutcome) {
    if pendingCommand?.id == commandID {
      pendingCommand = nil
    }
    lastCommandOutcome = outcome
    switch outcome {
    case .accepted:
      lastRejection = nil
    case .rejected(let code):
      lastRejection = code
      lastError = MultiplayerReasonError(code: code)
    case .timedOut:
      lastError = GuestSessionError.commandTimedOut
    }
  }

  private func guestSessionDidEnd(_ reason: GuestSessionEndReason) {
    connectionState = .ended(reason)
    pendingCommand = nil
    if reason.invalidatesSavedSession, let savedGuestToken {
      SavedGuestSession.clear(token: savedGuestToken, defaults: defaults)
    }
    if reason == .gameFinished, let game = currentGame, game.hasStarted {
      onGuestGameFinished?(game)
    }
    onPresentationChanged?()
  }

  private func persistSavedGuestSession() {
    guard let guestSession, let token = guestSession.guestToken, let playerId = guestSession.playerId else { return }
    let name = guestSession.playerName ?? ""
    savedGuestToken = token
    SavedGuestSession.save(
      SavedGuestSession(
        guestToken: token,
        sessionCode: guestSession.sessionCode,
        playerId: playerId,
        playerName: name,
        hostDisplayName: nil,
        serviceName: serviceName,
        gameName: guestSession.lobbyGameName ?? currentGame?.name
      ),
      defaults: defaults
    )
    if !name.isEmpty {
      GuestJoinPreferences.displayName = name
    }
  }

  @discardableResult
  private func submitGuestCommands(_ commands: [GameCommand]) -> Error? {
    guard let guestSession else { return nil }
    for command in commands {
      do {
        let commandID = try guestSession.submitGuestCommand(command)
        pendingCommand = guestSession.pendingCommands[commandID]
        lastCommandOutcome = nil
        lastRejection = nil
      } catch {
        lastError = error
        return error
      }
    }
    return nil
  }

  // MARK: - GameStoring

  func loadGame(id: UUID) {
    if let hostSession, hostSession.isActive {
      // Live session: the session game is the source of truth; never reload it from disk (H4).
      currentGame = hostSession.game
      didAttemptLoad = true
      return
    }
    guard let hostBackingStore else { return }
    hostBackingStore.loadGame(id: id)
    mirrorBackingStore()
  }

  func apply(_ command: GameCommand) {
    switch role {
    case .host:
      if let hostSession, hostSession.isActive {
        lastError = hostSession.applyHostCommands([command])
      } else if let hostBackingStore {
        hostBackingStore.apply(command)
        mirrorBackingStore()
      }
    case .guest:
      submitGuestCommands([command])
    }
  }

  @discardableResult
  func applyBatch(_ commands: [GameCommand], validate: ((Game) throws -> Void)? = nil) -> Error? {
    switch role {
    case .host:
      if let hostSession, hostSession.isActive {
        let error = hostSession.applyHostCommands(commands, validate: validate)
        lastError = error
        return error
      }
      guard let hostBackingStore else { return nil }
      let error = hostBackingStore.applyBatch(commands, validate: validate)
      mirrorBackingStore()
      return error
    case .guest:
      return submitGuestCommands(commands)
    }
  }

  private func mirrorBackingStore() {
    guard let hostBackingStore else { return }
    currentGame = hostBackingStore.currentGame
    lastError = hostBackingStore.lastError
    didAttemptLoad = hostBackingStore.didAttemptLoad
  }

  private static func makeSetupGame(players: [Player], gameID: UUID?, name: String?) -> Game? {
    guard players.count >= 2 else { return nil }
    return try? Game(
      id: gameID ?? UUID(),
      name: name ?? String(localized: "UI.GameSession.NavigationFallback", defaultValue: "Game"),
      mode: .multiPhone,
      players: players
    )
  }
}
