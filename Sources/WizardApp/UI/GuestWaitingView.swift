import SwiftUI
#if canImport(WizardDomain)
import WizardDomain
#endif
#if canImport(WizardNet)
import WizardNet
#endif

/// Guest after claiming a seat, until the host starts the game (`GameSessionContainerView` then switches to
/// `GuestGameSessionView`). Shows the live lobby, the connection state and lets the guest leave.
struct GuestWaitingView: View {
  @ObservedObject var store: MultiplayerGameStore

  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale

  private var guestPlayerID: UUID? {
    if case .guest(let playerId) = store.role { return playerId }
    return nil
  }

  private var isLive: Bool {
    !store.connectionState.isEnded
  }

  private var seats: [GuestWaitingSeat] {
    GuestWaitingSeat.make(
      slots: store.lobbySlots,
      players: store.currentGame?.players ?? [],
      guestPlayerID: guestPlayerID
    )
  }

  private var ownName: String? {
    guard let guestPlayerID else { return nil }
    return seats.first(where: { $0.id == guestPlayerID })?.name
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GuestConnectionBannerView(store: store, onClose: { dismiss() })

        if isLive {
          statusCard
        }

        seatsSection
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
    }
    .navigationTitle(
      store.currentGame?.name ?? String(localized: "UI.GameSession.NavigationFallback", defaultValue: "Game")
    )
#if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
#endif
    .wizardBackground()
    .guestSessionLeaveControls(store: store)
    .keepsScreenAwake(isLive)
  }

  private var statusCard: some View {
    HStack(alignment: .center, spacing: 12) {
      if store.connectionState == .connected {
        ProgressView()
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("UI.GuestWaiting.Message")
          .font(.headline)
        if let ownName {
          Text(
            verbatim: GuestText.format(
              "UI.GuestWaiting.PlayingAs",
              fallback: "You play as %@.",
              ownName
            )
          )
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
    }
  }

  private var seatsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("UI.GuestWaiting.Players.Header")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)

      ForEach(seats) { seat in
        seatRow(seat)
      }

      Text("UI.GuestWaiting.SeatOrder.Footer")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }
  }

  private func seatRow(_ seat: GuestWaitingSeat) -> some View {
    HStack(spacing: 10) {
      Text(verbatim: "\(seat.number).")
        .font(.subheadline.weight(.semibold).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 24, alignment: .leading)

      Text(verbatim: seat.name)
        .font(.headline.weight(seat.isYou ? .bold : .semibold))
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer(minLength: 8)

      seatBadge(seat)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(seat.isYou ? Color.green.opacity(0.6) : Color.white.opacity(0.18), lineWidth: 1)
    }
  }

  @ViewBuilder
  private func seatBadge(_ seat: GuestWaitingSeat) -> some View {
    if seat.isYou {
      Text("UI.GuestWaiting.You")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.green)
    } else if seat.isHost {
      Text("UI.GuestWaiting.Seat.Host")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
    } else {
      switch seat.device {
      case .connected:
        Label("UI.GuestWaiting.Seat.Phone", systemImage: "iphone")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      case .offline:
        Label("UI.GuestWaiting.Seat.Offline", systemImage: "iphone.slash")
          .font(.subheadline)
          .foregroundStyle(.orange)
      case .noPhone:
        Text("UI.GuestWaiting.Seat.HostEnters")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }
}
