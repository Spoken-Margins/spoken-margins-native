import XCTest
@testable import SessionKit

/// The pinned Margin card's words, its buttons, and the two-press Next Margin rule (#3220, #460, #3597).
final class PinnedMarginCardTests: XCTestCase {
    private let cole = PinnedMarginCard.Subject.friend("Cole")
    private let nobody = PinnedMarginCard.Subject.friend(nil)
    private let leadIn = MarginMomentSequence.reviewLeadInMs / 1_000

    private func card(
        _ subject: PinnedMarginCard.Subject, _ stage: PinnedMarginCard.Stage, voiceTime: String? = nil,
        noun: SourceNoun = .episode, press: NextMarginPress = .unavailable, run: PinnedMarginCard.Run = .review
    ) -> PinnedMarginCard {
        PinnedMarginCard(subject: subject, stage: stage, voiceTime: voiceTime, noun: noun, nextPress: press, run: run)
    }

    private func titles(_ card: PinnedMarginCard) -> [String] { card.actions.map(\.title) }

    private let more = NextMarginPress.skipVoice
    private let seek = NextMarginPress.seekToLeadIn(mediaTimeMs: 1)

    // MARK: The lead-in is the real one

    func testTheLeadInInTheButtonIsTheReviewsOwnValueNotALiteral() {
        XCTAssertEqual(MarginMomentSequence.reviewLeadInMs, 20_000, "the owner's call on #3059; the old code comment said 15")
        let jump = card(cole, .upNext(msRemaining: 39 * 60_000, arrival: .playsByItself), press: seek).actions[0]
        XCTAssertEqual(jump.title, "Skip to just before Cole")
        XCTAssertEqual(jump.hint, "Moves the episode to about \(MarginMomentSequence.reviewLeadInMs / 1_000) seconds before the next Margin.")
        XCTAssertEqual(jump.hint, "Moves the episode to about 20 seconds before the next Margin.")
    }

    // MARK: Words while a Margin plays

    func testWhileAMarginPlaysTheHeadlineNamesTheSenderAndTheDetailSaysTheSourceIsPaused() {
        let speaking = card(cole, .speaking, voiceTime: "0:14 of 0:41")
        XCTAssertEqual(speaking.headline, "Margin from Cole")
        XCTAssertEqual(speaking.detail, "0:14 of 0:41 · Episode paused while it plays.")
        XCTAssertEqual(card(cole, .speaking).detail, "Episode paused while it plays.", "no clock yet")
        XCTAssertEqual(card(nobody, .speaking).headline, "Shared Margin")
        XCTAssertEqual(card(.yours, .speaking).headline, "Your Margin")
        XCTAssertEqual(card(cole, .voicePaused, voiceTime: "0:14 of 0:41").headline, "Margin from Cole is paused")
        XCTAssertEqual(card(cole, .voicePaused, voiceTime: "0:14 of 0:41").detail, "0:14 of 0:41 · Episode stays paused.")
        XCTAssertEqual(card(nobody, .voicePaused).headline, "Shared Margin is paused")
        XCTAssertEqual(card(nobody, .voicePaused).detail, "Episode stays paused.")
    }

    func testAWrittenMarginReadByThePhoneNeverSaysTheFriendSpeaks() {
        XCTAssertEqual(card(cole, .reading).headline, "Margin from Cole")
        XCTAssertEqual(card(cole, .reading).detail, "Your phone's voice is reading Cole's words.")
        XCTAssertEqual(card(nobody, .reading).headline, "Shared Margin")
        XCTAssertEqual(card(nobody, .reading).detail, "Your phone's voice is reading this Margin.")
        XCTAssertEqual(card(.yours, .reading).detail, "Your phone's voice is reading your words.")
        for subject in [cole, nobody, .yours] {
            XCTAssertFalse(card(subject, .reading).headline.contains("speaking"))
            XCTAssertFalse(card(subject, .reading).headline.contains("wrote"))
        }
    }

    func testLoadingKeepsTheOwnersWords() {
        XCTAssertEqual(card(cole, .loading).headline, "Loading Cole's Margin")
        XCTAssertEqual(card(nobody, .loading).headline, "Loading this Margin")
        XCTAssertEqual(card(cole, .loading).detail, "Hold on, this is getting ready.")
        XCTAssertEqual(card(.friend("Unsigned sender"), .loading).headline, "Loading this Margin", "the stand-in is never a name")
    }

