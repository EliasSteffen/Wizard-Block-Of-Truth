import SwiftUI
import SwiftData
#if canImport(WizardDomain)
import WizardDomain
#endif

struct NewGameView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext
  @Environment(\.colorScheme) private var colorScheme

  let onCreated: (UUID) -> Void

  @State private var name: String = "New Game"
  @State private var playerCount: Int = 4
  @State private var playerNames: [String] = []
  @State private var startingDealerIndex: Int = 0

  @State private var enabledGameConstraints: Set<Constraint.GameConstraint> = [.betSumNotEqualHandSize]

  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case gameName
    case playerName(Int)
  }

  private static let defaultNameFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_GB")
    f.timeZone = .current
    f.dateFormat = "dd/MM/yy HH:mm"
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
            TextField("Game name", text: $name)
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
              TextField("Player \(idx + 1)", text: Binding(
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
          Picker("Starting dealer", selection: $startingDealerIndex) {
            ForEach(0..<playerCount, id: \.self) { idx in
              Text(playerNames[safe: idx] ?? "Player \(idx + 1)")
                .tag(idx)
            }
          }
          .pickerStyle(.menu)
        }

        Section {
          ForEach(Constraint.GameConstraint.allCases, id: \.self) { constraint in
            Toggle(
              constraint.title,
              isOn: Binding(
                get: { enabledGameConstraints.contains(constraint) },
                set: { isEnabled in
                  if isEnabled {
                    enabledGameConstraints.insert(constraint)
                  } else {
                    enabledGameConstraints.remove(constraint)
                  }
                }
              )
            )
          }
        } header: {
          Text("House Rules")
        }
      }
#if os(iOS)
      .scrollContentBackground(.hidden)
      .scrollDisabled(true)
#endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
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
      resizeNames(to: playerCount)
      if name == "New Game" {
        name = Self.defaultGameName()
      }
      focusedField = .gameName
    }
  }

  private var playerCountBar: some View {
    HStack(spacing: 12) {
      Spacer(minLength: 0)

      Button {
        playerCount = max(2, playerCount - 1)
      } label: {
        pillText("-")
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Decrease player count")
      .disabled(playerCount <= 2)

      pillText("\(playerCount) Players")
        .accessibilityLabel("\(playerCount) players")

      Button {
        playerCount = min(6, playerCount + 1)
      } label: {
        pillText("+")
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Increase player count")
      .disabled(playerCount >= 6)

      Spacer(minLength: 0)
    }
    .padding(.vertical, 6)
    .onChange(of: playerCount) { _, newValue in
      resizeNames(to: newValue)
    }
  }

  private func pillText(_ text: String) -> some View {
    let fg = colorScheme == .dark ? Color.white : Color.black
    let bg = colorScheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.65)
    return Text(text)
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

  private func resizeNames(to count: Int) {
    if playerNames.isEmpty {
      playerNames = (0..<count).map { "Player \($0 + 1)" }
      startingDealerIndex = min(startingDealerIndex, max(0, count - 1))
      return
    }
    if playerNames.count < count {
      let start = playerNames.count
      playerNames.append(contentsOf: (start..<count).map { "Player \($0 + 1)" })
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

