import Foundation
import XCTest
@testable import SessionKit

/// #460: Skim goes to the next chapter or Margin, whichever comes first; a second press during a Margin's lead-in plays
/// the Margin; where nothing is ahead but a scene summary, Skim keeps today's behavior.
final class SkimStopRoutingTests: XCTestCase {
    private func chapter(_ id: String, _ ms: Int) -> SkimStop {
        .chapter(MediaTimelineChapter(id: id, title: id, startMs: ms, transcriptSegmentId: "segment-\(id)"))
    }

    private func margin(_ id: String, _ ms: Int) -> SkimStop {
        SkimStop(kind: .margin, id: id, position: ms)
    }

    private func target(_ stop: SkimStop, leadIn: Int? = nil) -> SkimStops.Target {
        SkimStops.Target(stop: stop, leadInStart: leadIn, leadInClamp: nil)
    }

    // MARK: Every item kind with chapters has a stop behind it in a middle chapter (#3865)

    /// The owner's text item: chapters at 0, 56, 65 and 74 percent, playing at 47%. The chapter row's back arrow is
    /// Skim back, so it is bright only when a stop is behind the playhead. Chapter starts are stops for text (by
    /// character) and for media (by millisecond) alike, with no Margins, no map and no summary.
    func testChapterStartsAreStopsBehindAndAheadOnEveryItemKind() throws {
        let percents = [0, 56, 65, 74]
        let textChapters = percents.enumerated().map { index, percent in
            Chapter(id: "c\(index)", title: "Chapter \(index)", startChar: percent * 100,
                    endChar: (index + 1 < percents.count ? percents[index + 1] : 100) * 100, percent: percent)
        }
        let mediaChapters = percents.enumerated().map { index, percent in
            MediaTimelineChapter(id: "c\(index)", title: "Chapter \(index)", startMs: percent * 10_000,
                                 transcriptSegmentId: "segment-\(index)")
        }
        let text = SkimStopRouting.stops(textChapters: textChapters, mediaChapters: [], ownMargins: [], sharedMargins: [],
                                         unit: .characters(perSecond: 15))
        let media = SkimStopRouting.stops(textChapters: [], mediaChapters: mediaChapters, ownMargins: [], sharedMargins: [],
                                          unit: .milliseconds)
        for (name, stops, scale) in [("text", text, 100), ("media", media, 10_000)] {
            // 47%: the first chapter's start is behind, the 56% chapter ahead.
            XCTAssertEqual(stops.previous(playhead: 47 * scale)?.stop.id, "c0", "\(name) at 47%")
            XCTAssertEqual(stops.next(playhead: 47 * scale)?.stop.id, "c1", "\(name) at 47%")
            // 60%: in the 56% chapter, so its own start is behind and 65% ahead.
            XCTAssertEqual(stops.previous(playhead: 60 * scale)?.stop.id, "c1", "\(name) at 60%")
            XCTAssertEqual(stops.next(playhead: 60 * scale)?.stop.id, "c2", "\(name) at 60%")
            // 99%: the last chapter is past its start: back goes to it, nothing ahead.
            XCTAssertEqual(stops.previous(playhead: 99 * scale)?.stop.id, "c3", "\(name) at 99%")
            XCTAssertNil(stops.next(playhead: 99 * scale), "\(name) at 99%")
            // the very start of the first chapter: nothing behind.
            XCTAssertNil(stops.previous(playhead: 0), "\(name) at 0%")
        }
    }

    // MARK: Choosing between a stop and the summary

    func testAChapterWithNoSummaryPlanIsAStop() {
        let next = target(chapter("c2", 600_000))
        XCTAssertEqual(SkimStopRouting.choose(direction: .forward, stop: next, summaryDestination: nil), .stop(next))
    }

    func testAChapterYieldsToTheSummaryThatEndsAtAScene() {
        let next = target(chapter("c2", 600_000))
        XCTAssertEqual(SkimStopRouting.choose(direction: .forward, stop: next, summaryDestination: 590_000), .summary)
    }

