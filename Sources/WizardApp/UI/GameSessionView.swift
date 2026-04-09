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
  @State private var selectedStartingDealerId: UUID?
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
      get: { storeHolder.store?.currentGame != nil && storeHolder.store?.lastError != nil },
      set: { newValue in if !newValue { storeHolder.store?.lastError = nil } }
    )) {
      Button("OK", role: .cancel) { storeHolder.store?.lastError = nil }
    } message: {
      Text(storeHolder.store?.lastError?.localizedDescription ?? "")
    }
  }

  @ViewBuilder
  private func content(game: Game) -> some View {
    let round = game.currentRound
    let totals = (try? game.totalPoints()) ?? [:]

    VStack(spacing: 16) {
      header(round: round, players: game.players)
        .padding(.horizontal)
        .padding(.top, 8)

      if round == nil {
        startCard(players: game.players)
          .padding(.horizontal)
      }

      scoreboard(game: game, totals: totals)
        .padding(.horizontal)

      Spacer(minLength: 0)

      primaryAction(game: game)
        .padding(.horizontal)
        .padding(.bottom, 12)
    }
    .background {
      // Liquid-glass friendly background.
      LinearGradient(
        colors: [.indigo.opacity(0.25), .cyan.opacity(0.18), .purple.opacity(0.15)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .ignoresSafeArea()
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
            store.lastError = nil
            for (pid, bet) in values {
              store.apply(.submitBet(playerId: pid, roundIndex: game.currentRoundIndex, bet: bet))
            }
            if let err = store.lastError { return err }
            guard let updated = store.currentGame else {
              return NSError(domain: "WizardApp", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing game state after submitting bets."])
            }
            do {
              try updated.rounds[updated.currentRoundIndex].validateConstraints(
                players: updated.players,
                additionalConstraints: updated.additionalConstraints
              )
              return nil
            } catch {
              return error
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
          title: "Enter Got",
          handSize: round.handSize,
          players: game.players,
          currentValues: game.rounds[game.currentRoundIndex].entries.mapValues { $0.got },
          valueLabel: "Got",
          accessory: AnyView(
            Toggle(isOn: $bombPlayedThisRound) {
              VStack(alignment: .leading, spacing: 2) {
                Text(GameConstraint.gotSumEqualsHandSizeMinusOne.title)
                  .font(.subheadline.weight(.semibold))
                Text(GameConstraint.gotSumEqualsHandSizeMinusOne.detail)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          ),
          onSubmit: { values in
            guard let store = storeHolder.store else { return NSError(domain: "WizardApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Store not ready."]) }
            store.lastError = nil
            for (pid, got) in values {
              store.apply(.submitGot(playerId: pid, roundIndex: game.currentRoundIndex, got: got))
            }
            if let err = store.lastError { return err }
            guard let updated = store.currentGame else {
              return NSError(domain: "WizardApp", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing game state after submitting got."])
            }

            // Validate round-specific constraints (e.g. Bomb) before closing the sheet.
            let constraints = constraintsForFinalize(game: updated, bombPlayed: bombPlayedThisRound) ?? updated.additionalConstraints
            do {
              try updated.rounds[updated.currentRoundIndex].validateConstraints(
                players: updated.players,
                additionalConstraints: constraints
              )
            } catch {
              return error
            }

            // Auto-finalize once got values are entered.
            store.apply(.finalizeCurrentRound(roundConstraints: constraints))
            if store.lastError == nil {
              bombPlayedThisRound = false
            }
            return store.lastError
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

  private func constraintsForFinalize(game: Game?, bombPlayed: Bool) -> [GameConstraint]? {
    guard let game else { return nil }
    var constraints = game.additionalConstraints.filter {
      $0 != .gotSumEqualsHandSize && $0 != .gotSumEqualsHandSizeMinusOne
    }
    constraints.append(bombPlayed ? .gotSumEqualsHandSizeMinusOne : .gotSumEqualsHandSize)
    return constraints
  }

  private func startCard(players: [Player]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Game overview")
        .font(.headline)

      Text("Pick a starting dealer, then enter bets for Round 1.")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 8) {
        Text("Starting dealer")
          .font(.caption)
          .foregroundStyle(.secondary)

        Picker("", selection: Binding(
          get: { selectedStartingDealerId ?? players.first?.id ?? UUID() },
          set: { selectedStartingDealerId = $0 }
        )) {
          ForEach(players, id: \.id) { p in
            Text(p.name).tag(p.id)
          }
        }
        .pickerStyle(.menu)
      }
    }
    .padding(14)
    .background {
      LinearGradient(
        colors: [
          Color.white.opacity(0.55),
          Color.white.opacity(0.30),
          Color.white.opacity(0.18),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .background(.ultraThinMaterial)
    }
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private func header(round: Round?, players: [Player]) -> some View {
    HStack(spacing: 12) {
      glassPill(title: "Round", value: round == nil ? "—" : "\(round?.handSize ?? 0)")
      if let dealerId = round?.dealer, let dealer = players.first(where: { $0.id == dealerId }) {
        glassPill(title: "Dealer", value: dealer.name)
      } else {
        glassPill(title: "Dealer", value: "—")
      }
      Spacer()
      Text(round == nil ? "Not started" : (round?.isFinalized == true ? "Finalized" : "In Progress"))
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }
  }

  private func glassPill(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.headline)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private func scoreboard(game: Game, totals: [UUID: Int]) -> some View {
    VStack(spacing: 10) {
      ForEach(game.players, id: \.id) { p in
        let total = totals[p.id, default: 0]
        let currentEntry = game.currentRound.flatMap { $0.entries[p.id] }
        let lastDelta = lastFinalizedDelta(for: p.id, in: game)

        HStack {
          Text(p.name).font(.headline)
          Spacer()
          VStack(alignment: .trailing, spacing: 2) {
            Text("\(total)")
              .font(.title3.weight(.semibold))
            if let lastDelta {
              Text(deltaString(lastDelta))
                .font(.caption)
                .foregroundStyle(lastDelta >= 0 ? .green : .red)
            } else {
              Text("—").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .bottomLeading) {
          if let currentEntry, (currentEntry.bet != nil || currentEntry.got != nil) {
            Text(currentEntryLine(currentEntry))
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 14)
              .padding(.bottom, 10)
          }
        }
      }
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
      label = "Enter Got"
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
      let dealerId = selectedStartingDealerId ?? game.players.first?.id
      if let dealerId {
        storeHolder.store?.apply(.startNewGame(startingDealer: dealerId))
      }
    }
    showingBets = true
  }

  private func currentEntryLine(_ entry: RoundEntry) -> String {
    let bet = entry.bet.map(String.init) ?? "—"
    let got = entry.got.map(String.init) ?? "—"
    return "Bet \(bet) · Got \(got)"
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
      selectedStartingDealerId = storeHolder.store?.currentGame?.players.first?.id
    } else if force || storeHolder.store?.currentGame?.id != gameId {
      storeHolder.store?.loadGame(id: gameId)
      selectedStartingDealerId = storeHolder.store?.currentGame?.players.first?.id
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

