import Foundation
import XCTest
@testable import SessionKit

/// #458: Skim visits chapters and Margins in order, with a clamped lead-in before a Margin.
final class SkimStopsTests: XCTestCase {
    func testNoStops() {
        let skim = SkimStops(chapters: [], margins: [])
        XCTAssertNil(skim.next(playhead: 0))
        XCTAssertNil(skim.previous(playhead: 60_000))
    }

    func testChaptersOnlyHaveNoLeadIn() throws {
        let skim = SkimStops(chapters: [chapter("c2", 600_000), chapter("c1", 0), chapter("c3", 1_200_000)], margins: [])
        let next = try XCTUnwrap(skim.next(playhead: 0))
        XCTAssertEqual(next.stop.id, "c2", "the chapter at the playhead is not next")
        XCTAssertNil(next.leadInStart)
        XCTAssertEqual(next.startPosition, 600_000)
        XCTAssertEqual(skim.previous(playhead: 700_000)?.stop.id, "c2")
        XCTAssertNil(skim.next(playhead: 1_200_000))
    }

    func testMarginsOnlyGetAFullLeadIn() throws {
        let skim = SkimStops(chapters: [], margins: [margin("m2", 300_000), margin("m1", 120_000)])
        let first = try XCTUnwrap(skim.next(playhead: 0, leadInMs: 30_000))
        XCTAssertEqual(first.stop.id, "m1")
        XCTAssertEqual(first.leadInStart, 90_000)
        XCTAssertFalse(first.isLeadInClamped)

        let second = try XCTUnwrap(skim.next(playhead: 120_000, current: first.stop, leadInMs: 60_000))
        XCTAssertEqual(second.stop.id, "m2")
        XCTAssertEqual(second.leadInStart, 240_000)
    }

    func testInterleavedStopsAreEachVisitedOnceInOrder() {
        let skim = SkimStops(
            chapters: [chapter("intro", 0), chapter("part-2", 900_000), chapter("part-3", 1_800_000)],
            margins: [margin("late", 2_000_000), margin("same-as-part-2", 900_000), margin("early", 400_000), margin("mid", 1_300_000)]
        )
        var visited: [String] = []
        var playhead = 0
        var current: SkimStop?
        while let target = skim.next(playhead: playhead, current: current) {
            visited.append(target.stop.id)
            XCTAssertLessThanOrEqual(visited.count, 10, "Skim looped")
            if visited.count > 10 { break }
            // The listener sits through the lead-in and plays on a little past the stop.
            playhead = target.stop.position + 500
            current = target.stop
        }
        XCTAssertEqual(visited, ["early", "part-2", "same-as-part-2", "mid", "part-3", "late"])
    }

    func testAStopListedTwiceIsVisitedOnce() {
        let skim = SkimStops(chapters: [chapter("c1", 50_000), chapter("c1", 50_000)], margins: [margin("x", 100_000), margin("x", 100_000)])
        XCTAssertEqual(skim.stops.map(\.id), ["c1", "x"])
        XCTAssertNil(skim.next(playhead: 100_000, current: margin("x", 100_000)))
    }

    func testOddInputsDoNotCrash() {
        let negative = SkimStops(chapters: [], margins: [SkimStop(kind: .margin, id: "m", position: -5)])
        XCTAssertEqual(negative.stops.first?.position, 0)
        XCTAssertNil(negative.next(playhead: 0, current: negative.stops.first))
        let text = SkimStops(chapters: [], margins: [margin("m", 10)], unit: .characters(perSecond: .infinity))
        XCTAssertEqual(text.next(playhead: 0)?.leadInStart, 10)
    }

    func testSecondPressDuringTheLeadInGoesStraightToTheMargin() throws {
        let skim = SkimStops(chapters: [], margins: [margin("m1", 120_000), margin("m2", 400_000)])
        let first = try XCTUnwrap(skim.next(playhead: 0))
        XCTAssertEqual(first.startPosition, 90_000)
        let second = try XCTUnwrap(skim.next(playhead: 95_000, current: first.stop))
        XCTAssertEqual(second.stop.id, "m1")
        XCTAssertNil(second.leadInStart)
        XCTAssertEqual(second.startPosition, 120_000)
    }

    func testAMarginTenSecondsInIsClampedAtTheItemStart() throws {
        let skim = SkimStops(chapters: [], margins: [margin("m1", 10_000)])
        let target = try XCTUnwrap(skim.next(playhead: 0, leadInMs: 30_000))
        XCTAssertEqual(target.leadInStart, 0)
        XCTAssertEqual(target.leadInClamp, .itemStart)
    }

