import SwiftUI
#if canImport(WizardDomain)
import WizardDomain
#endif

struct PlayerHistorySheetItem: Identifiable, Hashable {
  let id: UUID
}

struct PlayerRoundHistorySheet: View {
  let game: Game
  let playerId: UUID

  @Environment(\.dismiss) private var dismiss

  /// Wide enough for “Round” / “Runde” on one line (header + values share this width).
  private static let roundColumnWidth: CGFloat = 58
  private static let betWonSpacing: CGFloat = 10
  private static let trailingMetricsSpacing: CGFloat = 16
  private static let pointsColumnWidth: CGFloat = 54
  private static let rankColumnWidth: CGFloat = 40
  private static let totalColumnWidth: CGFloat = 52
  /// Same horizontal inset for header row and every data row (avoids `List`/`Section` header misalignment).
  private static let tableHorizontalPadding: CGFloat = 16
  /// Matches `GameSessionView` header / scoreboard cards.
  private static let sessionCardCornerRadius: CGFloat = 18

  private var playerName: String {
    game.players.first { $0.id == playerId }?.name
      ?? String(localized: "UI.Common.EmptyValue", defaultValue: "—")
  }

  var body: some View {
    NavigationStack {
      Group {
        if game.rounds.isEmpty {
          ContentUnavailableView(
            "UI.GameSession.PlayerHistory.Empty.Title",
            systemImage: "list.bullet.rectangle",
            description: Text("UI.GameSession.PlayerHistory.Empty.Description")
          )
        } else {
          VStack(spacing: 16) {
            standingsSummaryBanner
            ScrollView {
              VStack(spacing: 0) {
                columnHeaderRow
                  .padding(.horizontal, Self.tableHorizontalPadding)
                  .padding(.vertical, 10)
                Divider()
                  .padding(.horizontal, Self.tableHorizontalPadding)

                ForEach(Array(game.rounds.enumerated()), id: \.offset) { index, round in
                  roundRow(roundIndex: index, round: round)
                    .padding(.horizontal, Self.tableHorizontalPadding)
                    .padding(.vertical, 12)
                  if index < game.rounds.count - 1 {
                    Divider()
                      .padding(.horizontal, Self.tableHorizontalPadding)
                  }
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .background { sessionScoreboardCardBackground() }
              .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 6)
              .padding(.horizontal, 16)
              .padding(.bottom, 8)
            }
          }
        }
      }
      .navigationTitle(playerName)
#if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
#endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("UI.Common.Done") { dismiss() }
        }
      }
    }
    .wizardBackground()
  }

  private var standingsSummaryBanner: some View {
    let totals = (try? game.totalPoints()) ?? [:]
    let total = totals[playerId, default: 0]
    let rank = rank(for: playerId, totals: totals)

    return HStack(alignment: .firstTextBaseline, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("UI.GameSession.PlayerHistory.Banner.RankCaption")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(rankDisplay(rank))
          .font(.title2.weight(.bold).monospacedDigit())
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .trailing, spacing: 4) {
        Text("UI.GameSession.PlayerHistory.Banner.TotalCaption")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text("\(total)")
          .font(.title2.weight(.bold).monospacedDigit())
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.sessionCardCornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Self.sessionCardCornerRadius, style: .continuous)
        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
    }
    .padding(.horizontal, 16)
    .accessibilityElement(children: .combine)
  }

  private var columnHeaderRow: some View {
    HStack(spacing: Self.betWonSpacing) {
      Text("UI.GameSession.PlayerHistory.Column.Round")
        .frame(width: Self.roundColumnWidth, alignment: .leading)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      Text("UI.GameSession.Entry.Bet")
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
      Text("UI.GameSession.Entry.Won")
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(1)
        .minimumScaleFactor(0.75)

      HStack(spacing: Self.trailingMetricsSpacing) {
        Text("UI.GameSession.PlayerHistory.Column.Points")
          .frame(width: Self.pointsColumnWidth, alignment: .leading)
          .lineLimit(1)
        Text("UI.GameSession.PlayerHistory.Column.Rank")
          .frame(width: Self.rankColumnWidth, alignment: .leading)
          .lineLimit(1)
        Text("UI.GameSession.PlayerHistory.Column.CumulativeTotal")
          .frame(width: Self.totalColumnWidth, alignment: .leading)
          .lineLimit(1)
      }
    }
    .font(.caption2.weight(.semibold))
    .foregroundStyle(.secondary)
  }

  private func roundRow(roundIndex: Int, round: Round) -> some View {
    let entry = round.entries[playerId]
    let betText = entry?.bet.map(String.init)
      ?? String(localized: "UI.Common.EmptyValue", defaultValue: "—")
    let gotText = entry?.got.map(String.init)
      ?? String(localized: "UI.Common.EmptyValue", defaultValue: "—")
    let delta = entry.flatMap { try? $0.pointsDelta() }
    let cumulative = cumulativeTotalsThroughRound(inclusiveRoundIndex: roundIndex)
    let runningTotal = cumulative[playerId, default: 0]
    let runningRank = rank(for: playerId, totals: cumulative)

    return HStack(spacing: Self.betWonSpacing) {
      Text("\(roundIndex + 1)")
        .font(.body.weight(.medium).monospacedDigit())
        .frame(width: Self.roundColumnWidth, alignment: .leading)

      Text(betText)
        .font(.body.weight(.semibold).monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)

      Text(gotText)
        .font(.body.weight(.semibold).monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: Self.trailingMetricsSpacing) {
        Group {
          if let delta {
            Text(delta >= 0 ? "+\(delta)" : "\(delta)")
              .font(.body.weight(.semibold).monospacedDigit())
              .foregroundStyle(deltaColor(delta))
          } else {
            Text("UI.Common.EmptyValue")
              .font(.body.weight(.medium).monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
        .frame(width: Self.pointsColumnWidth, alignment: .leading)

        Text(rankDisplay(runningRank))
          .font(.body.weight(.semibold).monospacedDigit())
          .frame(width: Self.rankColumnWidth, alignment: .leading)

        Text("\(runningTotal)")
          .font(.body.weight(.semibold).monospacedDigit())
          .frame(width: Self.totalColumnWidth, alignment: .leading)
      }
    }
    .accessibilityElement(children: .combine)
  }

  /// Totals after applying every finalized round whose index is `<= inclusiveRoundIndex`.
  private func cumulativeTotalsThroughRound(inclusiveRoundIndex: Int) -> [UUID: Int] {
    var totals = Dictionary(uniqueKeysWithValues: game.players.map { ($0.id, 0) })
    let last = min(inclusiveRoundIndex, game.rounds.count - 1)
    guard last >= 0 else { return totals }
    for j in 0...last {
      let round = game.rounds[j]
      guard round.isFinalized else { continue }
      for player in game.players {
        guard let entry = round.entries[player.id],
              let delta = try? entry.pointsDelta() else { continue }
        totals[player.id, default: 0] += delta
      }
    }
    return totals
  }

  /// Rank `1...n` by total points (desc), then name (asc), matching `GameSessionView` ordering.
  private func rank(for playerId: UUID, totals: [UUID: Int]) -> Int {
    let sorted = game.players.sorted { a, b in
      let ta = totals[a.id, default: 0]
      let tb = totals[b.id, default: 0]
      if ta != tb { return ta > tb }
      return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
    return (sorted.firstIndex { $0.id == playerId }).map { $0 + 1 } ?? game.players.count
  }

  private func rankDisplay(_ rank: Int) -> String {
    String(
      format: String(localized: String.LocalizationValue("UI.GameSession.Score.RankPrefix")),
      locale: .current,
      rank
    )
  }

  private func deltaColor(_ delta: Int) -> Color {
    if delta > 0 { return .green }
    if delta < 0 { return .red }
    return .secondary
  }

  /// Same stack as scoreboard player cards in `GameSessionView`, with a slightly darker base under the material.
  @ViewBuilder
  private func sessionScoreboardCardBackground() -> some View {
    let shape = RoundedRectangle(cornerRadius: Self.sessionCardCornerRadius, style: .continuous)
    ZStack {
      shape.fill(Color.black.opacity(0.22))
      shape.fill(.ultraThinMaterial)
      shape.fill(
        LinearGradient(
          colors: [
            Color.white.opacity(0.20),
            Color.white.opacity(0.06),
            Color.white.opacity(0.02),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
    }
    .clipShape(shape)
    .overlay {
      shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
    }
  }
}
