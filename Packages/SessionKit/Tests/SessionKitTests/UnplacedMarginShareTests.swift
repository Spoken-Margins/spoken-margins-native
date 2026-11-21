import Foundation
import SessionKit
import SessionKitSharing
import XCTest

/// #4233, PR 4: a Margin moved from a live session with no place on its item (`Interjection.hasPlace == false`) is never
/// carried by a packet. The rule is one function (`ShareableMargins`) used by the packet writer and the draft's own switch,
/// so "Select all shown", a tap on its row, a starred Margin and a re-share all end in the same place: not included.
final class UnplacedMarginShareTests: XCTestCase {
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

    private func draft(_ margin: Interjection, included: Bool = true) -> ShareInterjectionDraft {
        ShareInterjectionDraft.initial(for: margin, isIncluded: included, hasVoice: true, itemTitle: "Episode")
    }

    func testAStarredMarginWithNoPlaceStartsUntickedAndSaysWhy() {
        let starred = draft(margin("s", unplaced: true, starred: true), included: true)
        XCTAssertFalse(starred.isIncluded, "the sheet ticks starred Margins by default; this one has no place")
        XCTAssertEqual(starred.warning, ShareableMargins.noPlaceLine)
        let placed = draft(margin("p", unplaced: false, starred: true), included: true)
        XCTAssertTrue(placed.isIncluded, "a placed starred Margin still starts ticked")
        XCTAssertNil(placed.warning)
    }

    func testTheMemberwiseInitCannotIncludeAMarginWithNoPlaceEither() {
        let direct = ShareInterjectionDraft(
            interjection: margin("u", unplaced: true), approvedTranscript: "Words.", representationChoice: .textOnly,
            anchorBefore: "", anchorAfter: "")
        XCTAssertFalse(direct.isIncluded, "isIncluded defaults to true; a Margin with no place is still out")
        let placed = ShareInterjectionDraft(
            interjection: margin("p", unplaced: false), approvedTranscript: "Words.", representationChoice: .textOnly,
            anchorBefore: "", anchorAfter: "")
        XCTAssertTrue(placed.isIncluded)
    }

    func testNothingCanSwitchAMarginWithNoPlaceOn() {
        var unplaced = draft(margin("u", unplaced: true), included: false)
        unplaced.setIncluded(true) // a tap on the row, its switch, "Select all shown"
        XCTAssertFalse(unplaced.isIncluded)
        var placed = draft(margin("p", unplaced: false), included: false)
        placed.setIncluded(true)
        XCTAssertTrue(placed.isIncluded)
        placed.setIncluded(false)
        XCTAssertFalse(placed.isIncluded)
    }

    func testTheCountCountsOnlyWhatAPacketCanCarry() {
        // "Select all shown" over one placed and one unplaced Margin: the sheet's counts come from the included drafts.
        var drafts = [draft(margin("p", unplaced: false), included: false), draft(margin("u", unplaced: true), included: false)]
        for index in drafts.indices { drafts[index].setIncluded(true) }
        let summary = SharedMarginSelectionSummary(drafts, isIncluded: \.isIncluded, text: \.approvedTranscript)
        XCTAssertEqual(summary.packetCount, 1)
        XCTAssertEqual(summary.leftOutCount, 0)
        XCTAssertEqual(drafts.filter(\.isIncluded).map(\.id), ["p"])
        XCTAssertEqual(ShareableMargins.filter(drafts.filter(\.isIncluded), margin: \.interjection).map(\.id), ["p"])
        // Every Margin listed has no place: nothing is selectable.
        let none = [draft(margin("u1", unplaced: true)), draft(margin("u2", unplaced: true))]
        XCTAssertEqual(none.filter(\.isIncluded).count, 0)
        XCTAssertEqual(ShareableMargins.filter(none, margin: \.interjection).count, 0)
    }
}
