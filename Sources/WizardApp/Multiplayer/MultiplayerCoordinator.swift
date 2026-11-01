import Foundation
import Combine
import SwiftData
import SwiftUI
import os
#if canImport(WizardDomain)
import WizardDomain
#endif
#if canImport(WizardNet)
import WizardNet
#endif

private let coordinatorLog = Logger(subsystem: "WizardBlockOfTruth", category: "Multiplayer")

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
  /// Per seat (table order): name, host flag, bound to a guest device, connected right now.
  var slots: [LobbyPlayerSlot]
  /// Seats bound to a guest device (connected or not).
  var boundGuestPlayerIDs: Set<UUID>
  /// Bonjour listener health (show a banner unless `.ready`).
  var listenerState: HostListenerState
}

enum MultiplayerCoordinatorError: Error, Equatable, LocalizedError {
  /// Only one hosted session at a time: ask "End session for <gameName>?", then `endSession(gameID:)` and retry.
  case anotherSessionActive(gameID: UUID, gameName: String)
  case gameNotFound(UUID)
  case noActiveHostSession

  var errorDescription: String? {
    MultiplayerReasonText.message(for: self, languageCode: AppLanguage.catalogLookupLanguageCode)
  }
}

/// Creates the network transports (tests inject in-memory ones).
struct MultiplayerTransportFactory {
  var makeHostTransport: @MainActor (_ serviceName: String) throws -> any HostSessionTransport
  var makeGuestTransport: @MainActor (_ serviceName: String) -> any GuestSessionTransport

  static var network: MultiplayerTransportFactory {
    MultiplayerTransportFactory(
      makeHostTransport: { serviceName in TCPHostTransport(serviceName: serviceName) },
      makeGuestTransport: { serviceName in TCPGuestTransport(serviceName: serviceName) }
    )
  }
}

/// Owns the (single) hosted session and the guest session(s) of this device.
@MainActor
final class MultiplayerCoordinator: ObservableObject {
  @Published private(set) var hostLobbyState: HostLobbyState?
  /// Discovery for the join screen. Its changes are forwarded to `objectWillChange`, so views observing the
  /// coordinator re-render when sessions appear/disappear.
  let browser: BonjourBrowser

  private struct HostContext {
    let gameID: UUID
    let session: HostSessionService
    let store: MultiplayerGameStore
    var hostPlayerId: UUID
    var hostDisplayName: String
  }

  private var hostContext: HostContext?
  private var guestStores: [UUID: MultiplayerGameStore] = [:]
  private let defaults: UserDefaults
  private let transportFactory: MultiplayerTransportFactory
  private let timing: SessionTiming
  private let makeSessionCode: () -> String
  private var browserCancellable: AnyCancellable?

  init(
    defaults: UserDefaults = .standard,
    transportFactory: MultiplayerTransportFactory = .network,
    timing: SessionTiming = .standard,
    makeSessionCode: @escaping () -> String = { SessionCode.random() }
  ) {
    self.defaults = defaults
    self.transportFactory = transportFactory
    self.timing = timing
    self.makeSessionCode = makeSessionCode
    self.browser = BonjourBrowser()
    browserCancellable = browser.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
  }

  /// Store for a hosted game id or a guest session id.
  func store(for sessionID: UUID) -> MultiplayerGameStore? {
    if let hostContext, hostContext.gameID == sessionID {
      return hostContext.store
    }
    return guestStores[sessionID]
  }

  // MARK: - Hosting

  /// The game hosted right now (at most one).
  var activeHostedGameID: UUID? {
    hostContext?.gameID
  }

  func isHosting(gameID: UUID) -> Bool {
    hostContext?.gameID == gameID
  }

  /// A persisted session for this game can be resumed (`resumeHosting`) — it was live when the app quit.
  func hasResumableHostSession(gameID: UUID) -> Bool {
    HostSessionPersistence.load(gameID: gameID, defaults: defaults) != nil
  }

