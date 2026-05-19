import SwiftUI
#if canImport(WizardNet)
import WizardNet
#endif

struct JoinGameView: View {
  let onJoined: (UUID) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @EnvironmentObject private var multiplayerCoordinator: MultiplayerCoordinator

  @State private var codeFilter: String = ""
  @State private var customDisplayName: String = GuestJoinPreferences.displayName
  @State private var selectedSessionID: String?
  @State private var joinError: String?
  @State private var isConnecting = false
  @State private var pendingGuest: GuestSessionService?
  @State private var lobbySlots: [LobbyPlayerSlot] = []
  @State private var isWaitingForHost = false
  @State private var claimedPlayerName: String?
  @State private var savedSession: SavedGuestSession? = SavedGuestSession.load()

  private var filteredSessions: [DiscoveredSession] {
    let normalized = codeFilter.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !normalized.isEmpty else { return multiplayerCoordinator.browser.sessions }
    return multiplayerCoordinator.browser.sessions.filter { $0.code.uppercased().contains(normalized) }
  }

  private var unclaimedSlots: [LobbyPlayerSlot] {
    lobbySlots.filter { !$0.isClaimed }
  }

  private var trimmedCustomName: String {
    customDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var isPickingPlayer: Bool {
    !lobbySlots.isEmpty && !isWaitingForHost
  }

  var body: some View {
    NavigationStack {
      Form {
        if isWaitingForHost {
          waitingForHostSection
        } else if isPickingPlayer {
          playerPickerSections
        } else {
          rejoinSection
          browseSections
        }

        if let joinError {
          Section {
            Text(joinError)
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle(navigationTitle)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(cancelButtonTitle) {
            if isWaitingForHost || isPickingPlayer {
              resetPicker()
            } else {
              dismiss()
            }
          }
        }
        if !isPickingPlayer && !isWaitingForHost {
          ToolbarItem(placement: .confirmationAction) {
            Button("Connect") { connectToSession() }
              .disabled(selectedSessionID == nil || isConnecting)
          }
        }
      }
    }
    .onAppear {
      multiplayerCoordinator.browser.start()
      customDisplayName = GuestJoinPreferences.displayName
      savedSession = SavedGuestSession.load()
    }
    .onDisappear { multiplayerCoordinator.browser.stop() }
  }

  private var navigationTitle: String {
    if isWaitingForHost {
      return String(localized: "UI.JoinGame.Waiting.Title", defaultValue: "Waiting for Host")
    }
    if isPickingPlayer {
      return String(localized: "UI.JoinGame.ChoosePlayer.Title", defaultValue: "Choose Player")
    }
    return String(localized: "UI.JoinGame.Title", defaultValue: "Join Game")
  }

  private var cancelButtonTitle: String {
    if isWaitingForHost || isPickingPlayer {
      return String(localized: "UI.Common.Back", defaultValue: "Back")
    }
    return String(localized: "UI.Common.Cancel", defaultValue: "Cancel")
  }

  @ViewBuilder
  private var rejoinSection: some View {
    if let savedSession {
      Section {
        Button {
          rejoinSavedSession(savedSession)
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(
              String(
                format: String(
                  localized: "UI.JoinGame.Rejoin.Button",
                  defaultValue: "Rejoin as %@",
                  locale: locale
                ),
                locale: locale,
                savedSession.playerName
              )
            )
            .font(.headline)
            Text(
              String(
                format: String(
                  localized: "UI.JoinGame.Rejoin.Code",
                  defaultValue: "Code: %@",
                  locale: locale
                ),
                locale: locale,
                savedSession.sessionCode
              )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        .disabled(isConnecting)

        Button("UI.JoinGame.Rejoin.Forget", role: .destructive) {
          SavedGuestSession.clear()
          self.savedSession = nil
        }
      } header: {
        Text("UI.JoinGame.Rejoin.Header")
      }
    }
  }

  @ViewBuilder
  private var waitingForHostSection: some View {
    Section {
      if let claimedPlayerName {
        Text(
          String(
            format: String(localized: "UI.JoinGame.Waiting.Claimed", defaultValue: "You joined as %@.", locale: locale),
            locale: locale,
            claimedPlayerName
          )
        )
      }
      Text("UI.JoinGame.Waiting.Message")
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var browseSections: some View {
    Section {
      TextField("Filter by code", text: $codeFilter)
#if os(iOS)
        .textInputAutocapitalization(.characters)
#endif
    } footer: {
      Text("Optional. Select a session below — Connect uses that session’s full code, not this filter.")
    }

    Section("Available Sessions") {
      if filteredSessions.isEmpty {
        Text("No sessions found on local network.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(filteredSessions) { session in
          HStack {
            VStack(alignment: .leading) {
              Text(session.displayName)
              Text("Code: \(session.code)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if selectedSessionID == session.id {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            }
          }
          .contentShape(Rectangle())
          .onTapGesture {
            selectedSessionID = session.id
            codeFilter = session.code
          }
        }
      }
    }
  }

  @ViewBuilder
  private var playerPickerSections: some View {
    if unclaimedSlots.isEmpty {
      Section {
        Text("UI.JoinGame.NoOpenSlots")
          .foregroundStyle(.secondary)
      }
    } else {
      Section {
        Text("UI.JoinGame.InProgress.Footer")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Section("Open Players") {
        ForEach(unclaimedSlots, id: \.playerId) { slot in
          Button(slot.name) {
            claimSlot(playerId: slot.playerId, displayName: slot.name)
          }
        }
      }
    }

    Section("Join With Your Name") {
      TextField("Display name", text: $customDisplayName)
      Button("Join as \(trimmedCustomName.isEmpty ? "…" : trimmedCustomName)") {
        claimSlot(playerId: nil, displayName: trimmedCustomName)
      }
      .disabled(trimmedCustomName.isEmpty || unclaimedSlots.isEmpty)
    }
  }

  private func rejoinSavedSession(_ saved: SavedGuestSession) {
    guard !isConnecting else { return }
    guard let session = multiplayerCoordinator.browser.sessions.first(where: {
      $0.code.uppercased() == saved.sessionCode.uppercased()
    }) else {
      joinError = String(
        localized: "UI.JoinGame.Rejoin.HostNotFound",
        defaultValue: "Host not found on the network. Open Join while near the host device."
      )
      codeFilter = saved.sessionCode
      return
    }
    selectedSessionID = session.id
    connectToSession(session: session, sessionCode: saved.sessionCode, guestToken: saved.guestToken)
  }

  private func connectToSession() {
    guard let selectedSessionID,
          let session = filteredSessions.first(where: { $0.id == selectedSessionID }) else {
      joinError = "Select a session first."
      return
    }
    let code = session.code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !code.isEmpty else {
      joinError = "Select a session with a valid code."
      return
    }
    connectToSession(session: session, sessionCode: code, guestToken: nil)
  }

  private func connectToSession(session: DiscoveredSession, sessionCode: String, guestToken: String?) {
    pendingGuest?.disconnect()
    pendingGuest = nil

    joinError = nil
    isConnecting = true

    do {
      let guest = try multiplayerCoordinator.connectGuest(
        discoveredSession: session,
        sessionCode: sessionCode,
        guestToken: guestToken
      )
      pendingGuest = guest
      wireGuestCallbacks(guest, sessionCode: sessionCode)
      try guest.connect()
    } catch {
      isConnecting = false
      joinError = error.localizedDescription
    }
  }

  private func wireGuestCallbacks(_ guest: GuestSessionService, sessionCode: String) {
    guest.onJoinLobby = { slots in
      lobbySlots = slots
      if guest.playerId == nil {
        isConnecting = false
      }
    }
    guest.onSlotClaimed = {
      claimedPlayerName = guest.playerName ?? trimmedCustomName
      isWaitingForHost = true
      isConnecting = false
    }
    guest.onJoinAccepted = {
      completeJoin(guest: guest, sessionCode: sessionCode)
    }
    guest.onError = { error in
      isConnecting = false
      if guestTokenProvided(error: error) {
        SavedGuestSession.clear()
        savedSession = nil
      }
      joinError = error.localizedDescription
      if case GuestSessionError.joinRejected = error {
        resetPicker()
      }
    }
  }

  private func guestTokenProvided(error: Error) -> Bool {
    if case GuestSessionError.joinRejected = error { return SavedGuestSession.load() != nil }
    return false
  }

  private func completeJoin(guest: GuestSessionService, sessionCode: String) {
    guard let playerId = guest.playerId,
          let guestToken = guest.guestToken else { return }
    let name = guest.playerName ?? trimmedCustomName
    GuestJoinPreferences.displayName = name
    SavedGuestSession.save(
      SavedGuestSession(
        guestToken: guestToken,
        sessionCode: sessionCode,
        playerId: playerId,
        playerName: name,
        hostDisplayName: nil
      )
    )
    savedSession = SavedGuestSession.load()
    let sessionID = multiplayerCoordinator.registerJoinedGuest(
      guest,
      playerId: playerId,
      setupPlayers: guest.setupPlayers
    )
    isConnecting = false
    onJoined(sessionID)
    dismiss()
  }

  private func claimSlot(playerId: UUID?, displayName: String) {
    guard let guest = pendingGuest else { return }
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      joinError = "Enter a display name."
      return
    }
    joinError = nil
    do {
      try guest.claimPlayer(playerId: playerId, displayName: name)
    } catch {
      joinError = error.localizedDescription
    }
  }

  private func resetPicker() {
    pendingGuest?.disconnect()
    pendingGuest = nil
    lobbySlots = []
    isWaitingForHost = false
    claimedPlayerName = nil
    isConnecting = false
    joinError = nil
  }
}
