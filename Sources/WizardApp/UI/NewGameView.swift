import SwiftUI
import SwiftData
#if canImport(WizardDomain)
import WizardDomain
#endif

private struct LobbySheetItem: Identifiable {
  let id: UUID
}

struct NewGameView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.locale) private var locale
  @EnvironmentObject private var multiplayerCoordinator: MultiplayerCoordinator
  @AppStorage("app.language") private var appLanguageRaw: String = AppLanguage.system.rawValue

  let onCreated: (UUID) -> Void
  var onMultiplayerGameStarted: ((UUID) -> Void)?

  @State private var name: String = String(localized: "UI.NewGame.DefaultName", defaultValue: "New Game")
  @AppStorage("newGame.defaultPlayerCount") private var defaultPlayerCount: Int = 4
  @State private var playerCount: Int = 4
  @State private var playerNames: [String] = []
  @State private var startingDealerIndex: Int = 0

  @State private var enabledGameConstraints: Set<Constraint.GameConstraint> = [.betSumNotEqualHandSize]
  @State private var firstRoundBetSumMayEqualHandSize: Bool = false
  @State private var playWithSpecialCards: Bool = true
  @State private var gameMode: GameMode = .singlePhone
  /// The multi-phone game this sheet created (at most one: "Create Lobby" again reopens it instead of a new game).
  @State private var createdLobbyGameID: UUID?
  @State private var createdLobbyHostPlayerId: UUID?
  @State private var presentedLobby: LobbySheetItem?
  @State private var hostDisplayName: String = GuestJoinPreferences.hostDisplayName
  @State private var hostingConflict: HostSessionConflict?
  @State private var hostingError: String?

  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case gameName
    case playerName(Int)
  }

  private static let defaultNameFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = .autoupdatingCurrent
    f.timeZone = .current
    f.setLocalizedDateFormatFromTemplate("ddMMyyHHmm")
    return f
  }()

  private static func defaultGameName(now: Date = .now) -> String {
    defaultNameFormatter.string(from: now)
  }

  private var isMultiPhone: Bool { gameMode == .multiPhone }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack {
            Spacer()
            TextField("UI.NewGame.Name.Placeholder", text: $name)
              .font(.title2.weight(.semibold))
              .textFieldStyle(.plain)
              .multilineTextAlignment(.center)
              .focused($focusedField, equals: .gameName)
            Spacer()
          }
          .frame(maxWidth: .infinity)
          .contentShape(Rectangle())
          .onTapGesture { focusedField = .gameName }
        }

        Section {
          Picker("UI.NewGame.Mode.Title", selection: $gameMode) {
            Text("UI.NewGame.Mode.SinglePhone").tag(GameMode.singlePhone)
            Text("UI.NewGame.Mode.MultiPhone").tag(GameMode.multiPhone)
          }
          .pickerStyle(.segmented)
        }

        if isMultiPhone {
          Section {
            Text("UI.NewGame.MultiPhone.PlayersHint")
              .foregroundStyle(.secondary)
          } header: {
            playerCountBar
          }
        } else {
          Section {
            ForEach(0..<playerCount, id: \.self) { idx in
              HStack {
                TextField(String(localized: "UI.NewGame.Player.Placeholder", defaultValue: "Player \(idx + 1)", locale: locale), text: Binding(
                  get: { playerNames[safe: idx] ?? "" },
                  set: { newValue in
                    if idx < playerNames.count { playerNames[idx] = newValue }
                  }
                ))
                .focused($focusedField, equals: .playerName(idx))
              }
              .contentShape(Rectangle())
              .onTapGesture { focusedField = .playerName(idx) }
            }
          } header: {
            playerCountBar
          }

          Section {
            Picker("UI.NewGame.StartingDealer.Title", selection: $startingDealerIndex) {
              ForEach(0..<playerCount, id: \.self) { idx in
                Text(playerNames[safe: idx] ?? String(localized: "UI.NewGame.Player.Placeholder", defaultValue: "Player \(idx + 1)", locale: locale))
                  .tag(idx)
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

      }
#if os(iOS)
      .scrollContentBackground(.hidden)
#endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("UI.Common.Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            if isMultiPhone {
              openOrCreateLobby()
            } else if let id = create() {
              onCreated(id)
              dismiss()
            }
          } label: {
            Text(confirmButtonTitleKey)
          }
          .disabled(!canCreate)
        }
      }
    }
    .wizardBackground()
    .onAppear {
      playerCount = min(6, max(2, defaultPlayerCount))
      resizeNames(to: playerCount)

      if name == String(localized: "UI.NewGame.DefaultName", defaultValue: "New Game") {
        name = Self.defaultGameName()
      }
      if hostDisplayName.isEmpty {
        hostDisplayName = GuestJoinPreferences.hostDisplayName
      }
      focusedField = nil
    }
    .sheet(item: $presentedLobby) { item in
      NavigationStack {
        MultiplayerLobbyView(
          gameID: item.id,
          onGameStarted: {
            // Dismissing this sheet also closes the lobby sheet on top of it; the list then opens the game.
            onMultiplayerGameStarted?(item.id)
            onCreated(item.id)
            dismiss()
          },
          onSessionEnded: {
            presentedLobby = nil
          }
        )
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("UI.MultiplayerLobby.Close") { presentedLobby = nil }
          }
        }
      }
      .environmentObject(multiplayerCoordinator)
      .presentationDetents([.large])
    }
    .hostSessionConflictDialog($hostingConflict) { pending in
      multiplayerCoordinator.endSession(gameID: pending.otherGameID)
      if let retryGameID = pending.retryGameID {
        hostLobby(gameID: retryGameID)
      } else {
        openOrCreateLobby()
      }
    }
    .alert(
      "UI.Common.Error",
      isPresented: Binding(
        get: { hostingError != nil },
        set: { isPresented in if !isPresented { hostingError = nil } }
      )
    ) {
      Button("UI.Common.OK", role: .cancel) { hostingError = nil }
    } message: {
      Text(hostingError ?? "")
    }
  }

  /// "Create Lobby", or "Open Lobby" once this sheet created one (never a second game).
  private var confirmButtonTitleKey: LocalizedStringKey {
    guard isMultiPhone else { return "UI.Common.Create" }
    return createdLobbyGameID == nil ? "UI.NewGame.CreateLobby" : "UI.MultiplayerLobby.Open"
  }

  /// The player count is fixed once the lobby exists (its seats were created with it).
  private var isPlayerCountLocked: Bool {
    isMultiPhone && createdLobbyGameID != nil
  }

  private var playerCountBar: some View {
    HStack(spacing: 12) {
      Spacer(minLength: 0)

      Button {
        playerCount = max(2, playerCount - 1)
      } label: {
        pillText(Text("UI.Common.Symbol.Minus"))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("UI.NewGame.PlayerCount.Decrease")
      .disabled(playerCount <= 2 || isPlayerCountLocked)

      pillText(
        Text(
          String(
            format: AppLocalization.string("UI.NewGame.PlayerCount.Display", languageCode: currentLanguageCode),
            locale: locale,
            Int64(playerCount)
          )
        )
      )
      .accessibilityLabel(
        String(
          format: AppLocalization.string("UI.NewGame.PlayerCount.Accessibility", languageCode: currentLanguageCode),
          locale: locale,
          Int64(playerCount)
        )
      )

      Button {
        playerCount = min(6, playerCount + 1)
      } label: {
        pillText(Text("UI.Common.Symbol.Plus"))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("UI.NewGame.PlayerCount.Increase")
      .disabled(playerCount >= 6 || isPlayerCountLocked)

      Spacer(minLength: 0)
    }
    .padding(.vertical, 6)
    .onChange(of: playerCount) { _, newValue in
      resizeNames(to: newValue)
    }
  }

  private func pillText(_ text: Text) -> some View {
    let fg = colorScheme == .dark ? Color.white : Color.black
    let bg = colorScheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.65)
    return text
      .font(.headline)
      .foregroundStyle(fg)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(bg, in: Capsule())
  }

  private var canCreate: Bool {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return false }
    if isMultiPhone { return true }
    let trimmed = playerNames.prefix(playerCount).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    return trimmed.allSatisfy { !$0.isEmpty }
  }

  private var currentLanguageCode: String? {
    let selected = AppLanguage(rawValue: appLanguageRaw) ?? .system
    return selected == .system ? nil : selected.rawValue
  }

  private func resizeNames(to count: Int) {
    if playerNames.isEmpty {
      playerNames = (0..<count).map { String(localized: "UI.NewGame.Player.Placeholder", defaultValue: "Player \($0 + 1)", locale: locale) }
      startingDealerIndex = min(startingDealerIndex, max(0, count - 1))
      return
    }
    if playerNames.count < count {
      let start = playerNames.count
      playerNames.append(contentsOf: (start..<count).map { String(localized: "UI.NewGame.Player.Placeholder", defaultValue: "Player \($0 + 1)", locale: locale) })
    } else if playerNames.count > count {
      playerNames = Array(playerNames.prefix(count))
    }
    startingDealerIndex = min(startingDealerIndex, max(0, count - 1))
  }

  /// Single-phone: creates and starts the game. Multi-phone: creates the unstarted game with "Player N" seats (the
  /// first seat is the host's); hosting is started by `hostLobby(gameID:)`.
  private func create() -> UUID? {
    let players: [Player]
    if isMultiPhone {
      players = (0..<playerCount).map { idx in
        Player(
          id: UUID(),
          name: String(localized: "UI.NewGame.Player.Placeholder", defaultValue: "Player \(idx + 1)", locale: locale)
        )
      }
    } else {
      players = (0..<playerCount).map { idx in
        Player(id: UUID(), name: playerNames[idx].trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }

    let store = GameStore(modelContext: modelContext)
    let constraints = Constraint.GameConstraint.allCases.filter { enabledGameConstraints.contains($0) }
    store.createGame(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      mode: gameMode,
      players: players,
      playWithSpecialCards: playWithSpecialCards,
      gameConstraints: isMultiPhone ? [.betSumNotEqualHandSize] : constraints,
      // Multi-phone games pick their house rules in the lobby (`MultiplayerLobbyView`).
      firstRoundBetSumMayEqualHandSize: !isMultiPhone
        && firstRoundBetSumMayEqualHandSize
        && constraints.contains(.betSumNotEqualHandSize)
    )

    if !isMultiPhone, let dealerId = players[safe: startingDealerIndex]?.id {
      store.apply(.startNewGame(startingDealer: dealerId))
    }

    guard let gameID = store.currentGame?.id else {
      if let error = store.lastError {
        hostingError = AppErrorMessage.presentableMessage(for: error, languageCode: AppLanguage.catalogLookupLanguageCode)
      }
      return nil
    }
    if isMultiPhone {
      createdLobbyHostPlayerId = players[0].id
    }
    return gameID
  }

  /// Multi-phone "Create Lobby": asks to end another running session first (one session at a time), creates the
  /// game once and opens its lobby. Tapping again reopens the same lobby instead of creating another game.
  private func openOrCreateLobby() {
    if let createdLobbyGameID {
      hostLobby(gameID: createdLobbyGameID)
      return
    }
    if let activeGameID = multiplayerCoordinator.activeHostedGameID {
      hostingConflict = HostSessionConflict(
        otherGameID: activeGameID,
        otherGameName: multiplayerCoordinator.hostLobbyState?.gameName ?? "",
        retryGameID: nil
      )
      return
    }
    guard let gameID = create() else { return }
    createdLobbyGameID = gameID
    hostLobby(gameID: gameID)
  }

  /// Starts (or rejoins) hosting `gameID` and shows its lobby. Errors are shown, never swallowed.
  private func hostLobby(gameID: UUID) {
    let hostName = hostDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedHostName = hostName.isEmpty
      ? String(localized: "UI.MultiplayerLobby.HostDefaultName", defaultValue: "Host", locale: locale)
      : hostName
    guard let hostPlayerId = createdLobbyHostPlayerId else { return }
    do {
      try multiplayerCoordinator.startHosting(
        gameID: gameID,
        modelContext: modelContext,
        hostPlayerId: hostPlayerId,
        hostDisplayName: resolvedHostName
      )
      presentedLobby = LobbySheetItem(id: gameID)
    } catch MultiplayerCoordinatorError.anotherSessionActive(let otherGameID, let otherGameName) {
      hostingConflict = HostSessionConflict(
        otherGameID: otherGameID,
        otherGameName: otherGameName,
        retryGameID: gameID
      )
    } catch {
      hostingError = AppErrorMessage.presentableMessage(for: error, languageCode: AppLanguage.catalogLookupLanguageCode)
    }
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    guard indices.contains(index) else { return nil }
    return self[index]
  }
}