  /// Starts hosting `gameID` (or returns the running lobby of that game).
  ///
  /// Throws `MultiplayerCoordinatorError.anotherSessionActive` when another game is hosted (one session at a time).
  /// Reuses a persisted session code and guest registry of this game, so guests can rejoin after a relaunch.
  /// Only a placeholder-named host seat takes `hostDisplayName`; real names are never overwritten.
  @discardableResult
  func startHosting(
    gameID: UUID,
    modelContext: ModelContext,
    hostPlayerId: UUID,
    hostDisplayName: String
  ) throws -> HostLobbyState {
    if let context = hostContext {
      if context.gameID == gameID, let lobby = hostLobbyState {
        return lobby
      }
      throw MultiplayerCoordinatorError.anotherSessionActive(
        gameID: context.gameID,
        gameName: context.session.game.name
      )
    }

    let backingStore = GameStore(modelContext: modelContext)
    backingStore.loadGame(id: gameID)
    guard let storedGame = backingStore.currentGame else {
      HostSessionPersistence.clear(gameID: gameID, defaults: defaults)
      throw MultiplayerCoordinatorError.gameNotFound(gameID)
    }

    let record = HostSessionPersistence.load(gameID: gameID, defaults: defaults)
    let trimmedHostName = hostDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedHostName = trimmedHostName.isEmpty
      ? AppLocalization.string(
        "UI.MultiplayerLobby.HostDefaultName",
        languageCode: AppLanguage.catalogLookupLanguageCode,
        fallback: "Host"
      )
      : trimmedHostName

    var game = storedGame
    game.mode = .multiPhone
    if let index = game.players.firstIndex(where: { $0.id == hostPlayerId }),
       PlayerNaming.isPlaceholderName(game.players[index].name, playerNumber: index + 1) {
      game.players[index].name = String(resolvedHostName.prefix(SeatNameRules.maxLength))
    }
    if game != storedGame {
      backingStore.replaceCurrentGame(game)
    }

    let code = record?.sessionCode ?? makeSessionCode()
    let serviceName = BonjourAdvertiser.serviceName(sessionCode: code, gameName: game.name)
    let transport = try transportFactory.makeHostTransport(serviceName)
    let session = HostSessionService(
      initialGame: game,
      sessionCode: code,
      transport: transport,
      initialRevision: record.map { $0.revision + 1 } ?? 0,
      hostReservedPlayerId: hostPlayerId,
      guestRegistry: record?.guestRegistry ?? [:],
      timing: timing
    )
    session.placeholderLanguageCode = AppLanguage.catalogLookupLanguageCode
    let store = MultiplayerGameStore(sessionID: gameID, hostBackingStore: backingStore, hostSession: session)
    store.onPresentationChanged = { [weak self] in
      self?.objectWillChange.send()
    }
    wireHostSession(session, store: store, gameID: gameID)
    hostContext = HostContext(
      gameID: gameID,
      session: session,
      store: store,
      hostPlayerId: hostPlayerId,
      hostDisplayName: resolvedHostName
    )

    do {
      try session.start()
    } catch {
      coordinatorLog.error("Starting the host session failed: \(String(describing: error), privacy: .public)")
      hostContext = nil
      throw error
    }

    persistHostRecord()
    refreshHostLobby()
    guard let lobby = hostLobbyState else {
      throw MultiplayerCoordinatorError.noActiveHostSession
    }
    return lobby
  }

  /// Converts an existing single-phone game to multi-phone and starts hosting (same player roster).
  @discardableResult
  func enableMultiplayer(
    gameID: UUID,
    modelContext: ModelContext,
    hostPlayerId: UUID,
    hostDisplayName: String
  ) throws -> HostLobbyState {
    try startHosting(
      gameID: gameID,
      modelContext: modelContext,
      hostPlayerId: hostPlayerId,
      hostDisplayName: hostDisplayName
    )
  }

  /// Resumes a session that was live when the app quit (same code and guest registry; guests reconnect).
  /// Returns `nil` when there is nothing to resume.
  @discardableResult
  func resumeHosting(gameID: UUID, modelContext: ModelContext) throws -> HostLobbyState? {
    if isHosting(gameID: gameID) {
      return hostLobbyState
    }
    guard let record = HostSessionPersistence.load(gameID: gameID, defaults: defaults) else { return nil }
    return try startHosting(
      gameID: gameID,
      modelContext: modelContext,
      hostPlayerId: record.hostPlayerId,
      hostDisplayName: record.hostDisplayName
    )
  }

  /// Ends the hosted session: guests get `sessionEnded(hostEnded)` before the sockets close; the store is
  /// released and the persisted session record removed.
  func endSession(gameID: UUID) {
    guard let context = hostContext, context.gameID == gameID else {
      HostSessionPersistence.clear(gameID: gameID, defaults: defaults)
      return
    }
    context.session.stop(reason: .hostEnded)
  }

  func stopHosting(gameID: UUID) {
    endSession(gameID: gameID)
  }

  func updateHostSlot(gameID: UUID, playerId: UUID, displayName: String) {
    guard var context = hostContext, context.gameID == gameID else { return }
    let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard context.session.reserveHostSlot(playerId: playerId, displayName: trimmed) else { return }
    context.hostPlayerId = playerId
    context.hostDisplayName = trimmed
    hostContext = context
    hostSessionDidChange(gameID: gameID)
  }

