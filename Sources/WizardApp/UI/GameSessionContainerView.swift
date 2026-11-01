import SwiftUI
import SwiftData
#if canImport(WizardDomain)
import WizardDomain
#endif
#if canImport(WizardNet)
import WizardNet
#endif

/// Routes a game id (or a guest session id) to the right screen:
/// - guest session → waiting room / guest game,
/// - hosted lobby (session live, not started) → `MultiplayerLobbyView` inside this pushed screen; after Start it
///   switches to the game (no pop),
/// - read-only copy of a finished guest game → `GameSessionView` read-only, never hosted,
/// - unstarted multi-phone game without a running session → its lobby is opened (never single-phone entry, M1),
/// - everything else → `GameSessionView` (host or single-phone). A started, unfinished game whose session was live when
///   the app quit resumes hosting; a finished game never does (its stale record is dropped).
struct GameSessionContainerView: View {
  let gameId: UUID

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var multiplayerCoordinator: MultiplayerCoordinator
  @State private var multiplayerSheetMode: GameSessionMultiplayerSheetMode?
  /// The stored game's mode and progress (routing while no session is live), loaded once per id.
  @State private var storedGame: StoredGameSummary?
  @State private var didLoadStoredGame = false
  @State private var lobbyError: String?
  @State private var conflict: HostSessionConflict?

  private struct StoredGameSummary: Equatable {
    var name: String
    var mode: GameMode
    var hasStarted: Bool
    var isFinished: Bool
    var players: [Player]
  }

  private var guestStore: MultiplayerGameStore? {
    guard let store = multiplayerCoordinator.store(for: gameId), case .guest = store.role else { return nil }
    return store
  }

  private var isHosting: Bool {
    multiplayerCoordinator.isHosting(gameID: gameId)
  }

  /// A finished game a guest kept from a host's session: strictly read-only.
  private var isReadOnlyGuestCopy: Bool {
    guestStore == nil && GuestFinishedGames.contains(gameId)
  }

  /// The hosted session of this game is live and not started yet.
  private var showsHostLobby: Bool {
    guard isHosting, let lobby = multiplayerCoordinator.hostLobbyState, lobby.gameID == gameId else { return false }
    return !lobby.hasStarted
  }

  /// An unstarted multi-phone game without a running session belongs in the lobby.
  private var needsLobby: Bool {
    guard !isHosting, let storedGame else { return false }
    return storedGame.mode == .multiPhone && !storedGame.hasStarted
  }

  private var showsHostControls: Bool {
    guestStore == nil && !isReadOnlyGuestCopy && !showsHostLobby && !needsLobby
  }

  var body: some View {
    sessionContent
      .gameSessionHostMultiplayerToolbar(
        gameID: gameId,
        showsControls: showsHostControls,
        isHosting: isHosting,
        sheetMode: $multiplayerSheetMode
      )
      .hostSessionConflictDialog($conflict) { pending in
        multiplayerCoordinator.endSession(gameID: pending.otherGameID)
        hostAfterConflict()
      }
      .task(id: gameId) {
        prepare()
      }
      .onChange(of: multiplayerCoordinator.hostLobbyState?.hasStarted) { _, hasStarted in
        // Keep the routing summary current once the hosted lobby starts (so a later session end stays in the game).
        guard multiplayerCoordinator.hostLobbyState?.gameID == gameId,
              let hasStarted,
              var summary = storedGame,
              summary.hasStarted != hasStarted
        else { return }
        summary.hasStarted = hasStarted
        storedGame = summary
      }
  }

  @ViewBuilder
  private var sessionContent: some View {
    if let guestStore {
      if guestStore.currentGame?.hasStarted == true {
        GuestGameSessionView(store: guestStore)
      } else {
        GuestWaitingView(store: guestStore)
      }
    } else if showsHostLobby {
      MultiplayerLobbyView(
        gameID: gameId,
        onGameStarted: {},
        onSessionEnded: { dismiss() }
      )
    } else if !didLoadStoredGame && !isHosting {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .wizardBackground()
    } else if isReadOnlyGuestCopy {
      GameSessionView(gameId: gameId, isReadOnlyGuestCopy: true)
    } else if needsLobby {
      lobbyPlaceholder
    } else {
      GameSessionView(gameId: gameId)
    }
  }

