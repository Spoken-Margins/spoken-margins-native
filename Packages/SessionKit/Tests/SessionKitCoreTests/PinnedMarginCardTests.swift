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
        XCTAssertEqual(PinnedMarginCard(subject: cole, stage: .reading, position: position).headline, "Cole wrote this", "a synthetic voice never reads as Cole speaking")
        XCTAssertEqual(PinnedMarginCard(subject: .friend(nil), stage: .reading).headline, "A friend wrote this")
        XCTAssertEqual(PinnedMarginCard(subject: cole, stage: .reading, voiceTime: "0:02 of 0:05").detail, "0:02 of 0:05 · Your phone's voice is reading Cole's words.")
        XCTAssertEqual(PinnedMarginCard(subject: cole, stage: .reading).detail, "Your phone's voice is reading Cole's words.")
        XCTAssertEqual(PinnedMarginCard(subject: .friend(nil), stage: .reading).detail, "Your phone's voice is reading your friend's words.")
        XCTAssertEqual(PinnedMarginCard(subject: cole, stage: .comingUp(msRemaining: 8_000)).headline, "Cole's Margin in 0:08")
        XCTAssertEqual(PinnedMarginCard(subject: cole, stage: .comingUp(msRemaining: nil)).headline, "Getting to Cole's Margin")
        XCTAssertEqual(PinnedMarginCard(subject: .yours, stage: .upNext(msRemaining: 80_000, arrival: .playsByItself)).headline, "Next: Your Margin in 1:20",
                       "his own Margins keep the old words (#3247)")
        XCTAssertEqual(PinnedMarginCard(subject: cole, stage: .waitingForTap).headline, "Cole's Margin is here")
        XCTAssertEqual(PinnedMarginCard(subject: .yours, stage: .speaking).headline, "You are speaking")
        XCTAssertEqual(PinnedMarginCard(subject: .friend(nil), stage: .speaking).headline, "A friend is speaking")
        XCTAssertEqual(PinnedMarginCard(subject: .friend(nil), stage: .failed(canMoveOn: true)).headline, "A friend's Margin could not play")
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

    func testAFailedVoiceOnTheLastMarginPointsAtReturnToSourceNotAtADisabledButton() {
        let last = PinnedMarginCard(subject: cole, stage: .failed(canMoveOn: false)).detail
        XCTAssertTrue(last.contains("Return to Source"))
        XCTAssertFalse(last.contains("Next Margin"))
        XCTAssertTrue(PinnedMarginCard(subject: cole, stage: .failed(canMoveOn: true)).detail.contains("Next Margin"))
    }

    /// The card promises what the offer will do, per Margin: a mixed set of layers on one episode (#3220 audit).
    func testWhatHappensAtAMarginComesFromThatMarginsOwnLayerAndTheOfferRules() {
        typealias Arrival = PinnedMarginCard.Arrival
        XCTAssertEqual(Arrival.forMargin(announced: false, revealMode: .guided), .playsByItself)
        XCTAssertEqual(Arrival.forMargin(announced: false, revealMode: .companion), .toneThenTap)
        XCTAssertEqual(Arrival.forMargin(announced: false, revealMode: nil), .toneThenTap)
        XCTAssertEqual(Arrival.forMargin(announced: true, revealMode: .guided), .onRequest, "announced is not offered again")
        XCTAssertEqual(Arrival.forMargin(announced: false, revealMode: .fresh), .waitsForYou, "Fresh is never offered")
        XCTAssertEqual(Arrival.forMargin(announced: true, revealMode: .fresh), .waitsForYou)
        // It agrees with the prompt style the model acts on, for every reveal mode.
        for mode in ImportedCommentaryRevealMode.allCases where mode != .fresh {
            let plays = SharedMarginPromptStyle.style(revealMode: mode, arrival: .crossed).autoPlayAfterMs != nil
            XCTAssertEqual(Arrival.forMargin(announced: false, revealMode: mode) == .playsByItself, plays, "\(mode)")
        }
    }

    func testAFreshLayersMarginIsReachedInOnePressNotThroughALeadInThatEndsInSilence() {
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: 10_000, nextMarginMs: 120_000, arrival: .waitsForYou)),
            .playMarginNow)
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: 10_000, nextMarginMs: 120_000, arrival: .toneThenTap)),
            .seekToLeadIn(mediaTimeMs: MarginMomentSequence.leadInStartMediaTimeMs(
                forTarget: MarginMomentAnchor(marginId: "m", mediaTimeMs: 120_000), leadInMs: MarginMomentSequence.reviewLeadInMs)))
    }

    func testAFailedVoiceSaysTheEpisodeStaysPaused() {
        XCTAssertTrue(PinnedMarginCard(subject: cole, stage: .failed(canMoveOn: true)).detail.hasPrefix("The episode is paused."))
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
            .speaking, .voicePaused, .loading, .failed(canMoveOn: true), .comingUp(msRemaining: 1_000), .waitingForTap, .upNext(msRemaining: nil, arrival: .toneThenTap),
            .answerSaved(atMs: nil, sentTo: "Cole"), .lastMargin(senders: 1), .lastMargin(senders: 2),
        ]
        for stage in stages {
            let card = PinnedMarginCard(subject: cole, stage: stage)
            XCTAssertFalse(card.headline.isEmpty, "\(stage)")
            XCTAssertFalse(card.detail.isEmpty, "\(stage)")
        }
    }

    func testReviewNextMarginGoesFromLeadInStraightToTheMarginAndFromAVoiceToTheNextLeadIn() {
        XCTAssertEqual(NextMarginPress.press(.momentLeadIn(isReview: true)), .playMarginNow, "no positions known: straight to the Margin")
        XCTAssertEqual(NextMarginPress.press(.momentVoice(isReview: true, isLastMargin: false)), .skipVoice)
        XCTAssertEqual(NextMarginPress.press(.momentVoice(isReview: true, isLastMargin: true)), .unavailable,
                       "after the last Margin Skip to the item is the only way on")
        XCTAssertEqual(NextMarginPress.press(.momentLeadIn(isReview: false)), .unavailable, "Play it now covers a single moment")
        XCTAssertEqual(NextMarginPress.press(.momentVoice(isReview: false, isLastMargin: false)), .unavailable)
    }

    /// Owner, 2026-11-06: between Margins the episode plays on and "you have to click a button to skim forward to the next
    /// person's Margins' lead-in". The first press hops to the lead-in; the second plays the Margin.
    func testReviewNextMarginBetweenMarginsIsTwoPressesAndNeverHopsByItself() {
        let marginAt = 2_312_900
        let leadIn = marginAt - MarginMomentSequence.reviewLeadInMs
        func press(at position: Int?) -> NextMarginPress {
            NextMarginPress.press(.momentLeadIn(isReview: true, positionMs: position, targetMs: marginAt))
        }
        XCTAssertEqual(press(at: 60_000), .seekToLeadIn(mediaTimeMs: leadIn), "far off: the first press goes to the lead-in")
        XCTAssertEqual(press(at: leadIn - 1_001), .seekToLeadIn(mediaTimeMs: leadIn))
        XCTAssertEqual(press(at: leadIn - 1), .playMarginNow, "the review's own seek can land a millisecond short: that is the lead-in")
        XCTAssertEqual(press(at: leadIn), .playMarginNow, "in the lead-in: the second press plays the Margin")
        XCTAssertEqual(press(at: marginAt - 500), .playMarginNow)
        XCTAssertEqual(press(at: nil), .playMarginNow)
        XCTAssertEqual(NextMarginPress.press(.momentLeadIn(isReview: true, positionMs: 1_000, targetMs: 5_000)), .playMarginNow,
                       "a Margin near the start has its lead-in clamped at 0, so there is nowhere to hop")
        XCTAssertEqual(NextMarginPress.press(.momentLeadIn(isReview: false, positionMs: 60_000, targetMs: marginAt)), .unavailable)
    }

    func testNextMarginInPlainPlaybackIsTwoPresses() {
        let marginAt = 120_000
        let leadIn = MarginMomentSequence.leadInStartMediaTimeMs(
            forTarget: MarginMomentAnchor(marginId: "m", mediaTimeMs: marginAt), leadInMs: MarginMomentSequence.reviewLeadInMs
        )
        XCTAssertLessThan(leadIn, marginAt)
        // First press, far away: go to the lead-in.
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: 10_000, nextMarginMs: marginAt, arrival: .playsByItself)),
            .seekToLeadIn(mediaTimeMs: leadIn))
        // Second press, now inside the lead-in: straight to the Margin.
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: leadIn, nextMarginMs: marginAt, arrival: .playsByItself)),
            .playMarginNow)
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: marginAt - 1, nextMarginMs: marginAt, arrival: .playsByItself)),
            .playMarginNow)
        // Just before the lead-in starts it is still a first press.
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: leadIn - 1, nextMarginMs: marginAt, arrival: .playsByItself)),
            .seekToLeadIn(mediaTimeMs: leadIn))
        // A voice sounding at 100 s with another Margin at 103 s: that Margin's lead-in began before the playhead, so
        // the press plays it, instead of seeking back into the Margin that is playing.
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: 100_000, nextMarginMs: 103_000, arrival: .playsByItself)), .playMarginNow)
        XCTAssertEqual(NextMarginPress.press(.sharedPlayback(positionMs: 10_000, nextMarginMs: nil, arrival: .playsByItself)), .unavailable)
    }

    func testALeadInThatWouldStartBeforeTheStartOfTheEpisodeSeeksToZero() {
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: nil, nextMarginMs: 500, arrival: .playsByItself)),
            .seekToLeadIn(mediaTimeMs: 0))
        XCTAssertEqual(
            NextMarginPress.press(.sharedPlayback(positionMs: 0, nextMarginMs: 500, arrival: .playsByItself)),
            .playMarginNow, "at the start, a Margin 0.5 s in is already inside its lead-in")
    }

    func testTheNextMarginIsTheFirstOneAfterThePlayhead() {
        XCTAssertEqual(NextMarginPress.nextMarginMs(after: 50_000, among: [90_000, 10_000, 60_000]), 60_000)
        XCTAssertNil(NextMarginPress.nextMarginMs(after: 90_000, among: [90_000, 10_000]), "the one playing is not the next")
        XCTAssertEqual(NextMarginPress.nextMarginMs(after: nil, among: [90_000, 10_000]), 10_000)
        XCTAssertNil(NextMarginPress.nextMarginMs(after: 5, among: []))
    }

    // MARK: A friend's words between Margins (#3247)

    private func upNextHeadline(_ subject: PinnedMarginCard.Subject, ms: Int?, first: Bool) -> String {
        PinnedMarginCard(subject: subject, stage: .upNext(msRemaining: ms, arrival: .playsByItself), isFirstFromSender: first).headline
    }

    func testAFriendsHeadlineSaysFirstOnlyWhenItIsTrueAndNextAfterThat() {
        XCTAssertEqual(upNextHeadline(cole, ms: 11 * 60_000 + 28_000, first: true), "Cole's first Margin in 12 min")
        XCTAssertEqual(upNextHeadline(cole, ms: 11 * 60_000, first: true), "Cole's first Margin in 11 min")
        XCTAssertEqual(upNextHeadline(cole, ms: 11 * 60_000, first: false), "Cole's next Margin in 11 min")
        XCTAssertEqual(upNextHeadline(.friend(nil), ms: 11 * 60_000, first: true), "A friend's first Margin in 11 min")
        XCTAssertEqual(upNextHeadline(.friend("  "), ms: 11 * 60_000, first: false), "A friend's next Margin in 11 min")
        XCTAssertEqual(upNextHeadline(.friend(SharedPacketArrival.unsignedSenderLabel), ms: 60_000, first: true), "A friend's first Margin in 1 min",
                       "the stand-in label is never a name")
        XCTAssertEqual(upNextHeadline(cole, ms: nil, first: true), "Cole's first Margin is ahead")
        XCTAssertEqual(upNextHeadline(.friend("Bartholomew"), ms: 5_000, first: false), "Bartholomew's next Margin in 5 sec")
    }

    func testOnlyAFriendsBetweenMarginsCardChangesItsWords() {
        XCTAssertEqual(upNextHeadline(.yours, ms: 11 * 60_000, first: true), "Next: Your Margin in 11:00")
        XCTAssertEqual(PinnedMarginCard(subject: cole, stage: .comingUp(msRemaining: 8_000), isFirstFromSender: true).headline, "Cole's Margin in 0:08",
                       "a review's lead-in keeps its seconds")
        XCTAssertEqual(PinnedMarginCard(subject: cole, stage: .waitingForTap, isFirstFromSender: true).headline, "Cole's Margin is here")
        for press in [NextMarginPress.seekToLeadIn(mediaTimeMs: 1), .playMarginNow, .skipVoice, .unavailable] {
            XCTAssertEqual(NextMarginWords(press: press, subject: .yours).title, "Next Margin", "\(press)")
            XCTAssertNil(NextMarginWords(press: press, subject: .yours).hint)
        }
    }

    func testTheMinuteCountdownRoundsUpNeverSaysZeroAndHandsOverToSecondsAtTheLeadIn() {
        let leadIn = MarginMomentSequence.reviewLeadInMs
        XCTAssertEqual(PinnedMarginCard.friendCountdown(11 * 60_000 + 28_000), "in 12 min")
        XCTAssertEqual(PinnedMarginCard.friendCountdown(11 * 60_000), "in 11 min")
        XCTAssertEqual(PinnedMarginCard.friendCountdown(120_001), "in 3 min", "rounds up")
        XCTAssertEqual(PinnedMarginCard.friendCountdown(60_001), "in 2 min")
        XCTAssertEqual(PinnedMarginCard.friendCountdown(60_000), "in 1 min", "exactly one minute")
        XCTAssertEqual(PinnedMarginCard.friendCountdown(59_999), "in under 1 min")
        XCTAssertEqual(PinnedMarginCard.friendCountdown(leadIn + 1), "in under 1 min")
        XCTAssertEqual(PinnedMarginCard.friendCountdown(leadIn), "in \(leadIn / 1_000) sec", "the lead-in starts the seconds")
        XCTAssertEqual(PinnedMarginCard.friendCountdown(1), "in 1 sec")
        XCTAssertEqual(PinnedMarginCard.friendCountdown(1_001), "in 2 sec")
        XCTAssertEqual(PinnedMarginCard.friendCountdown(0), "in 1 sec")
        XCTAssertEqual(PinnedMarginCard.friendCountdown(-500), "in 1 sec")
        for ms in stride(from: 0, through: 15 * 60_000, by: 997) {
            let text = PinnedMarginCard.friendCountdown(ms)
            XCTAssertFalse(text.hasPrefix("in 0 "),"\(ms): \(text)")
            XCTAssertFalse(text.contains(":"), "no clock format: \(text)")
        }
    }

    /// The label is built from the press the tap makes, so the two cannot disagree (#3247).
    func testTheSkipButtonDescribesWhatTheTapDoesAtThatMoment() {
        let lead = MarginMomentSequence.leadInStartMediaTimeMs(
            forTarget: MarginMomentAnchor(marginId: "m", mediaTimeMs: 120_000), leadInMs: MarginMomentSequence.reviewLeadInMs)
        func words(position: Int, arrival: PinnedMarginCard.Arrival = .toneThenTap, sender: String? = "Cole") -> NextMarginWords {
            let press = NextMarginPress.press(.sharedPlayback(positionMs: position, nextMarginMs: 120_000, arrival: arrival))
            return NextMarginWords(press: press, subject: .friend(sender))
        }
        XCTAssertEqual(words(position: 10_000).title, "Skip to just before Cole")
        XCTAssertEqual(words(position: lead - 1).title, "Skip to just before Cole")
        XCTAssertEqual(words(position: lead).title, "Skip to Cole now", "inside the lead-in the second press plays it")
        XCTAssertEqual(words(position: 10_000, arrival: .waitsForYou).title, "Skip to Cole now", "a Fresh layer has no lead-in")
        XCTAssertEqual(words(position: 10_000, sender: nil).title, "Skip to just before your friend")
        XCTAssertEqual(words(position: lead, sender: nil).title, "Skip to your friend now")
        XCTAssertEqual(words(position: 10_000, sender: "Bartholomew").title, "Skip to just before Bartholomew")
        XCTAssertEqual(words(position: 10_000, sender: SharedPacketArrival.unsignedSenderLabel).title, "Skip to just before your friend")
        XCTAssertEqual(words(position: 10_000).hint, "Moves the episode to about 20 seconds before Cole's Margin.")
        XCTAssertEqual(words(position: lead).hint, "Plays Cole's Margin now.")
        XCTAssertEqual(NextMarginWords(press: .unavailable, subject: .friend("Cole")).title, "Next Margin")
        XCTAssertNil(NextMarginWords(press: .unavailable, subject: .friend("Cole")).hint)
    }
}