  func startHostedGame(
    gameID: UUID,
    startingDealerId: UUID,
    gameConstraints: [Constraint.GameConstraint],
    playWithSpecialCards: Bool,
    firstRoundBetSumMayEqualHandSize: Bool = false
  ) throws {
    guard let hostSession = activeHostSession(for: gameID) else {
      throw MultiplayerCoordinatorError.noActiveHostSession
    }
    try hostSession.startGame(
      startingDealer: startingDealerId,
      gameConstraints: gameConstraints,
      playWithSpecialCards: playWithSpecialCards,
      firstRoundBetSumMayEqualHandSize: firstRoundBetSumMayEqualHandSize
    )
    hostSessionDidChange(gameID: gameID)
  }

  /// Host lobby: rename a seat (`SeatNameRules`; throws `HostSessionError.nameInvalid` / `.nameTaken`).
  func renameSeat(gameID: UUID, playerId: UUID, name: String) throws {
    guard let hostSession = activeHostSession(for: gameID) else {
      throw MultiplayerCoordinatorError.noActiveHostSession
    }
    try hostSession.renameSeat(playerId: playerId, to: name)
  }

  /// Host lobby: new seat order (before the start; every seat exactly once).
  func reorderSeats(gameID: UUID, orderedPlayerIDs: [UUID]) throws {
    guard let hostSession = activeHostSession(for: gameID) else {
      throw MultiplayerCoordinatorError.noActiveHostSession
    }
    try hostSession.reorderSeats(orderedPlayerIDs)
  }

  /// Host: unassign (kick) a guest's seat; the seat keeps its name and becomes claimable.
  @discardableResult
  func unassignSeat(gameID: UUID, playerId: UUID) -> Bool {
    activeHostSession(for: gameID)?.unassignSeat(playerId: playerId) ?? false
  }

  /// Host: is this player bound to a guest's device (connected or not)?
  func isSeatBoundToDevice(gameID: UUID, playerId: UUID) -> Bool {
    activeHostSession(for: gameID)?.isSeatBoundToDevice(playerId) ?? false
  }

  private func activeHostSession(for gameID: UUID) -> HostSessionService? {
    guard let context = hostContext, context.gameID == gameID else { return nil }
    return context.session
  }

  private func wireHostSession(_ session: HostSessionService, store: MultiplayerGameStore, gameID: UUID) {
    session.onGameSnapshot = { [weak self, weak store] game, _ in
      // Synchronous: the change is in SwiftData before the next command is processed (H4).
      store?.hostSessionDidCommit(game)
      self?.hostSessionDidChange(gameID: gameID)
    }
    session.onGuestsChanged = { [weak self] _ in
      self?.hostSessionDidChange(gameID: gameID)
    }
    session.onLobbyUpdated = { [weak self] _ in
      self?.hostSessionDidChange(gameID: gameID)
    }
    session.onRegistryChanged = { [weak self] _ in
      self?.hostSessionDidChange(gameID: gameID)
    }
    session.onListenerStateChanged = { [weak self] _ in
      self?.hostSessionDidChange(gameID: gameID)
    }
    session.onSessionEnded = { [weak self] reason in
      self?.hostSessionDidEnd(gameID: gameID, reason: reason)
    }
    session.onGuestCommandRejected = { guest, code in
      // Already answered to the guest; never alert the host about it (M7).
      coordinatorLog.info("Rejected command from \(guest.playerName, privacy: .public): \(code.rawCode, privacy: .public)")
    }
    session.onError = { error in
      coordinatorLog.error("Host session error: \(String(describing: error), privacy: .public)")
    }
  }

  private func hostSessionDidChange(gameID: UUID) {
    guard let context = hostContext, context.gameID == gameID, context.session.isActive else { return }
    context.store.hostSessionStateDidChange()
    persistHostRecord()
    refreshHostLobby()
  }

  private func hostSessionDidEnd(gameID: UUID, reason: SessionEndReason) {
    HostSessionPersistence.clear(gameID: gameID, defaults: defaults)
    guard let context = hostContext, context.gameID == gameID else { return }
    coordinatorLog.info("Hosted session ended: \(reason.rawValue, privacy: .public)")
    context.store.hostSessionStateDidChange()
    hostContext = nil
    hostLobbyState = nil
  }

  private func persistHostRecord() {
    guard let context = hostContext, context.session.isActive else { return }
    let session = context.session
    let record = HostSessionRecord(
      gameID: context.gameID,
      sessionCode: session.sessionCode,
      hostPlayerId: session.hostReservedPlayerId ?? context.hostPlayerId,
      hostDisplayName: context.hostDisplayName,
      guestRegistry: session.registeredGuests,
      revision: session.revision
    )
    HostSessionPersistence.save(record, defaults: defaults)
  }

