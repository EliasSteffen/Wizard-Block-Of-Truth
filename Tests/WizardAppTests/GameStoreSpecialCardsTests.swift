import SwiftData
import XCTest
@testable import WizardApp
@testable import WizardDomain

@MainActor
final class GameStoreSpecialCardsTests: XCTestCase {
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

  func testCreateGamePersistsSpecialCardsDisabled() throws {
    let store = try makeStore()
    let players = makePlayers(3)

    store.createGame(
      name: "No specials",
      mode: .singlePhone,
      players: players,
      playWithSpecialCards: false
    )
    let id = try XCTUnwrap(store.currentGame?.id)

    XCTAssertFalse(store.currentGame?.playWithSpecialCards ?? true)

    store.loadGame(id: id)
    XCTAssertFalse(store.currentGame?.playWithSpecialCards ?? true)
  }

  func testCreateGameDefaultsSpecialCardsToEnabled() throws {
    let store = try makeStore()
    let players = makePlayers(3)

    store.createGame(
      name: "Default specials",
      mode: .singlePhone,
      players: players
    )
    let id = try XCTUnwrap(store.currentGame?.id)

    XCTAssertTrue(store.currentGame?.playWithSpecialCards ?? false)

    store.loadGame(id: id)
    XCTAssertTrue(store.currentGame?.playWithSpecialCards ?? false)
  }
}
