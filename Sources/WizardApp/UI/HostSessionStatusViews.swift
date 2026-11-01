import SwiftUI
#if canImport(WizardDomain)
import WizardDomain
#endif
#if canImport(WizardNet)
import WizardNet
#endif

/// Warning shown on the host's lobby / game screen while guests can't reach the session (listener down or
/// restarting, Local Network permission off).
struct HostSessionHealthBanner: View {
  let health: MultiPhoneHostRules.SessionHealth
  var onRetry: (() -> Void)?

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("UI.Multiplayer.HostHealth.Title")
          .font(.subheadline.weight(.semibold))
        Text(message)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      if let onRetry {
        Button("UI.Common.Retry", action: onRetry)
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var message: String {
    let languageCode = AppLanguage.catalogLookupLanguageCode
    switch health {
    case .localNetworkDenied:
      return MultiplayerReasonText.message(for: TransportFailure.localNetworkDenied, languageCode: languageCode)
    case .unreachable:
      return AppLocalization.string(
        "UI.Multiplayer.HostHealth.Restarting",
        languageCode: languageCode,
        fallback: "The session is being restarted. Keep the app open on this phone."
      )
    }
  }
}

/// Per-seat phone status in the lobby / session sheet: host, phone connected, phone offline, no phone.
struct LobbySeatStatusBadge: View {
  let status: MultiPhoneHostRules.SeatDeviceStatus

  var body: some View {
    Label {
      Text(LocalizedStringKey(Self.titleKey(for: status)))
    } icon: {
      Image(systemName: Self.systemImage(for: status))
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(color)
    .labelStyle(.titleAndIcon)
  }

  static func titleKey(for status: MultiPhoneHostRules.SeatDeviceStatus) -> String {
    switch status {
    case .host:
      return "UI.MultiplayerLobby.Status.Host"
    case .phoneConnected:
      return "UI.MultiplayerLobby.Seat.PhoneConnected"
    case .phoneOffline:
      return "UI.MultiplayerLobby.Seat.PhoneOffline"
    case .noPhone:
      return "UI.MultiplayerLobby.Seat.NoPhone"
    }
  }

  static func title(for status: MultiPhoneHostRules.SeatDeviceStatus, languageCode: String?) -> String {
    switch status {
    case .host:
      return AppLocalization.string(titleKey(for: status), languageCode: languageCode, fallback: "Host")
    case .phoneConnected:
      return AppLocalization.string(titleKey(for: status), languageCode: languageCode, fallback: "Phone connected")
    case .phoneOffline:
      return AppLocalization.string(titleKey(for: status), languageCode: languageCode, fallback: "Phone offline")
    case .noPhone:
      return AppLocalization.string(titleKey(for: status), languageCode: languageCode, fallback: "No phone")
    }
  }

  private static func systemImage(for status: MultiPhoneHostRules.SeatDeviceStatus) -> String {
    switch status {
    case .host:
      return "star.fill"
    case .phoneConnected:
      return "iphone"
    case .phoneOffline:
      return "iphone.slash"
    case .noPhone:
      return "person.fill"
    }
  }

  private var color: Color {
    switch status {
    case .host:
      return .blue
    case .phoneConnected:
      return .green
    case .phoneOffline:
      return .orange
    case .noPhone:
      return .secondary
    }
  }
}

/// Compact row on the host's game screen: which guest phones are connected right now.
struct HostGuestPhonesStrip: View {
  let players: [Player]
  let boundPlayerIDs: Set<UUID>
  let connectedPlayerIDs: Set<UUID>

  var body: some View {
    let guests = players.filter { boundPlayerIDs.contains($0.id) }
    if !guests.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          Text("UI.GameSession.Multiplayer.Phones")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          ForEach(guests, id: \.id) { player in
            guestChip(player: player, isConnected: connectedPlayerIDs.contains(player.id))
          }
        }
        .padding(.horizontal, 2)
      }
    }
  }

  private func guestChip(player: Player, isConnected: Bool) -> some View {
    let status: MultiPhoneHostRules.SeatDeviceStatus = isConnected ? .phoneConnected : .phoneOffline
    return Label {
      Text(verbatim: player.name)
        .lineLimit(1)
    } icon: {
      Image(systemName: isConnected ? "iphone" : "iphone.slash")
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(isConnected ? Color.green : Color.orange)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(.ultraThinMaterial, in: Capsule())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      Text(verbatim: "\(player.name), \(LobbySeatStatusBadge.title(for: status, languageCode: AppLanguage.catalogLookupLanguageCode))")
    )
  }
}