    func testAMarginBeforeTheSummaryLandingWins() {
        let next = target(margin("m", 300_000), leadIn: 270_000)
        XCTAssertEqual(SkimStopRouting.choose(direction: .forward, stop: next, summaryDestination: 600_000), .stop(next))
    }

    func testAMarginAfterTheSummaryLandingLeavesTheSummary() {
        let next = target(margin("m", 900_000), leadIn: 870_000)
        XCTAssertEqual(SkimStopRouting.choose(direction: .forward, stop: next, summaryDestination: 600_000), .summary)
    }

    func testBackwardPicksTheMarginNearerThePlayhead() {
        let near = target(margin("m", 500_000), leadIn: 470_000)
        XCTAssertEqual(SkimStopRouting.choose(direction: .backward, stop: near, summaryDestination: 300_000), .stop(near))
        let far = target(margin("m", 100_000), leadIn: 70_000)
        XCTAssertEqual(SkimStopRouting.choose(direction: .backward, stop: far, summaryDestination: 300_000), .summary)
    }

    func testNothingAheadKeepsTodaysSummaryAndNothingAtAllIsUnavailable() {
        XCTAssertEqual(SkimStopRouting.choose(direction: .forward, stop: nil, summaryDestination: 600_000), .summary)
        XCTAssertEqual(SkimStopRouting.choose(direction: .forward, stop: nil, summaryDestination: nil), .unavailable)
    }

    func testTheControlShowsTheMarginNotItsLeadIn() {
        let next = target(margin("m", 300_000), leadIn: 270_000)
        XCTAssertEqual(SkimStopRouting.Choice.stop(next).destination(summaryDestination: 600_000), 300_000)
        XCTAssertEqual(SkimStopRouting.Choice.summary.destination(summaryDestination: 600_000), 600_000)
        XCTAssertNil(SkimStopRouting.Choice.unavailable.destination(summaryDestination: 600_000))
    }

    // MARK: A running moment

    func testASecondForwardPressDuringTheLeadInPlaysTheMarginAndDuringItsVoiceEndsIt() {
        XCTAssertEqual(SkimStopRouting.press(direction: .forward, moment: .none), .navigate)
        XCTAssertEqual(SkimStopRouting.press(direction: .forward, moment: .leadIn), .playMarginNow)
        XCTAssertEqual(SkimStopRouting.press(direction: .forward, moment: .voice), .skipVoice)
    }

    func testBackEndsARunningMomentThenGoesBack() {
        XCTAssertEqual(SkimStopRouting.press(direction: .backward, moment: .none), .navigate)
        XCTAssertEqual(SkimStopRouting.press(direction: .backward, moment: .leadIn), .endMomentThenNavigate)
        XCTAssertEqual(SkimStopRouting.press(direction: .backward, moment: .voice), .endMomentThenNavigate)
    }

    func testTheMomentStateFollowsTheSequencePhaseAndWhereTheSourceIs() {
        XCTAssertEqual(SkimStopRouting.MomentState(nil, positionMs: 0), .none)
        var sequence = MarginMomentSequence(
            itemId: "i", target: MarginMomentAnchor(marginId: "m", mediaTimeMs: 100_000), otherMargins: [])
        XCTAssertEqual(SkimStopRouting.MomentState(sequence, positionMs: 80_000), .leadIn)
        XCTAssertEqual(SkimStopRouting.MomentState(sequence, positionMs: nil), .leadIn)
        // The listener scrubbed or jumped a chapter away: the old lead-in no longer waits on a press.
        XCTAssertEqual(SkimStopRouting.MomentState(sequence, positionMs: 500_000), .staleLeadIn)
        XCTAssertEqual(SkimStopRouting.MomentState(sequence, positionMs: 10_000), .staleLeadIn)
        _ = sequence.jumpToTarget()
        XCTAssertEqual(SkimStopRouting.MomentState(sequence, positionMs: 500_000), .voice)
    }