    func testAStandInNeverBecomesAFriendOnTheCard() {
        for raw in ["Unsigned sender", "Imported collection", " imported collection ", "", "  "] {
            let subject = PinnedMarginCard.Subject.friend(raw)
            XCTAssertNil(subject.name, raw)
            XCTAssertEqual(subject.title, "Shared Margin", raw)
            XCTAssertEqual(subject.wordsOwner, "this Margin", raw)
        }
        XCTAssertEqual(PinnedMarginCard.Subject.friend("Ana").title, "Margin from Ana")
        XCTAssertEqual(PinnedMarginCard.Subject.friend(" Ana ").name, "Ana")
    }

    /// The Timeline's `collectionLabel` stand-in ("a friend") becomes a Margin's anchor label, which the model hands to
    /// `Subject.friend` as it is. The stand-in is dropped where the subject is built, so every stage reads "Shared Margin".
    func testTheTimelinesAFriendStandInIsNeverANameOnAnyStage() {
        for raw in ["a friend", "A friend", " a  Friend ", "your friend", "Friend"] {
            let subject = PinnedMarginCard.Subject.friend(raw)
            XCTAssertEqual(subject.title, "Shared Margin", raw)
            XCTAssertEqual(subject.loadingTitle, "Loading this Margin", raw)
            XCTAssertEqual(subject.wordsOwner, "this Margin", raw)
            for stage in [PinnedMarginCard.Stage.speaking, .reading, .loading, .failed, .comingUp(msRemaining: 8_000), .waitingForTap] {
                let c = card(subject, stage)
                let words = c.headline + " " + c.detail
                XCTAssertFalse(words.localizedCaseInsensitiveContains("friend"), "\(raw) in \(stage): \(words)")
            }
        }
        XCTAssertEqual(PinnedMarginCard.Subject.friend("Friendly Fran").name, "Friendly Fran", "a real name that starts with the word stays")
    }

    func testAnAnnouncedMarginIsOnlyHeardWhenItsVoiceTrulyPlayed() {
        // Announced (the tone sounded, or the card was dismissed) is not heard.
        XCTAssertEqual(PinnedMarginCard.Arrival.forMargin(announced: true, heard: true, revealMode: .guided), .onRequest)
        XCTAssertEqual(PinnedMarginCard.Arrival.forMargin(announced: true, heard: false, revealMode: .guided), .announcedUnheard)
        XCTAssertEqual(PinnedMarginCard.Arrival.forMargin(announced: false, heard: false, revealMode: .guided), .playsByItself)
        let unheard = card(cole, .upNext(msRemaining: 39 * 60_000, arrival: .announcedUnheard), press: seek)
        XCTAssertEqual(unheard.headline, "Next Margin in 39 min")
        XCTAssertEqual(unheard.detail, "It won't play by itself.")
        XCTAssertFalse((unheard.headline + unheard.detail).contains("heard"))
        XCTAssertEqual(titles(unheard), ["Skip to just before Cole"])
        let heard = card(cole, .upNext(msRemaining: 39 * 60_000, arrival: .onRequest), press: seek)
        XCTAssertEqual(heard.headline, "You've heard this one")
        XCTAssertEqual(titles(heard), ["Hear it again"])
    }

    func testAMarginWaitingForATapShowsItsWordsOnlyWhenTheListenerChoosesAndCapsThem() {
        XCTAssertEqual(PinnedMarginCard.waitingTranscript("  Hello there ", playsByItself: false), "Hello there")
        XCTAssertNil(PinnedMarginCard.waitingTranscript("Hello there", playsByItself: true), "an auto-played Margin keeps the card's own line: no 420 ms height change")
        XCTAssertNil(PinnedMarginCard.waitingTranscript("   ", playsByItself: false))
        XCTAssertNil(PinnedMarginCard.waitingTranscript(nil, playsByItself: false))
        let long = String(repeating: "word ", count: 200)
        let capped = PinnedMarginCard.waitingTranscript(long, playsByItself: false) ?? ""
        XCTAssertLessThanOrEqual(capped.count, 241, "Listen and Dismiss stay on the screen")
        XCTAssertTrue(capped.hasSuffix("…"))
    }

