import SwiftUI
#if canImport(WizardDomain)
import WizardDomain
#endif
#if canImport(WizardNet)
import WizardNet
#endif

/// Host lobby content without its own `NavigationStack`: it lives in a pushed screen (`GameSessionContainerView`) or
/// in a sheet's stack (`NewGameView`, `HostMultiplayerSheet`). The host arranges the seats (names of seats without a
/// phone, order, unassigning a guest's phone, their own seat), picks dealer and rules and can start at any time – not
/// every seat needs a phone (decision 3).
struct MultiplayerLobbyView: View {
  let gameID: UUID
  /// The game started. The embedding screen decides what to show next (the container switches to the game by itself).
  var onGameStarted: () -> Void = {}
  /// The host ended the session from the lobby.
  var onSessionEnded: () -> Void = {}

  @EnvironmentObject private var multiplayerCoordinator: MultiplayerCoordinator

  /// Name edits that are not committed yet (committed on submit / focus loss, never per keystroke).
  @State private var nameDrafts: [UUID: String] = [:]
  @FocusState private var focusedSeat: UUID?
  /// Dealer tracked by player id, so reordering seats never changes it.
  @State private var dealerId: UUID?
  @State private var enabledGameConstraints: Set<Constraint.GameConstraint> = [.betSumNotEqualHandSize]
  @State private var firstRoundBetSumMayEqualHandSize = false
  @State private var playWithSpecialCards = true
  @State private var errorMessage: String?
  @State private var seatToUnassign: LobbyPlayerSlot?
  @State private var confirmsEndSession = false
#if os(iOS)
  @State private var editMode: EditMode = .inactive
#endif

  private var lobby: HostLobbyState? {
    guard let state = multiplayerCoordinator.hostLobbyState, state.gameID == gameID else { return nil }
    return state
  }

  private var canStart: Bool {
    guard let lobby else { return false }
    return !lobby.hasStarted
  }

  private var languageCode: String? {
    AppLanguage.catalogLookupLanguageCode
  }

