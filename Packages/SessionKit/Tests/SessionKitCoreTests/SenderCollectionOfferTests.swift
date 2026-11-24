import XCTest
@testable import SessionKit

/// #5033: "Keep Sam's readings together" is offered once, after the listener answered a sender who sent two or more
/// items, and a sender whose collection the listener made gets later items added silently.
final class SenderCollectionOfferTests: XCTestCase {
    private let sam = "0123456789abcdef0123456789abcdef"
    private let ana = "fedcba9876543210fedcba9876543210"

    private func sender(_ id: String?, _ name: String? = "Sam", count: Int = 1) -> SharedMarginTally.Sender {
        SharedMarginTally.Sender(key: id, name: name, count: count)
    }

    private func item(_ id: String, _ senders: [SharedMarginTally.Sender], own: Int = 0) -> SenderCollectionOffer.ItemSenders {
        SenderCollectionOffer.ItemSenders(itemID: id, senders: senders, ownMarginCount: own)
    }

    private func decide(
        _ itemID: String, _ items: [SenderCollectionOffer.ItemSenders],
        collections: [ItemCollection] = [], record: SenderCollectionOfferRecord = SenderCollectionOfferRecord(),
        hidden: HiddenSenders = HiddenSenders()
    ) -> SenderCollectionOffer.Decision {
        SenderCollectionOffer.decide(itemID: itemID, items: items, collections: collections, record: record, hidden: hidden)
    }

    private func collection(_ id: String, _ name: String, _ items: [String]) -> ItemCollection {
        ItemCollection(id: id, name: name, itemIDs: items, createdAt: Date(timeIntervalSince1970: 0))
    }

    func testFirstPacketFromASenderIsAnOrdinaryShareWithNoOffer() {
        XCTAssertEqual(decide("a", [item("a", [sender(sam)], own: 1)]), .none)
    }

    func testSecondPacketBeforeTheListenerAnsweredGetsNoOffer() {
        XCTAssertEqual(decide("b", [item("a", [sender(sam)]), item("b", [sender(sam)])]), .none)
    }

    func testSecondPacketAfterAnAnswerOffersBothItems() {
        let decision = decide("b", [item("a", [sender(sam)], own: 1), item("b", [sender(sam)]), item("c", [])])
        guard case .offer(let offer) = decision else { return XCTFail("expected an offer, got \(decision)") }
        XCTAssertEqual(offer.senderID, sam)
        XCTAssertEqual(offer.itemIDs, ["a", "b"])
        XCTAssertEqual(offer.title, "Keep Sam's readings together")
        XCTAssertEqual(offer.detail, "Put the 2 items from Sam in one collection.")
        XCTAssertEqual(offer.countLine, "2 items from Sam")
        XCTAssertEqual(offer.defaultCollectionName, "From Sam")
        XCTAssertEqual(offer.accessibilityLabel, "Keep Sam's readings together. Put the 2 items from Sam in one collection.")
    }

    func testTheOfferShowsOnEitherOfTheSendersItems() {
        let items = [item("a", [sender(sam)], own: 1), item("b", [sender(sam)])]
        XCTAssertNotEqual(decide("a", items), .none)
        XCTAssertNotEqual(decide("b", items), .none)
    }

    func testAnItemWithNoMarginsFromTheSenderShowsNothing() {
        XCTAssertEqual(decide("c", [item("a", [sender(sam)], own: 1), item("b", [sender(sam)]), item("c", [], own: 3)]), .none)
    }

    func testALayerWithNoSenderIDNeverCounts() {
        // An older sender build sends no id: the tally keys it by name, and names prove nothing.
        let items = [item("a", [sender(nil)], own: 1), item("b", [sender(nil)])]
        XCTAssertEqual(decide("b", items), .none)
        XCTAssertEqual(decide("b", [item("a", [sender("not an id")], own: 1), item("b", [sender("not an id")])]), .none)
    }

