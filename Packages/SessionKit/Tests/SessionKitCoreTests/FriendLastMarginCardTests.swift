import Foundation
import XCTest
@testable import SessionKit

/// The card after a friend's last Margin (#3247), and how the player's Share opens on a friend's item.
final class FriendLastMarginCardTests: XCTestCase {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

    private func layer(_ id: String, label: String, importedAt: Double = 100, deleted: Bool = false) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, itemId: "item", packageDigest: "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
            displayLabel: label, importedAt: date(importedAt), sourceResolutionStatus: .resolved,
            isEnabled: true, isMuted: false, deletedAt: deleted ? date(importedAt) : nil
        )
    }

    private func own(_ id: String, madeAt: Double, replyingTo layerId: String? = nil) -> Interjection {
        Interjection(
            id: id, itemId: "item", sessionId: "session", targetType: .item, targetId: "item", createdAt: date(madeAt),
            roughPercent: 10, anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 60_000),
            audioPath: "Interjections/\(id).m4a", audioStatus: "ready", transcriptionStatus: "complete",
            transcript: "Words", cleanedTranscript: nil, displayText: "Words", status: "active",
            replyTo: layerId.map {
                MarginReplyLink(conversationId: "conversation", parentPackageDigest: "digest-\($0)", parentPackageScopedId: "f-1")
            }
        )
    }

    private func last(heard: Bool = true, now: Double = 1_000, margins: [Interjection] = [], layers: [ImportedCommentaryLayer]) -> PinnedMarginCard? {
        PinnedMarginCard.friendsLast(now: date(now), heardAMargin: heard, localMargins: margins, layers: layers)
    }

    func testANamedSenderGetsTheOwnersWordsWithoutAPronoun() throws {
        let card = try XCTUnwrap(last(layers: [layer("cole", label: "Cole")]))
        XCTAssertEqual(card.headline, "That was Cole's last Margin")
        XCTAssertEqual(card.detail, "To answer Cole, add a Margin of your own.")
    }

    func testAnUnnamedSenderIsYourFriendNeverAStandIn() throws {
        for label in ["", " ", "Unsigned sender", "Imported collection"] {
            let card = try XCTUnwrap(last(layers: [layer("a", label: label)]))
            XCTAssertEqual(card.headline, "That was your friend's last Margin", label)
            XCTAssertEqual(card.detail, "To answer your friend, add a Margin of your own.", label)
        }
    }

    func testSeveralSendersAreNotNamedOneByOne() throws {
        let card = try XCTUnwrap(last(layers: [layer("a", label: "Ana"), layer("b", label: "Ben", importedAt: 110)]))
        XCTAssertEqual(card.headline, "That was the last of your friends' Margins")
        XCTAssertEqual(card.detail, "To answer your friends, add a Margin of your own.")
        let mixed = try XCTUnwrap(last(layers: [layer("a", label: "Ana"), layer("b", label: "", importedAt: 110)]))
        XCTAssertEqual(mixed.headline, "That was the last of your friends' Margins", "a named sender and one with no name are two people")
    }

    func testTwoPacketsFromOneSenderAreOneSender() throws {
        let card = try XCTUnwrap(last(layers: [layer("a", label: "Cole"), layer("b", label: "Cole", importedAt: 110)]))
        XCTAssertEqual(card.headline, "That was Cole's last Margin")
    }

    func testOnlyAFriendsItemAfterAMarginWasHeard() {
        XCTAssertNil(last(layers: []), "the listener's own item")
        XCTAssertNil(last(layers: [layer("cole", label: "Cole", deleted: true)]), "a packet that was removed")
        XCTAssertNil(last(heard: false, layers: [layer("cole", label: "Cole")]), "nothing played yet, so nothing was the last")
    }

    func testTheSavedCardKeepsTheSlotThroughItsWindowThenTheLastMarginCardReturns() throws {
        let layers = [layer("cole", label: "Cole")], saved = [own("mine", madeAt: 200)]
        XCTAssertNil(last(now: 210, margins: saved, layers: layers), "the news that a saved Margin can be sent comes first")
        XCTAssertNotNil(PinnedMarginCard.answerSaved(now: date(210), localMargins: saved, layers: layers))
        let after = try XCTUnwrap(last(now: 200 + PinnedMarginCard.answerSavedWindow, margins: saved, layers: layers))
        XCTAssertEqual(after.headline, "That was Cole's last Margin")
    }

    func testShareOpensWithTheFriendsAnswersPickedOnAFriendsItem() throws {
        let layers = [layer("cole", label: "Cole")]
        let reply = own("reply", madeAt: 200, replyingTo: "cole"), other = own("other", madeAt: 210)
        guard case .friendAnswersPicked(let offer) = PlaybackShareStart.start(localMargins: [reply, other], layers: layers) else {
            return XCTFail("a friend's item with an answer must open on the answers")
        }
        XCTAssertTrue(offer.isPreselected(reply))
        XCTAssertFalse(offer.isPreselected(other), "the other new Margin is listed and left out, changeable")
        XCTAssertEqual(Set(offer.candidates.map(\.id)), ["reply", "other"])
        XCTAssertEqual(offer.title, "Send replies to Cole")
    }

    func testShareIsUnchangedWhereThereIsNoAnswerToPick() {
        let mine = own("mine", madeAt: 200)
        XCTAssertEqual(PlaybackShareStart.start(localMargins: [mine], layers: []), .defaults, "the listener's own item")
        XCTAssertEqual(PlaybackShareStart.start(localMargins: [], layers: [layer("cole", label: "Cole")]), .defaults, "a friend's item, nothing made")
        XCTAssertEqual(PlaybackShareStart.start(localMargins: [mine], layers: [layer("cole", label: "Cole")]), .defaults,
                       "a Margin that answers nothing leaves Share as it was, with the default Margins picked")
        XCTAssertEqual(PlaybackShareStart.start(localMargins: [own("r", madeAt: 200, replyingTo: "cole")], layers: [layer("cole", label: "Cole", deleted: true)]), .defaults,
                       "a removed packet")
    }
}
