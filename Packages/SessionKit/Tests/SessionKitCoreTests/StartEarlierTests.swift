import Foundation
import XCTest
@testable import SessionKit

/// "Start a minute earlier" (#4171, PR 3a of the Design): the rule and the sequence restart, hidden. Nothing calls them yet.
final class StartEarlierTests: XCTestCase {
    private func anchor(_ id: String, at ms: Int, leadInMs: Int? = nil, label: String? = "Sam") -> MarginMomentAnchor {
        MarginMomentAnchor(marginId: id, mediaTimeMs: ms, label: label, leadInMs: leadInMs)
    }

    private func review(_ margins: [MarginMomentAnchor], leadInMs: Int = MarginMomentSequence.reviewLeadInMs,
                        returnTo: Int? = nil) throws -> MarginMomentSequence {
        try XCTUnwrap(MarginMomentSequence(itemId: "item", reviewing: margins, returnToMediaTimeMs: returnTo, leadInMs: leadInMs))
    }

    // MARK: The rule

    func testAMarginInOrdinaryPlaybackGetsAMinuteAndEachPressAddsAnother() throws {
        let margin = anchor("m", at: 600_000)
        let first = try XCTUnwrap(StartEarlier.plan(for: margin, runUpMs: 0))
        XCTAssertEqual(first.leadInMs, 60_000)
        XCTAssertEqual(first.startMediaTimeMs, 540_000)
        let second = try XCTUnwrap(StartEarlier.plan(for: margin, runUpMs: first.leadInMs))
        XCTAssertEqual(second.leadInMs, 120_000)
        XCTAssertEqual(second.startMediaTimeMs, 480_000)
        // Past five minutes the sender's clamp does not apply: the listener's own presses keep adding.
        let sixMinutes = try XCTUnwrap(StartEarlier.plan(for: margin, runUpMs: 300_000))
        XCTAssertEqual(sixMinutes.leadInMs, 360_000)
        XCTAssertEqual(sixMinutes.startMediaTimeMs, 240_000)
    }

    func testTheStartStopsAtTheEpisodeAndThenThereIsNoButton() throws {
        // Table: where the Margin is, the run-up used just now, the new start (nil: no button).
        let rows: [(at: Int, used: Int, start: Int?)] = [
            (10_000, 0, 0),              // 0:10 with a minute: the start of the episode
            (10_000, 20_000, nil),       // the 20 s run-up already began at 0 (clamped), nothing earlier
            (10_000, 60_000, nil),
            (80_000, 20_000, 0),         // 1:20: 20 s used started at 1:00, a minute more reaches 0
            (80_000, 80_000, nil),       // used exactly the whole way back
            (80_000, 200_000, nil),      // more than the whole way back
            (0, 0, nil),                 // a Margin at the very start has nothing before it
            (7_170_000, 120_000, 6_990_000),
            (600_000, -5, 540_000),      // a negative length reads as none
        ]
        for row in rows {
            let plan = StartEarlier.plan(for: anchor("m", at: row.at), runUpMs: row.used)
            XCTAssertEqual(plan?.startMediaTimeMs, row.start, "at \(row.at) after \(row.used)")
        }
    }

    // MARK: The sequence offers it only where it helps

    func testComingUpAtTwentySecondsOffersEightyAndTheCountdownGrows() throws {
        var sequence = try review([anchor("a", at: 300_000)])
        XCTAssertEqual(sequence.startMediaTimeMs, 280_000)
        let plan = try XCTUnwrap(sequence.startEarlierPlan(currentMediaTimeMs: 285_000))
        XCTAssertEqual(plan.leadInMs, 80_000)
        XCTAssertEqual(plan.startMediaTimeMs, 220_000)
        XCTAssertEqual(sequence.restartLonger(marginId: "a", leadInMs: plan.leadInMs), 220_000)
        XCTAssertEqual(sequence.startMediaTimeMs, 220_000)
        XCTAssertEqual(sequence.targetCountdown(currentMediaTimeMs: 220_000), "1:20")
        XCTAssertEqual(sequence.targetCountdown(currentMediaTimeMs: nil), "1:20")
        // The next press adds a minute to the one just used.
        XCTAssertEqual(sequence.startEarlierPlan(currentMediaTimeMs: 230_000)?.leadInMs, 140_000)
    }

    func testASendersLengthIsTheRunUpTheNextPressAddsTo() throws {
        let sequence = try review([anchor("a", at: 600_000, leadInMs: 120_000)])
        XCTAssertEqual(sequence.startEarlierPlan(currentMediaTimeMs: 480_000)?.leadInMs, 180_000)
    }

