import SwiftUI
#if canImport(WizardDomain)
import WizardDomain
#endif

struct MultiplayerLobbyView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @EnvironmentObject private var multiplayerCoordinator: MultiplayerCoordinator

  let gameID: UUID
  let onGameStarted: () -> Void

  @State private var hostDisplayName: String = GuestJoinPreferences.hostDisplayName
  @State private var hostPlayerId: UUID?
  @State private var startingDealerIndex: Int = 0
  @State private var enabledGameConstraints: Set<Constraint.GameConstraint> = [.betSumNotEqualHandSize]
  @State private var playWithSpecialCards: Bool = true
  @State private var startError: String?

  private var lobby: HostLobbyState? {
    guard multiplayerCoordinator.hostLobbyState?.gameID == gameID else { return nil }
    return multiplayerCoordinator.hostLobbyState
  }

  private var claimedSlotCount: Int {
    guard let lobby else { return 0 }
    var claimed = lobby.connectedGuestPlayerIDs
    if let hostPlayerId { claimed.insert(hostPlayerId) }
    return claimed.count
  }

  private var allSlotsClaimed: Bool {
    guard let lobby else { return false }
    return claimedSlotCount >= lobby.players.count
  }

  private var canStart: Bool {
    guard let lobby else { return false }
    guard !trimmedHostName.isEmpty else { return false }
    guard allSlotsClaimed else { return false }
    return !lobby.hasStarted
  }

  private var trimmedHostName: String {
    hostDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    NavigationStack {
      Form {
        if let lobby {
          Section {
            Text(lobby.sessionCode)
              .font(.system(.title, design: .monospaced).weight(.bold))
              .frame(maxWidth: .infinity, alignment: .center)
          } header: {
            Text("UI.MultiplayerLobby.JoinCode.Header")
          } footer: {
            Text("UI.MultiplayerLobby.JoinCode.Footer")
          }

          Section {
            TextField("UI.MultiplayerLobby.HostName.Placeholder", text: $hostDisplayName)
              .onChange(of: hostDisplayName) { _, newValue in
                applyHostSlotIfPossible(name: newValue)
              }

            Picker("UI.MultiplayerLobby.HostSlot.Title", selection: Binding(
              get: { hostPlayerId ?? lobby.hostPlayerId },
              set: { newId in
                hostPlayerId = newId
                applyHostSlotIfPossible(name: hostDisplayName)
              }
            )) {
              ForEach(lobby.players, id: \.id) { player in
                let takenByGuest = lobby.connectedGuestPlayerIDs.contains(player.id)
                  && player.id != lobby.hostPlayerId
                Text(slotLabel(for: player, lobby: lobby))
                  .tag(player.id)
                  .disabled(takenByGuest)
              }
            }
          } header: {
            Text("UI.MultiplayerLobby.HostSection.Header")
          }

          Section {
            ForEach(lobby.players, id: \.id) { player in
              HStack {
                Text(player.name)
                Spacer()
                statusLabel(for: player, lobby: lobby)
              }
            }
          } header: {
            Text("UI.MultiplayerLobby.Players.Header")
          } footer: {
            if !allSlotsClaimed {
              Text("UI.MultiplayerLobby.WaitingForPlayers.Footer")
            }
          }

          if allSlotsClaimed {
            Section {
              Picker("UI.NewGame.StartingDealer.Title", selection: $startingDealerIndex) {
                ForEach(Array(lobby.players.enumerated()), id: \.offset) { idx, player in
                  Text(player.name).tag(idx)
                }
              }
              .pickerStyle(.menu)

              Toggle(isOn: $playWithSpecialCards) {
                Text("UI.NewGame.PlayWithSpecialCards.Toggle")
              }
            }

            Section {
              ForEach(Constraint.GameConstraint.allCases, id: \.self) { constraint in
                Toggle(isOn: Binding(
                  get: { enabledGameConstraints.contains(constraint) },
                  set: { isEnabled in
                    if isEnabled {
                      enabledGameConstraints.insert(constraint)
                    } else {
                      enabledGameConstraints.remove(constraint)
                    }
                  }
                )) {
                  Text(LocalizedStringKey(constraint.titleKey))
                }
              }
            } header: {
              Text("UI.NewGame.HouseRules.Header")
            }
          }

          if let startError {
            Section {
              Text(startError)
                .foregroundStyle(.red)
            }
          }
        } else {
          Section {
            ProgressView()
          }
        }
      }
      .navigationTitle("UI.MultiplayerLobby.Title")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("UI.Common.Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("UI.MultiplayerLobby.StartGame") {
            startGame()
          }
          .disabled(!canStart)
        }
      }
    }
    .onAppear {
      seedFromLobby()
    }
    .onChange(of: multiplayerCoordinator.hostLobbyState) { _, _ in
      seedFromLobby()
    }
  }

  @ViewBuilder
  private func statusLabel(for player: Player, lobby: HostLobbyState) -> some View {
    if player.id == lobby.hostPlayerId || player.id == hostPlayerId {
      Text("UI.MultiplayerLobby.Status.Host")
        .foregroundStyle(.blue)
    } else if let guestName = lobby.connectedGuestNames[player.id] {
      Text(
        String(
          format: String(localized: "UI.MultiplayerLobby.Status.ConnectedAs", defaultValue: "Connected as %@", locale: locale),
          locale: locale,
          guestName
        )
      )
      .foregroundStyle(.green)
    } else if lobby.connectedGuestPlayerIDs.contains(player.id) {
      Text("UI.MultiplayerLobby.Status.Connected")
        .foregroundStyle(.green)
    } else {
      Text("UI.MultiplayerLobby.Status.Waiting")
        .foregroundStyle(.secondary)
    }
  }

  private func slotLabel(for player: Player, lobby: HostLobbyState) -> String {
    if lobby.connectedGuestPlayerIDs.contains(player.id), player.id != lobby.hostPlayerId {
      return "\(player.name) (\(String(localized: "UI.MultiplayerLobby.SlotTaken", defaultValue: "taken")))"
    }
    return player.name
  }

  private func seedFromLobby() {
    guard let lobby else { return }
    if hostPlayerId == nil {
      hostPlayerId = lobby.hostPlayerId
    }
    if hostDisplayName.isEmpty {
      hostDisplayName = lobby.hostDisplayName
    }
    startingDealerIndex = min(startingDealerIndex, max(0, lobby.players.count - 1))
  }

  private func applyHostSlotIfPossible(name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let hostPlayerId else { return }
    GuestJoinPreferences.hostDisplayName = trimmed
    multiplayerCoordinator.updateHostSlot(gameID: gameID, playerId: hostPlayerId, displayName: trimmed)
  }

  private func startGame() {
    guard let lobby else { return }
    let dealerId = lobby.players[safe: startingDealerIndex]?.id ?? lobby.players[0].id
    let constraints = Constraint.GameConstraint.allCases.filter { enabledGameConstraints.contains($0) }
    startError = nil
    do {
      try multiplayerCoordinator.startHostedGame(
        gameID: gameID,
        startingDealerId: dealerId,
        gameConstraints: constraints,
        playWithSpecialCards: playWithSpecialCards
      )
      onGameStarted()
      dismiss()
    } catch {
      startError = error.localizedDescription
    }
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    guard indices.contains(index) else { return nil }
    return self[index]
  }
}