    // MARK: One button while a Margin plays

    func testWhileAMarginPlaysThereIsOneButtonNamedForWhatItDoes() {
        for stage in [PinnedMarginCard.Stage.speaking, .reading, .voicePaused, .loading] {
            // In a review with a lead-in: Skip this Margin alone, whether or not more follow, and never a Stop (#3597:
            // "No Stop button; the pause control already does that job"). Stopping a voice does not move the listener to the next
            // Margin, so the button never says "Next Margin" (audit on #3623).
            for press in [more, .playMarginNow, .unavailable] {
                XCTAssertEqual(titles(card(cole, stage, press: press)), ["Skip this Margin"], "\(stage) \(press)")
                XCTAssertEqual(card(cole, stage, press: press).actions.map(\.job), [.skipThisMargin])
                XCTAssertFalse(card(cole, stage, press: press).actions.contains { $0.job == .stopReview }, "\(stage) \(press)")
            }
            // Outside a review nothing teleports the listener: a friend's Margin that plays by itself, or a moment's, is
            // skipped, whatever the press would be (owner, 2026-11-06).
            for run in [PinnedMarginCard.Run.none, .moment] {
                for press in [more, seek, .playMarginNow, .unavailable] {
                    let c = card(cole, stage, press: press, run: run)
                    XCTAssertEqual(titles(c), ["Skip this Margin"], "\(stage) \(run) \(press)")
                    XCTAssertEqual(c.actions.map(\.job), [.skipThisMargin])
                }
            }
        }
    }

    func testACantPlayListeningKeepsItsStopBecauseItHasNoLeadInToLeaveFrom() {
        for stage in [PinnedMarginCard.Stage.speaking, .reading, .voicePaused, .loading] {
            let c = PinnedMarginCard(subject: cole, stage: stage, noun: .episode, nextPress: more, run: .review, chainsWithoutLeadIn: true)
            XCTAssertEqual(c.actions.map(\.job), [.skipThisMargin, .stopReview], "\(stage)")
            XCTAssertEqual(c.actions[1].prominence, .quiet)
            // Outside a review the flag changes nothing.
            let plain = PinnedMarginCard(subject: cole, stage: stage, noun: .episode, nextPress: more, run: .none, chainsWithoutLeadIn: true)
            XCTAssertEqual(plain.actions.map(\.job), [.skipThisMargin])
        }
    }

    func testAReviewsStopIsTrueToWhatItDoesWhichIsPause() {
        // `stopReview` pauses the source and goes back only to undo the review's own hop (`MarginMomentSequence.placeToReturnToWhenStopped`).
        // It is drawn only at a review's lead-in now, never while a voice plays.
        let stop = card(cole, .comingUp(msRemaining: 8_000), press: more).actions[1]
        XCTAssertEqual(stop.title, "Stop")
        XCTAssertEqual(stop.hint, "Stops these Margins and pauses the episode. If none of them has played yet, it goes back to where you were.")
        XCTAssertFalse(stop.hint.contains("carries on"))
    }

    func testFailureNamesTheSameWayOnAsTheButtonItDraws() {
        let onward = card(cole, .failed, press: more)
        XCTAssertEqual(onward.headline, "Margin from Cole could not play")
        XCTAssertEqual(onward.detail, "Tap Retry, or skip this Margin.")
        XCTAssertEqual(titles(onward), ["Retry", "Skip this Margin"])
        let last = card(cole, .failed, press: .unavailable)
        XCTAssertEqual(last.detail, "Tap Retry, or skip this Margin.")
        // The playback dock also draws "Return to Source" during a friend's voice; the card does not repeat that name.
        // Folding the two into one job is a follow-up for #3599.
        XCTAssertFalse(last.detail.contains("Return to Source"))
        let byItself = card(cole, .failed, press: more, run: .none)
        XCTAssertEqual(titles(byItself), ["Retry", "Skip this Margin"], "outside a review it is skipped, not hopped past")
        XCTAssertEqual(byItself.detail, "Tap Retry, or skip this Margin.")
        for c in [onward, last] { XCTAssertLessThanOrEqual(c.detail.count, 38, "fits one line at 322 pt") }
        XCTAssertEqual(titles(last), ["Retry", "Skip this Margin"])
        XCTAssertEqual(card(nobody, .failed).headline, "Shared Margin could not play")
        for press in [more, seek, .playMarginNow, .unavailable] {
            let c = card(cole, .failed, press: press)
            XCTAssertFalse(c.detail.contains("Next Margin"), "a failed voice is skipped, not hopped past: \(press)")
            XCTAssertFalse(titles(c).contains("Next Margin"), "\(press)")
        }
    }

