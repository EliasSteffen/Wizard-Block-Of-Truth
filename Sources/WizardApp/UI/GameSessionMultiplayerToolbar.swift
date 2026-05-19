import SwiftUI

/// Host-only multiplayer control (enable session or show join code).
enum GameSessionMultiplayerSheetMode: Identifiable {
  case enable
  case share

  var id: Self { self }
}

struct GameSessionMultiplayerToolbarContent: View {
  let gameID: UUID
  let isHosting: Bool
  let onTap: (GameSessionMultiplayerSheetMode) -> Void

  var body: some View {
    if isHosting {
      Button {
        onTap(.share)
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

extension View {
  @ViewBuilder
  func gameSessionHostMultiplayerToolbar(
    gameID: UUID,
    isGuestSession: Bool,
    isHosting: Bool,
    sheetMode: Binding<GameSessionMultiplayerSheetMode?>
  ) -> some View {
    let placement: ToolbarItemPlacement = {
#if os(iOS)
      return .topBarTrailing
#else
      return .automatic
#endif
    }()

    self
      .toolbar {
        if !isGuestSession {
          ToolbarItem(placement: placement) {
            GameSessionMultiplayerToolbarContent(
              gameID: gameID,
              isHosting: isHosting,
              onTap: { sheetMode.wrappedValue = $0 }
            )
          }
        }
      }
      .sheet(item: sheetMode) { mode in
        HostMultiplayerSheet(
          gameID: gameID,
          mode: mode == .enable ? .enable : .share
        )
      }
  }
}
