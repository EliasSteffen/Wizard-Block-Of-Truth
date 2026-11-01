import Foundation
import XCTest
@testable import WizardApp
@testable import WizardDomain
@testable import WizardNet

/// Pure decisions behind the multi-phone host screens (bulk sheets, waiting state, finalize message, lobby seats).
final class MultiPhoneHostRulesTests: XCTestCase {
  private let players: [Player] = ["Hanna", "Anna", "Ben", "Cid"].enumerated().map { index, name in
    Player(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, name: name)
  }

  private var hanna: Player { players[0] }
  private var anna: Player { players[1] }
  private var ben: Player { players[2] }
  private var cid: Player { players[3] }

  /// Hanna (host) and Cid have no phone; Anna and Ben are bound to guest phones.
  private var guestSeats: Set<UUID> { [anna.id, ben.id] }

  private func round(handSize: Int = 3, bets: [Int?], gots: [Int?] = [nil, nil, nil, nil], bomb: Bool = false) -> Round {
    var entries: [UUID: RoundEntry] = [:]
    for (index, player) in players.enumerated() {
      entries[player.id] = RoundEntry(bet: bets[index], got: gots[index])
    }
    return Round(handSize: handSize, dealer: hanna.id, entries: entries, bombPlayed: bomb)
  }

  private func slot(
    _ player: Player,
    isHost: Bool = false,
    bound: Bool = false,
    connected: Bool = false,
    placeholder: Bool = false
  ) -> LobbyPlayerSlot {
    LobbyPlayerSlot(
      playerId: player.id,
      name: player.name,
      isHost: isHost,
      isBoundToDevice: bound,
      isConnected: connected,
      isPlaceholderName: placeholder
    )
  }

  // MARK: - Bulk sheets and waiting state (H9)

  func testBulkEntryRowsSkipDeviceBoundSeatsAndKeepTheOrder() {
    let ordered = [ben, cid, hanna, anna]
    XCTAssertEqual(
      MultiPhoneHostRules.bulkEntryPlayers(ordered, boundPlayerIDs: guestSeats).map(\.id),
      [cid.id, hanna.id]
    )
    XCTAssertEqual(MultiPhoneHostRules.bulkEntryPlayers(ordered, boundPlayerIDs: []).map(\.id), ordered.map(\.id))
  }

  func testEnterBetsWhileASeatWithoutPhoneIsMissingABet() {
    let open = round(bets: [nil, 1, nil, 0])
    XCTAssertEqual(
      MultiPhoneHostRules.entryStep(for: open, orderedPlayers: players, boundPlayerIDs: guestSeats),
      .enter(.bets)
    )
  }

  func testWaitForGuestsWhenOnlyTheirBetsAreMissing() {
    let open = round(bets: [1, nil, nil, 0])
    XCTAssertEqual(
      MultiPhoneHostRules.entryStep(for: open, orderedPlayers: players, boundPlayerIDs: guestSeats),
      .waiting(.bets, players: [anna, ben])
    )
  }

  func testWonTricksFollowTheSameRulesThenFinalize() {
    let bets: [Int?] = [1, 0, 1, 0]
    XCTAssertEqual(
      MultiPhoneHostRules.entryStep(for: round(bets: bets), orderedPlayers: players, boundPlayerIDs: guestSeats),
      .enter(.wonTricks)
    )
    XCTAssertEqual(
      MultiPhoneHostRules.entryStep(
        for: round(bets: bets, gots: [1, nil, 2, 0]),
        orderedPlayers: players,
        boundPlayerIDs: guestSeats
      ),
      .waiting(.wonTricks, players: [anna])
    )
    XCTAssertEqual(
      MultiPhoneHostRules.entryStep(
        for: round(bets: bets, gots: [1, 0, 2, 0]),
        orderedPlayers: players,
        boundPlayerIDs: guestSeats
      ),
      .finalize
    )
  }

  func testWithoutGuestPhonesTheHostAlwaysEntersValues() {
    XCTAssertEqual(
      MultiPhoneHostRules.entryStep(for: round(bets: [1, nil, nil, 0]), orderedPlayers: players, boundPlayerIDs: []),
      .enter(.bets)
    )
  }

