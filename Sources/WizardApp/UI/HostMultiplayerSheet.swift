import SwiftUI
import SwiftData
#if canImport(WizardDomain)
import WizardDomain
#endif

/// Enables multi-phone on an existing game or shows the active session join code.
struct HostMultiplayerSheet: View {
  enum Mode {
    case enable
    case share
  }

  let gameID: UUID
  let mode: Mode

  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @Environment(\.modelContext) private var modelContext
  @EnvironmentObject private var multiplayerCoordinator: MultiplayerCoordinator

  @State private var hostPlayerId: UUID?
  @State private var hostDisplayName: String = GuestJoinPreferences.hostDisplayName
  @State private var enableError: String?
  @State private var didEnable = false
  @State private var enableGame: Game?

  private var lobby: HostLobbyState? {
    guard multiplayerCoordinator.hostLobbyState?.gameID == gameID else { return nil }
    return multiplayerCoordinator.hostLobbyState
  }

  private var trimmedHostName: String {
    hostDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    NavigationStack {
      Group {
        if case .share = mode, let lobby {
          shareContent(lobby: lobby)
        } else if didEnable, let lobby {
          if lobby.hasStarted {
            shareContent(lobby: lobby)
          } else {
            MultiplayerLobbyView(gameID: gameID) {
              dismiss()
            }
          }
        } else if case .enable = mode, let enableGame {
          enableContent(game: enableGame)
        } else if case .enable = mode {
          ProgressView()
            .task { loadEnableGameIfNeeded() }
        } else if let lobby {
          shareContent(lobby: lobby)
        } else {
          ProgressView()
        }
      }
      .navigationTitle(navigationTitle)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("UI.Common.Done") { dismiss() }
        }
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

  @ViewBuilder
  private func enableContent(game: Game) -> some View {
    Form {
      Section {
        Text("UI.GameSession.EnableMultiplayer.Message")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Section {
        TextField("UI.MultiplayerLobby.HostName.Placeholder", text: $hostDisplayName)
        Picker("UI.MultiplayerLobby.HostSlot.Title", selection: Binding(
          get: { hostPlayerId ?? game.players.first?.id ?? UUID() },
          set: { hostPlayerId = $0 }
        )) {
          ForEach(game.players, id: \.id) { player in
            Text(player.name).tag(player.id)
          }
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
        .disabled(trimmedHostName.isEmpty)
      }
    }
    .onAppear {
      if hostPlayerId == nil {
        hostPlayerId = game.players.first?.id
      }
    }
  }

  @ViewBuilder
  private func shareContent(lobby: HostLobbyState) -> some View {
    Form {
      Section {
        Text(lobby.sessionCode)
          .font(.system(.title, design: .monospaced).weight(.bold))
          .frame(maxWidth: .infinity, alignment: .center)
      } header: {
        Text("UI.MultiplayerLobby.JoinCode.Header")
      } footer: {
        Text("UI.GameSession.ShareSession.Footer")
      }

      Section {
        ForEach(lobby.players, id: \.id) { player in
          HStack {
            Text(player.name)
            Spacer()
            playerStatus(player: player, lobby: lobby)
          }
        }
      } header: {
        Text("UI.MultiplayerLobby.Players.Header")
      }
    }
  }

  @ViewBuilder
  private func playerStatus(player: Player, lobby: HostLobbyState) -> some View {
    if player.id == lobby.hostPlayerId {
      Text("UI.MultiplayerLobby.Status.Host")
        .foregroundStyle(.blue)
    } else if let guestName = lobby.connectedGuestNames[player.id] {
      Text(
        String(
          format: String(
            localized: "UI.MultiplayerLobby.Status.ConnectedAs",
            defaultValue: "Connected as %@",
            locale: locale
          ),
          locale: locale,
          guestName
        )
      )
      .foregroundStyle(.green)
      .font(.caption)
    } else if lobby.connectedGuestPlayerIDs.contains(player.id) {
      Text("UI.MultiplayerLobby.Status.Connected")
        .foregroundStyle(.green)
        .font(.caption)
    } else {
      Text("UI.MultiplayerLobby.Status.HostEnters")
        .foregroundStyle(.secondary)
        .font(.caption)
    }
  }

  private func loadEnableGameIfNeeded() {
    guard enableGame == nil else { return }
    let store = GameStore(modelContext: modelContext)
    store.loadGame(id: gameID)
    enableGame = store.currentGame
  }

  private func createSession(game: Game) {
    guard let hostPlayerId else { return }
    enableError = nil
    do {
      let resolvedName = trimmedHostName.isEmpty
        ? String(localized: "UI.MultiplayerLobby.HostDefaultName", defaultValue: "Host")
        : trimmedHostName
      _ = try multiplayerCoordinator.enableMultiplayer(
        gameID: gameID,
        modelContext: modelContext,
        hostPlayerId: hostPlayerId,
        hostDisplayName: resolvedName
      )
      GuestJoinPreferences.hostDisplayName = resolvedName
      didEnable = true
    } catch {
      enableError = error.localizedDescription
    }
  }
}