    func testASameNamedFriendWithADifferentIDIsAnotherSender() {
        let items = [item("a", [sender(sam, "Sam")], own: 1), item("b", [sender(ana, "Sam")])]
        XCTAssertEqual(decide("b", items), .none)
    }

    func testAPacketWithNoSenderNameGetsNoRow() {
        let items = [item("a", [sender(sam, "Unsigned sender")], own: 1), item("b", [sender(sam, nil)])]
        XCTAssertEqual(decide("b", items), .none)
    }

    func testTheNameComesFromThisItemsPacketElseAnotherOne() {
        let named = decide("b", [item("a", [sender(sam, "Sam R.")], own: 1), item("b", [sender(sam, "Prof. Sam")])])
        guard case .offer(let offer) = named else { return XCTFail("expected an offer") }
        XCTAssertEqual(offer.senderName, "Prof. Sam")
        let unnamedHere = decide("b", [item("a", [sender(sam, "Sam R.")], own: 1), item("b", [sender(sam, nil)])])
        guard case .offer(let other) = unnamedHere else { return XCTFail("expected an offer") }
        XCTAssertEqual(other.senderName, "Sam R.")
    }

    func testAHiddenSenderGetsNoOfferAndNoJoin() {
        var hidden = HiddenSenders()
        XCTAssertTrue(hidden.hide(sam, displayLabel: "Sam"))
        let items = [item("a", [sender(sam)], own: 1), item("b", [sender(sam)])]
        XCTAssertEqual(decide("b", items, hidden: hidden), .none)
        var record = SenderCollectionOfferRecord()
        record.recordCollection("c1", for: sam)
        XCTAssertEqual(decide("b", items, collections: [collection("c1", "From Sam", ["a"])], record: record, hidden: hidden), .none)
    }

    func testNotNowIsFinalForThatSender() {
        var record = SenderCollectionOfferRecord()
        record.recordDeclined(for: sam)
        let items = [item("a", [sender(sam)], own: 1), item("b", [sender(sam)]), item("c", [sender(sam)])]
        XCTAssertEqual(decide("c", items, record: record), .none)
    }

    /// The regression the issue names: a later packet from a sender the listener made a collection for joins that
    /// collection, never a new one and never a second offer.
    func testALaterPacketFromARecordedSenderJoinsTheSameCollection() {
        var record = SenderCollectionOfferRecord()
        record.recordCollection("c1", for: sam)
        let items = [item("a", [sender(sam)], own: 1), item("b", [sender(sam)]), item("c", [sender(sam)])]
        let decision = decide("c", items, collections: [collection("c1", "HIST 210", ["a", "b"])], record: record)
        XCTAssertEqual(decision, .join(.init(senderID: sam, collectionID: "c1", collectionName: "HIST 210", itemID: "c")))
        guard case .join(let join) = decision else { return XCTFail("expected a join") }
        XCTAssertEqual(join.banner, "Added to HIST 210.")
    }

    func testAnItemTheListenerTookOutOfTheCollectionIsNotAddedBack() {
        var record = SenderCollectionOfferRecord()
        record.recordCollection("c1", for: sam)
        record.recordPlaced(["a", "b"])
        let items = [item("a", [sender(sam)], own: 1), item("b", [sender(sam)])]
        XCTAssertEqual(decide("b", items, collections: [collection("c1", "From Sam", ["a"])], record: record), .none)
    }

    func testAnItemAlreadyInTheRecordedCollectionShowsNothing() {
        var record = SenderCollectionOfferRecord()
        record.recordCollection("c1", for: sam)
        let items = [item("a", [sender(sam)], own: 1), item("b", [sender(sam)])]
        XCTAssertEqual(decide("b", items, collections: [collection("c1", "From Sam", ["a", "b"])], record: record), .none)
    }