  private var lobbyPlaceholder: some View {
    ContentUnavailableView {
      Label("UI.GameSession.Lobby.Unavailable.Title", systemImage: "person.2.wave.2")
    } description: {
      Text(
        lobbyError ?? AppLocalization.string(
          "UI.GameSession.Lobby.Unavailable.Message",
          languageCode: AppLanguage.catalogLookupLanguageCode,
          fallback: "This multi-phone game hasn’t started yet. Open its lobby so guests can join."
        )
      )
    } actions: {
      Button("UI.MultiplayerLobby.Open") {
        openLobby()
      }
      .buttonStyle(.borderedProminent)
    }
    .navigationTitle(storedGame?.name ?? "")
#if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
#endif
    .wizardBackground()
  }

  // MARK: - Hosting

  private func prepare() {
    reloadStoredGame()
    guard guestStore == nil, !isReadOnlyGuestCopy, let storedGame else { return }
    if storedGame.isFinished {
      // A finished game is never hosted again; drop a stale session record.
      if !isHosting, multiplayerCoordinator.hasResumableHostSession(gameID: gameId) {
        multiplayerCoordinator.endSession(gameID: gameId)
      }
      return
    }
    guard !isHosting else { return }
    if needsLobby {
      openLobby()
    } else if multiplayerCoordinator.hasResumableHostSession(gameID: gameId) {
      resumeSession()
    }
  }

  private func reloadStoredGame() {
    let store = GameStore(modelContext: modelContext)
    store.loadGame(id: gameId)
    storedGame = store.currentGame.map { game in
      StoredGameSummary(
        name: game.name,
        mode: game.mode,
        hasStarted: game.hasStarted,
        isFinished: HostSessionService.isGameFinished(game),
        players: game.players
      )
    }
    didLoadStoredGame = true
  }

  /// Opens the lobby of an unstarted multi-phone game: resumes its saved session (same code, guests keep their
  /// seats) or starts a new one. Only a seat with a default name takes the host's name.
  private func openLobby() {
    guard let storedGame else { return }
    lobbyError = nil
    do {
      if multiplayerCoordinator.hasResumableHostSession(gameID: gameId) {
        _ = try multiplayerCoordinator.resumeHosting(gameID: gameId, modelContext: modelContext)
      } else {
        let preferredName = GuestJoinPreferences.hostDisplayName
        guard let hostSeat = MultiPhoneHostRules.defaultHostSeat(in: storedGame.players, preferredName: preferredName)
        else { return }
        _ = try multiplayerCoordinator.startHosting(
          gameID: gameId,
          modelContext: modelContext,
          hostPlayerId: hostSeat,
          hostDisplayName: preferredName
        )
      }
    } catch MultiplayerCoordinatorError.anotherSessionActive(let otherGameID, let otherGameName) {
      conflict = HostSessionConflict(otherGameID: otherGameID, otherGameName: otherGameName, retryGameID: gameId)
    } catch {
      lobbyError = AppErrorMessage.presentableMessage(for: error, languageCode: AppLanguage.catalogLookupLanguageCode)
    }
  }

  /// Re-hosts a started game whose session was live when the app quit (same code, so guests reconnect).
  private func resumeSession() {
    do {
      _ = try multiplayerCoordinator.resumeHosting(gameID: gameId, modelContext: modelContext)
    } catch MultiplayerCoordinatorError.anotherSessionActive(let otherGameID, let otherGameName) {
      conflict = HostSessionConflict(otherGameID: otherGameID, otherGameName: otherGameName, retryGameID: gameId)
    } catch {
      // The game stays playable on this phone (the saved session is kept for the next attempt); the host can also
      // enable multi-phone again from the toolbar.
    }
  }

  private func hostAfterConflict() {
    guard !isHosting else { return }
    if needsLobby {
      openLobby()
    } else if multiplayerCoordinator.hasResumableHostSession(gameID: gameId) {
      resumeSession()
    }
  }
}
