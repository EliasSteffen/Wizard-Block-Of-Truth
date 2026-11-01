import SwiftUI
import SwiftData
#if canImport(WizardDomain)
import WizardDomain
#endif

struct GameListView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.locale) private var locale
  @EnvironmentObject private var multiplayerCoordinator: MultiplayerCoordinator
  @AppStorage("app.language") private var appLanguageRaw: String = AppLanguage.system.rawValue
  @Query(sort: \GameSnapshotEntity.updatedAt, order: .reverse) private var games: [GameSnapshotEntity]

  @State private var showingNewGame = false
  @State private var showingJoinGame = false
  /// Host the Join sheet connects to right away ("Pick a seat again" from an ended guest session).
  @State private var joinTarget: GuestJoinTarget?
  @State private var path: [UUID] = []
  @State private var searchText: String = ""
  @State private var showingSettings = false
  @State private var showingInfo = false

#if os(iOS)
  @State private var editMode: EditMode = .inactive
#endif

  /// Ended guest sessions are dropped once their screen is gone (after the pop animation).
  private static let endedSessionCleanupDelay: Duration = .milliseconds(700)
  /// Lets the pop finish before the Join sheet is presented.
  private static let joinSheetDelay: Duration = .milliseconds(450)

  var body: some View {
    NavigationStack(path: $path) {
      ZStack {
        WizardBackground.gradient
          .ignoresSafeArea()

        gamesList
      }
      .navigationTitle("UI.GameList.NavigationTitle")
      .navigationDestination(for: UUID.self) { id in
        GameSessionContainerView(gameId: id)
      }
#if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      .environment(\.editMode, $editMode)
#endif
      .toolbar {
#if os(iOS)
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button(editMode == .active ? "UI.Common.Done" : "UI.Common.Edit") {
            withAnimation {
              editMode = (editMode == .active) ? .inactive : .active
            }
          }

          Menu {
            Button {
              showingSettings = true
            } label: {
              Label("UI.GameList.Menu.Settings", systemImage: "gearshape")
            }
            Button {
              showingInfo = true
            } label: {
              Label("UI.GameList.Menu.Info", systemImage: "info.circle")
            }
          } label: {
            Image(systemName: "ellipsis")
          }
          .accessibilityLabel("UI.GameList.OverflowMenu.Accessibility")
        }
#else
        ToolbarItemGroup(placement: .automatic) {
          Button("UI.Common.Edit") { }
          Menu {
            Button {
              showingSettings = true
            } label: {
              Label("UI.GameList.Menu.Settings", systemImage: "gearshape")
            }
            Button {
              showingInfo = true
            } label: {
              Label("UI.GameList.Menu.Info", systemImage: "info.circle")
            }
          } label: {
            Image(systemName: "ellipsis")
          }
          .accessibilityLabel("UI.GameList.OverflowMenu.Accessibility")
        }
#endif

        ToolbarItem(placement: .principal) {
          Text("UI.GameList.NavigationTitle")
            .font(.headline)
        }
      }
      .safeAreaInset(edge: .bottom) {
        bottomBar
      }
      .sheet(isPresented: $showingNewGame) {
        NewGameView(
          onCreated: { newId in path = [newId] },
          onMultiplayerGameStarted: { newId in path = [newId] }
        )
        .presentationDetents([.large])
      }
      .sheet(isPresented: $showingJoinGame, onDismiss: { joinTarget = nil }) {
        JoinGameView(initialTarget: joinTarget) { joinedSessionID in
          path = [joinedSessionID]
        }
        .presentationDetents([.large])
      }
      .sheet(isPresented: $showingSettings) {
        SettingsView()
          .presentationDetents([.medium, .large])
      }
      .sheet(isPresented: $showingInfo) {
        AboutInfoView()
          .presentationDetents([.medium])
      }
    }
    .environment(\.guestSessionNavigation, GuestSessionNavigation(rejoin: { target in
      openJoin(for: target)
    }))
    .onChange(of: path) { _, _ in
      scheduleEndedGuestSessionCleanup()
    }
    .background(Color.clear)
    .wizardBackground()
  }

  private var gamesList: some View {
    List {
      activeSessionSection
      listRows
    }
#if os(iOS)
    .scrollContentBackground(.hidden)
    .listStyle(.insetGrouped)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbarBackground(.hidden, for: .tabBar)
    .listRowSeparatorTint(.white.opacity(0.18))
#endif
    .background(Color.clear)
  }

  // MARK: - Active multi-phone session

  /// Live multi-phone sessions of this device: the hosted game (one at a time) and guest sessions. Guest sessions
  /// are not in the SwiftData list, so this row is the way back to them.
  @ViewBuilder
  private var activeSessionSection: some View {
    let hostedGameID = multiplayerCoordinator.activeHostedGameID
    let guestSessionIDs = multiplayerCoordinator.guestSessionIDs.sorted { $0.uuidString < $1.uuidString }
    if hostedGameID != nil || !guestSessionIDs.isEmpty {
      Section {
        if let hostedGameID, let store = multiplayerCoordinator.store(for: hostedGameID) {
          NavigationLink(value: hostedGameID) {
            ActiveHostSessionRow(store: store)
          }
          .listRowBackground(Rectangle().fill(.ultraThinMaterial))
        }
        ForEach(guestSessionIDs, id: \.self) { sessionID in
          if let store = multiplayerCoordinator.store(for: sessionID) {
            NavigationLink(value: sessionID) {
              ActiveGuestSessionRow(store: store)
            }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))
          }
        }
      } header: {
        Text("UI.GameList.ActiveSession.Title")
      }
    }
  }

  // MARK: - Saved games

  @ViewBuilder
  private var listRows: some View {
    if filteredGames.isEmpty {
      ContentUnavailableView(
        "UI.GameList.Empty.Title",
        systemImage: "wand.and.stars",
        description: Text("UI.GameList.Empty.Description")
      )
      .listRowBackground(Color.clear)
    } else {
      let guestCopies = GuestFinishedGames.all()
      ForEach(filteredGames) { game in
        NavigationLink {
          GameSessionContainerView(gameId: game.id)
        } label: {
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
              Text(game.name)
                .font(.headline)
              Text(
                String(
                  format: AppLocalization.string("UI.GameList.UpdatedAt", languageCode: currentLanguageCode),
                  locale: locale
                  ,
                  game.updatedAt.formatted(
                    Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
                  )
                )
              )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if guestCopies.contains(game.id) {
              Spacer(minLength: 8)
              guestCopyBadge
            }
          }
        }
        .listRowBackground(Rectangle().fill(.ultraThinMaterial))
      }
      .onDelete(perform: deleteGames)
    }
  }

  /// Read-only copy of a finished game this phone played as a guest.
  private var guestCopyBadge: some View {
    Label("UI.GameList.GuestCopy.Badge", systemImage: "person.crop.circle.badge.checkmark")
      .labelStyle(.titleAndIcon)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(Capsule().fill(Color.secondary.opacity(0.15)))
      .accessibilityHint(Text("UI.GameList.GuestCopy.AccessibilityHint"))
  }

  private var filteredGames: [GameSnapshotEntity] {
    let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return games }
    return games.filter { $0.name.localizedCaseInsensitiveContains(q) }
  }

  private var bottomBar: some View {
    HStack(spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("UI.GameList.Search.Placeholder", text: $searchText)
          .textFieldStyle(.plain)
#if os(iOS)
          .textInputAutocapitalization(.never)
#endif
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(.ultraThinMaterial, in: Capsule())

      Button {
        showingNewGame = true
      } label: {
        Image(systemName: "plus")
          .font(.headline)
          .frame(width: 44, height: 44)
          .background(.ultraThinMaterial, in: Capsule())
          .overlay {
            Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
          }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("UI.GameList.NewGame.Accessibility")

      Button {
        joinTarget = nil
        showingJoinGame = true
      } label: {
        Image(systemName: "person.2.wave.2")
          .font(.headline)
          .frame(width: 44, height: 44)
          .background(.ultraThinMaterial, in: Capsule())
          .overlay {
            Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
          }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("UI.GameList.JoinGame.Accessibility")
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 12)
    .background(Color.clear)
  }

  private func deleteGames(at offsets: IndexSet) {
    let deleted = offsets.map { filteredGames[$0] }
    for game in deleted {
      let gameID = game.id
      // Deleting a hosted game ends its session (guests are told) and drops a stale resume record.
      multiplayerCoordinator.endSession(gameID: gameID)
      GuestFinishedGames.remove(gameID)
      modelContext.delete(game)
    }
    do {
      try modelContext.save()
    } catch {
      // Ignore for now; the list will refresh on next load.
    }
  }

  // MARK: - Guest navigation

  /// "Pick a seat again" from an ended guest session: back to the list, then Join for that host.
  private func openJoin(for target: GuestJoinTarget) {
    path = []
    joinTarget = target
    Task { @MainActor in
      try? await Task.sleep(for: Self.joinSheetDelay)
      showingJoinGame = true
    }
  }

  private func scheduleEndedGuestSessionCleanup() {
    Task { @MainActor in
      try? await Task.sleep(for: Self.endedSessionCleanupDelay)
      removeEndedGuestSessions()
    }
  }

  /// Drops guest sessions that are over and no longer on screen (left, ended by the host, game finished, …).
  private func removeEndedGuestSessions() {
    for sessionID in multiplayerCoordinator.guestSessionIDs where !path.contains(sessionID) {
      guard let store = multiplayerCoordinator.store(for: sessionID), store.connectionState.isEnded else { continue }
      multiplayerCoordinator.removeGuestSession(sessionID: sessionID)
    }
  }

  private var currentLanguageCode: String? {
    let selected = AppLanguage(rawValue: appLanguageRaw) ?? .system
    return selected == .system ? nil : selected.rawValue
  }
}

// MARK: - Active session rows

private struct ActiveHostSessionRow: View {
  @ObservedObject var store: MultiplayerGameStore

  @Environment(\.locale) private var locale

  var body: some View {
    let status = ActiveSessionStatus.host(game: store.currentGame)
    ActiveSessionRowLabel(
      title: store.currentGame?.name ?? "",
      subtitle: GuestText.format(
        "UI.GameList.ActiveSession.Subtitle",
        fallback: "%1$@ · %2$@",
        GuestText.string("UI.GameList.ActiveSession.Hosting", fallback: "You’re hosting"),
        status.localizedText
      ),
      detail: GuestText.format(
        "UI.GameList.ActiveSession.PhonesConnected",
        fallback: "Phones connected: %lld",
        store.connectedGuestPlayerIDs.count
      ),
      systemImage: "antenna.radiowaves.left.and.right",
      tint: .green
    )
  }
}

private struct ActiveGuestSessionRow: View {
  @ObservedObject var store: MultiplayerGameStore

  @Environment(\.locale) private var locale

  private var playerName: String? {
    guard case .guest(let playerId) = store.role else { return nil }
    return store.currentGame?.players.first(where: { $0.id == playerId })?.name
  }

  var body: some View {
    let status = ActiveSessionStatus.guest(game: store.currentGame, connectionState: store.connectionState)
    let role = playerName.map {
      GuestText.format("UI.GameList.ActiveSession.PlayingAs", fallback: "You play as %@", $0)
    } ?? GuestText.string("UI.GameList.ActiveSession.Guest", fallback: "Guest")
    ActiveSessionRowLabel(
      title: store.currentGame?.name ?? "",
      subtitle: GuestText.format(
        "UI.GameList.ActiveSession.Subtitle",
        fallback: "%1$@ · %2$@",
        role,
        status.localizedText
      ),
      detail: nil,
      systemImage: status.isEnded ? "person.2.slash" : "person.2.wave.2",
      tint: tint(for: status)
    )
  }

  private func tint(for status: ActiveSessionStatus) -> Color {
    switch status {
    case .reconnecting, .connecting:
      return .orange
    case .ended:
      return .red
    case .lobby, .playing, .finished:
      return .green
    }
  }
}

private struct ActiveSessionRowLabel: View {
  let title: String
  let subtitle: String
  let detail: String?
  let systemImage: String
  let tint: Color

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.title3)
        .foregroundStyle(tint)
        .frame(width: 30)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: title)
          .font(.headline)
          .lineLimit(1)
        Text(verbatim: subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
        if let detail {
          Text(verbatim: detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 2)
  }
}
