import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WizardDomain)
import WizardDomain
#endif
#if canImport(WizardNet)
import WizardNet
#endif

// Shared building blocks of the guest's waiting and game screens: connection banner, leave controls,
// Bomb/Cloud indicator and the navigation hook back into the game list.

// MARK: - Navigation hook

/// Lets a guest screen (pushed from the game list) ask the game list to pop and open Join for a host again.
struct GuestSessionNavigation {
  /// Pops to the game list and opens Join for `target` ("Pick a seat again").
  var rejoin: @MainActor (GuestJoinTarget) -> Void
}

private struct GuestSessionNavigationKey: EnvironmentKey {
  static var defaultValue: GuestSessionNavigation? { nil }
}

extension EnvironmentValues {
  var guestSessionNavigation: GuestSessionNavigation? {
    get { self[GuestSessionNavigationKey.self] }
    set { self[GuestSessionNavigationKey.self] = newValue }
  }
}

// MARK: - Connection banner

/// Connecting / reconnecting / session ended. Shows nothing while connected.
struct GuestConnectionBannerView: View {
  @ObservedObject var store: MultiplayerGameStore
  /// Leaves the (already ended) screen, back to the game list.
  let onClose: () -> Void

  @Environment(\.guestSessionNavigation) private var navigation
  @Environment(\.locale) private var locale

