import Foundation
import XCTest
@testable import SessionKit

/// The card after a friend saves a Margin (#3247): the owner's words, and only on a friend's item, only for a while.
final class FriendAnswerSavedCardTests: XCTestCase {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

    private func layer(_ id: String, label: String, deleted: Bool = false) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: id, itemId: "item", packageDigest: "digest-\(id)", packageId: "package-\(id)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
            displayLabel: label, importedAt: date(100), sourceResolutionStatus: .resolved,
            isEnabled: true, isMuted: false, deletedAt: deleted ? date(100) : nil
        )
    }

    private func own(_ id: String, madeAt: Double, atMs: Int? = 2_380_000) -> Interjection {
        Interjection(
            id: id, itemId: "item", sessionId: "session", targetType: .item, targetId: "item", createdAt: date(madeAt),
            roughPercent: 10, anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: atMs),
            audioPath: "Interjections/\(id).m4a", audioStatus: "ready", transcriptionStatus: "complete",
            transcript: "Words", cleanedTranscript: nil, displayText: "Words", status: "active"
        )
    }

    func testTheCardSaysTheOwnersWordsWithTheTimeAndTheFriendsName() throws {
        let card = try XCTUnwrap(PinnedMarginCard.answerSaved(now: date(210), localMargins: [own("mine", madeAt: 200)], layers: [layer("cole", label: "Cole")]))
        XCTAssertEqual(card.headline, "Your Margin is saved at 39:40")
        XCTAssertEqual(card.detail, "To send it to Cole, tap Share below. You pick which of your Margins go.")
    }

    func testAnUnnamedFriendIsYourFriendNeverAStandIn() throws {
        for label in ["", " ", "Unsigned sender", "Imported collection"] {
            let card = try XCTUnwrap(PinnedMarginCard.answerSaved(now: date(210), localMargins: [own("mine", madeAt: 200)], layers: [layer("a", label: label)]))
            XCTAssertEqual(card.detail, "To send it to your friend, tap Share below. You pick which of your Margins go.", label)
        }
    }

    func testATextItemHasNoTimeToSay() throws {
        let card = try XCTUnwrap(PinnedMarginCard.answerSaved(now: date(210), localMargins: [own("mine", madeAt: 200, atMs: nil)], layers: [layer("cole", label: "Cole")]))
        XCTAssertEqual(card.headline, "Your Margin is saved")
    }

    func testPastAnHourTheTimeKeepsItsHour() throws {
        let card = try XCTUnwrap(PinnedMarginCard.answerSaved(now: date(210), localMargins: [own("mine", madeAt: 200, atMs: 3_723_000)], layers: [layer("cole", label: "Cole")]))
        XCTAssertEqual(card.headline, "Your Margin is saved at 1:02:03")
    }

    func testOnlyAFriendsItemGetsTheCard() {
        XCTAssertNil(PinnedMarginCard.answerSaved(now: date(210), localMargins: [own("mine", madeAt: 200)], layers: []), "the listener's own item")
        XCTAssertNil(PinnedMarginCard.answerSaved(now: date(210), localMargins: [own("mine", madeAt: 200)], layers: [layer("cole", label: "Cole", deleted: true)]),
                     "a friend's packet that was removed")
        XCTAssertNil(PinnedMarginCard.answerSaved(now: date(210), localMargins: [own("old", madeAt: 50)], layers: [layer("cole", label: "Cole")]),
                     "a Margin made before the friend's packet arrived is not an answer")
    }

    func testTheCardLeavesTheSlotAfterItsWindowAndNeverShowsBeforeTheSave() {
        let margins = [own("mine", madeAt: 200)], layers = [layer("cole", label: "Cole")]
        XCTAssertNotNil(PinnedMarginCard.answerSaved(now: date(200 + PinnedMarginCard.answerSavedWindow - 1), localMargins: margins, layers: layers))
        XCTAssertNil(PinnedMarginCard.answerSaved(now: date(200 + PinnedMarginCard.answerSavedWindow), localMargins: margins, layers: layers))
        XCTAssertNil(PinnedMarginCard.answerSaved(now: date(190), localMargins: margins, layers: layers), "a clock that ran backwards")
    }

    func testTheNewestMarginSetsTheTimeAndTwoFriendsAreBothNamed() throws {
        let card = try XCTUnwrap(PinnedMarginCard.answerSaved(
            now: date(215), localMargins: [own("first", madeAt: 200, atMs: 60_000), own("second", madeAt: 210, atMs: 125_000)],
            layers: [layer("a", label: "Ana"), layer("b", label: "Ben")]))
        XCTAssertEqual(card.headline, "Your Margin is saved at 2:05")
        XCTAssertEqual(card.detail, "To send it to Ana and Ben, tap Share below. You pick which of your Margins go.")
    }
}
