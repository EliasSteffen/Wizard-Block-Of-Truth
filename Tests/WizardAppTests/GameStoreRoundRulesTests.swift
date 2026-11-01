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
}