  func testEnteredSumAndCompletenessOnlyLookAtTheGivenSeats() {
    let open = round(bets: [2, 1, nil, 0])
    XCTAssertEqual(MultiPhoneHostRules.enteredSum(.bets, in: open, playerIDs: guestSeats), 1)
    XCTAssertFalse(MultiPhoneHostRules.allEntered(.bets, in: open, playerIDs: guestSeats))
    XCTAssertTrue(MultiPhoneHostRules.allEntered(.bets, in: open, playerIDs: [hanna.id, anna.id]))
    XCTAssertTrue(MultiPhoneHostRules.allEntered(.wonTricks, in: open, playerIDs: []))
  }

  func testWaitingTitleNamesThePlayers() {
    XCTAssertEqual(MultiPhoneHostRules.waitingTitle(for: [anna], languageCode: nil), "Waiting for Anna")
    XCTAssertEqual(MultiPhoneHostRules.waitingTitle(for: [anna, ben], languageCode: nil), "Waiting for 2 players: Anna, Ben")
    XCTAssertFalse(MultiPhoneHostRules.waitingHint(for: .bets, languageCode: nil).isEmpty)
    XCTAssertNotEqual(
      MultiPhoneHostRules.waitingHint(for: .bets, languageCode: nil),
      MultiPhoneHostRules.waitingHint(for: .wonTricks, languageCode: nil)
    )
  }

  // MARK: - Finalize (H10)

  func testFinalizeConstraintsFollowTheDeclaredBomb() {
    let bets: [Int?] = [1, 0, 1, 0]
    XCTAssertEqual(
      MultiPhoneHostRules.finalizeConstraints(for: round(bets: bets, bomb: true), playWithSpecialCards: true),
      [.gotSumEqualsHandSizeMinusOne]
    )
    XCTAssertEqual(
      MultiPhoneHostRules.finalizeConstraints(for: round(bets: bets), playWithSpecialCards: true),
      [.gotSumEqualsHandSize]
    )
    XCTAssertEqual(
      MultiPhoneHostRules.finalizeConstraints(for: round(bets: bets, bomb: true), playWithSpecialCards: false),
      [.gotSumEqualsHandSize]
    )
  }

  func testTrickSumMismatchReportsExpectedAndActual() {
    let bets: [Int?] = [1, 0, 1, 0]
    XCTAssertNil(MultiPhoneHostRules.trickSumMismatch(in: round(bets: bets, gots: [1, 0, 2, 0]), playWithSpecialCards: true))
    XCTAssertNil(
      MultiPhoneHostRules.trickSumMismatch(in: round(bets: bets, gots: [1, nil, 2, 0]), playWithSpecialCards: true),
      "Missing values are not a sum mismatch"
    )
    XCTAssertEqual(
      MultiPhoneHostRules.trickSumMismatch(in: round(bets: bets, gots: [1, 1, 2, 0]), playWithSpecialCards: true),
      .init(handSize: 3, bombPlayed: false, bombAvailable: true, expected: 3, actual: 4)
    )
    XCTAssertEqual(
      MultiPhoneHostRules.trickSumMismatch(in: round(bets: bets, gots: [1, 0, 2, 0], bomb: true), playWithSpecialCards: true),
      .init(handSize: 3, bombPlayed: true, bombAvailable: true, expected: 2, actual: 3)
    )
    XCTAssertNil(
      MultiPhoneHostRules.trickSumMismatch(in: round(bets: bets, gots: [1, 0, 1, 0], bomb: true), playWithSpecialCards: true)
    )
  }

  func testTrickSumMismatchMessageShowsBothSums() {
    let plain = MultiPhoneHostRules.TrickSumMismatch(handSize: 3, bombPlayed: false, bombAvailable: false, expected: 3, actual: 4)
    let message = MultiPhoneHostRules.trickSumMismatchMessage(plain, languageCode: nil)
    XCTAssertTrue(message.contains("4"), message)
    XCTAssertTrue(message.contains("3"), message)
    XCTAssertFalse(message.contains("Bomb"), message)

    let withBomb = MultiPhoneHostRules.TrickSumMismatch(handSize: 5, bombPlayed: true, bombAvailable: true, expected: 4, actual: 5)
    let bombMessage = MultiPhoneHostRules.trickSumMismatchMessage(withBomb, languageCode: nil)
    XCTAssertTrue(bombMessage.contains("Bomb"), bombMessage)
    XCTAssertTrue(bombMessage.contains("4"), bombMessage)

    // One trick short with special cards: hint that the Bomb may have been played.
    let oneShort = MultiPhoneHostRules.TrickSumMismatch(handSize: 3, bombPlayed: false, bombAvailable: true, expected: 3, actual: 2)
    XCTAssertTrue(MultiPhoneHostRules.trickSumMismatchMessage(oneShort, languageCode: nil).contains("Bomb"))
  }

