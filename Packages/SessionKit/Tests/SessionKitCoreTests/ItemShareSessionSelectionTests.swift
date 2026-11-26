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

    /// #4233: a newer session holding only Margins with no place must not hide an older session a packet can carry; if
    /// there is nothing better it is still opened, so the sheet can say why nothing can be shared.
    func testPrefersASessionWithAPlacedMarginOverANewerOneWithOnlyUnplacedMargins() {
        func unplaced(_ id: String, session: String) -> Interjection {
            var m = margin(id, session: session)
            m.movedOrigin = MovedMarginOrigin(
                marginId: id, itemId: "item", sessionId: session, liveMarginId: "l", fromLiveSessionId: "live",
                fromLiveSessionTitle: "Quick", markedAt: m.createdAt, movedAt: m.createdAt, placeKnown: false)
            return m
        }
        let mixed = ["new": [unplaced("u", session: "new")], "old": [margin("m1", session: "old")]]
        XCTAssertEqual(ItemShareSessionSelection.sessionId(newestFirst: ["new", "old"]) { mixed[$0] ?? [] }, "old")
        let onlyUnplaced = ["new": [unplaced("u", session: "new")], "old": [unplaced("v", session: "old")]]
        XCTAssertEqual(ItemShareSessionSelection.sessionId(newestFirst: ["new", "old"]) { onlyUnplaced[$0] ?? [] }, "new",
                       "nothing better: the newest session opens and the sheet explains")
        let bothPlaced = ["new": [margin("m2", session: "new")], "old": [margin("m1", session: "old")]]
        XCTAssertEqual(ItemShareSessionSelection.sessionId(newestFirst: ["new", "old"]) { bothPlaced[$0] ?? [] }, "new")
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
