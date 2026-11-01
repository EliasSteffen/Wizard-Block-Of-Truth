import SwiftData
import XCTest
@testable import WizardApp
@testable import WizardDomain

@MainActor
final class GameStoreRoundRulesTests: XCTestCase {
  private func makeStore() throws -> GameStore {
    let schema = Schema([GameSnapshotEntity.self])
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(container)
    return GameStore(modelContext: context)
  }

  private func makePlayers(_ count: Int) -> [Player] {
    (0..<count).map { idx in
      Player(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idx + 1))!, name: "P\(idx + 1)")
    }
  }

  func testCreateGamePersistsFirstRoundBetSumRule() throws {
    let store = try makeStore()
    store.createGame(
      name: "First round may add up",
      mode: .singlePhone,
      players: makePlayers(3),
      firstRoundBetSumMayEqualHandSize: true
    )
    let id = try XCTUnwrap(store.currentGame?.id)
    XCTAssertTrue(store.currentGame?.firstRoundBetSumMayEqualHandSize ?? false)

    store.loadGame(id: id)
    XCTAssertTrue(store.currentGame?.firstRoundBetSumMayEqualHandSize ?? false)
  }

  func testCreateGameDefaultsFirstRoundBetSumRuleToOff() throws {
    let store = try makeStore()
    store.createGame(name: "Default", mode: .singlePhone, players: makePlayers(3))
    XCTAssertFalse(store.currentGame?.firstRoundBetSumMayEqualHandSize ?? true)
  }

  func testEditFinalizedRoundIsPersisted() throws {
    let store = try makeStore()
    let players = makePlayers(3)
    store.createGame(name: "Edit", mode: .singlePhone, players: players)
    let id = try XCTUnwrap(store.currentGame?.id)

    store.apply(.startNewGame(startingDealer: players[0].id))
    var setup: [GameCommand] = players.map { .submitBet(playerId: $0.id, roundIndex: 0, bet: 0) }
    setup.append(.submitGot(playerId: players[0].id, roundIndex: 0, got: 1))
    setup.append(.submitGot(playerId: players[1].id, roundIndex: 0, got: 0))
    setup.append(.submitGot(playerId: players[2].id, roundIndex: 0, got: 0))
    setup.append(.finalizeCurrentRound())
    XCTAssertNil(store.applyBatch(setup, validate: nil))

    let corrected: [UUID: RoundEntry] = [
      players[0].id: RoundEntry(bet: 0, got: 0),
      players[1].id: RoundEntry(bet: 0, got: 1),
      players[2].id: RoundEntry(bet: 0, got: 0),
    ]
    XCTAssertNil(store.applyBatch([
      .editFinalizedRound(roundIndex: 0, entries: corrected, bombPlayed: false, cloudCardPlayed: false),
    ], validate: nil))

    store.loadGame(id: id)
    XCTAssertEqual(store.currentGame?.rounds[0].entries, corrected)
    XCTAssertEqual(store.currentGame?.currentRoundIndex, 1)

    // A rejected edit leaves the stored game unchanged and reports the error.
    let error = store.applyBatch([
      .editFinalizedRound(roundIndex: 1, entries: corrected, bombPlayed: false, cloudCardPlayed: false),
    ], validate: nil)
    XCTAssertEqual(error as? DomainError, .roundNotFinalized)
    store.loadGame(id: id)
    XCTAssertEqual(store.currentGame?.rounds[0].entries, corrected)
  }
}
