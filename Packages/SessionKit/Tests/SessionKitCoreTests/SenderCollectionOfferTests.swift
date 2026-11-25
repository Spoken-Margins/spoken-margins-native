import Foundation
import XCTest
import SessionKit

/// #5033 slice 1: a student whose readings arrive from one sender is offered one collection, after answering.
final class SenderCollectionOfferTests: XCTestCase {
    private let sam = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let ana = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private let now = Date(timeIntervalSince1970: 1_000)

    private func facts(_ id: String, _ senders: Set<String>, trashed: Bool = false, answered: Bool = false) -> SenderCollectionOffer.ItemFacts {
        .init(itemId: id, senderIds: senders, isInRecentlyDeleted: trashed, hasListenerMargin: answered)
    }

    private func decide(
        _ item: String, sender: String?, _ items: [SenderCollectionOffer.ItemFacts],
        collections: [ItemCollection] = [], record: SenderCollectionRecord = .init(), hidden: Set<String> = []
    ) -> SenderCollectionOffer.Decision {
        SenderCollectionOffer.decide(
            newItemId: item, senderId: sender, items: items, collections: collections, record: record,
            isHidden: { hidden.contains($0) })
    }

    func testFirstPacketHasNoOffer() {
        XCTAssertEqual(decide("a", sender: sam, [facts("a", [sam], answered: true)]), .none)
    }

    func testSecondPacketBeforeAnyAnswerHasNoOffer() {
        XCTAssertEqual(decide("b", sender: sam, [facts("a", [sam]), facts("b", [sam])]), .none)
    }

    func testSecondPacketAfterAnAnswerOffersBothItems() {
        let items = [facts("a", [sam], answered: true), facts("b", [sam]), facts("c", [ana], answered: true)]
        XCTAssertEqual(decide("b", sender: sam, items), .offer(itemIds: ["a", "b"]))
    }

    func testAnAnswerOnAnyOfTheSendersItemsCounts() {
        let items = [facts("a", [sam]), facts("b", [sam], answered: true)]
        XCTAssertEqual(decide("a", sender: sam, items), .offer(itemIds: ["a", "b"]))
    }

    func testAnswerOnAnotherSendersItemDoesNotCount() {
        let items = [facts("a", [sam]), facts("b", [sam]), facts("c", [ana], answered: true)]
        XCTAssertEqual(decide("b", sender: sam, items), .none)
    }

    func testSenderIdTable() {
        let items = [facts("a", [sam], answered: true), facts("b", [sam])]
        let rows: [(sender: String?, expected: SenderCollectionOffer.Decision)] = [
            (nil, .none), ("", .none), ("short", .none), ("has space has space has space!", .none),
            (String(repeating: "a", count: 65), .none), (sam, .offer(itemIds: ["a", "b"])),
            (sam.uppercased(), .none),
        ]
        for row in rows {
            XCTAssertEqual(decide("b", sender: row.sender, items), row.expected, "sender \(row.sender ?? "nil")")
        }
    }

    func testHiddenSenderGetsNoOfferAndNoJoin() {
        let items = [facts("a", [sam], answered: true), facts("b", [sam])]
        XCTAssertEqual(decide("b", sender: sam, items, hidden: [sam]), .none)
        var record = SenderCollectionRecord()
        record.link(sam, toCollection: "c1")
        let col = ItemCollection(id: "c1", name: "From Sam", itemIDs: ["a"], createdAt: now)
        XCTAssertEqual(decide("b", sender: sam, items, collections: [col], record: record, hidden: [sam]), .none)
    }

    func testDeclinedSenderIsNeverOfferedAgain() {
        var record = SenderCollectionRecord()
        record.decline(sam)
        let items = [facts("a", [sam], answered: true), facts("b", [sam]), facts("c", [sam])]
        XCTAssertEqual(decide("c", sender: sam, items, record: record), .none)
    }

    /// Fails without the join rule: a third packet would offer again instead of joining.
    func testRecordedCollectionJoinsThirdPacketSilently() {
        var record = SenderCollectionRecord()
        record.link(sam, toCollection: "c1")
        let col = ItemCollection(id: "c1", name: "From Sam", itemIDs: ["a", "b"], createdAt: now)
        let items = [facts("a", [sam], answered: true), facts("b", [sam]), facts("c", [sam])]
        XCTAssertEqual(decide("c", sender: sam, items, collections: [col], record: record),
                       .join(collectionId: "c1", itemId: "c"))
    }

