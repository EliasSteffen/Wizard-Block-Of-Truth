import SwiftUI
import SwiftData
#if canImport(WizardDomain)
import WizardDomain
#endif

struct NewGameView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  let onCreated: (UUID) -> Void

  @State private var name: String = "New Game"
  @State private var playerCount: Int = 4
  @State private var playerNames: [String] = []

  @State private var enforceBetSumNotEqualHandSize: Bool = true

  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case gameName
    case playerName(Int)
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
          Toggle(GameConstraint.betSumNotEqualHandSize.title, isOn: $enforceBetSumNotEqualHandSize)
        } header: {
          Text("Constraints")
        } footer: {
          Text(GameConstraint.betSumNotEqualHandSize.detail)
        }
      }
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
    .onAppear {
      resizeNames(to: playerCount)
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
    Text(text)
      .font(.headline)
      .foregroundStyle(.primary)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(Color.white.opacity(0.65), in: Capsule())
  }

  private var canCreate: Bool {
    let trimmed = playerNames.prefix(playerCount).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && trimmed.allSatisfy { !$0.isEmpty }
  }

  private func resizeNames(to count: Int) {
    if playerNames.isEmpty {
      playerNames = (0..<count).map { "Player \($0 + 1)" }
      return
    }
    if playerNames.count < count {
      let start = playerNames.count
      playerNames.append(contentsOf: (start..<count).map { "Player \($0 + 1)" })
    } else if playerNames.count > count {
      playerNames = Array(playerNames.prefix(count))
    }
  }

  private func create() -> UUID? {
    let players: [Player] = (0..<playerCount).map { idx in
      Player(id: UUID(), name: playerNames[idx].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    let store = GameStore(modelContext: modelContext)
    var constraints: [GameConstraint] = []
    constraints.append(.gotSumEqualsHandSize)
    if enforceBetSumNotEqualHandSize {
      constraints.append(.betSumNotEqualHandSize)
    }
    store.createGame(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      mode: .singlePhone,
      players: players,
      additionalConstraints: constraints
    )
    return store.currentGame?.id
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    guard indices.contains(index) else { return nil }
    return self[index]
  }
}