    // MARK: Coming up (a lead-in under way)

    func testAReviewsLeadInMainButtonIsThePressAndItsExitIsStop() {
        let far = card(cole, .comingUp(msRemaining: 39 * 60_000), press: seek)
        XCTAssertEqual(titles(far), ["Skip to just before Cole", "Stop"])
        XCTAssertEqual(far.actions.map(\.job), [.goToNextMargin, .stopReview])
        XCTAssertEqual(far.actions[0].hint, "Moves the episode to about 20 seconds before this Margin.")
        for press in [NextMarginPress.playMarginNow, .unavailable, .skipVoice] {
            let near = card(cole, .comingUp(msRemaining: 8_000), press: press)
            XCTAssertEqual(titles(near), ["Skip to Cole now", "Stop"], "\(press)")
            XCTAssertEqual(near.actions.map(\.job), [.playMomentNow, .stopReview])
        }
        for c in [far, card(cole, .comingUp(msRemaining: 8_000))] {
            XCTAssertFalse(titles(c).contains("Back to the episode"), "a review's Stop pauses; it does not carry on")
            XCTAssertFalse(c.actions[1].hint.contains("carries on"))
        }
    }

    /// #3791: the two presses between a friend's Margins are "Skip to …", the owner's words of 2026-11-05. A sender with
    /// no name reads "it"; your own Margins keep the words they had.
    func testTheTwoPressesOfAFriendsMarginReadSkipToAndYourOwnKeepTheirWords() {
        for (subject, hop, now) in [
            (cole, "Skip to just before Cole", "Skip to Cole now"),
            (nobody, "Skip to just before it", "Skip to it now"),
        ] {
            XCTAssertEqual(titles(card(subject, .comingUp(msRemaining: 39 * 60_000), press: seek))[0], hop)
            XCTAssertEqual(titles(card(subject, .comingUp(msRemaining: 8_000), press: .playMarginNow))[0], now)
            XCTAssertEqual(titles(card(subject, .upNext(msRemaining: 120_000, arrival: .playsByItself), press: seek)), [hop])
            XCTAssertEqual(titles(card(subject, .upNext(msRemaining: 120_000, arrival: .playsByItself), press: .playMarginNow)), [now])
        }
        XCTAssertEqual(titles(card(.yours, .comingUp(msRemaining: 8_000), press: .playMarginNow, run: .moment)), ["Play it now", "Keep listening"])
        XCTAssertEqual(titles(card(.yours, .comingUp(msRemaining: 39 * 60_000), press: seek))[0], "Jump to 20 sec before it")
    }

    func testAPlainMomentsLeadInOffersPlayItNowAndKeepListening() {
        for press in [more, seek, .playMarginNow, .unavailable] {
            let c = card(cole, .comingUp(msRemaining: 8_000), press: press, run: .moment)
            XCTAssertEqual(titles(c), ["Skip to Cole now", "Keep listening"], "\(press)")
            XCTAssertEqual(c.actions.map(\.job), [.playMomentNow, .keepListening])
        }
    }

    func testALeadInOffersPlayItNowAndANamedExitAndNothingThatRepeatsThem() {
        for press in [more, seek, .playMarginNow, .unavailable] {
            let c = card(cole, .comingUp(msRemaining: 8_000), press: press, run: .moment)
            XCTAssertEqual(titles(c).count, 2, "\(press)")
        }
        let c = card(cole, .comingUp(msRemaining: 8_000), run: .moment)
        XCTAssertEqual(c.headline, "Margin from Cole in 0:08")
        XCTAssertEqual(c.detail, "It plays by itself when the episode gets there.")
        XCTAssertEqual(card(nobody, .comingUp(msRemaining: 8_000)).headline, "Shared Margin in 0:08")
        XCTAssertEqual(card(.yours, .comingUp(msRemaining: 8_000)).headline, "Your Margin in 0:08")
        XCTAssertEqual(card(cole, .comingUp(msRemaining: nil)).headline, "Margin from Cole is coming up")
        XCTAssertFalse(titles(c).contains("Stop review"))
        XCTAssertFalse(titles(c).contains("Cancel"))
    }

