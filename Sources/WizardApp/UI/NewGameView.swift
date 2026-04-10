import SwiftUI
import SwiftData
#if canImport(WizardDomain)
import WizardDomain
#endif

struct NewGameView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.locale) private var locale
  @AppStorage("app.language") private var appLanguageRaw: String = AppLanguage.system.rawValue

  let onCreated: (UUID) -> Void

  @State private var name: String = String(localized: "UI.NewGame.DefaultName", defaultValue: "New Game")
  @AppStorage("newGame.defaultPlayerCount") private var defaultPlayerCount: Int = 4
  @State private var playerCount: Int = 4
  @State private var playerNames: [String] = []
  @State private var startingDealerIndex: Int = 0

  @State private var enabledGameConstraints: Set<Constraint.GameConstraint> = [.betSumNotEqualHandSize]
  @State private var playWithSpecialCards: Bool = true

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

        Section {
          Toggle(isOn: $playWithSpecialCards) {
            Text("UI.NewGame.PlayWithSpecialCards.Toggle")
          }
        }
      }
#if os(iOS)
      .scrollContentBackground(.hidden)
      .scrollDisabled(true)
#endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("UI.Common.Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("UI.Common.Create") {
            if let id = create() {
              onCreated(id)
            }
            dismiss()
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
      focusedField = nil
    }
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
      .disabled(playerCount <= 2)

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
      .disabled(playerCount >= 6)

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
    let trimmed = playerNames.prefix(playerCount).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && trimmed.allSatisfy { !$0.isEmpty }
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

  private func create() -> UUID? {
    let players: [Player] = (0..<playerCount).map { idx in
      Player(id: UUID(), name: playerNames[idx].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    let store = GameStore(modelContext: modelContext)
    let constraints = Constraint.GameConstraint.allCases.filter { enabledGameConstraints.contains($0) }
    store.createGame(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      mode: .singlePhone,
      players: players,
      playWithSpecialCards: playWithSpecialCards,
      gameConstraints: constraints
    )

    // Start immediately so the session doesn't need a separate "pick dealer" step.
    if let dealerId = players[safe: startingDealerIndex]?.id {
      store.apply(.startNewGame(startingDealer: dealerId))
    }
    return store.currentGame?.id
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    guard indices.contains(index) else { return nil }
    return self[index]
  }
}

