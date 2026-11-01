import SwiftUI
#if canImport(WizardDomain)
import WizardDomain
#endif

/// Corrects an already finalized round: every player's bet and won tricks, plus the special cards that were played,
/// so the sum checks match what really happened. Totals are derived from finalized rounds and recompute automatically.
/// Host / single-phone only — guests never get an editor.
struct RoundEditorView: View {
  let game: Game
  let roundIndex: Int
  /// Applies `.editFinalizedRound` (e.g. `store.applyBatch([command])`). A returned error is shown inline and keeps
  /// the editor open; `nil` dismisses it.
  let onSave: (GameCommand) -> Error?

  @AppStorage("app.language") private var appLanguageRaw: String = AppLanguage.system.rawValue
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale

  @State private var bets: [UUID: Int]
  @State private var wonTricks: [UUID: Int]
  @State private var bombPlayed: Bool
  @State private var cloudCardPlayed: Bool
  @State private var saveErrorText: String? = nil

  init(game: Game, roundIndex: Int, onSave: @escaping (GameCommand) -> Error?) {
    self.game = game
    self.roundIndex = roundIndex
    self.onSave = onSave

    let round: Round? = game.rounds.indices.contains(roundIndex) ? game.rounds[roundIndex] : nil
    var initialBets: [UUID: Int] = [:]
    var initialWonTricks: [UUID: Int] = [:]
    for player in game.players {
      initialBets[player.id] = round?.entries[player.id]?.bet ?? 0
      initialWonTricks[player.id] = round?.entries[player.id]?.got ?? 0
    }
    _bets = State(initialValue: initialBets)
    _wonTricks = State(initialValue: initialWonTricks)
    _bombPlayed = State(initialValue: game.playWithSpecialCards && (round?.inferredBombPlayed ?? false))
    _cloudCardPlayed = State(initialValue: game.playWithSpecialCards && (round?.cloudCardResolved ?? false))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          ForEach(orderedPlayers, id: \.id) { player in
            playerRow(player)
          }
        } header: {
          Text(handSizeText)
        }

        if game.playWithSpecialCards {
          Section {
            Toggle(isOn: $bombPlayed) {
              Text(LocalizedStringKey(Constraint.RoundConstraint.gotSumEqualsHandSizeMinusOne.titleKey))
            }
            Toggle(isOn: $cloudCardPlayed) {
              Text("UI.RoundEditor.CloudCardPlayed.Toggle")
            }
          } header: {
            Text("UI.RoundEditor.SpecialCards.Header")
          } footer: {
            Text("UI.RoundEditor.SpecialCards.Footer")
          }
        }

        Section {
          sumRow(labelKey: "UI.RoundEditor.BetSum.Label", total: betSum, target: handSize, isValid: isBetSumValid)
          sumRow(labelKey: "UI.RoundEditor.WonSum.Label", total: wonTricksSum, target: expectedWonTricksSum, isValid: isWonTricksSumValid)
          ForEach(validationMessages, id: \.self) { message in
            Text(message)
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.red)
          }
          if let saveErrorText {
            Text(saveErrorText)
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.red)
          }
        } footer: {
          Text("UI.RoundEditor.Footer")
        }
      }
#if os(iOS)
      .scrollContentBackground(.hidden)
#endif
      .navigationTitle(titleText)