    // MARK: Waiting for a tap

    func testAMarginWaitingForATapOffersListenAndDismiss() {
        let c = card(cole, .waitingForTap)
        XCTAssertEqual(c.headline, "Margin from Cole is here")
        XCTAssertEqual(c.detail, "Tap Listen to hear it.", "a tone-only card leaves the episode playing, so it never says paused")
        XCTAssertEqual(titles(c), ["Listen", "Dismiss"])
        XCTAssertEqual(c.actions.map(\.job), [.listen, .dismiss])
        XCTAssertEqual(card(nobody, .waitingForTap).headline, "Shared Margin is here")
    }

    // MARK: Between Margins

    func testBetweenMarginsTheHeadlineAndDetailFollowWhatHappensAtTheNextMargin() {
        func up(_ arrival: PinnedMarginCard.Arrival, ms: Int? = 39 * 60_000, press: NextMarginPress = .unavailable, subject: PinnedMarginCard.Subject? = nil) -> PinnedMarginCard {
            card(subject ?? cole, .upNext(msRemaining: ms, arrival: arrival), press: press)
        }
        XCTAssertEqual(up(.playsByItself).headline, "Next Margin in 39 min")
        XCTAssertEqual(up(.playsByItself).detail, "Plays by itself when you get there.")
        XCTAssertEqual(up(.playsByItself, ms: nil).headline, "Next Margin is ahead")
        XCTAssertEqual(up(.toneThenTap).headline, "Next Margin in 39 min")
        XCTAssertEqual(up(.toneThenTap).detail, "You'll hear a tone. Tap Listen to hear it.")
        XCTAssertEqual(up(.onRequest).headline, "You've heard this one")
        XCTAssertEqual(up(.onRequest).detail, "It's 39 min ahead and won't play by itself.")
        XCTAssertEqual(up(.onRequest, ms: nil).detail, "It won't play by itself.")
        XCTAssertEqual(up(.onRequest, ms: 30_000).detail, "It's under 1 min ahead and won't play by itself.")
        XCTAssertEqual(up(.onRequest, ms: 5_000).detail, "It's 5 sec ahead and won't play by itself.")
        XCTAssertEqual(up(.waitsForYou).headline, "Next Margin in 39 min")
        XCTAssertEqual(up(.waitsForYou).detail, "This one waits for you.")
        XCTAssertEqual(up(.playsByItself, ms: 5_000).headline, "Next Margin in 5 sec")
        for subject in [cole, nobody] {
            let text = [up(.playsByItself, subject: subject), up(.onRequest, subject: subject)].map { $0.headline + $0.detail }.joined()
            XCTAssertFalse(text.contains("friend"), "no name, no friend")
            XCTAssertFalse(text.contains("first"), "the owner replaced 'first Margin' (2026-11-06)")
        }
    }

    func testBetweenMarginsTheOneButtonIsTheOneTheTapMakes() {
        func button(_ arrival: PinnedMarginCard.Arrival, _ press: NextMarginPress) -> [String] {
            titles(card(cole, .upNext(msRemaining: 120_000, arrival: arrival), press: press))
        }
        XCTAssertEqual(button(.playsByItself, seek), ["Skip to just before Cole"])
        XCTAssertEqual(button(.toneThenTap, seek), ["Skip to just before Cole"])
        XCTAssertEqual(button(.playsByItself, .playMarginNow), ["Skip to Cole now"])
        XCTAssertEqual(button(.toneThenTap, .playMarginNow), ["Skip to Cole now"])
        XCTAssertEqual(button(.onRequest, seek), ["Hear it again"])
        XCTAssertEqual(button(.onRequest, .playMarginNow), ["Hear it again"], "a heard Margin never offers \"Skip to Cole now\" (text sources always press playMarginNow)")
        XCTAssertEqual(button(.waitsForYou, .playMarginNow), ["Skip to Cole now"])
        XCTAssertEqual(button(.playsByItself, .unavailable), [], "nowhere to go, no button")
        XCTAssertEqual(button(.onRequest, .unavailable), [])
        let all = [PinnedMarginCard.Arrival.playsByItself, .toneThenTap, .onRequest, .waitsForYou]
        for arrival in all {
            XCTAssertEqual(card(cole, .upNext(msRemaining: 1, arrival: arrival), press: seek).actions.map(\.job), [.goToNextMargin])
        }
    }

