import SwiftUI

/// Host-only multiplayer control (enable a session, or show the running session / end it).
enum GameSessionMultiplayerSheetMode: Identifiable {
  case enable
  case share

  var id: Self { self }
}

struct GameSessionMultiplayerToolbarContent: View {
  let gameID: UUID
  let isHosting: Bool
  let onTap: (GameSessionMultiplayerSheetMode) -> Void
  var onEndSession: () -> Void = {}

  var body: some View {
    if isHosting {
      Menu {
        Button {
          onTap(.share)
        } label: {
          Label("UI.GameSession.ShareSession.Menu", systemImage: "person.2")
        }
        Button(role: .destructive) {
          onEndSession()
        } label: {
          Label("UI.GameSession.EndSession.Menu", systemImage: "xmark.circle")
        }
      } label: {
        Label {
          Text("UI.GameSession.ShareSession.Toolbar")
        } icon: {
          Image(systemName: "person.2.fill")
        }
      }
      .accessibilityLabel("UI.GameSession.ShareSession.Accessibility")
    } else {
      Button {
        onTap(.enable)
      } label: {
        Label {
          Text("UI.GameSession.EnableMultiplayer.Toolbar")
        } icon: {
          Image(systemName: "person.2.badge.plus")
        }
      }
      .accessibilityLabel("UI.GameSession.EnableMultiplayer.Accessibility")
    }
  }
}

private struct GameSessionHostMultiplayerToolbarModifier: ViewModifier {
  let gameID: UUID
  let showsControls: Bool
  let isHosting: Bool
  @Binding var sheetMode: GameSessionMultiplayerSheetMode?

  @EnvironmentObject private var multiplayerCoordinator: MultiplayerCoordinator
  @State private var confirmsEndSession = false

  private var placement: ToolbarItemPlacement {
#if os(iOS)
    return .topBarTrailing
#else
    return .automatic
#endif
  }

  func body(content: Content) -> some View {
    content
      .toolbar {
        if showsControls {
          ToolbarItem(placement: placement) {
            GameSessionMultiplayerToolbarContent(
              gameID: gameID,
              isHosting: isHosting,
              onTap: { sheetMode = $0 },
              onEndSession: { confirmsEndSession = true }
            )
          }
        }
      }
      .sheet(item: $sheetMode) { mode in
        HostMultiplayerSheet(
          gameID: gameID,
          mode: mode == .enable ? .enable : .share
        )
      }
      .confirmationDialog(
        "UI.GameSession.EndSession.Confirm.Title",
        isPresented: $confirmsEndSession,
        titleVisibility: .visible
      ) {
        Button("UI.GameSession.EndSession.Confirm.Action", role: .destructive) {
          multiplayerCoordinator.endSession(gameID: gameID)
        }
        Button("UI.Common.Cancel", role: .cancel) {}
      } message: {
        Text("UI.GameSession.EndSession.Confirm.Message")
      }
  }
}

extension View {
  /// Host toolbar: "Multi-Phone" (enable) or a session menu (session & players, End session… with confirmation).
  /// Hidden for guests, the lobby and read-only copies (`showsControls == false`).
  func gameSessionHostMultiplayerToolbar(
    gameID: UUID,
    showsControls: Bool,
    isHosting: Bool,
    sheetMode: Binding<GameSessionMultiplayerSheetMode?>
  ) -> some View {
    modifier(
      GameSessionHostMultiplayerToolbarModifier(
        gameID: gameID,
        showsControls: showsControls,
        isHosting: isHosting,
        sheetMode: sheetMode
      )
    )
  }
}