    func testAStaleLeadInEndsAndTheNextStopIsFound() {
        XCTAssertEqual(SkimStopRouting.press(direction: .forward, moment: .staleLeadIn), .endMomentThenNavigate)
        XCTAssertEqual(SkimStopRouting.press(direction: .backward, moment: .staleLeadIn), .endMomentThenNavigate)
    }

    // MARK: Starting a Margin stop

    func testAMarginAheadOfItsLeadInStartsALeadInAndOneInsideItPlaysNow() {
        let skim = SkimStops(chapters: [], margins: [margin("m1", 100_000), margin("m2", 110_000)])
        let farAhead = skim.next(playhead: 0)!
        XCTAssertEqual(SkimStopRouting.startAction(playhead: 0, target: farAhead), .leadIn)
        // Scenario: m1 just played; the source is at 100.4 s and m2 is 10 s away. The lead-in is clamped to m1, so
        // it is already inside: play m2 now, never seeking back to 80 s where m1 would play again.
        let second = skim.next(playhead: 100_400)!
        XCTAssertEqual(second.stop.id, "m2")
        XCTAssertEqual(second.leadInStart, 100_000)
        XCTAssertEqual(SkimStopRouting.startAction(playhead: 100_400, target: second), .playNow)
        // A forward press at 90 s with m1 at 100 s: 10 s from the Margin, so no seek back to 70 s.
        let near = skim.next(playhead: 90_000)!
        XCTAssertEqual(SkimStopRouting.startAction(playhead: 90_000, target: near), .playNow)
    }

    // MARK: Walking the interleaved list

    /// Each press from a stop leaves the listener where the next press finds the following stop: a Margin's lead-in
    /// press, then the second press that plays it, then the next stop after it.
    func testRepeatedSkimVisitsChaptersAndMarginsInOrderAndBackAgain() throws {
        let skim = SkimStops(
            chapters: [chapter("intro", 0), chapter("part-2", 900_000)],
            margins: [margin("early", 400_000), margin("late", 1_300_000)])
        var visited: [String] = []
        var playhead = 0
        var moment = SkimStopRouting.MomentState.none
        for _ in 0..<12 {
            switch SkimStopRouting.press(direction: .forward, moment: moment) {
            case .playMarginNow:
                // The Margin plays, then the source carries on a little past it.
                moment = .none
                playhead += 40_000
                continue
            case .skipVoice, .endMomentThenNavigate: XCTFail("unexpected")
            case .navigate: break
            }
            guard let next = skim.next(playhead: playhead) else { break }
            visited.append(next.stop.id)
            playhead = next.startPosition
            if next.stop.kind == .margin {
                moment = .leadIn
                // The listener presses Skim again during the lead-in: it goes straight to the Margin.
                XCTAssertEqual(next.leadInStart, next.stop.position - SkimStops.minimumLeadInMs)
                playhead = next.stop.position
            }
        }
        XCTAssertEqual(visited, ["early", "part-2", "late"])
        XCTAssertEqual(skim.previous(playhead: 1_400_000)?.stop.id, "late")
        XCTAssertEqual(skim.previous(playhead: 1_000_000)?.stop.id, "part-2")
        XCTAssertEqual(skim.previous(playhead: 100_000)?.stop.id, "intro")
    }

    // MARK: Building the list

    func testTextItemsStopAtCharactersAndMediaItemsAtMilliseconds() throws {
        let media = SkimStopRouting.stops(
            textChapters: [], mediaChapters: [MediaTimelineChapter(id: "m1", title: "One", startMs: 30_000, transcriptSegmentId: "s")],
            ownMargins: [], sharedMargins: [], unit: .milliseconds)
        XCTAssertEqual(media.stops.map(\.position), [30_000])
        let text = SkimStopRouting.stops(
            textChapters: [], mediaChapters: [MediaTimelineChapter(id: "m1", title: "One", startMs: 30_000, transcriptSegmentId: "s")],
            ownMargins: [], sharedMargins: [], unit: .characters(perSecond: 15))
        XCTAssertTrue(text.stops.isEmpty, "a text item doesn't stop at a media chapter")
    }
}
