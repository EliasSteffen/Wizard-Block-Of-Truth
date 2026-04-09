import SwiftUI
import SwiftData

struct NewGameView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var modelContext

  let onCreated: (UUID) -> Void

  @State private var name: String = "New Game"
  @State private var playerCount: Int = 4
  @State private var playerNames: [String] = ["Alice", "Bob", "Cara", "Dan"]

  var body: some View {
    NavigationStack {
      Form {
        Section("Game") {
          TextField("Name", text: $name)
          Picker("Players", selection: $playerCount) {
            ForEach(2..<7, id: \.self) { n in
              Text("\(n)").tag(n)
            }
          }
          .onChange(of: playerCount) { _, newValue in
            resizeNames(to: newValue)
          }
        }

        Section("Players") {
          ForEach(0..<playerCount, id: \.self) { idx in
            TextField("Player \(idx + 1)", text: Binding(
              get: { playerNames[safe: idx] ?? "" },
              set: { newValue in
                if idx < playerNames.count { playerNames[idx] = newValue }
              }
            ))
          }
        }
      }
      .navigationTitle("New Game")
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
    .onAppear { resizeNames(to: playerCount) }
  }

  private var canCreate: Bool {
    let trimmed = playerNames.prefix(playerCount).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && trimmed.allSatisfy { !$0.isEmpty }
  }

  private func resizeNames(to count: Int) {
    if playerNames.count < count {
      playerNames.append(contentsOf: Array(repeating: "", count: count - playerNames.count))
    } else if playerNames.count > count {
      playerNames = Array(playerNames.prefix(count))
    }
  }

  private func create() -> UUID? {
    let players: [Player] = (0..<playerCount).map { idx in
      Player(id: UUID(), name: playerNames[idx].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    let store = GameStore(modelContext: modelContext)
    store.createGame(name: name.trimmingCharacters(in: .whitespacesAndNewlines), mode: .singlePhone, players: players)
    return store.currentGame?.id
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    guard indices.contains(index) else { return nil }
    return self[index]
  }
}