  // MARK: - Lobby seats (decision 3)

  func testDeviceStatusPerSeat() {
    XCTAssertEqual(MultiPhoneHostRules.deviceStatus(of: slot(hanna, isHost: true)), .host)
    XCTAssertEqual(MultiPhoneHostRules.deviceStatus(of: slot(anna, bound: true, connected: true)), .phoneConnected)
    XCTAssertEqual(MultiPhoneHostRules.deviceStatus(of: slot(ben, bound: true)), .phoneOffline)
    XCTAssertEqual(MultiPhoneHostRules.deviceStatus(of: slot(cid)), .noPhone)
  }

  func testHostRenamesOnlyPhonelessSeatsAndTheirOwn() {
    XCTAssertTrue(MultiPhoneHostRules.isNameEditableByHost(slot(hanna, isHost: true)))
    XCTAssertTrue(MultiPhoneHostRules.isNameEditableByHost(slot(cid)))
    XCTAssertFalse(MultiPhoneHostRules.isNameEditableByHost(slot(anna, bound: true)))
    XCTAssertEqual(
      MultiPhoneHostRules.hostSeatOptions([slot(hanna, isHost: true), slot(anna, bound: true), slot(cid)]).map(\.playerId),
      [hanna.id, cid.id]
    )
  }

  func testSeatNameCommit() {
    let placeholderSeat = LobbyPlayerSlot(
      playerId: cid.id,
      name: "Player 4",
      isHost: false,
      isBoundToDevice: false,
      isConnected: false,
      isPlaceholderName: true
    )
    XCTAssertEqual(MultiPhoneHostRules.seatNameCommit(draft: "  ", slot: placeholderSeat, players: players), .none)
    XCTAssertEqual(MultiPhoneHostRules.seatNameCommit(draft: "", slot: slot(cid), players: players), .revert)
    XCTAssertEqual(MultiPhoneHostRules.seatNameCommit(draft: "Cid ", slot: slot(cid), players: players), .none)
    XCTAssertEqual(
      MultiPhoneHostRules.seatNameCommit(draft: "anna", slot: slot(cid), players: players),
      .rejected(.nameTaken)
    )
    XCTAssertEqual(
      MultiPhoneHostRules.seatNameCommit(draft: String(repeating: "x", count: 25), slot: slot(cid), players: players),
      .rejected(.nameInvalid)
    )
    XCTAssertEqual(MultiPhoneHostRules.seatNameCommit(draft: " Dora ", slot: slot(cid), players: players), .rename("Dora"))
  }

  func testHostSeatChangeIsRefusedForGuestPhonesAndDuplicateNames() {
    let slots = [slot(hanna, isHost: true), slot(anna, bound: true), slot(ben), slot(cid)]
    XCTAssertEqual(
      MultiPhoneHostRules.hostSeatChangeRejection(to: anna.id, hostName: "Hanna", slots: slots, players: players),
      .seatBoundToDevice
    )
    XCTAssertEqual(
      MultiPhoneHostRules.hostSeatChangeRejection(to: cid.id, hostName: "Ben", slots: slots, players: players),
      .nameTaken
    )
    XCTAssertNil(MultiPhoneHostRules.hostSeatChangeRejection(to: cid.id, hostName: "Hanna", slots: slots, players: players))
    XCTAssertNil(MultiPhoneHostRules.hostSeatChangeRejection(to: hanna.id, hostName: "Hanna", slots: slots, players: players))
    XCTAssertEqual(
      MultiPhoneHostRules.hostSeatChangeRejection(to: UUID(), hostName: "Hanna", slots: slots, players: players),
      .seatNotFound
    )
  }