  var body: some View {
    if let banner = GuestConnectionBanner.make(
      state: store.connectionState,
      transportFailure: store.lastTransportFailure
    ) {
      content(for: banner)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(tint(for: banner).opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
  }

  @ViewBuilder
  private func content(for banner: GuestConnectionBanner) -> some View {
    switch banner {
    case .connecting:
      HStack(spacing: 10) {
        ProgressView()
        Text("UI.GuestSession.Banner.Connecting")
          .font(.subheadline.weight(.semibold))
      }

    case .reconnecting(let attempt, let localNetworkDenied):
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 10) {
          ProgressView()
          Text(
            verbatim: GuestText.format(
              "UI.GuestSession.Banner.Reconnecting",
              fallback: "Connection lost – reconnecting… (attempt %lld)",
              attempt
            )
          )
          .font(.subheadline.weight(.semibold))
        }
        if localNetworkDenied {
          Text(
            verbatim: MultiplayerReasonText.message(
              for: TransportFailure.localNetworkDenied,
              languageCode: AppLanguage.catalogLookupLanguageCode
            )
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        } else {
          Text("UI.GuestSession.Banner.Reconnecting.Hint")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        HStack(spacing: 12) {
          Button {
            store.reconnectNow()
          } label: {
            Label("UI.GuestSession.Banner.RetryNow", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.bordered)
          if localNetworkDenied {
            LocalNetworkSettingsButton()
          }
        }
      }

    case .ended(let reason, let canPickSeatAgain):
      VStack(alignment: .leading, spacing: 10) {
        Label {
          Text(
            verbatim: MultiplayerReasonText.message(
              for: reason,
              languageCode: AppLanguage.catalogLookupLanguageCode
            )
          )
          .font(.subheadline.weight(.semibold))
        } icon: {
          Image(systemName: "exclamationmark.octagon.fill")
            .foregroundStyle(.red)
        }
        HStack(spacing: 12) {
          Button {
            onClose()
          } label: {
            Text("UI.GuestSession.Ended.Close")
          }
          .buttonStyle(.borderedProminent)
          if canPickSeatAgain, let navigation, let target = pickSeatAgainTarget {
            Button {
              navigation.rejoin(target)
            } label: {
              Text("UI.GuestSession.Ended.PickSeatAgain")
            }
            .buttonStyle(.bordered)
          }
        }
      }
    }
  }

  /// The same host, without a token: the join screen shows its seats again.
  private var pickSeatAgainTarget: GuestJoinTarget? {
    guard let serviceName = store.serviceName, let code = store.guestSessionCode else { return nil }
    return GuestJoinTarget(
      serviceName: serviceName,
      sessionCode: code,
      gameName: store.currentGame?.name ?? BonjourServiceDescriptor.parse(serviceName: serviceName).displayName
    )
  }

  private func tint(for banner: GuestConnectionBanner) -> Color {
    switch banner {
    case .connecting:
      return .blue
    case .reconnecting:
      return .orange
    case .ended:
      return .red
    }
  }
}

/// "Open Settings" for the Local Network permission (iOS only; nothing on macOS).
struct LocalNetworkSettingsButton: View {
  @Environment(\.openURL) private var openURL

  var body: some View {
#if canImport(UIKit)
    Button {
      if let url = URL(string: UIApplication.openSettingsURLString) {
        openURL(url)
      }
    } label: {
      Label("UI.GuestSession.OpenSettings", systemImage: "gearshape")
    }
    .buttonStyle(.bordered)
#else
    EmptyView()
#endif
  }
}

// MARK: - Bomb / Cloud indicator

/// Read-only note that the host declared the Bomb or the Cloud (decision 5: host only, guests see it).
struct GuestSpecialCardsIndicator: View {
  let summary: GuestSpecialCardsSummary

  @Environment(\.locale) private var locale

  var body: some View {
    if !summary.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        if summary.bombThisRound {
          row(
            text: GuestText.string(
              "UI.GuestSession.SpecialCards.BombThisRound",
              fallback: "Bomb played this round – the won tricks add up to one less."
            ),
            systemImage: "burst.fill",
            tint: .orange
          )
        }
        if summary.cloudThisRound {
          row(
            text: GuestText.string(
              "UI.GuestSession.SpecialCards.CloudThisRound",
              fallback: "Cloud played this round – one bet was changed by 1."
            ),
            systemImage: "cloud.fill",
            tint: .blue
          )
        }
        if let roundNumber = summary.previousRoundNumber {
          if summary.bombPreviousRound {
            row(
              text: GuestText.format(
                "UI.GuestSession.SpecialCards.BombPreviousRound",
                fallback: "Round %lld: the Bomb was played.",
                roundNumber
              ),
              systemImage: "burst",
              tint: .secondary
            )
          }
          if summary.cloudPreviousRound {
            row(
              text: GuestText.format(
                "UI.GuestSession.SpecialCards.CloudPreviousRound",
                fallback: "Round %lld: the Cloud was played.",
                roundNumber
              ),
              systemImage: "cloud",
              tint: .secondary
            )
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
  }

  private func row(text: String, systemImage: String, tint: Color) -> some View {
    Label {
      Text(verbatim: text)
        .font(.footnote.weight(.semibold))
    } icon: {
      Image(systemName: systemImage)
        .foregroundStyle(tint)
    }
  }
}

// MARK: - Leave controls

extension View {
  /// While the session is live: the back button asks first (stay connected and go back, or leave the session for
  /// good), and a Leave button sits in the toolbar. After the session ended the normal back button returns.
  func guestSessionLeaveControls(store: MultiplayerGameStore) -> some View {
    modifier(GuestSessionLeaveControlsModifier(store: store))
  }
}

private struct GuestSessionLeaveControlsModifier: ViewModifier {
  @ObservedObject var store: MultiplayerGameStore

  @Environment(\.dismiss) private var dismiss
  @State private var showingLeaveDialog = false

  func body(content: Content) -> some View {
    let isLive = !store.connectionState.isEnded
    return content
      .navigationBarBackButtonHidden(isLive)
      .toolbar {
        if isLive {
          ToolbarItem(placement: Self.leadingPlacement) {
            Button {
              showingLeaveDialog = true
            } label: {
              HStack(spacing: 4) {
                Image(systemName: "chevron.backward")
                Text("UI.GuestSession.Toolbar.Back")
              }
            }
            .accessibilityHint(Text("UI.GuestSession.Toolbar.Back.AccessibilityHint"))
          }
          ToolbarItem(placement: Self.trailingPlacement) {
            Button(role: .destructive) {
              showingLeaveDialog = true
            } label: {
              Label("UI.GuestSession.Toolbar.Leave", systemImage: "rectangle.portrait.and.arrow.right")
            }
          }
        }
      }
      .confirmationDialog(
        "UI.GuestSession.Leave.Title",
        isPresented: $showingLeaveDialog,
        titleVisibility: .visible
      ) {
        Button("UI.GuestSession.Leave.Confirm", role: .destructive) {
          store.leave()
          dismiss()
        }
        Button("UI.GuestSession.Leave.StayConnected") {
          dismiss()
        }
        Button("UI.Common.Cancel", role: .cancel) {}
      } message: {
        Text("UI.GuestSession.Leave.Message")
      }
  }

  private static var leadingPlacement: ToolbarItemPlacement {
#if os(iOS)
    return .topBarLeading
#else
    return .cancellationAction
#endif
  }

  private static var trailingPlacement: ToolbarItemPlacement {
#if os(iOS)
    return .topBarTrailing
#else
    return .primaryAction
#endif
  }
}
