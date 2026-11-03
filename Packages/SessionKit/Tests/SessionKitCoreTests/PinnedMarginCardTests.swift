import XCTest
@testable import SessionKit

/// The pinned Margin card's words, the slot it holds, and the two-press Next Margin rule (#3220, #460).
final class PinnedMarginCardTests: XCTestCase {
    private let cole = PinnedMarginCard.Subject.friend("Cole")

    func testHeadlinesNameWhoIsSpeakingAndHowLongUntilTheNextMargin() {
        let position = PinnedMarginCard.position(1, of: 3)
        XCTAssertEqual(position, "1 of 3")
        XCTAssertEqual(PinnedMarginCard(subject: cole, stage: .speaking, position: position).headline, "Cole is speaking")
        XCTAssertEqual(PinnedMarginCard(subject: cole, stage: .voicePaused).headline, "Cole's Margin is paused")
        XCTAssertEqual(PinnedMarginCard(subject: cole, stage: .comingUp(msRemaining: 8_000)).headline, "Cole's Margin in 0:08")
        XCTAssertEqual(PinnedMarginCard(subject: cole, stage: .comingUp(msRemaining: nil)).headline, "Getting to Cole's Margin")
        XCTAssertEqual(PinnedMarginCard(subject: cole, stage: .upNext(msRemaining: 80_000, arrival: .playsByItself)).headline, "Next: Cole's Margin in 1:20")
        XCTAssertEqual(PinnedMarginCard(subject: cole, stage: .waitingForTap).headline, "Cole's Margin is here")
        XCTAssertEqual(PinnedMarginCard(subject: .yours, stage: .speaking).headline, "You are speaking")
        XCTAssertEqual(PinnedMarginCard(subject: .friend(nil), stage: .speaking).headline, "A friend is speaking")
        XCTAssertEqual(PinnedMarginCard(subject: .friend(nil), stage: .failed).headline, "A friend's Margin could not play")
    }

    func testWhatHappensAtTheNextMarginIsSaidPlainly() {
        func detail(_ arrival: PinnedMarginCard.Arrival) -> String {
            PinnedMarginCard(subject: cole, stage: .upNext(msRemaining: 5_000, arrival: arrival)).detail
        }
        XCTAssertEqual(detail(.playsByItself), "It plays by itself when the episode gets there.")
        XCTAssertEqual(detail(.toneThenTap), "You will hear a tone. Tap Listen to hear it.")
        XCTAssertEqual(detail(.onRequest), "You have heard this one. Tap Next Margin to hear it again.",
                       "a Margin that was announced already is not promised")
    }

    func testAPlayingVoiceShowsHowFarThroughItIs() {
        XCTAssertEqual(PinnedMarginCard.voiceTime(current: 14.4, duration: 40.2), "0:14 of 0:41")
        XCTAssertEqual(PinnedMarginCard.voiceTime(current: 99, duration: 40), "0:40 of 0:40", "never past the end")
        XCTAssertEqual(PinnedMarginCard.voiceTime(current: -1, duration: 40), "0:00 of 0:40")
        XCTAssertNil(PinnedMarginCard.voiceTime(current: 3, duration: .nan), "a clock that is not a number yet")
        XCTAssertNil(PinnedMarginCard.voiceTime(current: .nan, duration: 40))
        XCTAssertNil(PinnedMarginCard.voiceTime(current: 3, duration: 0))
        let card = PinnedMarginCard(subject: cole, stage: .speaking, voiceTime: "0:14 of 0:41")
        XCTAssertEqual(card.detail, "0:14 of 0:41 · The episode is paused.")
        XCTAssertEqual(PinnedMarginCard(subject: cole, stage: .speaking).detail, "The episode is paused while this plays.")
    }

    func testAFailedVoiceSaysTheEpisodeStaysPaused() {
        XCTAssertTrue(PinnedMarginCard(subject: cole, stage: .failed).detail.hasPrefix("The episode is paused."))
    }

    func testOneMarginIsNotCounted() {
        XCTAssertNil(PinnedMarginCard.position(1, of: 1))
        XCTAssertNil(PinnedMarginCard.position(1, of: 0))
    }

