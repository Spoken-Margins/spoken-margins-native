import XCTest
@testable import SessionKit

/// #147: the Margins tab's Share picked the newest session with any Margin, so a newer session holding
/// only a response Margin hid the older session's source Margins and the sheet refused to open.
final class ItemShareSessionSelectionTests: XCTestCase {
    func testSkipsANewerSessionWithOnlyResponseMargins() {
        let margins = ["new": [margin("r1", session: "new", target: .assistantTurn)],
                       "old": [margin("m1", session: "old")]]
        XCTAssertEqual(ItemShareSessionSelection.sessionId(newestFirst: ["new", "old"]) { margins[$0] ?? [] }, "old")
    }

    func testSkipsSessionsWhoseSourceMarginsAreAllDeleted() {
        let margins = ["new": [margin("m2", session: "new", status: "deleted")],
                       "old": [margin("m1", session: "old")]]
        XCTAssertEqual(ItemShareSessionSelection.sessionId(newestFirst: ["new", "old"]) { margins[$0] ?? [] }, "old")
    }

    func testPicksTheNewestSessionWithASourceMargin() {
        let margins = ["new": [margin("m2", session: "new")], "old": [margin("m1", session: "old")]]
        XCTAssertEqual(ItemShareSessionSelection.sessionId(newestFirst: ["new", "old"]) { margins[$0] ?? [] }, "new")
    }

    func testNoSessionWithASourceMarginGivesNil() {
        let margins = ["new": [margin("r1", session: "new", target: .assistantTurn)]]
        XCTAssertNil(ItemShareSessionSelection.sessionId(newestFirst: ["new", "empty"]) { margins[$0] ?? [] })
    }

    private func margin(
        _ id: String, session: String, target: InterjectionTargetType = .item, status: String = "active"
    ) -> Interjection {
        Interjection(
            id: id, itemId: "item", sessionId: session, targetType: target, targetId: target == .item ? "item" : "turn",
            createdAt: Date(timeIntervalSince1970: 0), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: id,
            cleanedTranscript: nil, displayText: id, status: status, captureKind: .written
        )
    }
}
