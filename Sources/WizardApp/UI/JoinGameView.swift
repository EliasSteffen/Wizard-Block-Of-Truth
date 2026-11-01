import SwiftUI
#if canImport(WizardDomain)
import WizardDomain
#endif
#if canImport(WizardNet)
import WizardNet
#endif

/// Join a multi-phone game: tap a host on the same Wi-Fi (no code typing), pick a seat, enter a name. Right after the
/// host accepts the seat the session is handed to a `MultiplayerGameStore` and the game screen opens (waiting room
/// until the host starts).
struct JoinGameView: View {
  /// Connect to this host right away (e.g. "Pick a seat again" after the seat was released).
  var initialTarget: GuestJoinTarget? = nil
  /// Called with the session id to open (`GameSessionContainerView(gameId:)`).
  let onJoined: (UUID) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  @Environment(\.modelContext) private var modelContext
  @Environment(\.scenePhase) private var scenePhase
  @EnvironmentObject private var multiplayerCoordinator: MultiplayerCoordinator

  @State private var phase: JoinPhase = .browsing
  @State private var pendingGuest: GuestSessionService?
  @State private var connectedServiceName: String?
  /// The pending guest session was handed to a `MultiplayerGameStore` (it must stay connected).
  @State private var didHandOff = false
  @State private var lobbySlots: [LobbyPlayerSlot] = []
  @State private var lobbyGameName: String?
  @State private var selectedSeatID: UUID?
  @State private var displayName: String = GuestJoinPreferences.displayName
  /// The host-given name put into the name field when a named seat was picked.
  @State private var prefilledSeatName: String?
  @State private var notice: JoinNotice?
  @State private var seatError: String?
  /// The host refused the name (shown at the name field until it is edited).
  @State private var hostNameError: String?
  @State private var savedSession: SavedGuestSession? = SavedGuestSession.load()
  @State private var searchGeneration = 0
  @State private var showsEmptyHint = false
  @State private var didApplyInitialTarget = false

  /// How long "Rejoin" waits for the host to show up in the list before connecting by name anyway.
  private static let lookForHostTimeout: Duration = .seconds(5)
  /// Searching longer than this without results shows the "same Wi-Fi" hint.
  private static let emptyHintDelay: Duration = .seconds(4)

