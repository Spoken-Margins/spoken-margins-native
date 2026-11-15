import XCTest
@testable import SessionKit

/// #3790: when a friend listen is under way on Now, and how the end card does the first-Margin prompt's job.
final class FriendListenStateTests: XCTestCase {
    private func card(_ subject: PinnedMarginCard.Subject, _ stage: PinnedMarginCard.Stage, run: PinnedMarginCard.Run = .none) -> PinnedMarginCard {
        PinnedMarginCard(subject: subject, stage: stage, run: run)
    }

    private func state(entries: Int = 0, card: PinnedMarginCard? = nil, selected: String = "A", playing: String? = "A") -> FriendListenState {
        FriendListenState(selectedItemId: selected, playingItemId: playing, entryCount: entries, pinnedCard: card)
    }

    func testNothingAheadAndNoCardIsNoFriendListen() {
        XCTAssertEqual(state(), .none)
        XCTAssertFalse(state().isInProgress)
        XCTAssertFalse(state().isShowingEndCard)
    }

    func testFriendMarginsAheadHoldTheListenOpenWithOrWithoutACard() {
        XCTAssertTrue(state(entries: 1).isInProgress, "auto-play off and the card not built yet: Margins ahead still count")
        XCTAssertTrue(state(entries: 3, card: card(.friend("Cole"), .upNext(msRemaining: 18_000, arrival: .toneThenTap))).isInProgress)
        XCTAssertFalse(state(entries: 1).isShowingEndCard)
    }

    /// The countdown, the voice, the wait between Margins and the wait for a tap are all the friend's card.
    func testEveryStageOfAFriendsCardIsAFriendListen() {
        let stages: [PinnedMarginCard.Stage] = [
            .speaking, .reading, .voicePaused, .loading, .failed, .comingUp(msRemaining: 8_000), .comingUp(msRemaining: nil),
            .waitingForTap, .upNext(msRemaining: nil, arrival: .playsByItself), .upNext(msRemaining: 5_000, arrival: .onRequest)
        ]
        for stage in stages {
            let value = state(card: card(.friend("Cole"), stage))
            XCTAssertTrue(value.isInProgress, "\(stage)")
            XCTAssertFalse(value.isShowingEndCard, "\(stage)")
        }
        XCTAssertTrue(state(card: card(.friend(nil), .speaking)).isInProgress, "a sender with no name is still a friend")
        XCTAssertTrue(state(card: card(.friend("Cole"), .comingUp(msRemaining: 3_000), run: .review)).isInProgress, "a review of friend Margins")
    }

    func testTheEndCardIsTheEndOfTheListenAndTheOnlyThingThatSaysSo() {
        for senders in [1, 2] {
            let value = state(card: card(.friend(senders == 1 ? "Cole" : nil), .lastMargin(senders: senders)))
            XCTAssertTrue(value.isInProgress, "the slot is still the friend's")
            XCTAssertTrue(value.isShowingEndCard, "\(senders) senders")
        }
    }

    func testTheListenersOwnCardsAreNotAFriendListen() {
        XCTAssertEqual(state(card: card(.yours, .answerSaved(atMs: 60_000, sentTo: "Cole"))), .none, "the Share offer after their reply")
        XCTAssertEqual(state(card: card(.yours, .comingUp(msRemaining: 4_000), run: .moment)), .none, "Play this moment")
        XCTAssertEqual(state(card: card(.yours, .speaking, run: .review)), .none, "a review of their own Margins")
        XCTAssertEqual(state(card: card(.yours, .lastMargin(senders: 1))), .none, "an end card is only ever a friend's")
    }

    /// The Design's first clause is about Margins ahead, whatever card is up: the card alone is not what holds it open.
    func testFriendMarginsAheadHoldTheListenOpenUnderTheListenersOwnCardToo() {
        let own = card(.yours, .answerSaved(atMs: 60_000, sentTo: "Cole"))
        XCTAssertTrue(state(entries: 1, card: own).isInProgress)
        XCTAssertFalse(state(entries: 1, card: own).isShowingEndCard, "only a friend's end card ends it")
    }

    /// A friend's packet on item A while item B plays: Now shows what plays, and that has no friend listen.
    func testOnlyTheItemOnNowThatIsPlayingCanBeAFriendListen() {
        let friends = card(.friend("Cole"), .lastMargin(senders: 1))
        XCTAssertEqual(state(entries: 2, card: friends, selected: "A", playing: "B"), .none)
        XCTAssertEqual(state(entries: 2, card: friends, selected: "B", playing: "A"), .none)
        XCTAssertEqual(state(entries: 2, card: friends, selected: "A", playing: nil), .none, "nothing is playing")
        XCTAssertEqual(state(entries: 0, card: nil, selected: "B", playing: "B"), .none, "B has no friend Margins")
    }

    // MARK: The first-Margin prompt

    private func fresh(steps: [String]? = nil) -> OnboardingProgress {
        OnboardingProgress(storedSteps: steps, storedStage: nil, isCardDismissed: false)
    }

    func testThePromptHidesDuringAFriendListenAndComesBackWhenItIsOverUnlessTheEndCardShowed() {
        let value = fresh()
        XCTAssertTrue(value.shouldShowFirstMarginPrompt(hasActiveSession: true, suppressed: false), "J11: no friend, the prompt shows")
        XCTAssertTrue(value.shouldShowFirstMarginPrompt(hasActiveSession: true, suppressed: false, duringFriendListen: false))
        XCTAssertFalse(value.shouldShowFirstMarginPrompt(hasActiveSession: true, suppressed: false, duringFriendListen: true))
        XCTAssertFalse(value.isComplete(.sawFirstMarginPrompt), "hiding does not mark it seen")
    }

    func testTheEndCardMarksThePromptSeenAndNothingElseDoes() {
        var value = fresh()
        for other in [FriendListenState.none, state(entries: 2), state(card: card(.friend("Cole"), .upNext(msRemaining: 9_000, arrival: .playsByItself)))] {
            XCTAssertEqual(value.noteFriendListen(other), [])
        }
        XCTAssertTrue(value.shouldShowFirstMarginPrompt(hasActiveSession: true, suppressed: false), "not marked by a listen under way")

        let end = state(card: card(.friend("Cole"), .lastMargin(senders: 1)))
        XCTAssertEqual(value.noteFriendListen(end), .steps)
        XCTAssertTrue(value.isComplete(.sawFirstMarginPrompt))
        XCTAssertFalse(value.shouldShowFirstMarginPrompt(hasActiveSession: true, suppressed: false), "so it does not appear later")
        XCTAssertEqual(value.noteFriendListen(end), [], "a second call writes nothing")
    }

    func testTheSeenMarkSurvivesARelaunchAndTheEndCardIsNotACoreStep() {
        var value = fresh()
        value.noteFriendListen(state(card: card(.friend("Cole"), .lastMargin(senders: 1))))
        let reloaded = fresh(steps: value.storedSteps)
        XCTAssertFalse(reloaded.shouldShowFirstMarginPrompt(hasActiveSession: true, suppressed: false))
        XCTAssertEqual(reloaded.coreCompletedCount, 0, "seeing the prompt is not a tour step")
        XCTAssertEqual(reloaded.stage, .inactive)
    }

    func testAListenerWhoAlreadySawOrDismissedThePromptIsUnchanged() {
        var value = fresh(steps: ["saw_first_margin_prompt"])
        let before = value.storedSteps
        XCTAssertEqual(value.noteFriendListen(state(card: card(.friend("Cole"), .lastMargin(senders: 1)))), [])
        XCTAssertEqual(value.storedSteps, before)
    }
}