  private func refreshHostLobby() {
    guard let context = hostContext else {
      if hostLobbyState != nil { hostLobbyState = nil }
      return
    }
    let session = context.session
    let guests = Array(session.guestsByConnection.values)
    var guestNames: [UUID: String] = [:]
    for guest in guests {
      guestNames[guest.playerId] = guest.playerName
    }
    let lobby = HostLobbyState(
      gameID: context.gameID,
      gameName: session.game.name,
      sessionCode: session.sessionCode,
      players: session.game.players,
      hostPlayerId: session.hostReservedPlayerId ?? context.hostPlayerId,
      hostDisplayName: context.hostDisplayName,
      connectedGuestPlayerIDs: Set(guests.map(\.playerId)),
      connectedGuestNames: guestNames,
      hasStarted: session.game.hasStarted,
      slots: session.lobbySlots,
      boundGuestPlayerIDs: session.boundGuestPlayerIDs,
      listenerState: session.listenerState
    )
    if lobby != hostLobbyState {
      hostLobbyState = lobby
    }
  }

  // MARK: - Guest

  func connectGuest(
    discoveredSession: DiscoveredSession,
    sessionCode: String,
    guestToken: String? = nil
  ) throws -> GuestSessionService {
    connectGuest(serviceName: discoveredSession.serviceName, sessionCode: sessionCode, guestToken: guestToken)
  }

  /// Connects by Bonjour service name (no browse result needed, e.g. for "Rejoin").
  func connectGuest(serviceName: String, sessionCode: String, guestToken: String? = nil) -> GuestSessionService {
    GuestSessionService(
      sessionCode: sessionCode,
      guestToken: guestToken,
      transport: transportFactory.makeGuestTransport(serviceName),
      timing: timing
    )
  }

  /// Rejoin from the saved session (nil for sessions saved by app 1.1 without a service name).
  func connectGuest(savedSession: SavedGuestSession) -> GuestSessionService? {
    guard let serviceName = savedSession.serviceName else { return nil }
    return connectGuest(
      serviceName: serviceName,
      sessionCode: savedSession.sessionCode,
      guestToken: savedSession.guestToken
    )
  }

  /// Hands a guest session over to a store right after `claimAccepted` (or `joinAccepted`): from then on the
  /// store persists the rejoin token and owns the session's callbacks. Returns the id to navigate to
  /// (`GameSessionContainerView(gameId:)`). Older guest sessions are closed (one guest session at a time).
  func registerJoinedGuest(
    _ guestSession: GuestSessionService,
    playerId: UUID,
    setupPlayers: [Player],
    serviceName: String? = nil,
    modelContext: ModelContext? = nil
  ) -> UUID {
    if let existing = guestStores.first(where: { $0.value.isBacked(by: guestSession) }) {
      return existing.key
    }
    for (sessionID, store) in guestStores {
      store.closeGuestSessionLocally()
      guestStores.removeValue(forKey: sessionID)
    }

    let sessionID = UUID()
    let store = MultiplayerGameStore(
      sessionID: sessionID,
      guestSession: guestSession,
      playerId: playerId,
      setupPlayers: setupPlayers,
      serviceName: serviceName,
      defaults: defaults
    )
    store.onPresentationChanged = { [weak self] in
      self?.objectWillChange.send()
    }
    store.onGuestGameFinished = { [weak self] game in
      self?.saveFinishedGuestGame(game, modelContext: modelContext)
    }
    guestStores[sessionID] = store
    objectWillChange.send()
    return sessionID
  }

  /// Ids of guest sessions (newest first is not guaranteed; there is normally at most one).
  var guestSessionIDs: [UUID] {
    Array(guestStores.keys)
  }

  /// Guest: leave the session for good (host releases the seat) and drop the store.
  func leaveGuestSession(sessionID: UUID) {
    guestStores[sessionID]?.leave()
    removeGuestSession(sessionID: sessionID)
  }

  /// Drops an (ended) guest store.
  func removeGuestSession(sessionID: UUID) {
    guard let store = guestStores.removeValue(forKey: sessionID) else { return }
    store.closeGuestSessionLocally()
    objectWillChange.send()
  }

  /// Local read-only copy of a finished game (ids in `GuestFinishedGames`).
  private func saveFinishedGuestGame(_ game: Game, modelContext: ModelContext?) {
    guard let modelContext else { return }
    let store = GameStore(modelContext: modelContext)
    store.replaceCurrentGame(game)
    if let error = store.lastError {
      coordinatorLog.error("Saving the finished guest game failed: \(String(describing: error), privacy: .public)")
      return
    }
    GuestFinishedGames.insert(game.id, defaults: defaults)
  }

  // MARK: - App lifecycle

  /// Call from `.onChange(of: scenePhase)`. On `.active`: the host restarts a failed listener (same code) and
  /// guests reconnect right away.
  func handleScenePhase(_ phase: ScenePhase) {
    guard phase == .active else { return }
    hostContext?.session.handleAppDidBecomeActive()
    for store in guestStores.values {
      store.handleAppDidBecomeActive()
    }
  }
}