    func testADeletedRecordedCollectionMeansNoJoinAndNoNewOffer() {
        var record = SenderCollectionOfferRecord()
        record.recordCollection("gone", for: sam)
        let items = [item("a", [sender(sam)], own: 1), item("b", [sender(sam)]), item("c", [sender(sam)])]
        XCTAssertEqual(decide("c", items, collections: [collection("other", "Mine", [])], record: record), .none)
    }

    func testAHandMadeCollectionIsNotAdoptedSoTheOfferStillShows() {
        let items = [item("a", [sender(sam)], own: 1), item("b", [sender(sam)])]
        let decision = decide("b", items, collections: [collection("mine", "Sam stuff", ["a", "b"])])
        guard case .offer = decision else { return XCTFail("expected an offer, got \(decision)") }
    }

    func testAnItemInRecentlyDeletedIsNotCounted() {
        // The Library's rows leave out items in Recently Deleted, so only one of Sam's items is listed.
        XCTAssertEqual(decide("b", [item("b", [sender(sam)], own: 1)]), .none)
        // Restored, it is listed again and counts.
        guard case .offer = decide("b", [item("a", [sender(sam)]), item("b", [sender(sam)], own: 1)]) else {
            return XCTFail("expected an offer once the item is back")
        }
    }

    func testAJoinIsHonouredBeforeAnotherSendersOffer() {
        var record = SenderCollectionOfferRecord()
        record.recordCollection("c1", for: sam)
        let items = [
            item("a", [sender(sam), sender(ana, "Ana")], own: 1), item("b", [sender(ana, "Ana")]),
            item("c", [sender(ana, "Ana"), sender(sam)]),
        ]
        let decision = decide("c", items, collections: [collection("c1", "From Sam", ["a"])], record: record)
        guard case .join(let join) = decision else { return XCTFail("expected a join, got \(decision)") }
        XCTAssertEqual(join.senderID, sam)
        // Once the item is in Sam's collection, Ana's offer shows.
        let after = decide("c", items, collections: [collection("c1", "From Sam", ["a", "c"])], record: record)
        guard case .offer(let offer) = after else { return XCTFail("expected Ana's offer, got \(after)") }
        XCTAssertEqual(offer.senderID, ana)
        XCTAssertEqual(offer.itemIDs, ["a", "b", "c"])
    }

    func testTheDefaultNameIsCutToTheCollectionNameLimit() {
        let long = String(repeating: "S", count: 80)
        let decision = decide("b", [item("a", [sender(sam, long)], own: 1), item("b", [sender(sam, long)])])
        guard case .offer(let offer) = decision else { return XCTFail("expected an offer") }
        XCTAssertEqual(offer.defaultCollectionName.count, ItemCollectionEditing.maximumNameCharacters)
    }

    func testTheRecordSurvivesARelaunch() throws {
        let suite = "SenderCollectionOfferTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(SenderCollectionOfferRecord.load(from: defaults), SenderCollectionOfferRecord())
        var record = SenderCollectionOfferRecord()
        record.recordDeclined(for: sam)
        record.recordCollection("collection-1", for: ana)
        record.recordPlaced(["item-1", "item-2"])
        record.save(to: defaults)

        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        let loaded = SenderCollectionOfferRecord.load(from: reopened)
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(loaded.choice(for: sam), .declined)
        XCTAssertEqual(loaded.choice(for: ana), .collection("collection-1"))
        XCTAssertTrue(loaded.wasPlaced("item-2"))
        XCTAssertFalse(loaded.wasPlaced("item-3"))
    }

    func testARecordThatCannotBeReadStartsEmpty() throws {
        let suite = "SenderCollectionOfferTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("garbage", forKey: SenderCollectionOfferRecord.defaultsKey)
        XCTAssertEqual(SenderCollectionOfferRecord.load(from: defaults), SenderCollectionOfferRecord())
        defaults.set(["short": "declined", sam: ""], forKey: SenderCollectionOfferRecord.defaultsKey)
        XCTAssertEqual(SenderCollectionOfferRecord.load(from: defaults), SenderCollectionOfferRecord())
    }
}
