import Foundation
import SessionKit
import XCTest

/// #4233, PR 4: a Margin moved from a live session with no place on its item (`Interjection.hasPlace == false`) is never
/// carried by a packet. The rule is one function (`ShareableMargins`), used by the packet writer and the draft's own switch.
final class UnplacedMarginShareRuleTests: XCTestCase {
    private func margin(_ id: String, unplaced: Bool, starred: Bool = false) -> Interjection {
        var margin = Interjection(
            id: id, itemId: "item", sessionId: "session", targetType: .item, targetId: "item",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000), roughPercent: unplaced ? 0 : 30,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: unplaced ? 0 : 120_000),
            audioPath: "SpokenMargins/interjections/\(id).m4a", audioStatus: "recorded", transcriptionStatus: "transcribed",
            transcript: "Words for \(id).", cleanedTranscript: nil, displayText: "Words for \(id).", status: "active", captureKind: .audio)
        margin.isStarredForSharing = starred
        if unplaced {
            margin.movedOrigin = MovedMarginOrigin(
                marginId: id, itemId: "item", sessionId: "session", liveMarginId: "live-\(id)", fromLiveSessionId: "live",
                fromLiveSessionTitle: "Quick session", markedAt: margin.createdAt, movedAt: margin.createdAt, placeKnown: false)
        }
        return margin
    }

    func testFilterDropsAMarginWithNoPlaceAndKeepsEveryOtherInOrder() {
        let margins = [margin("a", unplaced: false), margin("b", unplaced: true), margin("c", unplaced: false), margin("d", unplaced: true)]
        XCTAssertEqual(ShareableMargins.filter(margins).map(\.id), ["a", "c"])
        XCTAssertEqual(ShareableMargins.filter(margins, margin: { $0 }).map(\.id), ["a", "c"])
        XCTAssertEqual(ShareableMargins.filter([margin("b", unplaced: true)]), [])
        XCTAssertEqual(ShareableMargins.filter([Interjection]()), [])
        // A Margin moved with a known place is shareable, like one recorded there.
        var movedPlaced = margin("m", unplaced: false)
        movedPlaced.movedOrigin = MovedMarginOrigin(
            marginId: "m", itemId: "item", sessionId: "session", liveMarginId: "l", fromLiveSessionId: "live",
            fromLiveSessionTitle: "Quick", markedAt: movedPlaced.createdAt, movedAt: movedPlaced.createdAt, placeKnown: true)
        XCTAssertEqual(ShareableMargins.filter([movedPlaced]).map(\.id), ["m"])
    }

    func testTheWordsAreTheOnesTheSheetShows() {
        XCTAssertEqual(ShareableMargins.noPlaceLine, "No place, so it can't be shared")
        XCTAssertEqual(ShareableMargins.allWithoutPlaceLine, "These Margins have no place, so they can't be shared.")
    }
}
