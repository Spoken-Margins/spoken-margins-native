import Foundation
import XCTest
import SessionKit

/// #5033 slice 2: the words, the facts and the screen's answer for the sender collection offer.
final class SenderCollectionOfferPresentationTests: XCTestCase {
    private typealias Presentation = SenderCollectionOfferPresentation
    private let sam = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let ana = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private let now = Date(timeIntervalSince1970: 1_000)

    private func row(_ id: String, senders: [(id: String, name: String)] = [], answered: Bool = false) -> LibraryItemRow {
        var row = LibraryItemRow(id: id, title: id, status: "", canDelete: true)
        row.sharedMargins = SharedMarginTally(
            total: senders.count, new: 0,
            senders: senders.map { SharedMarginTally.Sender(key: $0.id, name: $0.name, count: 1) })
        row.marginCount = answered ? 1 : 0
        return row
    }

    private func layer(_ item: String, sender: String?, name: String?, at seconds: TimeInterval = 1) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: "layer-\(item)-\(seconds)", itemId: item, packageDigest: String(repeating: "d", count: 64), packageId: "p",
            itemIdentity: SharedItemIdentity(itemType: .pdf, title: item), displayLabel: name,
            importedAt: Date(timeIntervalSince1970: seconds), senderId: sender)
    }

    private func decide(
        _ item: String, layers: [ImportedCommentaryLayer], rows: [LibraryItemRow],
        collections: [ItemCollection] = [], record: SenderCollectionRecord = .init(), hidden: Set<String> = []
    ) -> Presentation.Result {
        Presentation.decide(
            openItemId: item, layers: layers, rows: rows, collections: collections, record: record,
            isHidden: { hidden.contains($0) })
    }

    private var twoFromSamAnsweredOnFirst: [LibraryItemRow] {
        [row("a", senders: [(sam, "Sam")], answered: true), row("b", senders: [(sam, "Sam")])]
    }

    // MARK: words (Design section 1 and 2, character for character)

    func testWordsMatchTheDesign() {
        let offer = Presentation.Offer(senderId: sam, senderName: "Sam", itemIds: ["a", "b"])
        XCTAssertEqual(offer.title, "Keep Sam’s readings together")
        XCTAssertEqual(offer.detail, "Put the 2 items from Sam in one collection.")
        XCTAssertEqual(offer.accessibilityLabel, "Keep Sam’s readings together. Put the 2 items from Sam in one collection.")
        XCTAssertEqual(offer.defaultCollectionName, "From Sam")
        XCTAssertEqual(offer.sheetLine, "2 items from Sam")
        XCTAssertEqual(Presentation.Words.banner(collectionName: "From Sam"), "Added to From Sam.")
        XCTAssertEqual(Presentation.Words.makeButton, "Make a Collection")
        XCTAssertEqual(Presentation.Words.notNowButton, "Not now")
        XCTAssertEqual(Presentation.Words.sheetTitle, "New Collection")
        XCTAssertEqual(Presentation.Words.namePlaceholder, "Name, such as HIST 210")
        XCTAssertEqual(Presentation.Words.createButton, "Create")
    }

    // MARK: facts

    func testFactsReadSendersAndAnswersOffTheRows() {
        let facts = Presentation.facts(from: [
            row("a", senders: [(sam, "Sam"), (ana, "Ana")], answered: true),
            row("b", senders: [(sam, "Sam")]),
            row("c"),
        ])
        XCTAssertEqual(facts.map(\.itemId), ["a", "b", "c"])
        XCTAssertEqual(facts[0].senderIds, [sam, ana])
        XCTAssertTrue(facts[0].hasListenerMargin)
        XCTAssertEqual(facts[1].senderIds, [sam])
        XCTAssertFalse(facts[1].hasListenerMargin)
        XCTAssertEqual(facts[2].senderIds, [])
    }

    func testASenderKeyedOnlyByNameNeverCounts() {
        var named = row("a")
        named.sharedMargins = SharedMarginTally(total: 1, new: 0, senders: [SharedMarginTally.Sender(key: nil, name: "Sam", count: 1)])
        XCTAssertEqual(Presentation.facts(from: [named])[0].senderIds, [])
    }

    // MARK: the screen's answer

    func testSecondPacketAfterAnAnswerOffersWithTheNewestName() {
        let layers = [layer("b", sender: sam, name: "Samuel", at: 5), layer("a", sender: sam, name: "Sam", at: 1)]
        XCTAssertEqual(
            decide("b", layers: layers, rows: twoFromSamAnsweredOnFirst),
            .offer(Presentation.Offer(senderId: sam, senderName: "Samuel", itemIds: ["a", "b"])))
    }

    func testFirstPacketAndUnansweredSecondPacketShowNothing() {
        XCTAssertEqual(decide("a", layers: [layer("a", sender: sam, name: "Sam")], rows: [row("a", senders: [(sam, "Sam")], answered: true)]), .none)
        XCTAssertEqual(
            decide("b", layers: [layer("b", sender: sam, name: "Sam")], rows: [row("a", senders: [(sam, "Sam")]), row("b", senders: [(sam, "Sam")])]),
            .none)
    }

    func testNoRowForAnUnsignedSenderButTheOfferNeedsOnlyAName() {
        let rows = twoFromSamAnsweredOnFirst
        for label in [nil, "", "   ", "Unsigned sender", "Someone", "Your friend"] as [String?] {
            XCTAssertEqual(decide("b", layers: [layer("b", sender: sam, name: label)], rows: rows), .none, "label \(label ?? "nil")")
        }
    }

    func testNoRowWithoutASenderIdOrForAHiddenSender() {
        let rows = twoFromSamAnsweredOnFirst
        XCTAssertEqual(decide("b", layers: [layer("b", sender: nil, name: "Sam")], rows: rows), .none)
        XCTAssertEqual(decide("b", layers: [layer("b", sender: sam, name: "Sam")], rows: rows, hidden: [sam]), .none)
    }

    func testRecordedCollectionJoinsInsteadOfOffering() {
        var record = SenderCollectionRecord()
        record.link(sam, toCollection: "col-1")
        let collections = [ItemCollection(id: "col-1", name: "From Sam", itemIDs: ["a"], createdAt: now)]
        XCTAssertEqual(
            decide("b", layers: [layer("b", sender: sam, name: nil)], rows: twoFromSamAnsweredOnFirst, collections: collections, record: record),
            .join(senderId: sam, collectionId: "col-1", itemId: "b"))
    }

    func testDeclinedAndDeletedCollectionShowNothing() {
        var declined = SenderCollectionRecord()
        declined.decline(sam)
        XCTAssertEqual(decide("b", layers: [layer("b", sender: sam, name: "Sam")], rows: twoFromSamAnsweredOnFirst, record: declined), .none)
        var linked = SenderCollectionRecord()
        linked.link(sam, toCollection: "gone")
        XCTAssertEqual(decide("b", layers: [layer("b", sender: sam, name: "Sam")], rows: twoFromSamAnsweredOnFirst, collections: [], record: linked), .none)
    }

    func testAnotherSendersNewestLayerDoesNotHideTheOffer() {
        let rows = [row("a", senders: [(sam, "Sam")], answered: true), row("b", senders: [(sam, "Sam"), (ana, "Ana")])]
        let layers = [layer("b", sender: ana, name: "Ana", at: 9), layer("b", sender: sam, name: "Sam", at: 2)]
        XCTAssertEqual(decide("b", layers: layers, rows: rows), .offer(Presentation.Offer(senderId: sam, senderName: "Sam", itemIds: ["a", "b"])))
    }

    // MARK: the keeper (real UserDefaults suite)

    private func suite() throws -> UserDefaults {
        let name = "SenderCollectionOfferKeeperTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    func testNotNowSurvivesARelaunch() throws {
        let defaults = try suite()
        SenderCollectionOfferKeeper(defaults: defaults).declined(sam)
        let record = SenderCollectionOfferKeeper(defaults: defaults).record(reconciledWith: [])
        XCTAssertEqual(record.standing(of: sam), .declined)
    }

    func testALinkedCollectionSurvivesARelaunchAndADeletedOneBecomesDeclined() throws {
        let defaults = try suite()
        SenderCollectionOfferKeeper(defaults: defaults).linked(sam, toCollection: "col-1")
        let live = [ItemCollection(id: "col-1", name: "From Sam", createdAt: now)]
        XCTAssertEqual(SenderCollectionOfferKeeper(defaults: defaults).record(reconciledWith: live).standing(of: sam), .collection("col-1"))
        XCTAssertEqual(SenderCollectionOfferKeeper(defaults: defaults).record(reconciledWith: []).standing(of: sam), .declined)
        // Written back: a collection that comes back under the same id does not undo the decline.
        XCTAssertEqual(SenderCollectionOfferKeeper(defaults: defaults).record(reconciledWith: live).standing(of: sam), .declined)
    }

    func testAnUnusableSenderIdIsNeverRecorded() throws {
        let defaults = try suite()
        let keeper = SenderCollectionOfferKeeper(defaults: defaults)
        keeper.declined("short")
        keeper.linked("short", toCollection: "col-1")
        keeper.linked(sam, toCollection: "")
        XCTAssertEqual(keeper.record(reconciledWith: []).entries, [:])
    }
}
