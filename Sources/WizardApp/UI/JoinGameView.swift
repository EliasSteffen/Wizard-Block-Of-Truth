import SwiftUI
#if canImport(WizardNet)
import WizardNet
#endif

struct JoinGameView: View {
  let onJoined: (UUID) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @Environment(\.modelContext) private var modelContext
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
  @State private var pendingServiceName: String?
  /// The pending guest session was handed to a `MultiplayerGameStore` (it must stay connected).
  @State private var didHandOff = false

  private var filteredSessions: [DiscoveredSession] {
    let normalized = codeFilter.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !normalized.isEmpty else { return multiplayerCoordinator.browser.sessions }
    return multiplayerCoordinator.browser.sessions.filter { $0.code.uppercased().contains(normalized) }
  }

  private var unclaimedPlaceholderSlots: [LobbyPlayerSlot] {
    lobbySlots.filter { !$0.isClaimed && $0.isPlaceholderName }
  }

  private var unclaimedNamedSlots: [LobbyPlayerSlot] {
    lobbySlots.filter { !$0.isClaimed && !$0.isPlaceholderName }
  }

  private var hasUnclaimedSlots: Bool {
    !unclaimedPlaceholderSlots.isEmpty || !unclaimedNamedSlots.isEmpty
  }

  private var canJoinWithCustomName: Bool {
    !unclaimedPlaceholderSlots.isEmpty
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
    .onDisappear {
      multiplayerCoordinator.browser.stop()
      if !didHandOff {
        pendingGuest?.disconnect()
      }
    }
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
    if !hasUnclaimedSlots {
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

      if !unclaimedNamedSlots.isEmpty {
        Section {
          ForEach(unclaimedNamedSlots, id: \.playerId) { slot in
            Button(slot.name) {
              claimSlot(playerId: slot.playerId, displayName: slot.name)
            }
          }
        } header: {
          Text("UI.JoinGame.ClaimPlayer.Header")
        }
      }

      if canJoinWithCustomName {
        Section {
          TextField("UI.JoinGame.CustomName.Placeholder", text: $customDisplayName)
          Button(customNameJoinTitle) {
            claimSlot(playerId: nil, displayName: trimmedCustomName)
          }
          .disabled(trimmedCustomName.isEmpty)
        } header: {
          Text("UI.JoinGame.CustomName.Header")
        }
      }
    }
  }

  private var customNameJoinTitle: String {
    let name = trimmedCustomName.isEmpty ? "…" : trimmedCustomName
    return String(
      format: String(
        localized: "UI.JoinGame.CustomName.Button",
        defaultValue: "Join as %@",
        locale: locale
      ),
      locale: locale,
      name
    )
  }

  private func rejoinSavedSession(_ saved: SavedGuestSession) {
    guard !isConnecting else { return }
    let discovered = multiplayerCoordinator.browser.sessions.first(where: {
      $0.code.uppercased() == saved.sessionCode.uppercased()
    })
    // Sessions saved since protocol v2 know the host's Bonjour name: connect by name, no browse result needed.
    let byName = saved.serviceName.map {
      DiscoveredSession(id: $0, code: saved.sessionCode, displayName: saved.gameName ?? $0, serviceName: $0)
    }
    guard let session = discovered ?? byName else {
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
    pendingServiceName = session.serviceName

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
      joinError = AppErrorMessage.presentableMessage(for: error, languageCode: AppLanguage.catalogLookupLanguageCode)
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
      // Hand over right at `claimAccepted`: the store persists the token and shows the waiting screen (H5).
      claimedPlayerName = guest.playerName ?? trimmedCustomName
      completeJoin(guest: guest, sessionCode: sessionCode)
    }
    guest.onJoinAccepted = {
      completeJoin(guest: guest, sessionCode: sessionCode)
    }
    guest.onError = { error in
      isConnecting = false
      if case GuestSessionError.joinRejected(.tokenInvalid) = error, let saved = savedSession {
        // The saved seat is gone on the host; the host sends the lobby next, so the guest can pick again.
        SavedGuestSession.clear(token: saved.guestToken)
        savedSession = nil
      }
      joinError = AppErrorMessage.presentableMessage(for: error, languageCode: AppLanguage.catalogLookupLanguageCode)
      if guest.connectionState.isEnded {
        resetPicker(keepError: true)
      }
    }
  }

  private func completeJoin(guest: GuestSessionService, sessionCode: String) {
    guard !didHandOff, let playerId = guest.playerId, guest.guestToken != nil else { return }
    didHandOff = true
    // The store saves `SavedGuestSession` (keyed by token) and the display name.
    let sessionID = multiplayerCoordinator.registerJoinedGuest(
      guest,
      playerId: playerId,
      setupPlayers: guest.setupPlayers,
      serviceName: pendingServiceName,
      modelContext: modelContext
    )
    savedSession = SavedGuestSession.load()
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
      joinError = AppErrorMessage.presentableMessage(for: error, languageCode: AppLanguage.catalogLookupLanguageCode)
    }
  }

  private func resetPicker(keepError: Bool = false) {
    if !didHandOff {
      pendingGuest?.disconnect()
    }
    pendingGuest = nil
    lobbySlots = []
    isWaitingForHost = false
    claimedPlayerName = nil
    isConnecting = false
    if !keepError {
      joinError = nil
    }
  }
}
