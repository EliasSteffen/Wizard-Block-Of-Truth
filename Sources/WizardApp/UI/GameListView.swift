import SwiftUI
import SwiftData

struct GameListView: View {
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \GameSnapshotEntity.updatedAt, order: .reverse) private var games: [GameSnapshotEntity]

  @State private var showingNewGame = false
  @State private var path: [UUID] = []

  var body: some View {
    NavigationStack(path: $path) {
      List {
        if games.isEmpty {
          ContentUnavailableView(
            "No games yet",
            systemImage: "wand.and.stars",
            description: Text("Create a game to start tracking scores.")
          )
        } else {
          ForEach(games) { game in
            NavigationLink {
              GameSessionView(gameId: game.id)
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(game.name).font(.headline)
                Text("Updated \(game.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .navigationDestination(for: UUID.self) { id in
        GameSessionView(gameId: id)
      }
      .navigationTitle("Wizard")
      .toolbar {
        ToolbarItem(placement: toolbarPlacement) {
          Button {
            showingNewGame = true
          } label: {
            Label("New Game", systemImage: "plus")
          }
        }
      }
      .sheet(isPresented: $showingNewGame) {
        NewGameView { newId in
          path = [newId]
        }
          .presentationDetents([.medium, .large])
      }
    }
  }

  private var toolbarPlacement: ToolbarItemPlacement {
#if os(iOS)
    return .topBarTrailing
#else
    return .automatic
#endif
  }
}

