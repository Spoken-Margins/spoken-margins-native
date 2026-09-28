import Foundation
import XCTest
@testable import SessionKit

/// "Play this moment" (#159): lead in, play the Margin when playback reaches it, continue with the others.
final class MarginMomentTests: XCTestCase {
    private let target = MarginMomentAnchor(marginId: "ij-003", mediaTimeMs: 120_000)

    func testStartsThirtySecondsBeforeTheMarginAndClampsAtTheStart() {
        XCTAssertEqual(MarginMomentSequence(itemId: "ep", target: target, otherMargins: []).startMediaTimeMs, 90_000)
        let early = MarginMomentAnchor(marginId: "ij-001", mediaTimeMs: 12_000)
        XCTAssertEqual(MarginMomentSequence(itemId: "ep", target: early, otherMargins: []).startMediaTimeMs, 0)
    }

    func testPlaysTheMarginWhenPlaybackReachesItThenReturnsToListening() {
        var sequence = MarginMomentSequence(itemId: "ep", target: target, otherMargins: [])
        XCTAssertEqual(sequence.msUntilTarget(currentMediaTimeMs: 90_000), 30_000)
        XCTAssertNil(sequence.progressed(from: 90_000, to: 119_500))
        XCTAssertEqual(sequence.progressed(from: 119_500, to: 120_000), target)
        XCTAssertEqual(sequence.phase, .playingMargin("ij-003"))
        XCTAssertNil(sequence.progressed(from: 120_000, to: 120_500), "nothing else plays while a Margin plays")
        sequence.marginFinished()
        XCTAssertEqual(sequence.phase, .listening)
        XCTAssertNil(sequence.progressed(from: 119_000, to: 121_000), "a played Margin doesn't replay")
    }

    func testSkippingOverTheMarginDoesNotPlayIt() {
        var sequence = MarginMomentSequence(itemId: "ep", target: target, otherMargins: [])
        XCTAssertNil(sequence.progressed(from: 100_000, to: 130_000), "a 30 s skip is a seek, not playback")
        XCTAssertNil(sequence.msUntilTarget(currentMediaTimeMs: 130_000))
        XCTAssertEqual(sequence.progressed(from: 119_000, to: 120_200), target, "seeking back and playing through works")
    }

    func testPlayItNowSkipsTheLeadInAndEarlierMargins() {
        let during = MarginMomentAnchor(marginId: "ij-002", mediaTimeMs: 100_000)
        let later = MarginMomentAnchor(marginId: "ij-004", mediaTimeMs: 200_000)
        var sequence = MarginMomentSequence(itemId: "ep", target: target, otherMargins: [during, later])
        XCTAssertEqual(sequence.jumpToTarget(), target)
        sequence.marginFinished()
        XCTAssertEqual(sequence.unplayed, [later])
        XCTAssertNil(sequence.jumpToTarget(), "only during the lead-in")
    }

    func testOtherMarginsPlayAsTheyComeUpButNotOnesBeforeTheLeadIn() {
        let before = MarginMomentAnchor(marginId: "ij-001", mediaTimeMs: 10_000)
        let during = MarginMomentAnchor(marginId: "ij-002", mediaTimeMs: 100_000)
        let later = MarginMomentAnchor(marginId: "ij-004", mediaTimeMs: 200_000)
        var sequence = MarginMomentSequence(itemId: "ep", target: target, otherMargins: [later, before, during, target])
        XCTAssertEqual(sequence.unplayed.map(\.marginId), ["ij-002", "ij-003", "ij-004"])

        XCTAssertEqual(sequence.progressed(from: 99_800, to: 100_300), during)
        sequence.marginFinished()
        XCTAssertEqual(sequence.phase, .leadIn, "the chosen Margin is still ahead")
        XCTAssertEqual(sequence.progressed(from: 119_800, to: 120_300), target)
        sequence.marginFinished()
        XCTAssertEqual(sequence.progressed(from: 199_800, to: 200_300), later)
        sequence.marginFinished()
        XCTAssertEqual(sequence.phase, .listening)
        XCTAssertTrue(sequence.unplayed.isEmpty)
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
