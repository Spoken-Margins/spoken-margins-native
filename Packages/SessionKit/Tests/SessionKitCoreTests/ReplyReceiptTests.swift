import Foundation
@testable import SessionKit
import XCTest

/// The "Tell Sam you got it" offer (#3902, Design E1): when a friend's packet answers one of the listener's own Margins,
/// which packet the intro offers from, and the words the button and the message use. The records are built by hand, the
/// way `MarginReplyGraphTests` builds them; the packet round trip is the app-hosted test that follows (Design E2).
final class ReplyReceiptTests: XCTestCase {
    private let digestMine = String(repeating: "a", count: 64)
    private let digestBen = String(repeating: "b", count: 64)
    private let digestCy = String(repeating: "c", count: 64)
    private let date = Date(timeIntervalSince1970: 1_777_000_000)
    private var item: SharedItemIdentity { SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/a", title: "A") }

    private func identity(_ digest: String, _ scoped: String) -> MarginPacketIdentity {
        MarginPacketIdentity(packageDigest: digest, packageScopedId: scoped)
    }

    /// The listener's own Margin `id`, shared in the packet `digestMine` as `scoped`.
    private func own(_ id: String, scoped: String) -> Interjection {
        Interjection(
            id: id, itemId: "item", sessionId: "session", targetType: .item, targetId: "item", createdAt: date, roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: "Words", cleanedTranscript: nil,
            displayText: "Words", status: "active", captureKind: .written
        ).recordingShare(as: identity(digestMine, scoped))
    }

    private func layer(_ id: String, digest: String, label: String?, importedAt: Double = 0, deleted: Bool = false) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, packageDigest: digest, packageId: id, itemIdentity: item, displayLabel: label,
            importedAt: date.addingTimeInterval(importedAt), deletedAt: deleted ? date : nil)
    }

    private func friendMargin(_ id: String, layer: String, answering parent: MarginPacketIdentity? = nil) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: layer, packageScopedId: "\(id)-scoped", createdAt: date,
            anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "Words",
            replyLinks: parent.map { [MarginReplyLink.replying(to: $0, parentConversationId: nil)] })
    }

    private func newest(
        _ layers: [ImportedCommentaryLayer], _ margins: [ImportedCommentaryInterjection], local: [Interjection]? = nil
    ) -> ReplyReceipt.Offer? {
        let graph = MarginReplyGraph.build(localMargins: local ?? [own("mine", scoped: "a-1")], layers: layers, importedMargins: margins)
        return ReplyReceipt.newestOffer(layers: layers, graph: graph, importedMargins: margins)
    }

    // MARK: When the offer shows

    func testAFriendsReplyToMyMarginOffersOneTapAndNamesTheFriend() throws {
        let ben = layer("ben", digest: digestBen, label: "Ben")
        let offer = try XCTUnwrap(newest([ben], [friendMargin("r1", layer: "ben", answering: identity(digestMine, "a-1"))]))
        XCTAssertEqual(offer.layerId, "ben")
        XCTAssertEqual(offer.senderLabel, "Ben")
        XCTAssertEqual(offer.replyCount, 1)
        XCTAssertEqual(offer.buttonTitle, "Tell Ben you got it")
        XCTAssertEqual(offer.message(itemTitle: "Harbour Lights"), "Got your reply on \u{201C}Harbour Lights\u{201D} in Spoken Margins.")
    }

    func testTwoRepliesInOnePacketSayReplies() throws {
        let ben = layer("ben", digest: digestBen, label: "Ben")
        let margins = [
            friendMargin("r1", layer: "ben", answering: identity(digestMine, "a-1")),
            friendMargin("r2", layer: "ben", answering: identity(digestMine, "a-2")),
        ]
        let local = [own("mine-1", scoped: "a-1"), own("mine-2", scoped: "a-2")]
        let offer = try XCTUnwrap(newest([ben], margins, local: local))
        XCTAssertEqual(offer.replyCount, 2)
        XCTAssertEqual(offer.message(itemTitle: "Harbour Lights"), "Got your replies on \u{201C}Harbour Lights\u{201D} in Spoken Margins.")
    }

    /// An answer that came through a reply box offers no receipt (#4675); other packets keep theirs.
    func testExcludingALayerDropsItsOfferAndTheIntroWhenItWasNewest() {
        let a = ReplyReceipt.Offer.forTest(layerId: "box")
        let b = ReplyReceipt.Offer.forTest(layerId: "file")
        let offers = ReplyReceipt.ItemOffers.forTest(byLayer: ["box": a, "file": b], newest: a)
        let kept = offers.excluding { $0 == "box" }
        XCTAssertEqual(Array(kept.byLayer.keys), ["file"])
        XCTAssertNil(kept.newest)
        XCTAssertEqual(offers.excluding { $0 == "file" }.newest, a)
    }

    func testAFriendsFirstShareIsNotAReplyAndGetsNoButton() {
        let ben = layer("ben", digest: digestBen, label: "Ben")
        XCTAssertNil(newest([ben], [friendMargin("first", layer: "ben")]))
        XCTAssertNil(newest([ben], []), "a packet with no Margin offers nothing")
        XCTAssertNil(newest([], []), "no packet offers nothing")
    }

    func testAPacketWithOneReplyAndOtherMarginsCountsOnlyTheReply() throws {
        let ben = layer("ben", digest: digestBen, label: "Ben")
        let margins = [
            friendMargin("new-1", layer: "ben"),
            friendMargin("r1", layer: "ben", answering: identity(digestMine, "a-1")),
            friendMargin("new-2", layer: "ben"),
        ]
        XCTAssertEqual(try XCTUnwrap(newest([ben], margins)).replyCount, 1)
    }

    func testAReplyToAnotherFriendsMarginDoesNotCount() {
        // Cy holds Ana's packet and Ben's reply to it. Ben's reply answers Ana's Margin, not one of Cy's own.
        let ana = layer("ana", digest: digestMine, label: "Ana")
        let ben = layer("ben", digest: digestBen, label: "Ben")
        let margins = [
            friendMargin("a-1", layer: "ana"),
            friendMargin("r1", layer: "ben", answering: identity(digestMine, "a-1-scoped")),
        ]
        XCTAssertNil(newest([ana, ben], margins, local: []))
    }

    func testAReplyWhoseParentHasNotArrivedDoesNotCount() {
        let ben = layer("ben", digest: digestBen, label: "Ben")
        XCTAssertNil(newest([ben], [friendMargin("r1", layer: "ben", answering: identity(digestMine, "a-1"))], local: []))
    }

    func testAForkDoesNotCount() throws {
        let ben = layer("ben", digest: digestBen, label: "Ben")
        let reply = ImportedCommentaryInterjection(
            id: "r1", layerId: "ben", packageScopedId: "r1-scoped", createdAt: date,
            anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "Words",
            replyLinks: [
                MarginReplyLink.replying(to: identity(digestMine, "a-1"), parentConversationId: nil),
                MarginReplyLink.replying(to: identity(digestMine, "a-2"), parentConversationId: nil),
            ])
        let local = [own("mine-1", scoped: "a-1"), own("mine-2", scoped: "a-2")]
        let graph = MarginReplyGraph.build(localMargins: local, layers: [ben], importedMargins: [reply])
        guard case .fork? = graph.states[.imported("r1")] else { return XCTFail("a reply naming two parents is a fork") }
        XCTAssertNil(ReplyReceipt.newestOffer(layers: [ben], graph: graph, importedMargins: [reply]))
    }

    func testADeletedPacketAndADeletedOwnMarginDoNotCount() throws {
        let reply = friendMargin("r1", layer: "ben", answering: identity(digestMine, "a-1"))
        XCTAssertNil(newest([layer("ben", digest: digestBen, label: "Ben", deleted: true)], [reply]))
        var gone = own("mine", scoped: "a-1")
        gone.status = "deleted"
        XCTAssertNil(newest([layer("ben", digest: digestBen, label: "Ben")], [reply], local: [gone]))
        XCTAssertNotNil(newest([layer("ben", digest: digestBen, label: "Ben")], [reply]), "the same packet and Margin, kept, offers")
    }

    func testADeletedPacketOffersNothingEvenIfTheGraphWasBuiltBeforeItWasDeleted() {
        // `offer(layer:)` checks the layer itself, not only what the graph kept.
        let live = layer("ben", digest: digestBen, label: "Ben")
        let reply = friendMargin("r1", layer: "ben", answering: identity(digestMine, "a-1"))
        let graph = MarginReplyGraph.build(localMargins: [own("mine", scoped: "a-1")], layers: [live], importedMargins: [reply])
        XCTAssertNotNil(ReplyReceipt.offer(layer: live, graph: graph, importedMargins: [reply]))
        XCTAssertNil(ReplyReceipt.offer(layer: layer("ben", digest: digestBen, label: "Ben", deleted: true), graph: graph, importedMargins: [reply]))
        XCTAssertNil(ReplyReceipt.newestOffer(layers: [layer("ben", digest: digestBen, label: "Ben", deleted: true)], graph: graph, importedMargins: [reply]))
    }

    func testAnOfferForOnePacketIgnoresAnotherPacketsReplies() throws {
        let ben = layer("ben", digest: digestBen, label: "Ben")
        let dee = layer("dee", digest: digestCy, label: "Dee")
        let margins = [friendMargin("r1", layer: "ben", answering: identity(digestMine, "a-1")), friendMargin("d1", layer: "dee")]
        let graph = MarginReplyGraph.build(localMargins: [own("mine", scoped: "a-1")], layers: [ben, dee], importedMargins: margins)
        XCTAssertEqual(ReplyReceipt.offer(layer: ben, graph: graph, importedMargins: margins)?.replyCount, 1)
        XCTAssertNil(ReplyReceipt.offer(layer: dee, graph: graph, importedMargins: margins))
    }

    // MARK: Which packet the intro offers from

    func testTheIntroOffersFromTheNewestPacketThatAnswersMe() throws {
        let mine = identity(digestMine, "a-1")
        let margins = [friendMargin("rb", layer: "ben", answering: mine), friendMargin("rc", layer: "cy", answering: mine)]
        for (benImportedAt, cyImportedAt, expected) in [(300.0, 400.0, "Cy"), (400.0, 300.0, "Ben")] {
            let layers = [
                layer("ben", digest: digestBen, label: "Ben", importedAt: benImportedAt),
                layer("cy", digest: digestCy, label: "Cy", importedAt: cyImportedAt),
            ]
            XCTAssertEqual(try XCTUnwrap(newest(layers, margins)).senderLabel, expected)
            XCTAssertEqual(try XCTUnwrap(newest(layers.reversed(), margins)).senderLabel, expected, "the list order does not decide it")
        }
    }

    func testANewerPacketWithNoReplyToMeDoesNotHideAnOlderOneThatHas() throws {
        let layers = [
            layer("ben", digest: digestBen, label: "Ben", importedAt: 300),
            layer("dee", digest: digestCy, label: "Dee", importedAt: 500),
        ]
        let margins = [friendMargin("rb", layer: "ben", answering: identity(digestMine, "a-1")), friendMargin("d1", layer: "dee")]
        XCTAssertEqual(try XCTUnwrap(newest(layers, margins)).senderLabel, "Ben")
    }

    func testPacketsImportedAtTheSameMomentTakeTheLaterInTheList() throws {
        let mine = identity(digestMine, "a-1")
        let margins = [friendMargin("rb", layer: "ben", answering: mine), friendMargin("rc", layer: "cy", answering: mine)]
        let ben = layer("ben", digest: digestBen, label: "Ben", importedAt: 300)
        let cy = layer("cy", digest: digestCy, label: "Cy", importedAt: 300)
        XCTAssertEqual(try XCTUnwrap(newest([ben, cy], margins)).layerId, "cy")
        XCTAssertEqual(try XCTUnwrap(newest([cy, ben], margins)).layerId, "ben")
    }

    func testTheOfferIsWorkedOutFromSavedRecordsEachTime() throws {
        // What a reopened Library holds is the same layers, Margins and links, so the same graph and the same offer.
        let ben = layer("ben", digest: digestBen, label: "Ben")
        let margins = [friendMargin("r1", layer: "ben", answering: identity(digestMine, "a-1"))]
        XCTAssertEqual(newest([ben], margins), newest([ben], margins))
        let encoded = try JSONEncoder().encode(margins)
        let decoded = try JSONDecoder().decode([ImportedCommentaryInterjection].self, from: encoded)
        XCTAssertEqual(newest([ben], decoded), newest([ben], margins))
    }

    // MARK: The item screen's offers (Design E2)

    /// The item screen asks once per item: each replying card gets its own offer, the intro gets the newest, and a
    /// friend's first share on the same item gets none.
    func testAnItemOffersOnEachReplyingCardAndTheNewestInTheIntro() throws {
        var item = ItemDetailState()
        item.interjections = [own("mine-1", scoped: "a-1"), own("mine-2", scoped: "a-2")]
        item.importedCommentaryLayers = [
            layer("ben", digest: digestBen, label: "Ben", importedAt: 10),
            layer("cy", digest: digestCy, label: "Cy", importedAt: 20),
            layer("dee", digest: String(repeating: "d", count: 64), label: "Dee", importedAt: 30),
        ]
        item.importedCommentaryInterjections = [
            "ben": [friendMargin("b1", layer: "ben", answering: identity(digestMine, "a-1"))],
            "cy": [
                friendMargin("c1", layer: "cy", answering: identity(digestMine, "a-1")),
                friendMargin("c2", layer: "cy", answering: identity(digestMine, "a-2")),
            ],
            "dee": [friendMargin("first", layer: "dee")],
        ]
        let offers = ReplyReceipt.offers(on: item)
        XCTAssertEqual(Set(offers.byLayer.keys), ["ben", "cy"], "Dee's first share is not an answer")
        XCTAssertEqual(offers.byLayer["ben"]?.replyCount, 1)
        XCTAssertEqual(offers.byLayer["cy"]?.replyCount, 2)
        XCTAssertEqual(offers.newest?.layerId, "cy", "the newer replying packet, not Dee's even newer first share")
        XCTAssertEqual(offers.newest?.buttonTitle, "Tell Cy you got it")
    }

    func testAnItemWithNoReplyLinksOffersNothing() {
        var item = ItemDetailState()
        item.interjections = [own("mine", scoped: "a-1")]
        item.importedCommentaryLayers = [layer("ben", digest: digestBen, label: "Ben")]
        item.importedCommentaryInterjections = ["ben": [friendMargin("first", layer: "ben")]]
        XCTAssertEqual(ReplyReceipt.offers(on: item), .empty)
        XCTAssertEqual(ReplyReceipt.offers(on: ItemDetailState()), .empty, "an item with no friends' packets")
    }

    func testAnItemsDeletedPacketAndADeletedOwnMarginOfferNothing() {
        var item = ItemDetailState()
        item.importedCommentaryLayers = [layer("ben", digest: digestBen, label: "Ben", deleted: true)]
        item.importedCommentaryInterjections = ["ben": [friendMargin("r1", layer: "ben", answering: identity(digestMine, "a-1"))]]
        item.interjections = [own("mine", scoped: "a-1")]
        XCTAssertEqual(ReplyReceipt.offers(on: item), .empty, "a deleted packet")

        item.importedCommentaryLayers = [layer("ben", digest: digestBen, label: "Ben")]
        var deleted = own("mine", scoped: "a-1")
        deleted.status = "deleted"
        item.interjections = [deleted]
        XCTAssertEqual(ReplyReceipt.offers(on: item).byLayer, [:], "the Margin it answered was deleted")
    }

    // MARK: The words

    func testTheButtonNamesTheFriendOrSaysYourFriend() {
        let rows: [(label: String?, title: String)] = [
            ("Sam", "Tell Sam you got it"),
            ("  Sam  ", "Tell Sam you got it"),
            ("Sam Ortiz", "Tell Sam Ortiz you got it"),
            ("Ana María", "Tell Ana María you got it"),
            (nil, "Tell your friend you got it"),
            ("", "Tell your friend you got it"),
            ("   ", "Tell your friend you got it"),
            ("Someone", "Tell your friend you got it"),
            ("SOMEONE", "Tell your friend you got it"),
            ("  someone ", "Tell your friend you got it"),
            ("Unsigned sender", "Tell your friend you got it"),
            ("Imported collection", "Tell your friend you got it"),
        ]
        for row in rows {
            XCTAssertEqual(ReplyReceipt.buttonTitle(senderLabel: row.label), row.title, "label \(String(describing: row.label))")
        }
    }

    func testTheMessageHandlesTheTitleAndTheCount() {
        let open = "\u{201C}", close = "\u{201D}"
        let rows: [(title: String?, count: Int, message: String)] = [
            ("Episode", 1, "Got your reply on \(open)Episode\(close) in Spoken Margins."),
            ("Episode", 2, "Got your replies on \(open)Episode\(close) in Spoken Margins."),
            ("Episode", 9, "Got your replies on \(open)Episode\(close) in Spoken Margins."),
            (nil, 1, "Got your reply in Spoken Margins."),
            ("", 1, "Got your reply in Spoken Margins."),
            ("  \n\t ", 2, "Got your replies in Spoken Margins."),
            ("\u{00A0}\u{2003}", 1, "Got your reply in Spoken Margins."),
            ("\u{200B}\u{FEFF}", 1, "Got your reply in Spoken Margins."),
            ("Zero\u{200B}width", 1, "Got your reply on \(open)Zerowidth\(close) in Spoken Margins."),
            ("  Two   words\n", 1, "Got your reply on \(open)Two words\(close) in Spoken Margins."),
            ("Why \"quotes\" nest", 1, "Got your reply on \(open)Why 'quotes' nest\(close) in Spoken Margins."),
            ("Why \u{201C}curly\u{201D} too", 1, "Got your reply on \(open)Why \u{2018}curly\u{2019} too\(close) in Spoken Margins."),
            ("Café – naïve", 1, "Got your reply on \(open)Café – naïve\(close) in Spoken Margins."),
        ]
        for row in rows {
            XCTAssertEqual(ReplyReceipt.message(itemTitle: row.title, replyCount: row.count), row.message, "title \(String(describing: row.title))")
        }
    }
}

private extension ReplyReceipt.Offer {
    static func forTest(layerId: String) -> Self { Self(layerId: layerId, senderLabel: nil, replyCount: 1) }
}

private extension ReplyReceipt.ItemOffers {
    static func forTest(byLayer: [String: ReplyReceipt.Offer], newest: ReplyReceipt.Offer?) -> Self { Self(byLayer: byLayer, newest: newest) }
}
