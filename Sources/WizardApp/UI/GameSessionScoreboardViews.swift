import SwiftUI
#if canImport(WizardDomain)
import WizardDomain
#endif

@MainActor
struct GameSessionScoreboardOptions {
  var onPlayerCardTap: ((UUID) -> Void)?
  var onBetChipTap: ((UUID) -> Void)?
  var onWonChipTap: (() -> Void)?

  static let readOnly = GameSessionScoreboardOptions()
}

struct GameSessionHeaderView: View {
  let game: Game

  var body: some View {
    let round = game.currentRound
    let players = game.players
    let roundText = GameSessionScoreboardMetrics.roundProgressText(for: game)
    let betsText = GameSessionScoreboardMetrics.betsProgressText(for: game)
    let dealerName: String = {
      guard let dealerId = round?.dealer,
            let dealer = players.first(where: { $0.id == dealerId }) else {
        return String(localized: "UI.Common.EmptyValue", defaultValue: "—")
      }
      return dealer.name
    }()

    VStack(alignment: .center, spacing: 8) {
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Text("UI.GameSession.Header.Dealer")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(dealerName)
          .font(.headline.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 0)
      }

      HStack(spacing: 10) {
        Spacer(minLength: 0)
        Text("UI.GameSession.Header.Round")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(verbatim: roundText)
          .font(.headline.weight(.semibold).monospacedDigit())

        Text("UI.GameSession.Header.Separator")
          .foregroundStyle(.secondary.opacity(0.7))

        Text("UI.GameSession.Header.Bets")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(verbatim: betsText)
          .font(.headline.weight(.semibold).monospacedDigit())

        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
    }
  }
}

struct GameSessionScoreboardView: View {
  let game: Game
  let totals: [UUID: Int]
  var options: GameSessionScoreboardOptions = .readOnly

  private let sparklineMinWidth: CGFloat = 90

  var body: some View {
    let placeDeltas = GameSessionScoreboardMetrics.placeDeltasComparedToPreviousRound(in: game)
    let histories = GameSessionScoreboardMetrics.scoreHistoryByPlayer(in: game)
    let sortedPlayers = GameSessionScoreboardMetrics.scoreboardPlayerOrder(game: game, totals: totals)

    VStack(spacing: 10) {
      ForEach(Array(sortedPlayers.enumerated()), id: \.element.id) { idx, player in
        playerCard(
          player: player,
          rank: idx + 1,
          isLeader: idx == 0,
          total: totals[player.id, default: 0],
          display: game.scoreboardDisplayValues(for: player.id),
          placeDelta: placeDeltas?[player.id],
          history: histories[player.id, default: [0]],
          pointsDelta: GameSessionScoreboardMetrics.scoreboardPointsDeltaCaption(for: player.id, in: game)
        )
      }
    }
  }

  @ViewBuilder
  private func playerCard(
    player: Player,
    rank: Int,
    isLeader: Bool,
    total: Int,
    display: (bet: Int?, got: Int?),
    placeDelta: Int?,
    history: [Int],
    pointsDelta: Int?
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(String(localized: "UI.GameSession.Score.RankPrefix", defaultValue: "#\(rank)"))
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
          if let placeDelta {
            Text(GameSessionScoreboardMetrics.placeDeltaString(placeDelta))
              .font(.caption2.weight(.semibold).monospacedDigit())
              .foregroundStyle(GameSessionScoreboardMetrics.placeDeltaColor(placeDelta))
          }
        }
        .frame(width: 36, alignment: .leading)

        Text(player.name)
          .font(.headline.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.tail)

        Spacer(minLength: 0)

        if isLeader {
          Image(systemName: "crown.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.yellow.opacity(0.9))
        }
      }
      .accessibilityLabel(player.name)
      .accessibilityHint("UI.GameSession.PlayerHistory.AccessibilityHint")

