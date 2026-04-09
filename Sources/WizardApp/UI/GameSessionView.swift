import SwiftUI
import SwiftData
#if canImport(Combine)
import Combine
#endif
#if canImport(WizardDomain)
import WizardDomain
#endif

struct GameSessionView: View {
  let gameId: UUID

  @Environment(\.modelContext) private var modelContext
  @StateObject private var storeHolder = StoreHolder()

  @State private var showingBets = false
  @State private var showingGot = false
  @State private var bombPlayedThisRound: Bool = false

  @State private var betsDetent: PresentationDetent = .medium
  @State private var gotDetent: PresentationDetent = Self.defaultGotDetent

  private static var defaultGotDetent: PresentationDetent {
#if os(iOS)
    return .fraction(0.75)
#else
    return .medium
#endif
  }

  var body: some View {
    Group {
      if let game = storeHolder.store?.currentGame {
        content(game: game)
      } else if storeHolder.store?.didAttemptLoad == true {
        ContentUnavailableView(
          "Couldn’t open game",
          systemImage: "exclamationmark.triangle",
          description: Text(storeHolder.store?.lastError?.localizedDescription ?? "Unknown error.")
        )
        .overlay(alignment: .bottom) {
          Button("Retry") { loadIfNeeded(force: true) }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 16)
        }
      } else {
        ProgressView()
          .task { loadIfNeeded() }
      }
    }
    .navigationTitle(storeHolder.store?.currentGame?.name ?? "Game")
#if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
#endif
    .onAppear { loadIfNeeded() }
    .alert("Error", isPresented: Binding(
      get: { shouldPresentGlobalErrorAlert },
      set: { newValue in if !newValue { storeHolder.store?.lastError = nil } }
    )) {
      Button("OK", role: .cancel) { storeHolder.store?.lastError = nil }
    } message: {
      Text(storeHolder.store?.lastError?.localizedDescription ?? "")
    }
    .wizardBackground()
  }

  private var shouldPresentGlobalErrorAlert: Bool {
    // Avoid presenting an alert on top of (or during dismissal of) a sheet.
    if showingBets || showingGot { return false }
    guard storeHolder.store?.currentGame != nil else { return false }
    guard let err = storeHolder.store?.lastError else { return false }

#if canImport(WizardDomain)
    // Constraint failures are shown inline in `EntrySheetView`; don't also show a global alert.
    if let domainErr = err as? DomainError, case .constraintNotSatisfied = domainErr {
      return false
    }
#endif
    return true
  }

  @ViewBuilder
  private func content(game: Game) -> some View {
    let round = game.currentRound
    let totals = (try? game.totalPoints()) ?? [:]

    ScrollView {
      VStack(spacing: 16) {
        header(round: round, players: game.players)
          .padding(.horizontal)
          .padding(.top, 8)

        scoreboard(game: game, totals: totals)
          .padding(.horizontal)
          .padding(.bottom, 8)
      }
    }
    // Mirror `GameListView`: the bottom control overlays the content, so the list is "under" it.
    .safeAreaInset(edge: .bottom) {
      primaryAction(game: game)
        .padding(.horizontal)
        .padding(.bottom, 12)
        .padding(.top, 8)
        .background(Color.clear)
    }
    .sheet(isPresented: $showingBets) {
      if let round = game.currentRound {
        EntrySheetView(
          title: "Enter Bets",
          handSize: round.handSize,
          players: game.players,
          currentValues: game.rounds[game.currentRoundIndex].entries.mapValues { $0.bet },
          valueLabel: "Bet",
          accessory: nil,
          onSubmit: { values in
            guard let store = storeHolder.store else { return NSError(domain: "WizardApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Store not ready."]) }
            let cmds: [GameCommand] = values.map { (pid, bet) in
              .submitBet(playerId: pid, roundIndex: game.currentRoundIndex, bet: bet)
            }
            return store.applyBatch(cmds) { updated in
              try updated.rounds[updated.currentRoundIndex].validateConstraints(
                players: updated.players,
                gameConstraints: updated.gameConstraints,
                roundConstraints: [.gotSumEqualsHandSize]
              )
            }
          }
        )
#if os(iOS)
        // Slightly taller than the standard `.medium`.
        .presentationDetents([.fraction(0.75)], selection: $gotDetent)
#else
        .presentationDetents([.medium], selection: $gotDetent)
#endif
      }
    }
    .sheet(isPresented: $showingGot) {
      if let round = game.currentRound {
        EntrySheetView(
          title: "Enter Won Tricks",
          handSize: round.handSize,
          players: game.players,
          currentValues: game.rounds[game.currentRoundIndex].entries.mapValues { $0.got },
          valueLabel: "Won",
          accessory: AnyView(
            Toggle(isOn: $bombPlayedThisRound) {
              VStack(alignment: .leading, spacing: 2) {
                Text(Constraint.RoundConstraint.gotSumEqualsHandSizeMinusOne.title)
                  .font(.subheadline.weight(.semibold))
              }
            }
          ),
          onSubmit: { values in
            guard let store = storeHolder.store else { return NSError(domain: "WizardApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Store not ready."]) }
            let constraints = constraintsForFinalize(game: game, bombPlayed: bombPlayedThisRound) ?? [.gotSumEqualsHandSize]
            var cmds: [GameCommand] = values.map { (pid, got) in
              .submitGot(playerId: pid, roundIndex: game.currentRoundIndex, got: got)
            }
            cmds.append(.finalizeCurrentRound(roundConstraints: constraints))

            let err = store.applyBatch(cmds)
            if err == nil {
              bombPlayedThisRound = false
            }
            return err
          }
        )
#if os(iOS)
        // Slightly taller than the standard `.medium`.
        .presentationDetents([.fraction(0.75)], selection: $gotDetent)
#else
        .presentationDetents([.medium], selection: $gotDetent)
#endif
      }
    }
  }

  private func constraintsForFinalize(game: Game?, bombPlayed: Bool) -> [Constraint.RoundConstraint]? {
    guard game != nil else { return nil }
    return [bombPlayed ? .gotSumEqualsHandSizeMinusOne : .gotSumEqualsHandSize]
  }

  private func header(round: Round?, players: [Player]) -> some View {
    let roundText = round == nil ? "—" : "\(round?.handSize ?? 0)"
    let dealerName: String = {
      guard let dealerId = round?.dealer,
            let dealer = players.first(where: { $0.id == dealerId }) else { return "—" }
      return dealer.name
    }()

    return HStack(alignment: .center, spacing: 10) {
      Text("Round")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .baselineOffset(0)
      Text(roundText)
        .font(.headline.weight(.semibold).monospacedDigit())

      Text("·")
        .foregroundStyle(.secondary.opacity(0.7))

      Text("Dealer")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .baselineOffset(0)
      Text(dealerName)
        .font(.headline.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.tail)

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
    }
  }

  private func scoreboard(game: Game, totals: [UUID: Int]) -> some View {
    let sortedPlayers = game.players.sorted { a, b in
      let ta = totals[a.id, default: 0]
      let tb = totals[b.id, default: 0]
      if ta != tb { return ta > tb }
      return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    return VStack(spacing: 10) {
      ForEach(Array(sortedPlayers.enumerated()), id: \.element.id) { idx, p in
        let total = totals[p.id, default: 0]
        let currentEntry = game.currentRound.flatMap { $0.entries[p.id] }
        let lastDelta = lastFinalizedDelta(for: p.id, in: game)

        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 10) {
            Text("#\(idx + 1)")
              .font(.caption.weight(.semibold).monospacedDigit())
              .foregroundStyle(.secondary)
              .frame(width: 28, alignment: .leading)

            Text(p.name)
              .font(.headline.weight(.semibold))
              .lineLimit(1)
              .truncationMode(.tail)

            Spacer(minLength: 0)

            if idx == 0 {
              Image(systemName: "crown.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.yellow.opacity(0.9))
            }
          }

          HStack(alignment: .bottom, spacing: 10) {
            entryChip(title: "Bet", value: currentEntry?.bet)
            entryChip(title: "Won", value: currentEntry?.got)

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 2) {
              Text("\(total)")
                .font(.title3.weight(.semibold).monospacedDigit())
              if let lastDelta {
                Text(deltaString(lastDelta))
                  .font(.caption)
                  .foregroundStyle(lastDelta >= 0 ? .green : .red)
              } else {
                Text("—").font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
        .padding(14)
        .background {
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
              LinearGradient(
                colors: [
                  Color.white.opacity(0.20),
                  Color.white.opacity(0.06),
                  Color.white.opacity(0.02),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
              .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .overlay {
              RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            }
        }
        .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 6)
      }
    }
  }

  private func entryChip(title: String, value: Int?) -> some View {
    let text = value.map(String.init) ?? "—"
    let isMissing = value == nil

    return VStack(alignment: .leading, spacing: 2) {
      Text(title.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(text)
        .font(.headline.weight(.semibold).monospacedDigit())
        .foregroundStyle(isMissing ? .secondary : .primary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(width: 72, alignment: .leading)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
    }
  }

  private func primaryAction(game: Game) -> some View {
    let round = game.currentRound
    let entries = round?.entries ?? [:]

    let allBetsPresent = entries.values.allSatisfy { $0.bet != nil }
    let allGotPresent = entries.values.allSatisfy { $0.got != nil }

    let label: String
    let action: () -> Void
    let enabled: Bool

    if round == nil {
      label = "Enter Bets"
      action = { startAndShowBetsIfNeeded(game: game) }
      enabled = true
    } else if !allBetsPresent {
      label = "Enter Bets"
      action = { showingBets = true }
      enabled = true
    } else if !allGotPresent {
      label = "Enter Won Tricks"
      action = { showingGot = true }
      enabled = true
    } else {
      label = "Finalize Round"
      action = {
        guard let store = storeHolder.store else { return }
        let constraints = constraintsForFinalize(game: store.currentGame, bombPlayed: bombPlayedThisRound)
        store.apply(.finalizeCurrentRound(roundConstraints: constraints))
        if store.lastError == nil {
          bombPlayedThisRound = false
        }
      }
      enabled = true
    }

    return Button(action: action) {
      Text(label)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .font(.headline)
    }
    .buttonStyle(.borderedProminent)
    .disabled(!enabled)
  }

  private func startAndShowBetsIfNeeded(game: Game) {
    if game.currentRound == nil {
      let dealerId = game.players.first?.id
      if let dealerId { storeHolder.store?.apply(.startNewGame(startingDealer: dealerId)) }
    }
    showingBets = true
  }

  private func deltaString(_ delta: Int) -> String {
    delta >= 0 ? "+\(delta)" : "\(delta)"
  }

  private func lastFinalizedDelta(for playerId: UUID, in game: Game) -> Int? {
    for round in game.rounds.reversed() where round.isFinalized {
      guard let entry = round.entries[playerId] else { continue }
      if let d = try? entry.pointsDelta() { return d }
    }
    return nil
  }

  private func loadIfNeeded(force: Bool = false) {
    if storeHolder.store == nil {
      storeHolder.store = GameStore(modelContext: modelContext)
      storeHolder.store?.loadGame(id: gameId)
    } else if force || storeHolder.store?.currentGame?.id != gameId {
      storeHolder.store?.loadGame(id: gameId)
    }
  }
}

@MainActor
private final class StoreHolder: ObservableObject {
  @Published var store: GameStore? {
    didSet { bindStoreChanges() }
  }

  private var cancellable: AnyCancellable?

  private func bindStoreChanges() {
    cancellable = nil
    guard let store else { return }
    cancellable = store.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
  }
}