    func testLeadInIsClampedAtThePreviousStop() throws {
        let skim = SkimStops(chapters: [chapter("c1", 100_000)], margins: [margin("m1", 115_000)])
        let target = try XCTUnwrap(skim.next(playhead: 100_000, current: .chapter(MediaTimelineChapter(id: "c1", title: "c1", startMs: 100_000, transcriptSegmentId: "s"))))
        XCTAssertEqual(target.stop.id, "m1")
        XCTAssertEqual(target.leadInStart, 100_000)
        XCTAssertEqual(target.leadInClamp, .previousStop(SkimStop(kind: .chapter, id: "c1", position: 100_000)))
    }

    func testTwoMarginsAtTheSamePositionAreBothVisited() throws {
        let skim = SkimStops(chapters: [], margins: [margin("b", 200_000), margin("a", 200_000)])
        let first = try XCTUnwrap(skim.next(playhead: 0))
        XCTAssertEqual(first.stop.id, "a")
        XCTAssertEqual(first.leadInStart, 170_000)
        let second = try XCTUnwrap(skim.next(playhead: 200_500, current: first.stop))
        XCTAssertEqual(second.stop.id, "b")
        XCTAssertEqual(second.leadInStart, 200_000, "no lead-in: the previous stop is at the same place")
        XCTAssertEqual(second.leadInClamp, .previousStop(first.stop))
        XCTAssertNil(skim.next(playhead: 200_000, current: second.stop))
        XCTAssertEqual(skim.previous(playhead: 200_000, current: second.stop)?.stop.id, "a")
    }

    func testBackwardFromTheMiddle() throws {
        let skim = SkimStops(
            chapters: [chapter("c1", 0), chapter("c2", 600_000)],
            margins: [margin("m1", 300_000), margin("m2", 900_000)]
        )
        let back = try XCTUnwrap(skim.previous(playhead: 700_000))
        XCTAssertEqual(back.stop.id, "c2")
        let further = try XCTUnwrap(skim.previous(playhead: back.startPosition, current: back.stop))
        XCTAssertEqual(further.stop.id, "m1")
        XCTAssertEqual(further.leadInStart, 270_000)
        let again = try XCTUnwrap(skim.previous(playhead: further.startPosition, current: further.stop))
        XCTAssertEqual(again.stop.id, "c1", "from m1's lead-in, back goes before m1, not to it again")
        XCTAssertNil(skim.previous(playhead: 0, current: again.stop))
    }

    func testLeadInLengthIsClampedToThirtySecondsThroughTwoMinutes() throws {
        let skim = SkimStops(chapters: [], margins: [margin("m1", 600_000)])
        XCTAssertEqual(skim.next(playhead: 0, leadInMs: 5_000)?.leadInStart, 570_000)
        XCTAssertEqual(skim.next(playhead: 0, leadInMs: 90_000)?.leadInStart, 510_000)
        XCTAssertEqual(skim.next(playhead: 0, leadInMs: 600_000)?.leadInStart, 480_000)

        let text = SkimStops(chapters: [.chapter(Chapter(id: "c1", title: "One", startChar: 0, endChar: 4_000, percent: 0))],
                             margins: [SkimStop(kind: .margin, id: "m1", position: 3_000)],
                             unit: .characters(perSecond: 15))
        XCTAssertEqual(text.next(playhead: 0)?.leadInStart, 2_550, "30 s at 15 characters a second")
    }

    func testSharedMarginsUseTheListenersPosition() {
        let placed = ImportedCommentaryInterjection(
            id: "shared", layerId: "l", packageScopedId: "shared", createdAt: Date(timeIntervalSince1970: 0),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 50_000),
            approvedTranscript: "Nice", resolution: .init(evidenceClass: .acousticVerified, localMediaTimeMs: 52_000)
        )
        XCTAssertEqual(SkimStop.margin(placed, unit: .milliseconds)?.position, 52_000)
    }

    private func chapter(_ id: String, _ ms: Int) -> SkimStop {
        .chapter(MediaTimelineChapter(id: id, title: id, startMs: ms, transcriptSegmentId: "segment-\(id)"))
    }

    private func margin(_ id: String, _ ms: Int) -> SkimStop {
        SkimStop(kind: .margin, id: id, position: ms)
    }
}
