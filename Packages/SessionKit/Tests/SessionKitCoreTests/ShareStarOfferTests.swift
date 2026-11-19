import XCTest
@testable import SessionKit

/// #4173: which Margin rows on the playback screen show the sharing star. Share sends only Margins on the source itself, so a
/// Margin on a summary or an assistant reply has no star. Each row of the table is a Margin the player can list.
final class ShareStarOfferTests: XCTestCase {
    func testOnlyAMarginOnTheSourceIsOfferedTheStar() {
        let table: [(InterjectionTargetType, Bool)] = [(.item, true), (.summaryTurn, false), (.assistantTurn, false)]
        for (target, offered) in table {
            XCTAssertEqual(margin(target: target).isOfferedShareStar, offered, "\(target)")
        }
    }

    /// The star must never be offered on a Margin the Share sheet would drop, and never withheld from one it would list.
    func testTheOfferAgreesWithTheSheetsFilterForEveryTarget() {
        for target in [InterjectionTargetType.item, .summaryTurn, .assistantTurn] {
            let m = margin(target: target)
            XCTAssertEqual(m.isOfferedShareStar, ItemShareSessionSelection.isShareable(m), "\(target)")
        }
    }

    /// Offering the star doesn't depend on whether it is on: a starred and an unstarred Margin are both offered.
    func testAStarredAndAnUnstarredMarginAreBothOffered() {
        var starred = margin(target: .item)
        starred.isStarredForSharing = true
        XCTAssertTrue(starred.isOfferedShareStar)
        XCTAssertTrue(margin(target: .item).isOfferedShareStar)
    }

    private func margin(target: InterjectionTargetType) -> Interjection {
        Interjection(
            id: "m", itemId: "item", sessionId: "session", targetType: target, targetId: target == .item ? "item" : "turn",
            createdAt: Date(timeIntervalSince1970: 0), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: "m",
            cleanedTranscript: nil, displayText: "m", status: "active", captureKind: .written
        )
    }
}