    func testTheCountdownRoundsUpSoItNeverPromisesAnEarlyArrival() {
        XCTAssertEqual(PinnedMarginCard.countdown(0), "0:00")
        XCTAssertEqual(PinnedMarginCard.countdown(1), "0:01")
        XCTAssertEqual(PinnedMarginCard.countdown(8_000), "0:08")
        XCTAssertEqual(PinnedMarginCard.countdown(8_001), "0:09")
        XCTAssertEqual(PinnedMarginCard.countdown(61_000), "1:01")
        XCTAssertEqual(PinnedMarginCard.countdown(-5), "0:00")
    }

    func testEveryStageHasAnExplanationSoTheCardKeepsOneShape() {
        let stages: [PinnedMarginCard.Stage] = [
            .speaking, .voicePaused, .loading, .failed, .comingUp(msRemaining: 1_000), .waitingForTap, .upNext(msRemaining: nil, arrival: .toneThenTap),
        ]
        for stage in stages {
            let card = PinnedMarginCard(subject: cole, stage: stage)
            XCTAssertFalse(card.headline.isEmpty, "\(stage)")
            XCTAssertFalse(card.detail.isEmpty, "\(stage)")
        }
    }

    func testReviewNextMarginGoesFromLeadInStraightToTheMarginAndFromAVoiceToTheNextLeadIn() {
        XCTAssertEqual(NextMarginPress.press(.momentLeadIn(isReview: true)), .playMarginNow)
        XCTAssertEqual(NextMarginPress.press(.momentVoice(isReview: true, isLastMargin: false)), .skipVoice)
        XCTAssertEqual(NextMarginPress.press(.momentVoice(isReview: true, isLastMargin: true)), .unavailable,
                       "after the last Margin Skip to the item is the only way on")
        XCTAssertEqual(NextMarginPress.press(.momentLeadIn(isReview: false)), .unavailable, "Play it now covers a single moment")
        XCTAssertEqual(NextMarginPress.press(.momentVoice(isReview: false, isLastMargin: false)), .unavailable)
    }

    func testNextMarginInPlainPlaybackIsTwoPresses() {
        let marginAt = 120_000
        let leadIn = MarginMomentSequence.leadInStartMediaTimeMs(
            forTarget: MarginMomentAnchor(marginId: "m", mediaTimeMs: marginAt), leadInMs: MarginMomentSequence.reviewLeadInMs
        )
        XCTAssertLessThan(leadIn, marginAt)
        // First press, far away: go to the lead-in.
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: 10_000, nextMarginMs: marginAt)),
            .seekToLeadIn(mediaTimeMs: leadIn))
        // Second press, now inside the lead-in: straight to the Margin.
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: leadIn, nextMarginMs: marginAt)),
            .playMarginNow)
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: marginAt - 1, nextMarginMs: marginAt)),
            .playMarginNow)
        // Just before the lead-in starts it is still a first press.
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: leadIn - 1, nextMarginMs: marginAt)),
            .seekToLeadIn(mediaTimeMs: leadIn))
        // A voice sounding at 100 s with another Margin at 103 s: that Margin's lead-in began before the playhead, so
        // the press plays it, instead of seeking back into the Margin that is playing.
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: 100_000, nextMarginMs: 103_000)), .playMarginNow)
        XCTAssertEqual(NextMarginPress.press(.sharedPlayback(positionMs: 10_000, nextMarginMs: nil)), .unavailable)
    }

    func testALeadInThatWouldStartBeforeTheStartOfTheEpisodeSeeksToZero() {
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: nil, nextMarginMs: 500)),
            .seekToLeadIn(mediaTimeMs: 0))
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: 0, nextMarginMs: 500)),
            .playMarginNow, "at the start, a Margin 0.5 s in is already inside its lead-in")
    }

    func testTheNextMarginIsTheFirstOneAfterThePlayhead() {
        XCTAssertEqual(NextMarginPress.nextMarginMs(after: 50_000, among: [90_000, 10_000, 60_000]), 60_000)
        XCTAssertNil(NextMarginPress.nextMarginMs(after: 90_000, among: [90_000, 10_000]), "the one playing is not the next")
        XCTAssertEqual(NextMarginPress.nextMarginMs(after: nil, among: [90_000, 10_000]), 10_000)
        XCTAssertNil(NextMarginPress.nextMarginMs(after: 5, among: []))
    }
}
