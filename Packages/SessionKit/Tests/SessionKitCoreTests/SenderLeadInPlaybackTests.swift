import Foundation
import XCTest
@testable import SessionKit

/// Playback reads the run-up a sender chose for a Margin (#4171, PR 2 of the Design). Every place that counts a run-up
/// (the review's start, "Play this moment", the friends' cut, the Next Margin press, the card's words and the item screen's
/// minutes) takes the Margin's own length when its packet carried one, and keeps its own default when it didn't.
final class SenderLeadInPlaybackTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 1_700_000_000)

    private func layer() -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: "ana", itemId: "item", packageDigest: "digest", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 7_200_000),
            displayLabel: "Ana", importedAt: early, sourceResolutionStatus: .resolved, isEnabled: true, isMuted: false
        )
    }

    private func record(_ id: String, at ms: Int, leadInMs: Int?) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: "ana", packageScopedId: id, createdAt: early,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: ms), approvedTranscript: "Words",
            audioPath: "ImportedCommentary/\(id).m4a", audioDurationMs: 4_000,
            resolution: ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: ms, confidence: 1),
            senderLeadInMs: leadInMs
        )
    }

    private func entries(_ margins: [(id: String, at: Int, leadInMs: Int?)]) -> [SharedMarginReview.Entry] {
        SharedMarginReview.entries(
            layers: [layer()], records: ["ana": margins.map { record($0.id, at: $0.at, leadInMs: $0.leadInMs) }])
    }

    private func review(_ margins: [(id: String, at: Int, leadInMs: Int?)]) throws -> MarginMomentSequence {
        try XCTUnwrap(MarginMomentSequence(itemId: "item", reviewing: entries(margins).map(\.anchor)))
    }

    // MARK: The carrier

    func testTheAnchorCarriesWhatThePacketAskedAndClampsIt() {
        XCTAssertNil(MarginMomentAnchor(marginId: "m", mediaTimeMs: 1).leadInMs, "no length: each moment keeps its own")
        XCTAssertEqual(MarginMomentAnchor(marginId: "m", mediaTimeMs: 1, leadInMs: 60_000).leadInMs, 60_000)
        XCTAssertEqual(MarginMomentAnchor(marginId: "m", mediaTimeMs: 1, leadInMs: 9_000_000).leadInMs, 300_000)
        XCTAssertEqual(MarginMomentAnchor(marginId: "m", mediaTimeMs: 1, leadInMs: -5).leadInMs, 0)
        let entry = entries([("a", 600_000, 45_000)])[0]
        XCTAssertEqual(entry.anchor.leadInMs, 45_000, "an imported Margin's anchor carries the sender's length")
        XCTAssertNil(entries([("b", 600_000, nil)])[0].anchor.leadInMs)
    }

    // MARK: A review

    func testAReviewStartsTheSendersLengthBeforeTheFirstMargin() throws {
        let sequence = try review([("a", 600_000, 60_000)])
        XCTAssertEqual(sequence.startMediaTimeMs, 540_000, "60 s from the packet")
        XCTAssertEqual(sequence.targetCountdown(currentMediaTimeMs: nil), "1:00", "the card's countdown counts from it")
        XCTAssertEqual(sequence.review?.leadInMs, MarginMomentSequence.reviewLeadInMs, "the review's own length is unchanged")
    }

    func testAReviewWithNoLengthKeepsTwentySeconds() throws {
        XCTAssertEqual(try review([("a", 600_000, nil)]).startMediaTimeMs, 580_000, "an old packet: the default, no visible change")
    }

    func testTheLengthIsClampedAtTheStartOfTheEpisode() throws {
        XCTAssertEqual(try review([("a", 10_000, 60_000)]).startMediaTimeMs, 0, "a Margin at 0:10 with 1 min starts at 0")
        // 1:59:30 in a two-hour episode with 2 min starts at 1:57:30.
        XCTAssertEqual(try review([("a", 7_170_000, 120_000)]).startMediaTimeMs, 7_050_000)
    }

    func testEachMarginInAReviewUsesItsOwnLengthWhenTheListenerHopsToIt() throws {
        let sequence = try review([("a", 600_000, 45_000), ("b", 900_000, nil), ("c", 1_200_000, 120_000)])
        let anchors = entries([("a", 600_000, 45_000), ("b", 900_000, nil), ("c", 1_200_000, 120_000)]).map(\.anchor)
        XCTAssertEqual(anchors.map { sequence.leadInMs(for: $0) }, [45_000, 20_000, 120_000])
    }

    func testAListeningWithNoLeadInStaysWithoutOneWhateverTheSenderChose() {
        let flat = [
            MarginMomentAnchor(marginId: "words", mediaTimeMs: 300_000),
            MarginMomentAnchor(marginId: "a", mediaTimeMs: 300_000, leadInMs: 60_000),
        ]
        let sequence = MarginMomentSequence(itemId: "item", reviewing: flat, leadInMs: 0)
        XCTAssertEqual(sequence?.startMediaTimeMs, 300_000, "a can't-play listening has no episode to lead in with")
        XCTAssertEqual(sequence?.leadInMs(for: flat[1]), 0)
    }

    // MARK: "Play this moment" and the friends' cut

    func testPlayThisMomentOnAFriendsMarginUsesTheirLength() {
        let target = MarginMomentAnchor(marginId: "a", mediaTimeMs: 600_000, leadInMs: 60_000)
        XCTAssertEqual(MarginMomentSequence(itemId: "item", target: target, otherMargins: []).startMediaTimeMs, 540_000)
        let none = MarginMomentAnchor(marginId: "a", mediaTimeMs: 600_000)
        XCTAssertEqual(MarginMomentSequence(itemId: "item", target: none, otherMargins: []).startMediaTimeMs, 570_000, "no length: today's 30 s")
        let short = MarginMomentAnchor(marginId: "a", mediaTimeMs: 600_000, leadInMs: 5_000)
        XCTAssertEqual(MarginMomentSequence(itemId: "item", target: short, otherMargins: []).startMediaTimeMs, 595_000, "shorter than the default too")
    }

    func testAnOwnMarginsMomentIsUnchanged() {
        let own = MarginMomentAnchor(marginId: "own", mediaTimeMs: 120_000)
        XCTAssertEqual(MarginMomentSequence(itemId: "item", target: own, otherMargins: []).startMediaTimeMs, 90_000)
        XCTAssertEqual(MarginMomentSequence(itemId: "item", target: own, otherMargins: [], leadInMs: 8_000).startMediaTimeMs, 112_000)
    }

    func testTheFriendsCutTakesTheMarginsOwnLengthAndTheCallersLengthStillWins() {
        func start(_ margin: ListeningMoment.Margin, leadInMs: Int? = nil) -> ListeningMoment {
            ListeningMoment(use: .friendsCut, margin: margin, source: .media(), leadInMs: leadInMs)
        }
        let plain = ListeningMoment.Margin(id: "a", position: 300_000)
        let sender = ListeningMoment.Margin(id: "a", position: 300_000, leadInMs: 60_000)
        XCTAssertEqual(start(plain).sourceStartPosition, 280_000, "the friends' cut default, 20 s")
        XCTAssertEqual(start(sender).sourceStartPosition, 240_000)
        XCTAssertEqual(start(sender, leadInMs: 10_000).sourceStartPosition, 290_000, "an explicit length is the caller's decision")
        let early = ListeningMoment.Margin(id: "a", position: 10_000, leadInMs: 60_000)
        XCTAssertEqual(start(early).sourceStartPosition, 0)
        XCTAssertEqual(start(early).leadInClamp, .sourceStart)
        let planned = ListeningMoment.plan(use: .friendsCut, margins: [plain, ListeningMoment.Margin(id: "b", position: 600_000, leadInMs: 120_000)], source: .media())
        XCTAssertEqual(planned.map(\.sourceStartPosition), [280_000, 480_000])
    }

    // MARK: Next Margin

    func testTheFirstNextMarginPressGoesToTheSendersLeadIn() {
        let marginAt = 600_000
        XCTAssertEqual(
            NextMarginPress.press(.momentLeadIn(isReview: true, positionMs: 0, targetMs: marginAt, targetLeadInMs: 60_000)),
            .seekToLeadIn(mediaTimeMs: 540_000))
        XCTAssertEqual(
            NextMarginPress.press(.momentLeadIn(isReview: true, positionMs: 545_000, targetMs: marginAt, targetLeadInMs: 60_000)),
            .playMarginNow, "inside the sender's run-up: the second press plays the Margin")
        XCTAssertEqual(
            NextMarginPress.press(.momentLeadIn(isReview: true, positionMs: 545_000, targetMs: marginAt)),
            .seekToLeadIn(mediaTimeMs: 580_000), "with no length the same position is still before the 20 s lead-in")
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: 0, nextMarginMs: marginAt, arrival: .playsByItself, nextLeadInMs: 120_000)),
            .seekToLeadIn(mediaTimeMs: 480_000))
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: 500_000, nextMarginMs: marginAt, arrival: .playsByItself, nextLeadInMs: 120_000)),
            .playMarginNow)
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: 10_000, nextMarginMs: 30_000, arrival: .playsByItself, nextLeadInMs: 60_000)),
            .playMarginNow, "a Margin near the start with a long run-up clamps at 0, and the playhead is already inside it: play now")
    }

    // MARK: The card's words

    func testSecSwitchesOnAtTheMarginsOwnLength() {
        XCTAssertEqual(PinnedMarginCard.friendSpan(25_000), "under 1 min", "default: 20 s is the cut-over")
        XCTAssertEqual(PinnedMarginCard.friendSpan(20_000), "20 sec")
        XCTAssertEqual(PinnedMarginCard.friendSpan(45_000, leadInMs: 45_000), "45 sec")
        XCTAssertEqual(PinnedMarginCard.friendSpan(46_000, leadInMs: 45_000), "under 1 min")
        XCTAssertEqual(PinnedMarginCard.friendSpan(60_000, leadInMs: 60_000), "60 sec")
        XCTAssertEqual(PinnedMarginCard.friendSpan(61_000, leadInMs: 60_000), "2 min")
        XCTAssertEqual(PinnedMarginCard.friendSpan(10_000, leadInMs: 5_000), "under 1 min", "a short run-up cuts over earlier")
        XCTAssertEqual(PinnedMarginCard.friendCountdown(30_000, leadInMs: 45_000), "in 30 sec")
        let card = PinnedMarginCard(
            subject: .friend("Cole"), stage: .upNext(msRemaining: 40_000, arrival: .playsByItself), run: .none, targetLeadInMs: 45_000)
        XCTAssertEqual(card.headline, "Next Margin in 40 sec")
        let none = PinnedMarginCard(subject: .friend("Cole"), stage: .upNext(msRemaining: 40_000, arrival: .playsByItself), run: .none)
        XCTAssertEqual(none.headline, "Next Margin in under 1 min")
        let heard = PinnedMarginCard(
            subject: .friend("Cole"), stage: .upNext(msRemaining: 50_000, arrival: .onRequest), run: .none, targetLeadInMs: 60_000)
        XCTAssertEqual(heard.detail, "It's 50 sec ahead and won't play by itself.")
    }

    func testTheHopButtonsNameTheSendersLength() {
        let seek = NextMarginPress.seekToLeadIn(mediaTimeMs: 1)
        func hop(_ ms: Int?) -> PinnedMarginCard.Action {
            PinnedMarginCard(
                subject: .friend("Cole"), stage: .upNext(msRemaining: 600_000, arrival: .playsByItself), nextPress: seek, run: .review,
                targetLeadInMs: ms).actions[0]
        }
        XCTAssertEqual(hop(nil).hint, "Moves the episode to about 20 seconds before the next Margin.")
        XCTAssertEqual(hop(60_000).hint, "Moves the episode to about 1 minute before the next Margin.")
        XCTAssertEqual(hop(120_000).hint, "Moves the episode to about 2 minutes before the next Margin.")
        XCTAssertEqual(hop(45_000).hint, "Moves the episode to about 45 seconds before the next Margin.")
        XCTAssertEqual(hop(90_000).hint, "Moves the episode to about 90 seconds before the next Margin.")
        XCTAssertEqual(hop(60_000).title, "Skip to just before Cole", "the listener never sees a length in the button")
        let coming = PinnedMarginCard(
            subject: .friend("Cole"), stage: .comingUp(msRemaining: 300_000), nextPress: seek, run: .review, targetLeadInMs: 60_000)
        XCTAssertEqual(coming.actions[0].hint, "Moves the episode to about 1 minute before this Margin.")
    }

    // MARK: The item screen's minutes

    func testSkipMinutesCountTheSendersLengthBeforeEachMargin() {
        func waiting(_ leadInMs: Int?) -> ItemListeningChoices.WaitingMargin {
            ItemListeningChoices.WaitingMargin(senderName: "Cole", audioDurationMs: 4_000, transcript: "", leadInMs: leadInMs)
        }
        XCTAssertEqual(ItemListeningChoices.marginsOnlyMinutes([waiting(nil), waiting(nil)]), 1, "2 x (20 + 4) s")
        XCTAssertEqual(ItemListeningChoices.marginsOnlyMinutes([waiting(120_000), waiting(120_000)]), 4, "2 x (120 + 4) s")
        XCTAssertEqual(ItemListeningChoices.marginsOnlyMinutes([waiting(120_000), waiting(nil)]), 2, "one long, one default: 124 + 24 s")
        XCTAssertEqual(ItemListeningChoices.marginsOnlyMinutes([waiting(5_000)]), 1, "never under a minute")
        let entry = entries([("a", 600_000, 60_000)])[0]
        XCTAssertEqual(entry.waitingMargin.leadInMs, 60_000, "the item screen reads the imported length")
        XCTAssertNil(entries([("b", 600_000, nil)])[0].waitingMargin.leadInMs)
    }
}
