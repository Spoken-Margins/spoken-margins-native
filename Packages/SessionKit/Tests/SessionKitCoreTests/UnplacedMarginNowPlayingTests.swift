import Foundation
import XCTest
@testable import SessionKit

/// #4233, PR 3c: what Now Playing and the Timeline do with a Margin moved from a live session with no place on its item
/// (`Interjection.hasPlace == false`). Its stored zeros must never become a position: it sorts after every placed entry,
/// its corner says "No place", its row offers no Play, and no source-context job is started for it. A placed Margin is the
/// control in every row.
final class UnplacedMarginNowPlayingTests: XCTestCase {
    private func margin(unplaced: Bool = false, moved: Bool = false, mediaTimeMs: Int? = 90_000,
                        captureKind: InterjectionCaptureKind = .audio, targetType: InterjectionTargetType = .item) -> Interjection {
        var margin = Interjection(
            id: "m", itemId: "item", sessionId: "session", targetType: targetType, targetId: "item",
            createdAt: Date(timeIntervalSince1970: 1_780_000_000), roughPercent: unplaced ? 0 : 40,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "",
                           mediaTimeMs: unplaced ? (mediaTimeMs == nil ? nil : 0) : mediaTimeMs),
            audioPath: "SpokenMargins/interjections/m.m4a", audioStatus: "recorded", transcriptionStatus: "transcribed",
            transcript: "Words.", cleanedTranscript: nil, displayText: "Words.", status: "active", captureKind: captureKind)
        if unplaced || moved {
            margin.movedOrigin = MovedMarginOrigin(
                marginId: "m", itemId: "item", sessionId: "session", liveMarginId: "live-m", fromLiveSessionId: "live",
                fromLiveSessionTitle: "Quick session", sessionPlaceLabel: nil, markedAt: margin.createdAt,
                movedAt: margin.createdAt.addingTimeInterval(60), placeKnown: !unplaced)
        }
        return margin
    }

    /// The rail's own sort: an unplaced Margin's key against every kind of placed entry at the very end of the item.
    func testAMarginWithNoPlaceSortsAfterEveryPlacedEntryOnTheTimeline() {
        let unplaced = TimelineRailSortKey(position: MarginPlacePresentation.timelineSortPosition, rank: 1, id: "a-unplaced")
        let placedAtTheEnd: [(String, TimelineRailSortKey)] = [
            ("a chapter at 100%", TimelineRailSortKey(position: 100, rank: 0, id: "z-chapter", precisePosition: 100)),
            ("an own Margin at the very end", TimelineRailSortKey(position: 100, rank: 1, id: "z-own", precisePosition: 100)),
            ("a friend's Margin with no evidence (100)", TimelineRailSortKey(position: 100, rank: 1, id: "z-shared")),
            ("a reflection at its fallback 100", TimelineRailSortKey(position: 100, rank: 92, id: "z-turn", precisePosition: 100)),
            ("an own Margin at the start", TimelineRailSortKey(position: 0, rank: 1, id: "z-start", precisePosition: 0))
        ]
        for (name, placed) in placedAtTheEnd {
            XCTAssertLessThan(placed, unplaced, name)
        }
        XCTAssertGreaterThan(MarginPlacePresentation.timelineSortPosition, 100, "every placed position is clamped to 0...100")
    }

    func testTheTimelineCornerAndDetailSayNoPlaceNeverAZero() {
        let label = MarginPlacePresentation.timelineLabel
        for text in [label.corner, label.spoken, label.chapterDetail] {
            XCTAssertEqual(text, "No place")
            XCTAssertFalse(text.contains("%"))
            XCTAssertFalse(text.contains("0:00"))
            XCTAssertFalse(text.contains("101"))
        }
        XCTAssertEqual(MarginPlacePresentation.timelineDetail(for: margin(unplaced: true), position: 101), "No place")
        XCTAssertEqual(MarginPlacePresentation.timelineDetail(for: margin(), position: 40), "Captured at 40%")
        XCTAssertEqual(MarginPlacePresentation.timelineDetail(for: margin(moved: true), position: 40), "Captured at 40%",
                       "a Margin moved with a known place reads like one recorded there")
    }

    func testNowPlayingRowsOfferPlayOnlyForAMarginWithAPlace() {
        let table: [(String, Interjection, Bool)] = [
            ("recorded in place", margin(), true),
            ("moved with a known place", margin(moved: true), true),
            ("moved with no place, zero time stored", margin(unplaced: true), false),
            ("moved with no place, no time stored", margin(unplaced: true, mediaTimeMs: nil), false)
        ]
        for (name, margin, play) in table {
            XCTAssertEqual(MarginPlacePresentation.offersPlay(margin), play, name)
            XCTAssertEqual(MarginRowTap.action(for: margin) == .playMoment, play, "the row tap and Play agree: \(name)")
        }
    }

    func testNoSourceContextJobIsStartedForAMarginWithNoPlace() {
        let table: [(String, Interjection, Bool)] = [
            ("spoken, at a time", margin(), true),
            ("moved with a known place", margin(moved: true), true),
            ("moved with no place, zero time stored", margin(unplaced: true), false),
            ("moved with no place, no time stored", margin(unplaced: true, mediaTimeMs: nil), false),
            ("written", margin(captureKind: .written), false),
            ("a reply to a reflection", margin(targetType: .assistantTurn), false),
            ("spoken, no time", margin(mediaTimeMs: nil), false)
        ]
        for (name, margin, expected) in table {
            XCTAssertEqual(margin.canHaveSourceContext, expected, name)
        }
    }

    /// The Timeline's conversation order (`threadOrder`) comes from the thread rows: a Margin with no place, whose stored
    /// time is 0, follows the timed Margin instead of leading it.
    func testTheThreadOrderPutsAMarginWithNoPlaceAfterTheTimedOnes() {
        var unplaced = margin(unplaced: true)
        unplaced.id = "a-unplaced"
        var placed = margin()
        placed.id = "z-placed"
        placed.createdAt = unplaced.createdAt.addingTimeInterval(3_600)
        let rows = MarginThreadPresentation.rows(itemId: "item", localMargins: [unplaced, placed], layers: [], importedMargins: [])
        XCTAssertEqual(rows.map(\.reference), [.local("session::z-placed"), .local("session::a-unplaced")])
    }
}
