import Foundation
import XCTest
@testable import SessionKit

/// "Play this moment" (#159): lead in, play the Margin when playback reaches it, continue with the others.
final class MarginMomentTests: XCTestCase {
    private let target = MarginMomentAnchor(marginId: "ij-003", mediaTimeMs: 120_000)

    func testStartsThirtySecondsBeforeTheMarginAndClampsAtTheStart() {
        XCTAssertEqual(MarginMomentSequence(itemId: "ep", target: target, otherMargins: []).startMediaTimeMs, 90_000)
        let early = MarginMomentAnchor(marginId: "ij-001", mediaTimeMs: 5_000)
        XCTAssertEqual(MarginMomentSequence(itemId: "ep", target: early, otherMargins: []).startMediaTimeMs, 0)
    }

    func testPlaysTheMarginWhenPlaybackReachesItThenReturnsToListening() {
        var sequence = MarginMomentSequence(itemId: "ep", target: target, otherMargins: [])
        XCTAssertEqual(sequence.msUntilTarget(currentMediaTimeMs: 90_000), 30_000)
        XCTAssertNil(sequence.progressed(from: 118_500, to: 119_500))
        XCTAssertEqual(sequence.progressed(from: 119_500, to: 120_000), target)
        XCTAssertEqual(sequence.phase, .playingMargin("ij-003"))
        XCTAssertNil(sequence.progressed(from: 120_000, to: 120_500), "nothing else plays while a Margin plays")
        sequence.marginFinished()
        XCTAssertEqual(sequence.phase, .listening)
        XCTAssertNil(sequence.progressed(from: 119_000, to: 121_000), "a played Margin doesn't replay")
    }

    func testDefaultLeadInReachesTheChosenMarginAfterThirtySecondsOfSourcePlayback() {
        var sequence = MarginMomentSequence(itemId: "ep", target: target, otherMargins: [])
        let start = sequence.startMediaTimeMs
        XCTAssertEqual(target.mediaTimeMs - start, 30_000)
        for elapsed in stride(from: 500, through: 29_500, by: 500) {
            XCTAssertNil(sequence.progressed(from: start + elapsed - 500, to: start + elapsed))
        }
        XCTAssertEqual(sequence.progressed(from: start + 29_500, to: start + 30_000), target)
        XCTAssertEqual(sequence.phase, .playingMargin(target.marginId))
    }

    func testComingUpCountdownFollowsSourceProgressAndDisappearsDuringTheMargin() {
        var sequence = MarginMomentSequence(itemId: "ep", target: target, otherMargins: [])
        let readings: [(Int?, String?)] = [
            (nil, "0:30"), (90_000, "0:30"), (90_001, "0:30"),
            (91_000, "0:29"), (119_001, "0:01"), (120_000, "0:00"), (120_001, nil)
        ]
        for (position, expected) in readings {
            XCTAssertEqual(sequence.targetCountdown(currentMediaTimeMs: position), expected, "position: \(String(describing: position))")
        }
        XCTAssertEqual(sequence.jumpToTarget(), target)
        XCTAssertNil(sequence.targetCountdown(currentMediaTimeMs: 120_000))
        XCTAssertNil(sequence.targetCountdown(currentMediaTimeMs: nil))
        sequence.marginFinished()
        XCTAssertNil(sequence.targetCountdown(currentMediaTimeMs: 120_000))
    }

    func testComingUpCountdownUsesTheClampedLeadInNearTheSourceStart() {
        let early = MarginMomentAnchor(marginId: "early", mediaTimeMs: 5_000)
        let sequence = MarginMomentSequence(itemId: "ep", target: early, otherMargins: [])
        XCTAssertEqual(sequence.targetCountdown(currentMediaTimeMs: nil), "0:05")
        XCTAssertEqual(sequence.targetCountdown(currentMediaTimeMs: 2_500), "0:03")
    }

    func testSkippingOverTheMarginDoesNotPlayIt() {
        var sequence = MarginMomentSequence(itemId: "ep", target: target, otherMargins: [])
        XCTAssertNil(sequence.progressed(from: 100_000, to: 130_000), "a 30 s skip is a seek, not playback")
        XCTAssertNil(sequence.msUntilTarget(currentMediaTimeMs: 130_000))
        XCTAssertEqual(sequence.progressed(from: 119_000, to: 120_200), target, "seeking back and playing through works")
    }

    func testPlayItNowSkipsTheLeadInAndEarlierMargins() {
        let during = MarginMomentAnchor(marginId: "ij-002", mediaTimeMs: 116_000)
        let later = MarginMomentAnchor(marginId: "ij-004", mediaTimeMs: 200_000)
        var sequence = MarginMomentSequence(itemId: "ep", target: target, otherMargins: [during, later])
        XCTAssertEqual(sequence.jumpToTarget(), target)
        sequence.marginFinished()
        XCTAssertEqual(sequence.unplayed, [later])
        XCTAssertNil(sequence.jumpToTarget(), "only during the lead-in")
    }