  var body: some View {
    NavigationStack {
      Form {
        if let notice, !isNoticeShownByBrowserSection(notice) {
          noticeSection(notice)
        }

        switch phase {
        case .browsing:
          activeSessionSection
          rejoinSection
          browseSections
        case .lookingForHost(let target):
          progressSection(
            title: GuestText.format("UI.JoinGame.State.LookingForHost", fallback: "Looking for “%@”…", target.gameName)
          )
        case .connecting(let target):
          progressSection(
            title: GuestText.format("UI.JoinGame.State.Connecting", fallback: "Connecting to “%@”…", target.gameName)
          )
        case .pickingSeat(let target), .claiming(let target):
          seatSections(target: target)
        }
      }
      .navigationTitle(navigationTitle)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(cancelButtonTitle) {
            if case .browsing = phase {
              dismiss()
            } else {
              backToBrowsing()
            }
          }
        }
      }
    }
    .onAppear {
      startBrowsing()
      savedSession = SavedGuestSession.load()
      if displayName.isEmpty {
        displayName = GuestJoinPreferences.displayName
      }
      if !didApplyInitialTarget, let initialTarget {
        didApplyInitialTarget = true
        startLookingForHost(initialTarget)
      }
    }
    .onDisappear {
      multiplayerCoordinator.browser.stop()
      // No zombie connection when the sheet is dismissed while connecting or picking a seat.
      cancelPendingConnection()
    }
    .onChange(of: multiplayerCoordinator.browser.sessions) { _, sessions in
      discoveredSessionsDidChange(sessions)
    }
    .onChange(of: scenePhase) { _, newPhase in
      // Back from Settings (Local Network permission) or from the background: search again.
      guard newPhase == .active, browserNeedsRestart else { return }
      startBrowsing()
    }
    .onChange(of: displayName) { _, _ in
      hostNameError = nil
    }
    .task(id: phase) {
      guard case .lookingForHost(let target) = phase else { return }
      try? await Task.sleep(for: Self.lookForHostTimeout)
      guard !Task.isCancelled, phase == .lookingForHost(target) else { return }
      lookingForHostTimedOut(target)
    }
    .task(id: searchGeneration) {
      showsEmptyHint = false
      try? await Task.sleep(for: Self.emptyHintDelay)
      guard !Task.isCancelled else { return }
      showsEmptyHint = true
    }
  }

  // MARK: - Titles

  private var navigationTitle: LocalizedStringKey {
    switch phase {
    case .pickingSeat, .claiming:
      return "UI.JoinGame.ChoosePlayer.Title"
    case .browsing, .lookingForHost, .connecting:
      return "UI.JoinGame.Title"
    }
  }

  private var cancelButtonTitle: LocalizedStringKey {
    if case .browsing = phase {
      return "UI.Common.Cancel"
    }
    return "UI.Common.Back"
  }

  // MARK: - Browsing

  /// Discovered hosts, without a session this phone hosts itself.
  private var discoveredSessions: [DiscoveredSession] {
    let sessions = multiplayerCoordinator.browser.sessions
    guard let ownCode = multiplayerCoordinator.hostLobbyState?.sessionCode else { return sessions }
    return sessions.filter { !GuestJoinTarget.codesMatch($0.code, ownCode) }
  }

  private var browserIsDenied: Bool {
    switch multiplayerCoordinator.browser.state {
    case .waiting(.localNetworkDenied), .failed(.localNetworkDenied):
      return true
    case .idle, .browsing, .waiting, .failed:
      return false
    }
  }

  private var browserNeedsRestart: Bool {
    switch multiplayerCoordinator.browser.state {
    case .idle, .waiting, .failed:
      return true
    case .browsing:
      return false
    }
  }

  /// The guest session this phone is in right now (not ended), if any.
  private var activeGuestSession: (id: UUID, store: MultiplayerGameStore)? {
    let ids = multiplayerCoordinator.guestSessionIDs.sorted { $0.uuidString < $1.uuidString }
    for id in ids {
      if let store = multiplayerCoordinator.store(for: id), !store.connectionState.isEnded {
        return (id, store)
      }
    }
    return nil
  }

  @ViewBuilder
  private var activeSessionSection: some View {
    if let active = activeGuestSession {
      Section {
        Button {
          openSession(active.id)
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(
              verbatim: GuestText.format(
                "UI.JoinGame.Active.Open",
                fallback: "Back to “%@”",
                active.store.currentGame?.name ?? ""
              )
            )
            .font(.headline)
            if let name = playerName(in: active.store) {
              Text(verbatim: GuestText.format("UI.JoinGame.Active.PlayingAs", fallback: "You play as %@", name))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      } header: {
        Text("UI.JoinGame.Active.Header")
      }
    }
  }

  @ViewBuilder
  private var rejoinSection: some View {
    if let savedSession, !belongsToActiveSession(savedSession) {
      let target = GuestJoinTarget(saved: savedSession)
      Section {
        Button {
          startLookingForHost(target)
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Text(
              verbatim: GuestText.format(
                "UI.JoinGame.Rejoin.Title",
                fallback: "Rejoin “%1$@” as %2$@",
                target.gameName,
                savedSession.playerName
              )
            )
            .font(.headline)
            Text(
              verbatim: GuestText.format("UI.JoinGame.Rejoin.Code", fallback: "Code: %@", savedSession.sessionCode)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }

        Button("UI.JoinGame.Rejoin.Forget", role: .destructive) {
          SavedGuestSession.clear()
          self.savedSession = nil
        }
      } header: {
        Text("UI.JoinGame.Rejoin.Header")
      } footer: {
        Text("UI.JoinGame.Rejoin.Footer")
      }
    }
  }

  @ViewBuilder
  private var browseSections: some View {
    switch multiplayerCoordinator.browser.state {
    case .waiting(.localNetworkDenied), .failed(.localNetworkDenied):
      localNetworkDeniedSection
    case .failed:
      Section {
        Label {
          Text("UI.JoinGame.State.SearchFailed")
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
        Button("UI.JoinGame.TryAgain") {
          startBrowsing()
        }
      }
    case .idle, .browsing, .waiting:
      sessionsSection
    }
  }

  private var sessionsSection: some View {
    Section {
      let sessions = discoveredSessions
      if sessions.isEmpty {
        HStack(spacing: 12) {
          ProgressView()
          Text("UI.JoinGame.State.Searching")
            .foregroundStyle(.secondary)
        }
        if showsEmptyHint {
          Label {
            Text("UI.JoinGame.State.Empty")
          } icon: {
            Image(systemName: "wifi")
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      } else {
        ForEach(sessions) { session in
          sessionRow(session)
        }
      }
    } header: {
      Text("UI.JoinGame.Sessions.Header")
    } footer: {
      Text("UI.JoinGame.Sessions.Footer")
    }
  }

  private func sessionRow(_ session: DiscoveredSession) -> some View {
    Button {
      join(session)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: "person.2.wave.2")
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: session.displayName)
            .font(.headline)
            .foregroundStyle(.primary)
          Text(verbatim: GuestText.format("UI.JoinGame.Rejoin.Code", fallback: "Code: %@", session.code))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
          if let saved = savedSession, GuestJoinTarget.codesMatch(saved.sessionCode, session.code) {
            Text(verbatim: GuestText.format("UI.JoinGame.Session.SavedSeat", fallback: "Your seat: %@", saved.playerName))
              .font(.caption)
              .foregroundStyle(.green)
          }
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var localNetworkDeniedSection: some View {
    Section {
      Label {
        Text(
          verbatim: MultiplayerReasonText.message(
            for: TransportFailure.localNetworkDenied,
            languageCode: AppLanguage.catalogLookupLanguageCode
          )
        )
      } icon: {
        Image(systemName: "wifi.exclamationmark")
          .foregroundStyle(.orange)
      }
      Text("UI.JoinGame.LocalNetwork.Explanation")
        .font(.footnote)
        .foregroundStyle(.secondary)
      LocalNetworkSettingsButton()
      Button("UI.JoinGame.TryAgain") {
        startBrowsing()
      }
    } header: {
      Text("UI.JoinGame.LocalNetwork.Header")
    }
  }

  // MARK: - Connecting

  private func progressSection(title: String) -> some View {
    Section {
      HStack(spacing: 12) {
        ProgressView()
        Text(verbatim: title)
      }
      Text("UI.JoinGame.State.Connecting.Hint")
        .font(.footnote)
        .foregroundStyle(.secondary)
      Button("UI.Common.Cancel", role: .cancel) {
        backToBrowsing()
      }
    }
  }

  // MARK: - Notices

  private func isNoticeShownByBrowserSection(_ notice: JoinNotice) -> Bool {
    guard case .browsing = phase else { return false }
    return notice.kind == .localNetworkDenied && browserIsDenied
  }

  private func noticeSection(_ notice: JoinNotice) -> some View {
    Section {
      Label {
        Text(verbatim: notice.message)
      } icon: {
        Image(systemName: noticeIcon(notice.kind))
          .foregroundStyle(notice.kind == .seatReleased ? Color.blue : Color.orange)
      }
      switch notice.kind {
      case .localNetworkDenied:
        LocalNetworkSettingsButton()
      case .incompatibleHost:
        Link(destination: AppStoreInfo.appStoreURL) {
          Label("UI.JoinGame.Incompatible.AppStore", systemImage: "arrow.down.app")
        }
      case .seatReleased, .name, .seat, .general:
        EmptyView()
      }
    }
  }

  private func noticeIcon(_ kind: JoinFailureKind) -> String {
    switch kind {
    case .localNetworkDenied:
      return "wifi.exclamationmark"
    case .incompatibleHost:
      return "arrow.triangle.2.circlepath"
    case .seatReleased:
      return "info.circle.fill"
    case .name, .seat, .general:
      return "exclamationmark.triangle.fill"
    }
  }

  // MARK: - Seat picker

  private var lobbyPlayers: [Player] {
    lobbySlots.map { Player(id: $0.playerId, name: $0.name) }
  }

  private var isClaiming: Bool {
    if case .claiming = phase { return true }
    return false
  }

  private var selectedSlot: LobbyPlayerSlot? {
    guard let selectedSeatID else { return nil }
    return lobbySlots.first { $0.playerId == selectedSeatID && $0.isClaimable }
  }

  /// Client-side name check (`SeatNameRules`: trimmed, 1…24 characters, unique); the host checks again.
  private var nameRejection: MultiplayerReasonCode? {
    guard let selectedSeatID else { return nil }
    return SeatNameRules.rejection(for: displayName, in: lobbyPlayers, seat: selectedSeatID)
  }

  private var nameMessage: String? {
    if let hostNameError {
      return hostNameError
    }
    // An empty field only disables "Join"; other problems are explained right away.
    guard let nameRejection, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return MultiplayerReasonText.message(for: nameRejection, languageCode: AppLanguage.catalogLookupLanguageCode)
  }

  private var canClaim: Bool {
    guard case .pickingSeat = phase, selectedSlot != nil, pendingGuest != nil else { return false }
    return nameRejection == nil
  }

  @ViewBuilder
  private func seatSections(target: GuestJoinTarget) -> some View {
    let hasClaimableSeat = lobbySlots.contains { $0.isClaimable }
    Section {
      ForEach(Array(lobbySlots.enumerated()), id: \.element.playerId) { index, slot in
        seatRow(slot, number: index + 1)
      }
      if let seatError {
        Text(verbatim: seatError)
          .font(.footnote)
          .foregroundStyle(.red)
      }
    } header: {
      Text(verbatim: lobbyGameName ?? target.gameName)
    } footer: {
      if hasClaimableSeat {
        Text("UI.JoinGame.Seat.Footer")
      } else {
        Text("UI.JoinGame.Seat.NoneOpen")
      }
    }

    if let slot = selectedSlot {
      Section {
        TextField("UI.JoinGame.Seat.NamePlaceholder", text: $displayName)
          .autocorrectionDisabled()
          .submitLabel(.join)
          .onSubmit {
            claimSelectedSeat()
          }
#if os(iOS)
          .textInputAutocapitalization(.words)
#endif
          .disabled(isClaiming)

        if let nameMessage {
          Text(verbatim: nameMessage)
            .font(.footnote)
            .foregroundStyle(.red)
        }

        Button {
          claimSelectedSeat()
        } label: {
          HStack(spacing: 8) {
            if isClaiming {
              ProgressView()
            }
            Text(verbatim: joinButtonTitle(seat: slot))
              .font(.headline)
          }
        }
        .disabled(!canClaim)
      } header: {
        Text("UI.JoinGame.Seat.NameHeader")
      } footer: {
        Text("UI.JoinGame.Seat.NameFooter")
      }
    }
  }

  private func seatRow(_ slot: LobbyPlayerSlot, number: Int) -> some View {
    let isSelected = selectedSeatID == slot.playerId && slot.isClaimable
    return Button {
      selectSeat(slot)
    } label: {
      HStack(spacing: 10) {
        Text(verbatim: "\(number).")
          .font(.subheadline.weight(.semibold).monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(minWidth: 24, alignment: .leading)
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: slot.name)
            .foregroundStyle(slot.isClaimable ? Color.primary : Color.secondary)
          Text(seatStatus(slot))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else if !slot.isClaimable {
          Image(systemName: "lock.fill")
            .foregroundStyle(.secondary)
        } else {
          Image(systemName: "circle")
            .foregroundStyle(.tertiary)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!slot.isClaimable || isClaiming)
  }

  private func seatStatus(_ slot: LobbyPlayerSlot) -> LocalizedStringKey {
    if slot.isHost {
      return "UI.JoinGame.Seat.Status.Host"
    }
    if slot.isBoundToDevice {
      return slot.isConnected ? "UI.JoinGame.Seat.Status.Taken" : "UI.JoinGame.Seat.Status.Reserved"
    }
    return slot.isPlaceholderName ? "UI.JoinGame.Seat.Status.Open" : "UI.JoinGame.Seat.Status.Named"
  }

  private func joinButtonTitle(seat: LobbyPlayerSlot) -> String {
    let name = SeatNameRules.normalized(displayName) ?? "…"
    return GuestText.format("UI.JoinGame.Seat.JoinAs", fallback: "Join as %@", name)
  }

  // MARK: - Actions

  private func startBrowsing() {
    multiplayerCoordinator.browser.start()
    searchGeneration += 1
  }

  private func openSession(_ sessionID: UUID) {
    onJoined(sessionID)
    dismiss()
  }

  private func playerName(in store: MultiplayerGameStore) -> String? {
    guard case .guest(let playerId) = store.role else { return nil }
    return store.currentGame?.players.first(where: { $0.id == playerId })?.name
  }

  /// The saved session is the one this phone is connected to right now (then "Rejoin" would kick it).
  private func belongsToActiveSession(_ saved: SavedGuestSession) -> Bool {
    guard let code = activeGuestSession?.store.guestSessionCode else { return false }
    return GuestJoinTarget.codesMatch(code, saved.sessionCode)
  }

  private func join(_ session: DiscoveredSession) {
    // Already in this session on this phone: open it instead of connecting a second time.
    if let active = activeGuestSession, let code = active.store.guestSessionCode,
       GuestJoinTarget.codesMatch(code, session.code) {
      openSession(active.id)
      return
    }
    // Tapping the host of the saved session keeps the saved seat (token).
    let saved = savedSession.flatMap { GuestJoinTarget.codesMatch($0.sessionCode, session.code) ? $0 : nil }
    let target = GuestJoinTarget(discovered: session, guestToken: saved?.guestToken, playerName: saved?.playerName)
    connect(serviceName: session.serviceName, target: target)
  }

  /// Rejoin / pick a seat again: wait (briefly) until the host shows up in the list, then connect.
  private func startLookingForHost(_ target: GuestJoinTarget) {
    notice = nil
    if let match = target.match(in: discoveredSessions) {
      connect(serviceName: match.serviceName, target: target)
      return
    }
    cancelPendingConnection()
    phase = .lookingForHost(target)
  }

  private func discoveredSessionsDidChange(_ sessions: [DiscoveredSession]) {
    guard case .lookingForHost(let target) = phase, let match = target.match(in: sessions) else { return }
    connect(serviceName: match.serviceName, target: target)
  }

  private func lookingForHostTimedOut(_ target: GuestJoinTarget) {
    if let serviceName = target.serviceName {
      // Not (yet) in the browse results: try the saved Bonjour name directly; the connect timeout bounds it.
      connect(serviceName: serviceName, target: target)
    } else {
      phase = .browsing
      notice = JoinNotice(
        kind: .general,
        message: GuestText.string(
          "UI.JoinGame.State.HostNotFound",
          fallback: "The host wasn’t found. Make sure you’re on the same Wi-Fi as the host and the game is open there."
        )
      )
    }
  }

  private func connect(serviceName: String, target: GuestJoinTarget) {
    cancelPendingConnection()
    notice = nil
    seatError = nil
    hostNameError = nil
    lobbySlots = []
    lobbyGameName = nil
    selectedSeatID = nil

    let guest = multiplayerCoordinator.connectGuest(
      serviceName: serviceName,
      sessionCode: target.sessionCode,
      guestToken: target.guestToken
    )
    pendingGuest = guest
    connectedServiceName = serviceName
    phase = .connecting(target)
    wireCallbacks(of: guest, target: target)
    do {
      try guest.connect()
    } catch {
      pendingGuest = nil
      guest.disconnect()
      phase = .browsing
      notice = JoinNotice(kind: JoinFailureKind.classify(error), message: presentable(error))
    }
  }

  private func wireCallbacks(of guest: GuestSessionService, target: GuestJoinTarget) {
    guest.onJoinLobby = { [weak guest] slots in
      guard let guest, pendingGuest === guest else { return }
      lobbyDidChange(slots, gameName: guest.lobbyGameName, target: target)
    }
    guest.onLobbyUpdated = nil
    guest.onSlotClaimed = { [weak guest] in
      guard let guest else { return }
      completeJoin(guest)
    }
    guest.onJoinAccepted = { [weak guest] in
      guard let guest else { return }
      completeJoin(guest)
    }
    guest.onError = { [weak guest] error in
      guard let guest, pendingGuest === guest else { return }
      handleJoinError(error, target: target)
    }
    guest.onSessionEnded = { [weak guest] reason in
      guard let guest, pendingGuest === guest, !didHandOff else { return }
      pendingGuest = nil
      lobbySlots = []
      selectedSeatID = nil
      phase = .browsing
      if notice == nil {
        notice = JoinNotice(
          kind: .general,
          message: MultiplayerReasonText.message(for: reason, languageCode: AppLanguage.catalogLookupLanguageCode)
        )
      }
    }
  }

  private func lobbyDidChange(_ slots: [LobbyPlayerSlot], gameName: String?, target: GuestJoinTarget) {
    lobbySlots = slots
    lobbyGameName = gameName
    switch phase {
    case .connecting(let connectingTarget), .lookingForHost(let connectingTarget):
      phase = .pickingSeat(connectingTarget)
      preselectSeat(preferredName: target.playerName)
    case .pickingSeat, .claiming, .browsing:
      break
    }
    // Someone else took the selected seat meanwhile.
    if !isClaiming, let selectedSeatID,
       !slots.contains(where: { $0.playerId == selectedSeatID && $0.isClaimable }) {
      self.selectedSeatID = nil
      seatError = MultiplayerReasonText.message(
        for: MultiplayerReasonCode.seatTaken,
        languageCode: AppLanguage.catalogLookupLanguageCode
      )
    }
  }

  /// Preselects the seat matching the saved / last used name, or the only open seat.
  private func preselectSeat(preferredName: String?) {
    guard selectedSeatID == nil else { return }
    let claimable = lobbySlots.filter(\.isClaimable)
    let candidates = [preferredName, GuestJoinPreferences.displayName].compactMap { $0 }.filter { !$0.isEmpty }
    for candidate in candidates {
      if let slot = claimable.first(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
        selectSeat(slot)
        return
      }
    }
    if claimable.count == 1, let only = claimable.first {
      selectSeat(only)
    }
  }

  private func selectSeat(_ slot: LobbyPlayerSlot) {
    guard slot.isClaimable, !isClaiming else { return }
    selectedSeatID = slot.playerId
    seatError = nil
    hostNameError = nil
    let current = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !slot.isPlaceholderName {
      // Host-named phone-less seat: prefill the host's name (the guest may change it).
      displayName = slot.name
      prefilledSeatName = slot.name
    } else if current.isEmpty || current == prefilledSeatName {
      displayName = GuestJoinPreferences.displayName
      prefilledSeatName = nil
    }
  }

  private func claimSelectedSeat() {
    guard canClaim, case .pickingSeat(let target) = phase, let guest = pendingGuest,
          let seatID = selectedSeatID, let name = SeatNameRules.normalized(displayName) else { return }
    seatError = nil
    hostNameError = nil
    if notice?.kind != .seatReleased {
      notice = nil
    }
    do {
      try guest.claimPlayer(playerId: seatID, displayName: name)
      phase = .claiming(target)
    } catch {
      seatError = presentable(error)
    }
  }

  private func handleJoinError(_ error: Error, target: GuestJoinTarget) {
    let kind = JoinFailureKind.classify(error)
    let message = presentable(error)
    switch kind {
    case .name:
      hostNameError = message
    case .seat:
      seatError = message
      selectedSeatID = nil
    case .seatReleased:
      // The saved seat is gone on the host; the lobby follows and the guest picks again.
      if let token = target.guestToken {
        SavedGuestSession.clear(token: token)
        savedSession = SavedGuestSession.load()
      }
      notice = JoinNotice(kind: kind, message: message)
    case .localNetworkDenied, .incompatibleHost, .general:
      notice = JoinNotice(kind: kind, message: message)
    }
    if case .claiming(let claimingTarget) = phase {
      phase = .pickingSeat(claimingTarget)
    }
  }

  private func completeJoin(_ guest: GuestSessionService) {
    guard pendingGuest === guest, !didHandOff, let playerId = guest.playerId, guest.guestToken != nil else { return }
    didHandOff = true
    // From here on the store owns the session: it saves the rejoin token and shows the waiting/game screen.
    let sessionID = multiplayerCoordinator.registerJoinedGuest(
      guest,
      playerId: playerId,
      setupPlayers: guest.setupPlayers,
      serviceName: connectedServiceName,
      modelContext: modelContext
    )
    savedSession = SavedGuestSession.load()
    onJoined(sessionID)
    dismiss()
  }

  /// Back to the list; closes a pending connection.
  private func backToBrowsing() {
    cancelPendingConnection()
    phase = .browsing
    lobbySlots = []
    lobbyGameName = nil
    selectedSeatID = nil
    seatError = nil
    hostNameError = nil
  }

  private func cancelPendingConnection() {
    guard !didHandOff, let guest = pendingGuest else { return }
    pendingGuest = nil
    guest.disconnect()
  }

  private func presentable(_ error: Error) -> String {
    AppErrorMessage.presentableMessage(for: error, languageCode: AppLanguage.catalogLookupLanguageCode)
  }
}

// MARK: - State

extension JoinGameView {
  enum JoinPhase: Equatable {
    case browsing
    /// Waiting for the host of a saved session to appear in the list (bounded by a short timeout).
    case lookingForHost(GuestJoinTarget)
    /// TCP connect + waiting for the host's answer to `hello`.
    case connecting(GuestJoinTarget)
    case pickingSeat(GuestJoinTarget)
    /// `claimPlayer` sent, waiting for `claimAccepted` / `joinAccepted` / `joinRejected`.
    case claiming(GuestJoinTarget)
  }

  struct JoinNotice: Equatable {
    var kind: JoinFailureKind
    var message: String
  }
}
