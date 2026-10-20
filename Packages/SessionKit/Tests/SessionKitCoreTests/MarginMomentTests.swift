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

    // MARK: - Review new Margins (#474)

    private func anchor(_ id: String, _ ms: Int, _ label: String? = nil) -> MarginMomentAnchor {
        MarginMomentAnchor(marginId: id, mediaTimeMs: ms, label: label)
    }

    private func review(_ margins: [MarginMomentAnchor], returnTo: Int? = nil, resumes: Bool = false) throws -> MarginMomentSequence {
        try XCTUnwrap(MarginMomentSequence(itemId: "ep", reviewing: margins, returnToMediaTimeMs: returnTo, resumesAtEnd: resumes))
    }

    func testTheReviewLeadInIsTenSecondsAndSitsInTheLeadInTable() throws {
        XCTAssertEqual(MarginMomentSequence.reviewLeadInMs, 10_000)
        XCTAssertEqual(ListeningMoment.rule(for: .reviewNewMargins).leadInMs, 10_000)
        XCTAssertEqual(try review([anchor("a", 60_000)]).startMediaTimeMs, 50_000)
        XCTAssertEqual(try review([anchor("a", 4_000)]).startMediaTimeMs, 0, "clamped at the start of the episode")
        XCTAssertEqual(MarginMomentSequence.defaultLeadInMs, 30_000, "Play this moment keeps its own length (#1577)")
    }

    func testAReviewNeedsAtLeastOneMarginAndNeverPlaysOneTwice() throws {
        XCTAssertNil(MarginMomentSequence(itemId: "ep", reviewing: []))
        let sequence = try review([anchor("a", 60_000), anchor("a", 60_000), anchor("b", 90_000)])
        XCTAssertEqual(sequence.unplayed.map(\.marginId), ["a", "b"])
        XCTAssertEqual(sequence.review?.count, 2)
    }

    func testAReviewPlaysEachMarginWithItsOwnLeadInAndSkipsTheStretchesBetween() throws {
        var sequence = try review([anchor("a", 60_000), anchor("b", 120_000), anchor("c", 300_000)], returnTo: 1_500_000)
        XCTAssertTrue(sequence.isReview)
        XCTAssertEqual(sequence.startMediaTimeMs, 50_000, "the first lead-in starts ten seconds before the first Margin")
        XCTAssertEqual(sequence.msUntilTarget(currentMediaTimeMs: 50_000), 10_000)
        XCTAssertNil(sequence.progressed(from: 50_000, to: 55_000))

        XCTAssertEqual(sequence.progressed(from: 59_800, to: 60_300)?.marginId, "a")
        XCTAssertEqual(sequence.reviewNumber, 1)
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 60_300), .seek(toMediaTimeMs: 110_000),
                       "the stretch between a and b is skipped")
        XCTAssertEqual(sequence.phase, .leadIn)
        XCTAssertEqual(sequence.target.marginId, "b")
        XCTAssertEqual(sequence.reviewNumber, 2)
        XCTAssertNil(sequence.progressed(from: 110_000, to: 114_000), "still leading in")

        XCTAssertEqual(sequence.progressed(from: 119_800, to: 120_100)?.marginId, "b")
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 120_100), .seek(toMediaTimeMs: 290_000))
        XCTAssertEqual(sequence.progressed(from: 299_800, to: 300_200)?.marginId, "c")
        XCTAssertEqual(sequence.reviewNumber, 3)
        XCTAssertEqual(
            sequence.marginFinished(sourceAtMediaTimeMs: 300_200),
            .reviewDone(returnToMediaTimeMs: 1_500_000, resumes: false)
        )
        XCTAssertEqual(sequence.phase, .listening)
        XCTAssertTrue(sequence.unplayed.isEmpty, "it stops after the last one")
        XCTAssertNil(sequence.progressed(from: 300_200, to: 300_700), "nothing plays after the last Margin")
    }

    func testMarginsCloserThanTheLeadInPlayWithoutAnExtraSeek() throws {
        var sequence = try review([anchor("a", 60_000), anchor("b", 66_000), anchor("c", 76_000), anchor("d", 90_000)])
        XCTAssertEqual(sequence.progressed(from: 59_800, to: 60_300)?.marginId, "a")
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 60_300), .continueSource, "b is six seconds on")
        XCTAssertNil(sequence.progressed(from: 60_300, to: 60_800))
        XCTAssertEqual(sequence.progressed(from: 65_800, to: 66_300)?.marginId, "b")
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 66_300), .continueSource, "c is ten seconds on")
        XCTAssertEqual(sequence.progressed(from: 75_800, to: 76_300)?.marginId, "c")
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 76_300), .seek(toMediaTimeMs: 80_000),
                       "d is fourteen seconds on, so its lead-in is a hop of its own")
    }

    func testTwoMarginsAtTheSamePlaceBothPlayInTheOrderGiven() throws {
        var sequence = try review([anchor("first", 60_000, "Ana"), anchor("second", 60_000, "Ben"), anchor("later", 200_000)])
        // One progress tick crosses the shared place: only the first plays, the second isn't swallowed.
        XCTAssertEqual(sequence.progressed(from: 59_800, to: 60_400)?.marginId, "first")
        XCTAssertEqual(sequence.unplayed.map(\.marginId), ["second", "later"])
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 60_400), .playNow(anchor("second", 60_000, "Ben")))
        XCTAssertEqual(sequence.phase, .playingMargin("second"))
        XCTAssertEqual(sequence.playing?.marginId, "second")
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 60_400), .seek(toMediaTimeMs: 190_000))
    }

    func testAMarginTheTickAlreadyPassedPlaysRightAfterTheOneBeforeIt() throws {
        var sequence = try review([anchor("a", 60_000), anchor("b", 60_200)])
        XCTAssertEqual(sequence.progressed(from: 59_800, to: 60_400)?.marginId, "a")
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 60_400), .playNow(anchor("b", 60_200)),
                       "playback is already past b, so it can't be crossed again")
    }

    func testSkippingOverTheNextMarginInAReviewDoesNotPlayIt() throws {
        var sequence = try review([anchor("a", 60_000), anchor("b", 90_000)])
        XCTAssertNil(sequence.progressed(from: 50_000, to: 70_000), "a 20 s jump is a seek, not playback")
        XCTAssertEqual(sequence.phase, .leadIn)
        XCTAssertEqual(sequence.progressed(from: 59_500, to: 60_100)?.marginId, "a", "playing through still works")
        XCTAssertNil(sequence.progressed(from: 60_100, to: 60_600), "nothing else plays while a Margin plays")
    }

    func testPlayItNowInAReviewPlaysOnlyTheMarginAboutToCome() throws {
        var sequence = try review([anchor("a", 60_000), anchor("b", 62_000), anchor("c", 200_000)])
        XCTAssertEqual(sequence.jumpToTarget()?.marginId, "a")
        XCTAssertEqual(sequence.unplayed.map(\.marginId), ["b", "c"], "later Margins still come, even close ones")
        XCTAssertNil(sequence.jumpToTarget(), "only during a lead-in")
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 60_000), .continueSource)
        XCTAssertEqual(sequence.target.marginId, "b")
    }

    func testSkippingAMarginsVoiceMovesOnLikeAFinishedOne() throws {
        var sequence = try review([anchor("a", 60_000), anchor("b", 200_000)])
        _ = sequence.jumpToTarget()
        // The conductor reports a skip the same way as a finished voice.
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 60_000), .seek(toMediaTimeMs: 190_000))
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 190_000), .continueSource, "nothing is playing, so nothing moves")
    }

    func testAReviewKeepsWhereToGoBackAndWhetherToPlayOn() throws {
        var sequence = try review([anchor("a", 60_000)], returnTo: 900_000, resumes: true)
        XCTAssertEqual(sequence.review?.returnToMediaTimeMs, 900_000)
        _ = sequence.jumpToTarget()
        XCTAssertEqual(sequence.marginFinished(), .reviewDone(returnToMediaTimeMs: 900_000, resumes: true))

        var fresh = try review([anchor("a", 60_000)])
        _ = fresh.jumpToTarget()
        XCTAssertEqual(fresh.marginFinished(), .reviewDone(returnToMediaTimeMs: nil, resumes: false))
    }

    /// A review that ends in the middle (another item, a Timeline jump, Stop) owes the listener the way back; one that
    /// played its last Margin has already gone back, and a plain Margin moment never moves the listener.
    func testAReviewOwesTheWayBackUntilItsLastMarginHasPlayed() throws {
        var sequence = try review([anchor("a", 60_000), anchor("b", 200_000)], returnTo: 900_000)
        XCTAssertTrue(sequence.isUnfinishedReview, "in the lead-in to the first Margin")
        _ = sequence.progressed(from: 59_800, to: 60_300)
        XCTAssertTrue(sequence.isUnfinishedReview, "while the first Margin plays")
        _ = sequence.marginFinished(sourceAtMediaTimeMs: 60_300)
        XCTAssertTrue(sequence.isUnfinishedReview, "between the Margins, with the source hopping ahead")
        _ = sequence.progressed(from: 199_800, to: 200_300)
        XCTAssertTrue(sequence.isUnfinishedReview, "while the last Margin plays")
        _ = sequence.marginFinished(sourceAtMediaTimeMs: 200_300)
        XCTAssertFalse(sequence.isUnfinishedReview, "the last Margin has played and the source has gone back")

        XCTAssertFalse(MarginMomentSequence(itemId: "ep", target: target, otherMargins: []).isUnfinishedReview,
                       "Play this moment is not a review")
        XCTAssertFalse(
            MarginMomentSequence(itemId: "ep", resumingAtMediaTimeMs: 5_000, playedMargin: target, otherMargins: []).isUnfinishedReview,
            "neither is the play-on after one of your own Margins"
        )
    }

    func testPlayThisMomentStillEndsListeningWhenItsMarginsAreDone() {
        var sequence = MarginMomentSequence(itemId: "ep", target: target, otherMargins: [])
        XCTAssertFalse(sequence.isReview)
        XCTAssertNil(sequence.reviewNumber)
        _ = sequence.jumpToTarget()
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 120_000), .continueSource)
        XCTAssertEqual(sequence.phase, .listening)
    }
}