#if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
#endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("UI.Common.Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("UI.RoundEditor.Save") { save() }
            .disabled(!isValid)
        }
      }
    }
    .wizardBackground()
    .onChange(of: bombPlayed) { _, _ in saveErrorText = nil }
    .onChange(of: cloudCardPlayed) { _, _ in saveErrorText = nil }
  }

  // MARK: - Rows

  private func playerRow(_ player: Player) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text(player.name)
          .font(.headline)
          .lineLimit(1)
          .truncationMode(.tail)
        if player.id == round?.dealer {
          Text("UI.GameSession.Header.Dealer")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
        }
      }

      HStack {
        Text("UI.GameSession.Entry.Bet")
          .foregroundStyle(.secondary)
        Spacer()
        ValueStepperControl(value: betBinding(for: player.id), range: valueRange, style: .compact)
      }

      HStack {
        Text("UI.GameSession.Entry.Won")
          .foregroundStyle(.secondary)
        Spacer()
        ValueStepperControl(value: wonTricksBinding(for: player.id), range: valueRange, style: .compact)
      }
    }
    .padding(.vertical, 4)
  }

  private func sumRow(labelKey: String, total: Int, target: Int, isValid: Bool) -> some View {
    HStack {
      Text(LocalizedStringKey(labelKey))
      Spacer()
      Text(verbatim: "\(total)/\(target)")
        .monospacedDigit()
        .foregroundStyle(isValid ? Color.green : Color.red)
    }
    .font(.subheadline.weight(.semibold))
  }

  private func betBinding(for playerId: UUID) -> Binding<Int> {
    Binding(
      get: { bets[playerId, default: 0] },
      set: { newValue in
        saveErrorText = nil
        bets[playerId] = newValue
      }
    )
  }

  private func wonTricksBinding(for playerId: UUID) -> Binding<Int> {
    Binding(
      get: { wonTricks[playerId, default: 0] },
      set: { newValue in
        saveErrorText = nil
        wonTricks[playerId] = newValue
      }
    )
  }

  // MARK: - Round data

  private var round: Round? {
    game.rounds.indices.contains(roundIndex) ? game.rounds[roundIndex] : nil
  }

  private var handSize: Int {
    round?.handSize ?? 0
  }

  private var valueRange: ClosedRange<Int> {
    0...max(0, handSize)
  }

  /// Same seat order as the bet / won-tricks sheets (dealer last).
  private var orderedPlayers: [Player] {
    guard let round else { return game.players }
    return game.playersInBettingOrder(for: round)
  }

  // MARK: - Live validation (mirrors `GameCommand.editFinalizedRound`)

  private var effectiveBombPlayed: Bool {
    game.playWithSpecialCards && bombPlayed
  }

  private var effectiveCloudCardPlayed: Bool {
    game.playWithSpecialCards && cloudCardPlayed
  }

  private var betSum: Int {
    game.players.reduce(0) { $0 + bets[$1.id, default: 0] }
  }

  private var wonTricksSum: Int {
    game.players.reduce(0) { $0 + wonTricks[$1.id, default: 0] }
  }

  private var expectedWonTricksSum: Int {
    effectiveBombPlayed ? max(0, handSize - 1) : handSize
  }

  private var wonTricksConstraint: Constraint.RoundConstraint {
    effectiveBombPlayed ? .gotSumEqualsHandSizeMinusOne : .gotSumEqualsHandSize
  }

  private var isBetSumRuleActive: Bool {
    game.gameConstraints(forRoundAt: roundIndex).contains(.betSumNotEqualHandSize) && !effectiveCloudCardPlayed
  }

  private var isBetSumValid: Bool {
    !isBetSumRuleActive || betSum != handSize
  }

  private var isWonTricksSumValid: Bool {
    wonTricksSum == expectedWonTricksSum
  }

  private var isValid: Bool {
    round?.isFinalized == true && isBetSumValid && isWonTricksSumValid
  }

  private var validationMessages: [String] {
    var messages: [String] = []
    if !isBetSumValid {
      let constraint = Constraint.GameConstraint.betSumNotEqualHandSize
      messages.append(localized(constraint.showOnFailureKey, fallback: constraint.showOnFailure))
    }
    if !isWonTricksSumValid {
      messages.append(localized(wonTricksConstraint.showOnFailureKey, fallback: wonTricksConstraint.showOnFailure))
    }
    return messages
  }

  // MARK: - Save

  private func save() {
    saveErrorText = nil
    let entries = Dictionary(uniqueKeysWithValues: game.players.map { player in
      (player.id, RoundEntry(bet: bets[player.id, default: 0], got: wonTricks[player.id, default: 0]))
    })
    let command = GameCommand.editFinalizedRound(
      roundIndex: roundIndex,
      entries: entries,
      bombPlayed: effectiveBombPlayed,
      cloudCardPlayed: effectiveCloudCardPlayed
    )
    if let error = onSave(command) {
      saveErrorText = message(for: error)
      return
    }
    dismiss()
  }

  private func message(for error: Error) -> String {
    if let domainError = error as? DomainError,
       case .constraintNotSatisfied(let constraint) = domainError {
      switch constraint {
      case .game(let gameConstraint):
        return localized(gameConstraint.showOnFailureKey, fallback: gameConstraint.showOnFailure)
      case .round(let roundConstraint):
        return localized(roundConstraint.showOnFailureKey, fallback: roundConstraint.showOnFailure)
      }
    }
    return AppErrorMessage.presentableMessage(for: error, languageCode: currentLanguageCode)
  }

  // MARK: - Localization

  private var titleText: String {
    String(
      format: AppLocalization.string("UI.RoundEditor.Title", languageCode: currentLanguageCode, fallback: "Edit round %lld"),
      locale: locale,
      Int64(roundIndex + 1)
    )
  }

  private var handSizeText: String {
    String(
      format: AppLocalization.string("UI.RoundEditor.HandSize", languageCode: currentLanguageCode, fallback: "Hand size: %lld"),
      locale: locale,
      Int64(handSize)
    )
  }

  private func localized(_ key: String, fallback: String) -> String {
    AppLocalization.string(key, languageCode: currentLanguageCode, fallback: fallback)
  }

  private var currentLanguageCode: String? {
    let selectedLanguage = AppLanguage(rawValue: appLanguageRaw) ?? .system
    return selectedLanguage == .system ? nil : selectedLanguage.rawValue
  }
}
