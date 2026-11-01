import SwiftUI
#if canImport(WizardDomain)
import WizardDomain
#endif
#if canImport(WizardNet)
import WizardNet
#endif

/// Guest's game screen: read-only scoreboard, own bet / won tricks entry (with corrections while allowed), connection
/// banner, Bomb/Cloud indicator, leave controls, and the final scoreboard when the game is over.
struct GuestGameSessionView: View {
  @ObservedObject var store: MultiplayerGameStore

  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale

  @State private var draftValue: Int = 0
  /// The kind the guest is correcting (review → edit). A first entry needs no explicit edit mode.
  @State private var editingKind: GuestEntryKind?
  /// Error thrown while sending (e.g. not connected). The host's answer arrives in `store.lastCommandOutcome`.
  @State private var submitError: String?

  private var guestPlayerID: UUID? {
    if case .guest(let playerId) = store.role { return playerId }
    return nil
  }

  private var isLive: Bool {
    !store.connectionState.isEnded
  }

  private var isConnected: Bool {
    store.connectionState == .connected
  }

  private var isPending: Bool {
    store.pendingCommand != nil
  }

  private var entryContext: GuestEntryContext? {
    guard let game = store.currentGame, let guestPlayerID else { return nil }
    return GuestEntryPhaseResolver.context(game: game, guestPlayerID: guestPlayerID)
  }

  private var feedbackMessage: String? {
    submitError ?? GuestCommandFeedback.message(for: store.lastCommandOutcome)
  }