/// Session code shown as an identifier (guests tap the session; nobody types the code).
struct HostSessionCodeSection: View {
  let sessionCode: String

  var body: some View {
    Section {
      Text(verbatim: sessionCode)
        .font(.system(.title, design: .monospaced).weight(.bold))
        .frame(maxWidth: .infinity, alignment: .center)
        .textSelection(.enabled)
    } header: {
      Text("UI.MultiplayerLobby.Session.Header")
    } footer: {
      Text(
        AppLocalization.format(
          "UI.MultiplayerLobby.Session.Footer",
          languageCode: AppLanguage.catalogLookupLanguageCode,
          fallback: "Session %@ – guests on the same Wi-Fi tap it under Join to take a seat.",
          sessionCode
        )
      )
    }
  }
}

/// "Another multi-phone session is running" (one hosted session at a time, decision 7).
struct HostSessionConflict: Identifiable, Equatable {
  let otherGameID: UUID
  let otherGameName: String
  /// The game to host once the other session ended (`nil`: the caller decides).
  var retryGameID: UUID?

  var id: UUID { otherGameID }
}

private struct HostSessionConflictDialogModifier: ViewModifier {
  @Binding var conflict: HostSessionConflict?
  let onConfirm: (HostSessionConflict) -> Void

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        Text(title),
        isPresented: Binding(
          get: { conflict != nil },
          set: { isPresented in
            if !isPresented { conflict = nil }
          }
        ),
        titleVisibility: .visible,
        presenting: conflict
      ) { presented in
        Button("UI.GameSession.EndSession.Confirm.Action", role: .destructive) {
          conflict = nil
          onConfirm(presented)
        }
        Button("UI.Common.Cancel", role: .cancel) {
          conflict = nil
        }
      } message: { _ in
        Text("UI.Multiplayer.EndOtherSession.Message")
      }
  }

  private var title: String {
    AppLocalization.format(
      "UI.Multiplayer.EndOtherSession.Title",
      languageCode: AppLanguage.catalogLookupLanguageCode,
      fallback: "End the running session for “%@”?",
      conflict?.otherGameName ?? ""
    )
  }
}

extension View {
  /// Asks "End the running session for <name>?"; `onConfirm` must end that session and retry. Cancelling just
  /// clears `conflict`.
  func hostSessionConflictDialog(
    _ conflict: Binding<HostSessionConflict?>,
    onConfirm: @escaping (HostSessionConflict) -> Void
  ) -> some View {
    modifier(HostSessionConflictDialogModifier(conflict: conflict, onConfirm: onConfirm))
  }
}

private struct SeatUnassignDialogModifier: ViewModifier {
  @Binding var slot: LobbyPlayerSlot?
  let onConfirm: (LobbyPlayerSlot) -> Void

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        Text(title),
        isPresented: Binding(
          get: { slot != nil },
          set: { isPresented in
            if !isPresented { slot = nil }
          }
        ),
        titleVisibility: .visible,
        presenting: slot
      ) { presented in
        Button("UI.MultiplayerLobby.Seat.Kick", role: .destructive) {
          slot = nil
          onConfirm(presented)
        }
        Button("UI.Common.Cancel", role: .cancel) {
          slot = nil
        }
      } message: { _ in
        Text("UI.MultiplayerLobby.Seat.Kick.Confirm.Message")
      }
  }

  private var title: String {
    AppLocalization.format(
      "UI.MultiplayerLobby.Seat.Kick.Confirm.Title",
      languageCode: AppLanguage.catalogLookupLanguageCode,
      fallback: "Remove %@’s phone?",
      slot?.name ?? ""
    )
  }
}

extension View {
  /// Confirms unassigning (kicking) a guest's phone from a seat; the seat keeps its name and can be taken again.
  func seatUnassignDialog(
    _ slot: Binding<LobbyPlayerSlot?>,
    onConfirm: @escaping (LobbyPlayerSlot) -> Void
  ) -> some View {
    modifier(SeatUnassignDialogModifier(slot: slot, onConfirm: onConfirm))
  }
}