    func testTheButtonAndTheRealPressAgreeAtEveryPosition() {
        // The button is built from the press the rule makes, so the first press says "Skip to just before" and the second "Skip to … now".
        let marginAt = 120_000
        let lead = MarginMomentSequence.leadInStartMediaTimeMs(
            forTarget: MarginMomentAnchor(marginId: "m", mediaTimeMs: marginAt), leadInMs: MarginMomentSequence.reviewLeadInMs)
        func title(position: Int, arrival: PinnedMarginCard.Arrival = .toneThenTap) -> String? {
            let press = NextMarginPress.press(.sharedPlayback(positionMs: position, nextMarginMs: marginAt, arrival: arrival))
            return card(cole, .upNext(msRemaining: marginAt - position, arrival: arrival), press: press).actions.first?.title
        }
        XCTAssertEqual(title(position: 10_000), "Skip to just before Cole")
        XCTAssertEqual(title(position: lead - 1), "Skip to just before Cole")
        XCTAssertEqual(title(position: lead), "Skip to Cole now", "inside the lead-in the second press plays it")
        XCTAssertEqual(title(position: 10_000, arrival: .waitsForYou), "Skip to Cole now", "a Fresh layer has no lead-in")
        XCTAssertEqual(title(position: 10_000, arrival: .onRequest), "Hear it again")
        XCTAssertEqual(title(position: lead, arrival: .onRequest), "Hear it again")
    }

    func testAPlainMomentListeningForOthersSaysSoAndOffersOneWayToStop() {
        let c = card(.yours, .upNext(msRemaining: nil, arrival: .playsByItself))
        XCTAssertEqual(c.headline, "Your next Margin is ahead")
        XCTAssertEqual(c.detail, "Plays by itself when you get there.")
        XCTAssertEqual(titles(c), ["Stop playing my Margins"])
        XCTAssertEqual(c.actions[0].job, .stopPlayingMine)
        // Never another button here, whatever the press says.
        XCTAssertEqual(titles(card(.yours, .upNext(msRemaining: nil, arrival: .playsByItself), press: seek)), ["Stop playing my Margins"])
    }

    // MARK: The last Margin and a saved answer

    func testNoNameNeverBecomesYourFriendOnTheLastMarginCard() {
        let named = card(cole, .lastMargin(senders: 1))
        XCTAssertEqual(named.headline, "That was Cole's last Margin")
        XCTAssertEqual(named.detail, "To answer Cole, add a Margin of your own.")
        let unnamed = card(nobody, .lastMargin(senders: 1))
        XCTAssertEqual(unnamed.headline, "That was the last Margin")
        XCTAssertEqual(unnamed.detail, "To answer, add a Margin of your own.")
        XCTAssertEqual(unnamed.actions, [], "no buttons beyond what the sharing card draws")
        XCTAssertEqual(card(.yours, .answerSaved(atMs: nil, sentTo: "Cole")).actions, [])
    }

    // MARK: Every stage, every subject, every noun