  var body: some View {
    Group {
      if let game = store.currentGame, let guestPlayerID {
        content(game: game, guestPlayerID: guestPlayerID)
      } else {
        ProgressView()
      }
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
    .reviewPromptOnGameFinish(
      gameId: store.currentGame?.id,
      isFinished: store.currentGame.map { GuestEntryPhaseResolver.isGameFinished($0) }
    )
    .onChange(of: entryContext?.draftSeedKey) { _, _ in
      entryContextDidChange()
    }
    .onChange(of: store.lastCommandOutcome) { _, outcome in
      if outcome == .accepted {
        editingKind = nil
      }
    }
    .onAppear {
      entryContextDidChange()
    }
  }

  // MARK: - Layout

  @ViewBuilder
  private func content(game: Game, guestPlayerID: UUID) -> some View {
    let isFinished = GuestEntryPhaseResolver.isGameFinished(game) || store.connectionState == .ended(.gameFinished)
    let totals = (try? game.totalPoints()) ?? [:]

    ScrollView {
      VStack(spacing: 16) {
        if isFinished {
          finishedHeader
        }
        GameSessionScoreboardView(game: game, totals: totals, options: .readOnly)
      }
      .padding(.horizontal)
      .padding(.top, 8)
      .padding(.bottom, 16)
    }
    .safeAreaInset(edge: .top) {
      VStack(spacing: 8) {
        GuestConnectionBannerView(store: store, onClose: { dismiss() })
        GameSessionHeaderView(game: game)
        GuestSpecialCardsIndicator(summary: GuestSpecialCardsSummary.make(game: game))
      }
      .padding(.horizontal)
      .padding(.top, 8)
    }
    .safeAreaInset(edge: .bottom, spacing: 10) {
      if isLive, !isFinished, let context = GuestEntryPhaseResolver.context(game: game, guestPlayerID: guestPlayerID) {
        entryPanel(context: context, guestPlayerID: guestPlayerID)
          .padding(.bottom, 8)
      }
    }
  }

  private var finishedHeader: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("UI.GameSession.FinalScoreboard.Title")
        .font(.title3.weight(.bold))
      if store.connectionState == .ended(.gameFinished) {
        Label {
          Text("UI.GuestSession.Finished.SavedCopy")
        } icon: {
          Image(systemName: "tray.and.arrow.down.fill")
            .foregroundStyle(.green)
        }
        .font(.footnote)
        Button {
          dismiss()
        } label: {
          Text("UI.GuestSession.Finished.Done")
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func entryPanel(context: GuestEntryContext, guestPlayerID: UUID) -> some View {
    switch context.phase {
    case .enter(let kind):
      entryEditor(kind: kind, context: context, guestPlayerID: guestPlayerID, isCorrection: false)
    case .review(let kind, let value):
      if editingKind == kind {
        entryEditor(kind: kind, context: context, guestPlayerID: guestPlayerID, isCorrection: true)
      } else {
        reviewBar(kind: kind, value: value)
      }
    case .waiting:
      GuestEntryBottomGlassPanel {
        Text("UI.GuestSession.Waiting")
          .font(.subheadline.weight(.semibold))
          .multilineTextAlignment(.center)
      }
      .padding(.horizontal, 12)
    case .gameFinished:
      EmptyView()
    }
  }

  /// Stepper + Submit for a first entry or a correction.
  private func entryEditor(
    kind: GuestEntryKind,
    context: GuestEntryContext,
    guestPlayerID: UUID,
    isCorrection: Bool
  ) -> some View {
    let forbiddenBet: Int? = kind == .bet ? context.forbiddenBet : nil
    let isForbidden = forbiddenBet == draftValue
    let isUnchanged = isCorrection && context.ownValue(of: kind) == draftValue
    let canSubmit = isConnected && !isPending && !isForbidden && !isUnchanged
    let submitTitle: LocalizedStringKey = isPending ? "UI.GuestSession.Submit.Sending" : "UI.GuestSession.Submit"

    return VStack(spacing: 10) {
      GuestEntryBottomGlassPanel {
        VStack(spacing: 12) {
          Text(entryTitle(kind: kind, isCorrection: isCorrection))
            .font(.title2.weight(.bold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)

          ValueStepperControl(
            value: $draftValue,
            range: context.valueRange,
            isDisabled: isPending,
            style: .prominent
          )

          if let forbiddenBet {
            Text(
              verbatim: GuestText.format(
                "UI.GuestSession.Hint.ForbiddenBet",
                fallback: "%1$lld is not allowed – the bets may not add up to %2$lld.",
                forbiddenBet,
                context.handSize
              )
            )
            .font(.footnote.weight(isForbidden ? .semibold : .regular))
            .foregroundStyle(isForbidden ? Color.orange : Color.secondary)
            .multilineTextAlignment(.center)
          }
        }
      }
      .padding(.horizontal, 12)

      if let feedbackMessage {
        Text(verbatim: feedbackMessage)
          .font(.footnote)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
      }

      HStack(spacing: 12) {
        if isCorrection {
          Button {
            cancelEditing()
          } label: {
            Text("UI.Common.Cancel")
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .font(.headline)
          }
          .buttonStyle(.bordered)
          .disabled(isPending)
        }

        Button {
          submit(kind: kind, context: context, guestPlayerID: guestPlayerID)
        } label: {
          HStack(spacing: 8) {
            if isPending {
              ProgressView()
            }
            Text(submitTitle)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
          .font(.headline)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit)
      }
      .padding(.horizontal, 12)
    }
  }

  /// Own value already entered and still changeable: show it with "Edit".
  private func reviewBar(kind: GuestEntryKind, value: Int) -> some View {
    let caption: LocalizedStringKey = kind == .bet ? "UI.GuestSession.Review.YourBet" : "UI.GuestSession.Review.YourWonTricks"
    let hint: LocalizedStringKey = kind == .bet ? "UI.GuestSession.Review.BetHint" : "UI.GuestSession.Review.WonTricksHint"

    return VStack(spacing: 10) {
      GuestEntryBottomGlassPanel {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
              Text(caption)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
              Text(verbatim: "\(value)")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
            }
            Spacer(minLength: 8)
            Button {
              startEditing(kind: kind)
            } label: {
              Label("UI.GuestSession.Edit", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .disabled(!isConnected || isPending)
          }
          Text(hint)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 12)

      if let feedbackMessage {
        Text(verbatim: feedbackMessage)
          .font(.footnote)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
      }
    }
  }

  private func entryTitle(kind: GuestEntryKind, isCorrection: Bool) -> LocalizedStringKey {
    switch (kind, isCorrection) {
    case (.bet, false):
      return "UI.GuestSession.EnterBet"
    case (.bet, true):
      return "UI.GuestSession.ChangeBet"
    case (.got, false):
      return "UI.GuestSession.EnterWonTricks"
    case (.got, true):
      return "UI.GuestSession.ChangeWonTricks"
    }
  }

  // MARK: - Actions

  /// New round, other kind or own value changed (L8): leave a correction, reseed the stepper and drop stale
  /// feedback. Other players' entries keep a draft in progress.
  private func entryContextDidChange() {
    editingKind = nil
    submitError = nil
    if store.pendingCommand == nil, store.lastCommandOutcome != nil {
      store.clearLastRejection()
    }
    reseedDraft()
  }

  private func reseedDraft() {
    guard let context = entryContext, let kind = context.phase.editableKind else { return }
    draftValue = GuestEntryPhaseResolver.initialDraft(
      kind: kind,
      ownBet: context.ownBet,
      ownGot: context.ownGot,
      handSize: context.handSize
    )
  }

  private func startEditing(kind: GuestEntryKind) {
    submitError = nil
    store.clearLastRejection()
    editingKind = kind
    reseedDraft()
  }

  private func cancelEditing() {
    submitError = nil
    store.clearLastRejection()
    editingKind = nil
    reseedDraft()
  }

  private func submit(kind: GuestEntryKind, context: GuestEntryContext, guestPlayerID: UUID) {
    submitError = nil
    let command: GameCommand
    switch kind {
    case .bet:
      command = .submitBet(playerId: guestPlayerID, roundIndex: context.roundIndex, bet: draftValue)
    case .got:
      command = .submitGot(playerId: guestPlayerID, roundIndex: context.roundIndex, got: draftValue)
    }
    if let error = store.applyBatch([command], validate: nil) {
      submitError = AppErrorMessage.presentableMessage(
        for: error,
        languageCode: AppLanguage.catalogLookupLanguageCode
      )
    }
  }
}

// MARK: - Entry bottom glass chrome

private struct GuestEntryBottomGlassPanel<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    content()
      .padding(.horizontal, 16)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity)
      .background {
        GuestEntryBottomGlassBackground()
      }
  }
}

private struct GuestEntryBottomGlassBackground: View {
  private let cornerRadius: CGFloat = 22

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    ZStack {
      shape.fill(Color.black.opacity(0.05))
      shape.fill(.ultraThinMaterial)
      shape.fill(
        LinearGradient(
          colors: [
            Color.white.opacity(0.10),
            Color.white.opacity(0.02),
            Color.clear,
          ],
          startPoint: .top,
          endPoint: .bottom
        )
      )
    }
    .overlay {
      shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
    }
    .shadow(color: Color.black.opacity(0.14), radius: 20, x: 0, y: 10)
    .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 3)
  }
}