      HStack(alignment: .bottom, spacing: 10) {
        scoreboardEntryChip(
          titleKey: "UI.GameSession.Entry.Bet",
          value: display.bet,
          onTap: options.onBetChipTap.map { handler in { handler(player.id) } },
          accessibilityHintKey: "UI.GameSession.Score.Chip.EditBets.AccessibilityHint"
        )
        scoreboardEntryChip(
          titleKey: "UI.GameSession.Entry.Won",
          value: display.got,
          onTap: options.onWonChipTap,
          accessibilityHintKey: "UI.GameSession.Score.Chip.EditWonTricks.AccessibilityHint"
        )

        HStack(alignment: .bottom, spacing: 10) {
          GeometryReader { geometry in
            if geometry.size.width >= sparklineMinWidth {
              GameSessionSparklineView(
                values: history,
                color: GameSessionScoreboardMetrics.sparklineColor(for: history)
              )
              .padding(6)
              .frame(height: 30)
              .frame(maxWidth: .infinity, alignment: .center)
            }
          }
          .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)

          VStack(alignment: .trailing, spacing: 2) {
            Text("\(total)")
              .font(.title3.weight(.semibold).monospacedDigit())
            if let pointsDelta {
              Text(pointsDelta >= 0 ? "+\(pointsDelta)" : "\(pointsDelta)")
                .font(.caption)
                .foregroundStyle(pointsDelta >= 0 ? .green : .red)
            } else {
              Text("UI.Common.EmptyValue")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        .accessibilityLabel(player.name)
        .accessibilityHint("UI.GameSession.PlayerHistory.AccessibilityHint")
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
    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .modifier(PlayerCardTapModifier(playerId: player.id, onTap: options.onPlayerCardTap))
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func scoreboardEntryChip(
    titleKey: String,
    value: Int?,
    onTap: (() -> Void)?,
    accessibilityHintKey: String
  ) -> some View {
    if let onTap {
      Button(action: onTap) {
        entryChipChrome(titleKey: titleKey, value: value)
      }
      .buttonStyle(.plain)
      .accessibilityHint(LocalizedStringKey(accessibilityHintKey))
    } else {
      entryChipChrome(titleKey: titleKey, value: value)
    }
  }

  private func entryChipChrome(titleKey: String, value: Int?) -> some View {
    let text = value.map(String.init) ?? String(localized: "UI.Common.EmptyValue", defaultValue: "—")
    let isMissing = value == nil

    return VStack(alignment: .leading, spacing: 2) {
      Text(LocalizedStringKey(titleKey))
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
}

private struct PlayerCardTapModifier: ViewModifier {
  let playerId: UUID
  let onTap: ((UUID) -> Void)?

  func body(content: Content) -> some View {
    if let onTap {
      content.onTapGesture { onTap(playerId) }
    } else {
      content
    }
  }
}

struct GameSessionSparklineView: View {
  let values: [Int]
  let color: Color

  var body: some View {
    GeometryReader { geometry in
      let points = normalizedPoints(in: geometry.size)
      Path { path in
        guard let first = points.first else { return }
        path.move(to: first)
        for point in points.dropFirst() {
          path.addLine(to: point)
        }
      }
      .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }
  }

  private func normalizedPoints(in size: CGSize) -> [CGPoint] {
    let width = max(1, size.width)
    let height = max(1, size.height)
    let minValue = values.min() ?? 0
    let maxValue = values.max() ?? 0
    let span = max(maxValue - minValue, 1)
    let count = max(values.count - 1, 1)

    return values.enumerated().map { index, value in
      let x = CGFloat(index) / CGFloat(count) * width
      let yFactor = CGFloat(value - minValue) / CGFloat(span)
      let y = height - (yFactor * height)
      return CGPoint(x: x, y: y)
    }
  }
}

enum GameSessionScoreboardMetrics {
  static func activeRoundNumber(for game: Game) -> Int {
    guard !game.rounds.isEmpty else { return 0 }
    return min(game.currentRoundIndex + 1, game.totalRoundsPlanned)
  }

  static func roundProgressText(for game: Game) -> String {
    let current = activeRoundNumber(for: game)
    let total = game.totalRoundsPlanned
    guard current > 0, total > 0 else {
      return String(localized: "UI.Common.EmptyValue", defaultValue: "—")
    }
    return "\(current)/\(total)"
  }

  static func betsProgressText(for game: Game, betsSum: Int) -> String {
    let roundNumber = activeRoundNumber(for: game)
    guard roundNumber > 0 else { return "\(0)/\(0)" }
    return "\(betsSum)/\(roundNumber)"
  }

  static func betsProgressText(for game: Game) -> String {
    guard let round = game.currentRound else { return "\(0)/\(0)" }
    let betsSum = round.entries.values.reduce(into: 0) { partialResult, entry in
      partialResult += entry.bet ?? 0
    }
    return betsProgressText(for: game, betsSum: betsSum)
  }

  static func placeDeltaString(_ delta: Int) -> String {
    if delta > 0 { return "▲\(delta)" }
    if delta < 0 { return "▼\(abs(delta))" }
    return "•"
  }

  static func placeDeltaColor(_ delta: Int) -> Color {
    if delta > 0 { return .green }
    if delta < 0 { return .red }
    return .secondary
  }

  static func placeDeltasComparedToPreviousRound(in game: Game) -> [UUID: Int]? {
    let finalizedRounds = game.rounds.filter(\.isFinalized)
    guard finalizedRounds.count >= 2 else { return nil }

    var totalsBeforeMostRecent = Dictionary(uniqueKeysWithValues: game.players.map { ($0.id, 0) })

    for round in finalizedRounds.dropLast() {
      for player in game.players {
        guard let entry = round.entries[player.id],
              let delta = try? entry.pointsDelta() else { continue }
        totalsBeforeMostRecent[player.id, default: 0] += delta
      }
    }

    var totalsAfterMostRecent = totalsBeforeMostRecent
    if let mostRecentRound = finalizedRounds.last {
      for player in game.players {
        guard let entry = mostRecentRound.entries[player.id],
              let delta = try? entry.pointsDelta() else { continue }
        totalsAfterMostRecent[player.id, default: 0] += delta
      }
    }

    let previousRanks = ranks(for: totalsBeforeMostRecent, players: game.players)
    let currentRanks = ranks(for: totalsAfterMostRecent, players: game.players)

    return Dictionary(uniqueKeysWithValues: game.players.map { player in
      let previous = previousRanks[player.id, default: game.players.count]
      let current = currentRanks[player.id, default: game.players.count]
      return (player.id, previous - current)
    })
  }

  static func ranks(for totals: [UUID: Int], players: [Player]) -> [UUID: Int] {
    let sorted = players.sorted { a, b in
      let ta = totals[a.id, default: 0]
      let tb = totals[b.id, default: 0]
      if ta != tb { return ta > tb }
      return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
    var result: [UUID: Int] = [:]
    for (index, player) in sorted.enumerated() {
      result[player.id] = index + 1
    }
    return result
  }

  static func scoreHistoryByPlayer(in game: Game) -> [UUID: [Int]] {
    var histories = Dictionary(uniqueKeysWithValues: game.players.map { ($0.id, [0]) })
    for round in game.rounds where round.isFinalized {
      for player in game.players {
        let previous = histories[player.id]?.last ?? 0
        let delta = round.entries[player.id].flatMap { try? $0.pointsDelta() } ?? 0
        histories[player.id, default: [0]].append(previous + delta)
      }
    }
    return histories
  }

  static func sparklineColor(for values: [Int]) -> Color {
    guard values.count >= 2 else { return .secondary }
    let lastDelta = values[values.count - 1] - values[values.count - 2]
    if lastDelta > 0 { return .green }
    if lastDelta < 0 { return .red }
    return .secondary
  }

  static func lastFinalizedDelta(for playerId: UUID, in game: Game) -> Int? {
    for round in game.rounds.reversed() where round.isFinalized {
      guard let entry = round.entries[playerId] else { continue }
      if let delta = try? entry.pointsDelta() { return delta }
    }
    return nil
  }

  static func scoreboardPlayerOrder(game: Game, totals: [UUID: Int]) -> [Player] {
    game.players.sorted { a, b in
      let ta = totals[a.id, default: 0]
      let tb = totals[b.id, default: 0]
      if ta != tb { return ta > tb }
      return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
  }

  static func scoreboardPointsDeltaCaption(for playerId: UUID, in game: Game) -> Int? {
    lastFinalizedDelta(for: playerId, in: game)
  }
}