    func testEveryStageHasAHeadlineADetailAndNoFriendNobodyNamed() {
        let stages: [PinnedMarginCard.Stage] = [
            .speaking, .reading, .voicePaused, .loading, .failed, .comingUp(msRemaining: 1_000), .comingUp(msRemaining: nil), .waitingForTap,
            .upNext(msRemaining: nil, arrival: .toneThenTap), .upNext(msRemaining: 90_000, arrival: .onRequest),
            .answerSaved(atMs: nil, sentTo: "Cole"), .lastMargin(senders: 1),
        ]
        let nouns: [SourceNoun] = [.episode, .article, .pdf]
        for stage in stages {
            for noun in nouns {
                for press in [NextMarginPress.unavailable, seek] {
                    let c = card(nobody, stage, noun: noun, press: press)
                    XCTAssertFalse(c.headline.isEmpty, "\(stage)")
                    XCTAssertFalse(c.detail.isEmpty, "\(stage)")
                    let words = c.headline + " " + c.detail + c.actions.map(\.title).joined(separator: " ") + c.actions.map(\.hint).joined(separator: " ")
                    for banned in ["item", "review", "friend", "Return to Source"] {
                        XCTAssertFalse(words.localizedCaseInsensitiveContains(banned), "\(banned) in \(stage): \(words)")
                    }
                    if c.detail.contains("paused") || c.detail.contains("plays by itself when") {
                        XCTAssertTrue(c.detail.localizedCaseInsensitiveContains(noun.inSentence), "the source's own noun in \(stage): \(c.detail)")
                    }
                }
            }
        }
    }

    func testTheNounComesFromTheSourceAndIsInEveryLineThatNamesIt() {
        XCTAssertEqual(card(cole, .speaking, noun: .article).detail, "Article paused while it plays.")
        XCTAssertEqual(card(cole, .speaking, noun: .pdf).detail, "PDF paused while it plays.")
        XCTAssertEqual(card(cole, .voicePaused, noun: .pdf).detail, "PDF stays paused.")
        XCTAssertEqual(card(cole, .failed, noun: .article, press: more).detail, "Tap Retry, or skip this Margin.")
        XCTAssertEqual(card(cole, .comingUp(msRemaining: 1_000), noun: .article).detail, "It plays by itself when the article gets there.")
        XCTAssertEqual(card(cole, .comingUp(msRemaining: 1_000), noun: .pdf).detail, "It plays by itself when the PDF gets there.")
        XCTAssertEqual(card(cole, .comingUp(msRemaining: 1_000), noun: .article, press: more).actions[1].hint, "Stops these Margins and pauses the article. If none of them has played yet, it goes back to where you were.")
        XCTAssertEqual(card(cole, .speaking, noun: .pdf, run: .none).actions[0].hint, "Stops this Margin and carries on with the PDF.")
    }

    func testTheNounHelperReadsTheSameFactsTheLibraryRowReads() {
        XCTAssertEqual(SourceNoun(mediaType: "transcript_backed_media", sourceReference: nil, sourceReferenceType: nil), .episode)
        XCTAssertEqual(SourceNoun(mediaType: "podcast", sourceReference: nil, sourceReferenceType: nil), .episode)
        XCTAssertEqual(SourceNoun(mediaType: "article", sourceReference: nil, sourceReferenceType: nil), .article)
        XCTAssertEqual(SourceNoun(mediaType: "text", sourceReference: "https://example.com/a", sourceReferenceType: "url"), .article)
        XCTAssertEqual(SourceNoun(mediaType: "pdf", sourceReference: nil, sourceReferenceType: nil), .pdf)
        XCTAssertEqual(SourceNoun(mediaType: "text", sourceReference: "Paper.PDF", sourceReferenceType: "file"), .pdf)
        XCTAssertEqual(SourceNoun(mediaType: "epub", sourceReference: nil, sourceReferenceType: nil), .book)
        XCTAssertEqual(SourceNoun(mediaType: "audiobook", sourceReference: nil, sourceReferenceType: nil), .audiobook)
        XCTAssertEqual(SourceNoun(mediaType: "text", sourceReference: nil, sourceReferenceType: nil), .text)
        XCTAssertEqual(SourceNoun(mediaType: "PDF", sourceReference: nil, sourceReferenceType: nil).capitalized, "PDF")
    }

    // MARK: Hints say what a tap does

