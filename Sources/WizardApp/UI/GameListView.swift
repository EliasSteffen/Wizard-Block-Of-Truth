import SwiftUI
import SwiftData

struct GameListView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(\.locale) private var locale
  @AppStorage("app.language") private var appLanguageRaw: String = AppLanguage.system.rawValue
  @Query(sort: \GameSnapshotEntity.updatedAt, order: .reverse) private var games: [GameSnapshotEntity]

  @State private var showingNewGame = false
  @State private var path: [UUID] = []
  @State private var searchText: String = ""
  @State private var showingSettings = false
  @State private var showingInfo = false

#if os(iOS)
  @State private var editMode: EditMode = .inactive
#endif

  var body: some View {
    NavigationStack(path: $path) {
      ZStack {
        WizardBackground.gradient
          .ignoresSafeArea()

        gamesList
      }
      .navigationTitle("UI.GameList.NavigationTitle")
      .navigationDestination(for: UUID.self) { id in
        GameSessionView(gameId: id)
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
        NewGameView { newId in
          path = [newId]
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
    .background(Color.clear)
    .wizardBackground()
  }

  private var gamesList: some View {
    List {
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
      ForEach(filteredGames) { game in
        NavigationLink {
          GameSessionView(gameId: game.id)
        } label: {
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
        }
        .listRowBackground(Rectangle().fill(.ultraThinMaterial))
      }
      .onDelete(perform: deleteGames)
    }
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
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 12)
    .background(Color.clear)
  }

  private func deleteGames(at offsets: IndexSet) {
    for idx in offsets {
      let game = filteredGames[idx]
      modelContext.delete(game)
    }
    do {
      try modelContext.save()
    } catch {
      // Ignore for now; the list will refresh on next load.
    }
  }

  private var currentLanguageCode: String? {
    let selected = AppLanguage(rawValue: appLanguageRaw) ?? .system
    return selected == .system ? nil : selected.rawValue
  }
}

