import SwiftUI
import SwiftData
#if canImport(WizardDomain)
import WizardDomain
#endif
#if canImport(WizardNet)
import WizardNet
#endif

/// Enables multi-phone on an existing game, or shows the running session (code, seats with phone status) with
/// "End session". An unstarted session shows the lobby content.
struct HostMultiplayerSheet: View {
  enum Mode {
    case enable
    case share
  }

  let gameID: UUID
  let mode: Mode

  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject private var multiplayerCoordinator: MultiplayerCoordinator

  @State private var hostPlayerId: UUID?
  @State private var hostDisplayName: String = GuestJoinPreferences.hostDisplayName
  @State private var enableError: String?
  @State private var enableGame: Game?
  @State private var conflict: HostSessionConflict?
  @State private var seatToUnassign: LobbyPlayerSlot?
  @State private var confirmsEndSession = false

  private var lobby: HostLobbyState? {
    guard let state = multiplayerCoordinator.hostLobbyState, state.gameID == gameID else { return nil }
    return state
  }

  private var trimmedHostName: String {
    hostDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var languageCode: String? {
    AppLanguage.catalogLookupLanguageCode
  }

  var body: some View {
    NavigationStack {
      content
        .navigationTitle(navigationTitle)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("UI.Common.Done") { dismiss() }
          }
        }
    }
    .hostSessionConflictDialog($conflict) { pending in
      multiplayerCoordinator.endSession(gameID: pending.otherGameID)
      if let enableGame {
        createSession(game: enableGame)
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    if let lobby {
      if lobby.hasStarted {
        shareContent(lobby: lobby)
      } else {
        MultiplayerLobbyView(
          gameID: gameID,
          onGameStarted: { dismiss() },
          onSessionEnded: { dismiss() }
        )
      }
    } else if case .enable = mode {
      if let enableGame {
        enableContent(game: enableGame)
      } else {
        ProgressView()
          .task { loadEnableGameIfNeeded() }
      }
    } else {
      ContentUnavailableView {
        Label("UI.GameSession.ShareSession.Title", systemImage: "person.2.slash")
      } description: {
        Text(MultiplayerReasonText.message(for: HostSessionError.sessionEnded, languageCode: languageCode))
      }
    }
  }

  private var navigationTitle: String {
    switch mode {
    case .enable:
      return String(localized: "UI.GameSession.EnableMultiplayer.Title", defaultValue: "Multi-Phone Session")
    case .share:
      return String(localized: "UI.GameSession.ShareSession.Title", defaultValue: "Session")
    }
  }

  // MARK: - Enable

  /// The host's seat: picked, else the seat that already carries the host's name, else the first seat.
  private func selectedHostSeat(in game: Game) -> UUID? {
    if let hostPlayerId, game.players.contains(where: { $0.id == hostPlayerId }) {
      return hostPlayerId
    }
    return MultiPhoneHostRules.defaultHostSeat(in: game.players, preferredName: GuestJoinPreferences.hostDisplayName)
  }

  /// Only a seat that still has its default name takes the host's name; real names are never overwritten.
  private func selectedSeatHasPlaceholderName(in game: Game) -> Bool {
    guard let seat = selectedHostSeat(in: game),
          let index = game.players.firstIndex(where: { $0.id == seat }) else { return false }
    return PlayerNaming.isPlaceholderName(game.players[index].name, playerNumber: index + 1)
  }

  @ViewBuilder
  private func enableContent(game: Game) -> some View {
    Form {
      Section {
        Text("UI.GameSession.EnableMultiplayer.Message")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Section {
        Picker("UI.MultiplayerLobby.HostSlot.Title", selection: Binding(
          get: { selectedHostSeat(in: game) ?? game.players[0].id },
          set: { hostPlayerId = $0 }
        )) {
          ForEach(game.players, id: \.id) { player in
            Text(verbatim: player.name).tag(player.id)
          }
        }
        if selectedSeatHasPlaceholderName(in: game) {
          TextField("UI.MultiplayerLobby.HostName.Placeholder", text: $hostDisplayName)
            .autocorrectionDisabled()
        }
      } header: {
        Text("UI.MultiplayerLobby.HostSection.Header")
      }

      if let enableError {
        Section {
          Text(enableError)
            .foregroundStyle(.red)
        }
      }

      Section {
        Button("UI.GameSession.EnableMultiplayer.Create") {
          createSession(game: game)
        }
        .disabled(selectedSeatHasPlaceholderName(in: game) && trimmedHostName.isEmpty)
      }
    }
  }

  private func loadEnableGameIfNeeded() {
    guard enableGame == nil else { return }
    let store = GameStore(modelContext: modelContext)
    store.loadGame(id: gameID)
    enableGame = store.currentGame
    if enableGame == nil {
      enableError = AppErrorMessage.presentableMessage(for: store.lastError, languageCode: languageCode)
    }
  }

  private func createSession(game: Game) {
    guard let seat = selectedHostSeat(in: game),
          let index = game.players.firstIndex(where: { $0.id == seat }) else { return }
    enableError = nil
    let seatHasPlaceholderName = PlayerNaming.isPlaceholderName(game.players[index].name, playerNumber: index + 1)
    let resolvedName: String
    if seatHasPlaceholderName {
      resolvedName = trimmedHostName.isEmpty
        ? AppLocalization.string("UI.MultiplayerLobby.HostDefaultName", languageCode: languageCode, fallback: "Host")
        : trimmedHostName
    } else {
      resolvedName = game.players[index].name
    }
    do {
      _ = try multiplayerCoordinator.enableMultiplayer(
        gameID: gameID,
        modelContext: modelContext,
        hostPlayerId: seat,
        hostDisplayName: resolvedName
      )
      if seatHasPlaceholderName {
        GuestJoinPreferences.hostDisplayName = resolvedName
      }
    } catch MultiplayerCoordinatorError.anotherSessionActive(let otherGameID, let otherGameName) {
      conflict = HostSessionConflict(otherGameID: otherGameID, otherGameName: otherGameName, retryGameID: gameID)
    } catch {
      enableError = AppErrorMessage.presentableMessage(for: error, languageCode: languageCode)
    }
  }

  // MARK: - Running session

  private func shareContent(lobby: HostLobbyState) -> some View {
    Form {
      HostSessionCodeSection(sessionCode: lobby.sessionCode)

      if let health = MultiPhoneHostRules.sessionHealth(for: lobby.listenerState) {
        Section {
          HostSessionHealthBanner(health: health) {
            multiplayerCoordinator.handleScenePhase(.active)
          }
        }
      }

      Section {
        ForEach(lobby.slots, id: \.playerId) { slot in
          HStack {
            Text(verbatim: slot.name)
            Spacer()
            LobbySeatStatusBadge(status: MultiPhoneHostRules.deviceStatus(of: slot))
          }
          .contextMenu {
            if slot.isBoundToDevice {
              Button(role: .destructive) {
                seatToUnassign = slot
              } label: {
                Label("UI.MultiplayerLobby.Seat.Kick", systemImage: "iphone.slash")
              }
            }
          }
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if slot.isBoundToDevice {
              Button(role: .destructive) {
                seatToUnassign = slot
              } label: {
                Label("UI.MultiplayerLobby.Seat.Kick", systemImage: "iphone.slash")
              }
            }
          }
        }
      } header: {
        Text("UI.MultiplayerLobby.Players.Header")
      } footer: {
        Text("UI.GameSession.ShareSession.Footer")
      }

      Section {
        Button(role: .destructive) {
          confirmsEndSession = true
        } label: {
          Text("UI.GameSession.EndSession.Confirm.Action")
        }
      }
    }
    .keepsScreenAwake(true)
    .seatUnassignDialog($seatToUnassign) { slot in
      _ = multiplayerCoordinator.unassignSeat(gameID: gameID, playerId: slot.playerId)
    }
    .confirmationDialog(
      "UI.GameSession.EndSession.Confirm.Title",
      isPresented: $confirmsEndSession,
      titleVisibility: .visible
    ) {
      Button("UI.GameSession.EndSession.Confirm.Action", role: .destructive) {
        multiplayerCoordinator.endSession(gameID: gameID)
        dismiss()
      }
      Button("UI.Common.Cancel", role: .cancel) {}
    } message: {
      Text("UI.GameSession.EndSession.Confirm.Message")
    }
  }
}
