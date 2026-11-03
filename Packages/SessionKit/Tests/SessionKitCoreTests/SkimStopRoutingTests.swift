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

    func testTheMomentStateFollowsTheSequencePhase() {
        XCTAssertEqual(SkimStopRouting.MomentState(nil), .none)
        var sequence = MarginMomentSequence(
            itemId: "i", target: MarginMomentAnchor(marginId: "m", mediaTimeMs: 100_000), otherMargins: [])
        XCTAssertEqual(SkimStopRouting.MomentState(sequence), .leadIn)
        _ = sequence.jumpToTarget()
        XCTAssertEqual(SkimStopRouting.MomentState(sequence), .voice)
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