  var body: some View {
    Form {
      if let lobby {
        HostSessionCodeSection(sessionCode: lobby.sessionCode)

        if let health = MultiPhoneHostRules.sessionHealth(for: lobby.listenerState) {
          Section {
            HostSessionHealthBanner(health: health) {
              multiplayerCoordinator.handleScenePhase(.active)
            }
          }
        }

        seatsSection(lobby)
        hostSeatSection(lobby)
        gameSetupSection(lobby)
        rulesSection
        startSection(lobby)

        Section {
          Button(role: .destructive) {
            confirmsEndSession = true
          } label: {
            Text("UI.GameSession.EndSession.Confirm.Action")
          }
        }
      } else {
        Section {
          ProgressView()
            .frame(maxWidth: .infinity)
        }
      }
    }
    .scrollDismissesKeyboard(.interactively)
    .navigationTitle("UI.MultiplayerLobby.Title")
#if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    .environment(\.editMode, $editMode)
#endif
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("UI.MultiplayerLobby.StartGame") {
          startGame()
        }
        .disabled(!canStart)
      }
    }
    .keepsScreenAwake(true)
    .onChange(of: focusedSeat) { oldValue, newValue in
      // Commit when a name field loses focus.
      if let oldValue, oldValue != newValue {
        commitName(for: oldValue)
      }
    }
    .onDisappear {
      commitPendingNames()
    }
    .alert(
      "UI.Common.Error",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { isPresented in if !isPresented { errorMessage = nil } }
      )
    ) {
      Button("UI.Common.OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
    .seatUnassignDialog($seatToUnassign) { slot in
      _ = multiplayerCoordinator.unassignSeat(gameID: gameID, playerId: slot.playerId)
    }
    .confirmationDialog(
      "UI.GameSession.EndSession.Confirm.Title",
      isPresented: $confirmsEndSession,
      titleVisibility: .visible
    ) {
      Button("UI.GameSession.EndSession.Confirm.Action", role: .destructive) {
        endSession()
      }
      Button("UI.Common.Cancel", role: .cancel) {}
    } message: {
      Text("UI.MultiplayerLobby.EndSession.Confirm.Message")
    }
  }

  // MARK: - Seats

  private func seatsSection(_ lobby: HostLobbyState) -> some View {
    Section {
      ForEach(Array(lobby.slots.enumerated()), id: \.element.playerId) { index, slot in
        seatRow(slot, seatNumber: index + 1, lobby: lobby)
      }
      .onMove { source, destination in
        moveSeats(fromOffsets: source, toOffset: destination)
      }
    } header: {
      HStack {
        Text("UI.MultiplayerLobby.Seats.Header")
        Spacer()
#if os(iOS)
        Button {
          withAnimation {
            editMode = editMode.isEditing ? .inactive : .active
          }
        } label: {
          Text(
            editMode.isEditing
              ? LocalizedStringKey("UI.Common.Done")
              : LocalizedStringKey("UI.MultiplayerLobby.Seats.Reorder")
          )
        }
        .font(.caption.weight(.semibold))
        .textCase(nil)
        .disabled(lobby.hasStarted)
#endif
      }
    } footer: {
      Text("UI.MultiplayerLobby.Seats.Footer")
    }
  }

  @ViewBuilder
  private func seatRow(_ slot: LobbyPlayerSlot, seatNumber: Int, lobby: HostLobbyState) -> some View {
    let isDealer = MultiPhoneHostRules.resolvedDealerID(selected: dealerId, seatIDs: lobby.slots.map(\.playerId))
      == slot.playerId
    HStack(alignment: .center, spacing: 12) {
      Text(verbatim: "\(seatNumber)")
        .font(.subheadline.weight(.semibold).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 18, alignment: .leading)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        if MultiPhoneHostRules.isNameEditableByHost(slot) {
          TextField(text: nameBinding(for: slot), prompt: namePrompt(for: slot)) {
            Text(verbatim: slot.name)
          }
          .focused($focusedSeat, equals: slot.playerId)
          .submitLabel(.done)
          .onSubmit { commitName(for: slot.playerId) }
          .autocorrectionDisabled()
#if os(iOS)
          .textInputAutocapitalization(.words)
#endif
        } else {
          Text(verbatim: slot.name)
        }
        HStack(spacing: 8) {
          LobbySeatStatusBadge(status: MultiPhoneHostRules.deviceStatus(of: slot))
          if isDealer {
            Text("UI.GameSession.Header.Dealer")
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.secondary.opacity(0.18), in: Capsule())
          }
        }
      }
    }
    .padding(.vertical, 2)
    .contextMenu {
      seatActions(slot, lobby: lobby)
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

  @ViewBuilder
  private func seatActions(_ slot: LobbyPlayerSlot, lobby: HostLobbyState) -> some View {
    let ids = lobby.slots.map(\.playerId)
    if !lobby.hasStarted {
      if let movedUp = MultiPhoneHostRules.movedIDs(ids, moving: slot.playerId, by: -1) {
        Button {
          reorder(movedUp)
        } label: {
          Label("UI.MultiplayerLobby.Seat.MoveUp", systemImage: "arrow.up")
        }
      }
      if let movedDown = MultiPhoneHostRules.movedIDs(ids, moving: slot.playerId, by: 1) {
        Button {
          reorder(movedDown)
        } label: {
          Label("UI.MultiplayerLobby.Seat.MoveDown", systemImage: "arrow.down")
        }
      }
    }
    if slot.isBoundToDevice {
      Button(role: .destructive) {
        seatToUnassign = slot
      } label: {
        Label("UI.MultiplayerLobby.Seat.Kick", systemImage: "iphone.slash")
      }
    }
  }

  private func nameBinding(for slot: LobbyPlayerSlot) -> Binding<String> {
    Binding(
      get: { nameDrafts[slot.playerId] ?? (slot.isPlaceholderName ? "" : slot.name) },
      set: { nameDrafts[slot.playerId] = $0 }
    )
  }

  private func namePrompt(for slot: LobbyPlayerSlot) -> Text {
    if slot.isHost {
      return Text("UI.MultiplayerLobby.HostName.Placeholder")
    }
    if slot.isPlaceholderName {
      return Text(verbatim: slot.name)
    }
    return Text("UI.MultiplayerLobby.Seat.NamePlaceholder")
  }

  // MARK: - Host seat, setup, rules, start

  private func hostSeatSection(_ lobby: HostLobbyState) -> some View {
    Section {
      Picker(
        "UI.MultiplayerLobby.HostSlot.Title",
        selection: Binding(
          get: { lobby.hostPlayerId },
          set: { moveHost(to: $0) }
        )
      ) {
        ForEach(MultiPhoneHostRules.hostSeatOptions(lobby.slots), id: \.playerId) { slot in
          Text(verbatim: slot.name).tag(slot.playerId)
        }
      }
      .pickerStyle(.menu)
    } header: {
      Text("UI.MultiplayerLobby.HostSection.Header")
    } footer: {
      Text("UI.MultiplayerLobby.HostSlot.Footer")
    }
  }

  private func gameSetupSection(_ lobby: HostLobbyState) -> some View {
    let seatIDs = lobby.slots.map(\.playerId)
    return Section {
      Picker(
        "UI.NewGame.StartingDealer.Title",
        selection: Binding(
          get: { MultiPhoneHostRules.resolvedDealerID(selected: dealerId, seatIDs: seatIDs) ?? lobby.hostPlayerId },
          set: { dealerId = $0 }
        )
      ) {
        ForEach(lobby.slots, id: \.playerId) { slot in
          Text(verbatim: slot.name).tag(slot.playerId)
        }
      }
      .pickerStyle(.menu)

      Toggle(isOn: $playWithSpecialCards) {
        Text("UI.NewGame.PlayWithSpecialCards.Toggle")
      }
    } header: {
      Text("UI.MultiplayerLobby.Setup.Header")
    }
  }

  private var rulesSection: some View {
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
        if constraint == .betSumNotEqualHandSize, enabledGameConstraints.contains(.betSumNotEqualHandSize) {
          Toggle(isOn: $firstRoundBetSumMayEqualHandSize) {
            Text("UI.NewGame.HouseRules.FirstRoundMayEqualHandSize")
          }
        }
      }
    } header: {
      Text("UI.NewGame.HouseRules.Header")
    }
  }

  private func startSection(_ lobby: HostLobbyState) -> some View {
    Section {
      Button {
        startGame()
      } label: {
        Text("UI.MultiplayerLobby.StartGame")
          .font(.headline)
          .frame(maxWidth: .infinity)
      }
      .disabled(!canStart)
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        Text("UI.MultiplayerLobby.WaitingForPlayers.Footer")
        Text(
          AppLocalization.format(
            "UI.MultiplayerLobby.DevicesConnected.Footer",
            languageCode: languageCode,
            fallback: "%lld of %lld devices connected",
            MultiPhoneHostRules.connectedDeviceCount(lobby.slots),
            lobby.slots.count
          )
        )
      }
    }
  }

  // MARK: - Actions

  private func commitPendingNames() {
    for playerId in Array(nameDrafts.keys) {
      commitName(for: playerId)
    }
  }

  private func commitName(for playerId: UUID) {
    guard let draft = nameDrafts.removeValue(forKey: playerId) else { return }
    guard let lobby, !lobby.hasStarted,
          let slot = lobby.slots.first(where: { $0.playerId == playerId }),
          // A guest took the seat meanwhile: the guest's name wins.
          MultiPhoneHostRules.isNameEditableByHost(slot)
    else { return }

    switch MultiPhoneHostRules.seatNameCommit(draft: draft, slot: slot, players: lobby.players) {
    case .unchanged, .revert:
      return
    case .rejected(let code):
      errorMessage = MultiplayerReasonText.message(for: code, languageCode: languageCode)
    case .rename(let name):
      if slot.isHost {
        multiplayerCoordinator.updateHostSlot(gameID: gameID, playerId: slot.playerId, displayName: name)
        GuestJoinPreferences.hostDisplayName = name
      } else {
        do {
          try multiplayerCoordinator.renameSeat(gameID: gameID, playerId: slot.playerId, name: name)
        } catch {
          errorMessage = AppErrorMessage.presentableMessage(for: error, languageCode: languageCode)
        }
      }
    }
  }

  private func moveHost(to seat: UUID) {
    commitPendingNames()
    guard let lobby, !lobby.hasStarted, seat != lobby.hostPlayerId else { return }
    let hostName = currentHostName(lobby)
    if let rejection = MultiPhoneHostRules.hostSeatChangeRejection(
      to: seat,
      hostName: hostName,
      slots: lobby.slots,
      players: lobby.players
    ) {
      errorMessage = MultiplayerReasonText.message(for: rejection, languageCode: languageCode)
      return
    }
    multiplayerCoordinator.updateHostSlot(gameID: gameID, playerId: seat, displayName: hostName)
  }

  /// The host's name: their seat's name, unless that seat still has its default name.
  private func currentHostName(_ lobby: HostLobbyState) -> String {
    if let hostSlot = lobby.slots.first(where: \.isHost), !hostSlot.isPlaceholderName {
      return hostSlot.name
    }
    let stored = lobby.hostDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !stored.isEmpty { return stored }
    return AppLocalization.string("UI.MultiplayerLobby.HostDefaultName", languageCode: languageCode, fallback: "Host")
  }

  private func moveSeats(fromOffsets source: IndexSet, toOffset destination: Int) {
    guard let lobby, !lobby.hasStarted else { return }
    reorder(MultiPhoneHostRules.movedIDs(lobby.slots.map(\.playerId), fromOffsets: source, toOffset: destination))
  }

  private func reorder(_ orderedPlayerIDs: [UUID]) {
    do {
      try multiplayerCoordinator.reorderSeats(gameID: gameID, orderedPlayerIDs: orderedPlayerIDs)
    } catch {
      errorMessage = AppErrorMessage.presentableMessage(for: error, languageCode: languageCode)
    }
  }

  private func startGame() {
    commitPendingNames()
    guard let lobby, !lobby.hasStarted,
          let dealer = MultiPhoneHostRules.resolvedDealerID(selected: dealerId, seatIDs: lobby.slots.map(\.playerId))
    else { return }
    let constraints = Constraint.GameConstraint.allCases.filter { enabledGameConstraints.contains($0) }
    do {
      try multiplayerCoordinator.startHostedGame(
        gameID: gameID,
        startingDealerId: dealer,
        gameConstraints: constraints,
        playWithSpecialCards: playWithSpecialCards,
        firstRoundBetSumMayEqualHandSize: firstRoundBetSumMayEqualHandSize
          && constraints.contains(.betSumNotEqualHandSize)
      )
#if os(iOS)
      editMode = .inactive
#endif
      onGameStarted()
    } catch {
      errorMessage = AppErrorMessage.presentableMessage(for: error, languageCode: languageCode)
    }
  }

  private func endSession() {
    nameDrafts = [:]
    multiplayerCoordinator.endSession(gameID: gameID)
    onSessionEnded()
  }
}