    func testEveryButtonHasAHintThatSaysWhatItsTapDoes() {
        let cards = [
            card(cole, .speaking, press: more), card(cole, .speaking), card(cole, .failed, press: more),
            card(cole, .comingUp(msRemaining: 1_000)), card(cole, .comingUp(msRemaining: 1_000), run: .moment), card(cole, .waitingForTap),
            card(cole, .upNext(msRemaining: 90_000, arrival: .onRequest), press: seek),
            card(cole, .upNext(msRemaining: 90_000, arrival: .playsByItself), press: seek),
            card(cole, .upNext(msRemaining: 90_000, arrival: .playsByItself), press: .playMarginNow),
            card(.yours, .upNext(msRemaining: nil, arrival: .playsByItself)),
        ]
        for c in cards {
            XCTAssertFalse(c.actions.isEmpty, "\(c.stage)")
            for action in c.actions { XCTAssertFalse(action.hint.isEmpty, "\(action.title)") }
        }
        let jump = card(cole, .upNext(msRemaining: 90_000, arrival: .playsByItself), press: seek).actions[0]
        XCTAssertEqual(jump.hint, "Moves the episode to about 20 seconds before the next Margin.")
        XCTAssertEqual(card(cole, .upNext(msRemaining: 90_000, arrival: .playsByItself), press: .playMarginNow).actions[0].hint, "Plays the next Margin now.")
    }

    func testOnlyTheNextMarginButtonFollowsTheRecordingLock() {
        XCTAssertTrue(PinnedMarginCard.Action.Job.goToNextMargin.followsNavigationLock)
        for job in [PinnedMarginCard.Action.Job.skipThisMargin, .retry, .playMomentNow, .keepListening, .stopReview, .stopPlayingMine, .listen, .dismiss] {
            XCTAssertFalse(job.followsNavigationLock, "\(job)")
        }
    }

    // MARK: Clock, position, countdown

    func testAPlayingVoiceShowsHowFarThroughItIs() {
        XCTAssertEqual(PinnedMarginCard.voiceTime(current: 14.4, duration: 40.2), "0:14 of 0:41")
        XCTAssertEqual(PinnedMarginCard.voiceTime(current: 99, duration: 40), "0:40 of 0:40", "never past the end")
        XCTAssertEqual(PinnedMarginCard.voiceTime(current: -1, duration: 40), "0:00 of 0:40")
        XCTAssertNil(PinnedMarginCard.voiceTime(current: 3, duration: .nan), "a clock that is not a number yet")
        XCTAssertNil(PinnedMarginCard.voiceTime(current: .nan, duration: 40))
        XCTAssertNil(PinnedMarginCard.voiceTime(current: 3, duration: 0))
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

    func testOneMarginIsNotCounted() {
        XCTAssertNil(PinnedMarginCard.position(1, of: 1))
        XCTAssertNil(PinnedMarginCard.position(1, of: 0))
        XCTAssertEqual(PinnedMarginCard.position(2, of: 3), "2 of 3")
    }

    func testTheCountdownRoundsUpSoItNeverPromisesAnEarlyArrival() {
        XCTAssertEqual(PinnedMarginCard.countdown(0), "0:00")
        XCTAssertEqual(PinnedMarginCard.countdown(1), "0:01")
        XCTAssertEqual(PinnedMarginCard.countdown(8_000), "0:08")
        XCTAssertEqual(PinnedMarginCard.countdown(8_001), "0:09")
        XCTAssertEqual(PinnedMarginCard.countdown(61_000), "1:01")
        XCTAssertEqual(PinnedMarginCard.countdown(-5), "0:00")
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
        XCTAssertEqual(PinnedMarginCard.friendSpan(39 * 60_000), "39 min")
        for ms in stride(from: 0, through: 15 * 60_000, by: 997) {
            let text = PinnedMarginCard.friendCountdown(ms)
            XCTAssertFalse(text.hasPrefix("in 0 "), "\(ms): \(text)")
            XCTAssertFalse(text.contains(":"), "no clock format: \(text)")
        }
    }

    // MARK: The two presses (owner, 2026-10-31): unchanged

    func testReviewNextMarginGoesFromLeadInStraightToTheMarginAndFromAVoiceToTheNextLeadIn() {
        XCTAssertEqual(NextMarginPress.press(.momentLeadIn(isReview: true)), .playMarginNow, "no positions known: straight to the Margin")
        XCTAssertEqual(NextMarginPress.press(.momentVoice(isReview: true, isLastMargin: false)), .skipVoice)
        XCTAssertEqual(NextMarginPress.press(.momentVoice(isReview: true, isLastMargin: true)), .unavailable,
                       "after the last Margin Skip this Margin is the only way on")
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
}