  func testMovedIDsMatchesOnMoveSemantics() {
    let ids = players.map(\.id)
    // Drag the first seat below the second.
    XCTAssertEqual(
      MultiPhoneHostRules.movedIDs(ids, fromOffsets: IndexSet(integer: 0), toOffset: 2),
      [anna.id, hanna.id, ben.id, cid.id]
    )
    // Drag the last seat to the top.
    XCTAssertEqual(
      MultiPhoneHostRules.movedIDs(ids, fromOffsets: IndexSet(integer: 3), toOffset: 0),
      [cid.id, hanna.id, anna.id, ben.id]
    )
    // Drag to the end.
    XCTAssertEqual(
      MultiPhoneHostRules.movedIDs(ids, fromOffsets: IndexSet(integer: 1), toOffset: 4),
      [hanna.id, ben.id, cid.id, anna.id]
    )
    XCTAssertEqual(MultiPhoneHostRules.movedIDs(ids, fromOffsets: IndexSet(), toOffset: 1), ids)
  }

  func testMoveSeatUpAndDown() {
    let ids = players.map(\.id)
    XCTAssertEqual(MultiPhoneHostRules.movedIDs(ids, moving: ben.id, by: -1), [hanna.id, ben.id, anna.id, cid.id])
    XCTAssertEqual(MultiPhoneHostRules.movedIDs(ids, moving: ben.id, by: 1), [hanna.id, anna.id, cid.id, ben.id])
    XCTAssertNil(MultiPhoneHostRules.movedIDs(ids, moving: hanna.id, by: -1))
    XCTAssertNil(MultiPhoneHostRules.movedIDs(ids, moving: cid.id, by: 1))
  }

  func testDealerIsTrackedByIdNotIndex() {
    let reordered = [cid.id, ben.id, anna.id, hanna.id]
    XCTAssertEqual(MultiPhoneHostRules.resolvedDealerID(selected: ben.id, seatIDs: reordered), ben.id)
    XCTAssertEqual(MultiPhoneHostRules.resolvedDealerID(selected: nil, seatIDs: reordered), cid.id)
    XCTAssertEqual(MultiPhoneHostRules.resolvedDealerID(selected: UUID(), seatIDs: reordered), cid.id)
    XCTAssertNil(MultiPhoneHostRules.resolvedDealerID(selected: nil, seatIDs: []))
  }

  func testDefaultHostSeatPrefersTheSeatWithTheHostsName() {
    XCTAssertEqual(MultiPhoneHostRules.defaultHostSeat(in: players, preferredName: " ben "), ben.id)
    XCTAssertEqual(MultiPhoneHostRules.defaultHostSeat(in: players, preferredName: "Zoe"), hanna.id)
    XCTAssertEqual(MultiPhoneHostRules.defaultHostSeat(in: players, preferredName: ""), hanna.id)
  }

  func testConnectedDeviceCountIncludesTheHost() {
    let slots = [slot(hanna, isHost: true), slot(anna, bound: true, connected: true), slot(ben, bound: true), slot(cid)]
    XCTAssertEqual(MultiPhoneHostRules.connectedDeviceCount(slots), 2)
  }

  // MARK: - Session health

  func testSessionHealthWarnsOnlyWhenTheListenerIsDown() {
    XCTAssertNil(MultiPhoneHostRules.sessionHealth(for: nil))
    XCTAssertNil(MultiPhoneHostRules.sessionHealth(for: .ready))
    XCTAssertNil(MultiPhoneHostRules.sessionHealth(for: .starting))
    XCTAssertNil(MultiPhoneHostRules.sessionHealth(for: .stopped))
    XCTAssertEqual(MultiPhoneHostRules.sessionHealth(for: .failed(.network("boom"))), .unreachable)
    XCTAssertEqual(MultiPhoneHostRules.sessionHealth(for: .waiting(.network("boom"))), .unreachable)
    XCTAssertEqual(MultiPhoneHostRules.sessionHealth(for: .waiting(.localNetworkDenied)), .localNetworkDenied)
    XCTAssertEqual(MultiPhoneHostRules.sessionHealth(for: .failed(.localNetworkDenied)), .localNetworkDenied)
  }
}
