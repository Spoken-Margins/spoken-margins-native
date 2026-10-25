import Foundation
import SessionKit
import XCTest

/// A Margin recorded while a friend's shared Margin plays, or just after, answers it (#473, owner 2026-10-25).
final class SharedMarginReplyMemoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_777_000_000)
    private var memory = SharedMarginReplyMemory()

    private func layer(_ id: String, label: String) -> ImportedCommentaryLayer {
        var layer = ImportedCommentaryLayer(
            id: id, itemId: "item", packageDigest: String(repeating: id.first ?? "a", count: 64), packageId: id,
            itemIdentity: SharedItemIdentity(itemType: .podcast, canonicalURL: "https://example.com/a", title: "A"),
            displayLabel: label, importedAt: t0
        )
        layer.isEnabled = true
        return layer
    }

    private func draft(_ id: String, from layer: ImportedCommentaryLayer) -> MarginReplyDraft {
        let margin = ImportedCommentaryInterjection(
            id: id, layerId: layer.id, packageScopedId: "\(id)-scoped", createdAt: t0,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Words \(id)",
            resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: 1_000)
        )
        return MarginReplyDraft(parent: margin, in: layer)
    }

    func testRecordingWhileTheSharedMarginPlaysAnswersIt() {
        let ana = draft("a1", from: layer("a", label: "Ana"))
        memory.began(ana, itemId: "item")
        XCTAssertEqual(memory.reply(forItem: "item", at: t0.addingTimeInterval(600)), ana, "still playing, however long it takes")
    }

    func testRecordingJustAfterItEndsAnswersIt() {
        let ana = draft("a1", from: layer("a", label: "Ana"))
        memory.began(ana, itemId: "item")
        memory.ended(at: t0.addingTimeInterval(30))
        XCTAssertEqual(memory.reply(forItem: "item", at: t0.addingTimeInterval(30)), ana, "the instant it ends")
        XCTAssertEqual(memory.reply(forItem: "item", at: t0.addingTimeInterval(30 + SharedMarginReplyMemory.window)), ana, "the last second counts")
    }

    func testRecordingAfterTheWindowIsIndependent() {
        let ana = draft("a1", from: layer("a", label: "Ana"))
        memory.began(ana, itemId: "item")
        memory.ended(at: t0)
        XCTAssertNil(memory.reply(forItem: "item", at: t0.addingTimeInterval(SharedMarginReplyMemory.window + 0.5)))
    }

    func testTwoSharedMarginsInARowAnswerTheLatestOne() {
        let ana = draft("a1", from: layer("a", label: "Ana"))
        let ben = draft("b1", from: layer("b", label: "Ben"))
        memory.began(ana, itemId: "item")
        memory.ended(at: t0.addingTimeInterval(10))
        memory.began(ben, itemId: "item")
        XCTAssertEqual(memory.reply(forItem: "item", at: t0.addingTimeInterval(12)), ben, "Ben's is playing, though Ana's ended 2 s ago")
        memory.ended(at: t0.addingTimeInterval(20))
        XCTAssertEqual(memory.reply(forItem: "item", at: t0.addingTimeInterval(25)), ben)
        XCTAssertNil(memory.reply(forItem: "item", at: t0.addingTimeInterval(20 + SharedMarginReplyMemory.window + 1)),
                     "Ana's window ended long ago and Ben's has too: nothing is left to answer")
    }

    func testAnotherItemIsNeverAnAnswer() {
        memory.began(draft("a1", from: layer("a", label: "Ana")), itemId: "item")
        XCTAssertNil(memory.reply(forItem: "other", at: t0))
    }

    func testAnEndWithNothingHeardChangesNothing() {
        memory.ended(at: t0)
        XCTAssertNil(memory.reply(forItem: "item", at: t0))
    }

    func testASecondEndDoesNotExtendTheWindow() {
        memory.began(draft("a1", from: layer("a", label: "Ana")), itemId: "item")
        memory.ended(at: t0)
        memory.ended(at: t0.addingTimeInterval(15)) // a stop path that runs twice
        XCTAssertNil(memory.reply(forItem: "item", at: t0.addingTimeInterval(SharedMarginReplyMemory.window + 1)))
    }

    func testAClockStepBackwardsStillCountsAsJustAfter() {
        let ana = draft("a1", from: layer("a", label: "Ana"))
        memory.began(ana, itemId: "item")
        memory.ended(at: t0.addingTimeInterval(5))
        XCTAssertEqual(memory.reply(forItem: "item", at: t0), ana)
    }

    func testTheToggleSwitchesBetweenReplyAndIndependentWithoutLosingTheParent() {
        let ana = draft("a1", from: layer("a", label: "Ana"))
        var choice = MarginReplyChoice(suggested: ana)
        XCTAssertEqual(choice.effective, ana)
        XCTAssertTrue(choice.canToggle)
        choice.toggle()
        XCTAssertNil(choice.effective)
        XCTAssertTrue(choice.isIndependent)
        XCTAssertTrue(choice.canToggle, "the way back stays")
        choice.toggle()
        XCTAssertEqual(choice.effective, ana)
    }

    func testAMarginWithNothingToAnswerHasNothingToToggle() {
        var choice = MarginReplyChoice(suggested: nil)
        XCTAssertNil(choice.effective)
        XCTAssertFalse(choice.canToggle)
        choice.toggle()
        XCTAssertFalse(choice.isIndependent, "no state to flip, so a later suggestion isn't pre-dismissed")
    }

    func testTheWordsNameTheStateAndTheWayToSwitchIt() {
        let ana = draft("a1", from: layer("a", label: "Ana"))
        var choice = MarginReplyChoice(suggested: ana)
        XCTAssertEqual(choice.caption, ana.caption)
        XCTAssertEqual(choice.switchTitle, "Make independent")
        choice.toggle()
        XCTAssertEqual(choice.caption, "Independent Margin, not a reply to Ana")
        XCTAssertEqual(choice.switchTitle, "Reply to Ana")
        XCTAssertNil(MarginReplyChoice().caption)
        XCTAssertNil(MarginReplyChoice().switchTitle)
    }
}