    func testItemAlreadyInTheCollectionDoesNothing() {
        var record = SenderCollectionRecord()
        record.link(sam, toCollection: "c1")
        let col = ItemCollection(id: "c1", name: "HIST 210", itemIDs: ["a", "c"], createdAt: now)
        let items = [facts("a", [sam], answered: true), facts("c", [sam])]
        XCTAssertEqual(decide("c", sender: sam, items, collections: [col], record: record), .none)
    }

    func testRenamedCollectionStaysLinked() {
        var record = SenderCollectionRecord()
        record.link(sam, toCollection: "c1")
        let col = ItemCollection(id: "c1", name: "Renamed", itemIDs: ["a"], createdAt: now)
        let items = [facts("a", [sam], answered: true), facts("b", [sam])]
        XCTAssertEqual(decide("b", sender: sam, items, collections: [col], record: record),
                       .join(collectionId: "c1", itemId: "b"))
    }

    func testDeletedCollectionIsTreatedAsDeclined() {
        var record = SenderCollectionRecord()
        record.link(sam, toCollection: "gone")
        let items = [facts("a", [sam], answered: true), facts("b", [sam]), facts("c", [sam])]
        XCTAssertEqual(decide("c", sender: sam, items, record: record), .none)
        XCTAssertEqual(record.reconciled(with: []).standing(of: sam), .declined)
    }

    func testTrashedItemsAreNotCountedAndRestoredOnesAre() {
        let trashed = [facts("a", [sam], answered: true), facts("b", [sam], trashed: true), facts("c", [sam])]
        XCTAssertEqual(decide("c", sender: sam, trashed), .offer(itemIds: ["a", "c"]))
        let onlyOneLeft = [facts("a", [sam], answered: true), facts("b", [sam], trashed: true)]
        XCTAssertEqual(decide("a", sender: sam, onlyOneLeft), .none)
        let restored = [facts("a", [sam], answered: true), facts("b", [sam])]
        XCTAssertEqual(decide("b", sender: sam, restored), .offer(itemIds: ["a", "b"]))
    }

    func testTrashedNewItemGetsNothing() {
        let items = [facts("a", [sam], answered: true), facts("b", [sam], trashed: true)]
        XCTAssertEqual(decide("b", sender: sam, items), .none)
    }

    func testNewItemNotFromThatSenderOrMissingGetsNothing() {
        let items = [facts("a", [sam], answered: true), facts("b", [sam]), facts("c", [ana])]
        XCTAssertEqual(decide("c", sender: sam, items), .none)
        XCTAssertEqual(decide("zzz", sender: sam, items), .none)
    }

    func testTwoSendersAreIndependent() {
        var record = SenderCollectionRecord()
        record.decline(sam)
        let items = [facts("a", [ana], answered: true), facts("b", [ana]), facts("c", [sam])]
        XCTAssertEqual(decide("b", sender: ana, items, record: record), .offer(itemIds: ["a", "b"]))
    }

    func testRecordSurvivesARebuildInRealUserDefaults() throws {
        let suite = "SenderCollectionOfferTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var record = SenderCollectionRecord()
        record.decline(sam)
        record.link(ana, toCollection: "c1")
        SenderCollectionRecordStore(defaults: defaults).save(record)

        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        let loaded = SenderCollectionRecordStore(defaults: reopened).load()
        XCTAssertEqual(loaded.standing(of: sam), .declined)
        XCTAssertEqual(loaded.standing(of: ana), .collection("c1"))
        XCTAssertEqual(loaded.standing(of: "cccccccccccccccccccccccccccccccc"), .unknown)
    }

    func testRecordRefusesBadIdsAndDropsThemOnLoad() {
        var record = SenderCollectionRecord()
        record.decline("short")
        XCTAssertFalse(record.link("short", toCollection: "c1"))
        XCTAssertFalse(record.link(sam, toCollection: ""))
        XCTAssertFalse(record.link(sam, toCollection: SenderCollectionRecord.declinedMarker))
        XCTAssertTrue(record.entries.isEmpty)
        let loaded = SenderCollectionRecord(entries: ["short": "c1", sam: "", ana: "c2"])
        XCTAssertEqual(loaded.entries, [ana: "c2"])
    }
}