    func testOtherMarginsPlayAsTheyComeUpButNotOnesBeforeTheLeadIn() {
        let before = MarginMomentAnchor(marginId: "ij-001", mediaTimeMs: 10_000)
        let during = MarginMomentAnchor(marginId: "ij-002", mediaTimeMs: 116_000)
        let later = MarginMomentAnchor(marginId: "ij-004", mediaTimeMs: 200_000)
        var sequence = MarginMomentSequence(itemId: "ep", target: target, otherMargins: [later, before, during, target])
        XCTAssertEqual(sequence.unplayed.map(\.marginId), ["ij-002", "ij-003", "ij-004"])

        XCTAssertEqual(sequence.progressed(from: 115_800, to: 116_300), during)
        sequence.marginFinished()
        XCTAssertEqual(sequence.phase, .leadIn, "the chosen Margin is still ahead")
        XCTAssertEqual(sequence.progressed(from: 119_800, to: 120_300), target)
        sequence.marginFinished()
        XCTAssertEqual(sequence.progressed(from: 199_800, to: 200_300), later)
        sequence.marginFinished()
        XCTAssertEqual(sequence.phase, .listening)
        XCTAssertTrue(sequence.unplayed.isEmpty)
    }

    /// #1538: the listener heard one of their own Margins from its detail and the source comes back where it was.
    func testResumingAfterAHeardMarginPlaysOnlyTheLaterMarginsWithNoLeadIn() {
        let heard = MarginMomentAnchor(marginId: "ij-003", mediaTimeMs: 20_000)
        let earlier = MarginMomentAnchor(marginId: "ij-001", mediaTimeMs: 10_000)
        let sameSpot = MarginMomentAnchor(marginId: "ij-002", mediaTimeMs: 60_000)
        let later = MarginMomentAnchor(marginId: "ij-004", mediaTimeMs: 90_000)
        let latest = MarginMomentAnchor(marginId: "ij-005", mediaTimeMs: 150_000)
        var sequence = MarginMomentSequence(
            itemId: "ep", resumingAtMediaTimeMs: 60_000, playedMargin: heard,
            otherMargins: [latest, heard, later, sameSpot, earlier]
        )
        XCTAssertEqual(sequence.phase, .listening, "no lead-in")
        XCTAssertEqual(sequence.startMediaTimeMs, 60_000, "it carries on from where the source is, not from a lead-in")
        XCTAssertNil(sequence.msUntilTarget(currentMediaTimeMs: 59_000))
        XCTAssertEqual(sequence.unplayed.map(\.marginId), ["ij-004", "ij-005"],
                       "not the Margin just heard, and not ones at or before the resume point")

        XCTAssertNil(sequence.progressed(from: 60_000, to: 60_500))
        XCTAssertEqual(sequence.progressed(from: 89_800, to: 90_300), later)
        sequence.marginFinished()
        XCTAssertEqual(sequence.phase, .listening, "the Margin just heard is never ahead again")
        XCTAssertEqual(sequence.progressed(from: 149_800, to: 150_300), latest)
        sequence.marginFinished()
        XCTAssertTrue(sequence.unplayed.isEmpty)
    }

    func testResumingWithNothingLaterLeavesNothingToPlay() {
        let heard = MarginMomentAnchor(marginId: "ij-003", mediaTimeMs: 20_000)
        let sequence = MarginMomentSequence(itemId: "ep", resumingAtMediaTimeMs: 60_000, playedMargin: heard, otherMargins: [heard])
        XCTAssertTrue(sequence.unplayed.isEmpty)
        XCTAssertEqual(sequence.phase, .listening)
    }

    func testCrossingMatchesSharedMarginSemanticsWithoutALimit() {
        XCTAssertTrue(PlaybackAnchorCrossing.isCrossed(anchor: 5, before: 5, after: 6))
        XCTAssertTrue(PlaybackAnchorCrossing.isCrossed(anchor: 6, before: 5, after: 6))
        XCTAssertFalse(PlaybackAnchorCrossing.isCrossed(anchor: 5, before: 5, after: 5), "no forward movement")
        XCTAssertFalse(PlaybackAnchorCrossing.isCrossed(anchor: 5, before: 6, after: 2), "backward seek")
        XCTAssertFalse(PlaybackAnchorCrossing.isCrossed(anchor: 5, before: nil, after: 6))
        XCTAssertTrue(PlaybackAnchorCrossing.isCrossed(anchor: 50_000, before: 0, after: 90_000))
        XCTAssertFalse(PlaybackAnchorCrossing.isCrossed(anchor: 50_000, before: 0, after: 90_000, maxForwardMs: 4_000))
    }
}