    func testAReviewBetweenMarginsOffersNothingUntilThePlayheadIsInTheNextRunUp() throws {
        var sequence = try review([anchor("a", at: 100_000), anchor("b", at: 600_000)])
        XCTAssertNotNil(sequence.progressed(from: 99_800, to: 100_100))
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 100_100), .continueSource)
        XCTAssertEqual(sequence.target.marginId, "b")
        // The hop button is showing: the playhead is far before b's run-up, and a restart would move the listener forward.
        XCTAssertNil(sequence.startEarlierPlan(currentMediaTimeMs: 100_500))
        XCTAssertNil(sequence.startEarlierPlan(currentMediaTimeMs: nil), "a review that has reached a Margin and has no reading")
        XCTAssertNil(sequence.startEarlierPlan(currentMediaTimeMs: 578_999))
        XCTAssertNotNil(sequence.startEarlierPlan(currentMediaTimeMs: 580_000), "exactly at the run-up's start")
        XCTAssertNotNil(sequence.startEarlierPlan(currentMediaTimeMs: 600_000))
        XCTAssertNil(sequence.startEarlierPlan(currentMediaTimeMs: 601_000), "past the Margin")
    }

    func testAListeningWithNoLeadInAtAllNeverOffersIt() throws {
        var sequence = try review([anchor("a", at: 300_000)], leadInMs: 0)
        XCTAssertNil(sequence.startEarlierPlan(currentMediaTimeMs: 300_000))
        XCTAssertNotNil(sequence.progressed(from: 299_800, to: 300_100))
        XCTAssertNil(sequence.startEarlierPlan(currentMediaTimeMs: 300_100))
        XCTAssertNil(sequence.restartLonger(marginId: "a", leadInMs: 60_000))
    }

    func testAMarginNearTheStartOfTheEpisodeOffersNothingOnceItsRunUpBeganAtZero() throws {
        let sequence = try review([anchor("a", at: 10_000)])
        XCTAssertEqual(sequence.startMediaTimeMs, 0)
        XCTAssertNil(sequence.startEarlierPlan(currentMediaTimeMs: 5_000))
    }

    func testAPlainMomentOffersItsOwnRunUpPlusAMinuteWhileItsVoicePlays() throws {
        // "Play this moment" has 30 s.
        var sequence = MarginMomentSequence(itemId: "item", target: anchor("a", at: 300_000), otherMargins: [])
        XCTAssertEqual(sequence.startMediaTimeMs, 270_000)
        XCTAssertNotNil(sequence.progressed(from: 299_800, to: 300_100))
        let plan = try XCTUnwrap(sequence.startEarlierPlan(currentMediaTimeMs: 300_100))
        XCTAssertEqual(plan.leadInMs, 90_000)
        XCTAssertEqual(plan.startMediaTimeMs, 210_000)
    }

    func testAfterTheMarginHasPlayedAndTheEpisodeCarriesOnThereIsNothingToRestart() throws {
        var sequence = MarginMomentSequence(itemId: "item", target: anchor("a", at: 300_000), otherMargins: [])
        XCTAssertNotNil(sequence.progressed(from: 299_800, to: 300_100))
        sequence.marginFinished()
        XCTAssertEqual(sequence.phase, .listening)
        XCTAssertNil(sequence.startEarlierPlan(currentMediaTimeMs: 320_000))
        XCTAssertNil(sequence.restartLonger(marginId: "a", leadInMs: 80_000))
    }

    func testAnotherMarginIdCannotBeRestarted() throws {
        var sequence = try review([anchor("a", at: 300_000), anchor("b", at: 900_000)])
        XCTAssertNil(sequence.restartLonger(marginId: "b", leadInMs: 80_000))
        XCTAssertNil(sequence.restartLonger(marginId: "nobody", leadInMs: 80_000))
        XCTAssertEqual(sequence.startMediaTimeMs, 280_000)
        XCTAssertEqual(sequence.leadInMs(for: anchor("b", at: 900_000)), MarginMomentSequence.reviewLeadInMs)
    }

    // MARK: The restart keeps the review

    func testARestartOnTheSecondOfThreeKeepsTheThirdAndTheCount() throws {
        var sequence = try review([anchor("a", at: 100_000), anchor("b", at: 600_000), anchor("c", at: 900_000)], returnTo: 50_000)
        XCTAssertNotNil(sequence.progressed(from: 99_800, to: 100_100))
        sequence.marginFinished(sourceAtMediaTimeMs: 100_100)
        XCTAssertNotNil(sequence.progressed(from: 599_800, to: 600_100))
        XCTAssertEqual(sequence.reviewNumber, 2)
        let plan = try XCTUnwrap(sequence.startEarlierPlan(currentMediaTimeMs: 600_100))
        XCTAssertEqual(plan.leadInMs, 80_000)

        XCTAssertEqual(sequence.restartLonger(marginId: "b", leadInMs: plan.leadInMs), 520_000)
        XCTAssertEqual(sequence.phase, .leadIn)
        XCTAssertNil(sequence.playing)
        XCTAssertEqual(sequence.target.marginId, "b")
        XCTAssertEqual(sequence.unplayed.map(\.marginId), ["b", "c"])
        XCTAssertEqual(sequence.reviewNumber, 2, "still 2 of 3")
        XCTAssertEqual(sequence.review?.count, 3)
        XCTAssertEqual(sequence.review?.returnToMediaTimeMs, 50_000)
        XCTAssertTrue(sequence.hasReachedAMargin)

        // The run-up reaches b again, then b plays, then c is next as before.
        XCTAssertNil(sequence.progressed(from: 519_800, to: 520_300))
        XCTAssertEqual(sequence.progressed(from: 599_800, to: 600_100)?.marginId, "b")
        XCTAssertEqual(sequence.reviewNumber, 2)
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 600_100), .continueSource)
        XCTAssertEqual(sequence.target.marginId, "c")
        XCTAssertEqual(sequence.reviewNumber, 3)
    }

    func testARestartOnTheFirstMarginAfterItPlayedStillCountsAsHeardForStop() throws {
        var sequence = try review([anchor("a", at: 300_000), anchor("b", at: 900_000)], returnTo: 50_000)
        XCTAssertFalse(sequence.hasReachedAMargin)
        XCTAssertNotNil(sequence.progressed(from: 299_800, to: 300_100))
        XCTAssertTrue(sequence.hasReachedAMargin)
        // Stopped while it plays: the listener stays where they are (their place, 0:50, is behind them).
        XCTAssertNil(sequence.placeToReturnToWhenStopped(sourceAtMediaTimeMs: 300_100))
        sequence.restartLonger(marginId: "a", leadInMs: 80_000)
        XCTAssertEqual(sequence.unplayed.map(\.marginId), ["a", "b"])
        XCTAssertTrue(sequence.hasReachedAMargin, "unplayed.count alone would say no")
        XCTAssertNil(sequence.placeToReturnToWhenStopped(sourceAtMediaTimeMs: 250_000), "Stop after a restart returns as after a reached Margin")
        // A restart before it ever played does not change that: Stop still undoes the hop.
        var fresh = try review([anchor("a", at: 300_000)], returnTo: 50_000)
        fresh.restartLonger(marginId: "a", leadInMs: 80_000)
        XCTAssertFalse(fresh.hasReachedAMargin)
        XCTAssertEqual(fresh.placeToReturnToWhenStopped(sourceAtMediaTimeMs: 250_000), 50_000)
    }

    func testTheVoiceEndingAfterARestartDoesNotAdvanceTheReview() throws {
        var sequence = try review([anchor("a", at: 300_000), anchor("b", at: 900_000)])
        XCTAssertNotNil(sequence.progressed(from: 299_800, to: 300_100))
        sequence.restartLonger(marginId: "a", leadInMs: 80_000)
        // The app cancels the voice through the conductor; if its end still reaches the sequence it changes nothing.
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 300_100), .continueSource)
        XCTAssertEqual(sequence.target.marginId, "a")
        XCTAssertEqual(sequence.unplayed.map(\.marginId), ["a", "b"])
    }

    func testARestartTwiceGivesPlusSixtyThenPlusOneTwenty() throws {
        var sequence = try review([anchor("a", at: 900_000)])
        var used = sequence.leadInMs(for: sequence.target)
        XCTAssertEqual(used, 20_000)
        for expected in [80_000, 140_000] {
            let plan = try XCTUnwrap(sequence.startEarlierPlan(currentMediaTimeMs: 900_000 - used))
            XCTAssertEqual(plan.leadInMs, expected)
            sequence.restartLonger(marginId: "a", leadInMs: plan.leadInMs)
            used = sequence.leadInMs(for: sequence.target)
            XCTAssertEqual(used, expected)
        }
    }

    func testAPlainMomentRestartKeepsTheMarginsAfterItAndNeverPlaysOnesBeforeIt() throws {
        // "Play this moment" runs 30 s. b sits inside c's original run-up, so it is in the moment's list and has not played.
        var sequence = MarginMomentSequence(
            itemId: "item", target: anchor("c", at: 600_000),
            otherMargins: [anchor("b", at: 580_000), anchor("d", at: 900_000), anchor("early", at: 100_000)])
        XCTAssertEqual(sequence.unplayed.map(\.marginId), ["b", "c", "d"])
        XCTAssertEqual(sequence.restartLonger(marginId: "c", leadInMs: 90_000), 510_000)
        XCTAssertEqual(sequence.unplayed.map(\.marginId), ["c", "d"], "the run-up is this Margin's; b does not play in it")
        XCTAssertNil(sequence.progressed(from: 579_800, to: 580_300))
        XCTAssertEqual(sequence.progressed(from: 599_800, to: 600_100)?.marginId, "c")
    }

    func testTheSeekToARunUpsStartMayLandAMomentShort() throws {
        let sequence = try review([anchor("a", at: 300_000)])
        // The run-up starts at 280 s.
        XCTAssertNotNil(sequence.startEarlierPlan(currentMediaTimeMs: 279_000))
        XCTAssertNil(sequence.startEarlierPlan(currentMediaTimeMs: 278_999))
    }

    // MARK: Ordinary playback

    func testPressingInOrdinaryPlaybackStartsAOneMarginReviewThatPlaysOnAfterIt() throws {
        // A friend's Margin whose sender chose 2 min: ordinary playback still counts as no run-up, so the press gives one minute.
        let margin = anchor("a", at: 900_000, leadInMs: 120_000)
        let plan = try XCTUnwrap(StartEarlier.plan(for: margin, runUpMs: 0))
        XCTAssertEqual(plan.leadInMs, 60_000)
        var sequence = try XCTUnwrap(StartEarlier.review(itemId: "item", margin: margin, plan: plan))
        XCTAssertEqual(sequence.startMediaTimeMs, 840_000, "the review's own length, not the sender's")
        XCTAssertEqual(sequence.review?.count, 1)
        XCTAssertNil(sequence.review?.returnToMediaTimeMs)
        XCTAssertEqual(sequence.targetCountdown(currentMediaTimeMs: 840_000), "1:00")
        XCTAssertEqual(sequence.progressed(from: 899_800, to: 900_100)?.marginId, "a")
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 900_100), .reviewDone(returnToMediaTimeMs: nil, resumes: true))
        XCTAssertEqual(sequence.phase, .listening)
    }

    func testTheOrdinaryPlaybackReviewKeepsTheMarginsWords() throws {
        let margin = MarginMomentAnchor(
            marginId: "a", mediaTimeMs: 900_000, label: "Sam", isApproximate: true, caption: "Reply to your Margin at 12:34",
            isYours: false, isReadAloud: true, leadInMs: 45_000)
        let plan = try XCTUnwrap(StartEarlier.plan(for: margin, runUpMs: 0))
        let sequence = try XCTUnwrap(StartEarlier.review(itemId: "item", margin: margin, plan: plan))
        let target = sequence.target
        XCTAssertEqual(target.label, "Sam")
        XCTAssertTrue(target.isApproximate)
        XCTAssertEqual(target.caption, "Reply to your Margin at 12:34")
        XCTAssertTrue(target.isReadAloud)
        XCTAssertFalse(target.isYours)
    }

    /// PR 3b: the app's review of a Margin playing by itself passes its playlist steps and the place the source stood. A
    /// friend's reply plays after the listener's own Margin it answers (#3221), so the steps can be two.
    func testTheAppsReviewOfAPlayingMarginDropsEverySendersLengthAndPlaysOnFromTheMargin() throws {
        let yours = MarginMomentAnchor(marginId: "mine", mediaTimeMs: 880_000, isYours: true)
        let reply = anchor("reply", at: 900_000, leadInMs: 120_000)
        let plan = try XCTUnwrap(StartEarlier.plan(for: reply, runUpMs: 0))
        var sequence = try XCTUnwrap(StartEarlier.review(
            itemId: "item", margins: [yours, reply], returnToMediaTimeMs: 900_000, plan: plan))
        XCTAssertEqual(sequence.review?.count, 2)
        XCTAssertEqual(sequence.review?.returnToMediaTimeMs, 900_000)
        XCTAssertEqual(sequence.review?.resumesAtEnd, true, "the episode plays on after the Margin")
        XCTAssertEqual(sequence.startMediaTimeMs, 820_000, "a minute before the first step, not the sender's two")
        XCTAssertTrue(sequence.unplayed.allSatisfy { $0.leadInMs == nil })
        XCTAssertEqual(sequence.progressed(from: 879_800, to: 880_100)?.marginId, "mine")
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 880_100), .continueSource)
        XCTAssertEqual(sequence.progressed(from: 899_800, to: 900_100)?.marginId, "reply")
        XCTAssertEqual(sequence.marginFinished(sourceAtMediaTimeMs: 900_100), .reviewDone(returnToMediaTimeMs: nil, resumes: true))
    }

    func testTheOneMarginFormIsTheAppsFormWithOneStep() throws {
        let margin = anchor("a", at: 900_000, leadInMs: 45_000)
        let plan = try XCTUnwrap(StartEarlier.plan(for: margin, runUpMs: 0))
        XCTAssertEqual(
            StartEarlier.review(itemId: "item", margin: margin, plan: plan),
            StartEarlier.review(itemId: "item", margins: [margin], plan: plan))
    }

    // MARK: Margins crossed together (audit on #5093)

    private func prompt(_ id: String, media: Int?) -> ImportedCommentaryPrompt {
        let layer = ImportedCommentaryLayer(id: "layer", itemId: "item", packageDigest: "digest", packageId: "package",
                                            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
                                            importedAt: Date(timeIntervalSince1970: 0),
                                            sourceResolutionStatus: .resolved, isEnabled: true)
        let record = ImportedCommentaryInterjection(
            id: id, layerId: layer.id, packageScopedId: "packet-\(id)", createdAt: Date(timeIntervalSince1970: 0),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Words",
            resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: media))
        return ImportedCommentaryPrompt(layer: layer, interjection: record, index: 1, count: 1)
    }

    private func snapshot(_ media: Int) -> SessionSnapshot {
        var value = SessionSnapshot()
        value.itemId = "item"
        value.currentMediaTimeMs = media
        return value
    }

    /// Two friend's Margins crossed in one tick: A plays by itself, B waits its turn. A press during A reviews both, so B
    /// still plays, right after A, although the longer run-up empties the queue and B is already announced.
    func testAPressDuringAMarginCrossedWithAnotherReviewsTheOneWaitingToo() throws {
        let all = [prompt("a", media: 600_000), prompt("b", media: 600_300)]
        var queue = SharedMarginOfferQueue()
        let offered = try XCTUnwrap(queue.nextOffer(
            previous: snapshot(599_900), current: snapshot(600_400), selectedItemID: "item", canOffer: true, prompts: all))
        XCTAssertEqual(offered.id, "a")
        XCTAssertEqual(queue.waitingIDs, ["b"])

        let entries = StartEarlier.entries(playing: offered, waiting: queue.waitingIDs, among: all)
        XCTAssertEqual(entries.map(\.interjection.id), ["a", "b"])
        let plan = try XCTUnwrap(StartEarlier.plan(for: entries[0].anchor, runUpMs: 0))
        var sequence = try XCTUnwrap(StartEarlier.review(itemId: "item", margins: entries.map(\.anchor), plan: plan))
        XCTAssertEqual(sequence.startMediaTimeMs, 540_000)
        XCTAssertEqual(sequence.progressed(from: 599_800, to: 600_100)?.marginId, entries[0].marginId)
        guard case .playNow(let next) = sequence.marginFinished(sourceAtMediaTimeMs: 600_400) else {
            return XCTFail("b should play straight after a")
        }
        XCTAssertEqual(next.marginId, entries[1].marginId)
        // Without them (the defect), the queue the jump empties was B's only way to play.
        XCTAssertNil(queue.nextOffer(
            previous: snapshot(600_400), current: snapshot(540_000), selectedItemID: "item", canOffer: true, prompts: all))
        XCTAssertTrue(queue.waitingIDs.isEmpty)
    }

    func testTheReviewedMarginsSkipTheOnePlayingAndAnyNoLongerOfferedOrUnplaced() {
        let a = prompt("a", media: 600_000)
        let all = [a, prompt("b", media: 600_300), prompt("c", media: nil)]
        XCTAssertEqual(
            StartEarlier.entries(playing: a, waiting: ["a", "gone", "c", "b"], among: all).map(\.interjection.id), ["a", "b"])
        XCTAssertEqual(StartEarlier.entries(playing: a, waiting: [], among: []).map(\.interjection.id), ["a"])
        XCTAssertTrue(StartEarlier.entries(playing: prompt("t", media: nil), waiting: [], among: []).isEmpty)
    }
}
