import XCTest
@testable import SessionKit

/// "Start a minute earlier" on the pinned Margin card (#4171, Design PR 3b): where the button shows, in what order, with
/// what words, and where it never shows. The rule for what the press does is `StartEarlier` (`StartEarlierTests`).
final class StartEarlierCardTests: XCTestCase {
    private let sam = PinnedMarginCard.Subject.friend("Sam")
    private let title = "Start a minute earlier"

    private func card(
        _ subject: PinnedMarginCard.Subject, _ stage: PinnedMarginCard.Stage,
        press: NextMarginPress = .unavailable, run: PinnedMarginCard.Run = .review, chains: Bool = false, offered: Bool = true,
        noun: SourceNoun = .episode
    ) -> PinnedMarginCard {
        PinnedMarginCard(
            subject: subject, stage: stage, noun: noun, nextPress: press, run: run, chainsWithoutLeadIn: chains,
            canStartEarlier: offered)
    }

    private func card(
        _ stage: PinnedMarginCard.Stage, press: NextMarginPress = .unavailable, run: PinnedMarginCard.Run = .review,
        chains: Bool = false, offered: Bool = true
    ) -> PinnedMarginCard {
        card(sam, stage, press: press, run: run, chains: chains, offered: offered)
    }

    private func titles(_ card: PinnedMarginCard) -> [String] { card.actions.map(\.title) }

    // MARK: Where it shows, and in what order

    func testAReviewsRunUpOffersItBetweenSkipToNowAndStop() {
        XCTAssertEqual(
            titles(card(.comingUp(msRemaining: 8_000), press: .playMarginNow)),
            ["Skip to Sam now", title, "Stop Margins"])
    }

    func testAPlainMomentsRunUpOffersItBetweenSkipToNowAndKeepListening() {
        XCTAssertEqual(
            titles(card(.comingUp(msRemaining: 8_000), run: .moment)),
            ["Skip to Sam now", title, "Keep listening"])
    }

    func testWhileAFriendsVoicePlaysItIsTheSecondButtonInAnyRun() {
        for run in [PinnedMarginCard.Run.none, .moment, .review] {
            XCTAssertEqual(titles(card(.speaking, press: .skipVoice, run: run)), ["Skip this Margin", title], "\(run)")
        }
    }

    func testItIsSecondaryAndItsHintSaysWhatThePressDoes() throws {
        let action = try XCTUnwrap(card(.speaking).actions.first { $0.job == .startEarlier })
        XCTAssertEqual(action.prominence, PinnedMarginCard.Action.Prominence.secondary)
        XCTAssertEqual(action.hint, "Plays one more minute of the episode before this Margin.")
        XCTAssertEqual(action.title, title)
    }

    // MARK: Where it never shows

    func testFarOutsideAReviewsRunUpTheHopShowsAndItDoesNot() {
        // The hop is "Skip to just before Sam": a longer run-up from there would move the listener forward.
        let far = card(.comingUp(msRemaining: 120_000), press: .seekToLeadIn(mediaTimeMs: 1))
        XCTAssertEqual(titles(far), ["Skip to just before Sam", "Stop Margins"])
    }

    func testNotForTheListenersOwnMargin() {
        for stage in [PinnedMarginCard.Stage.speaking, .comingUp(msRemaining: 8_000)] {
            XCTAssertFalse(card(.yours, stage, press: .playMarginNow, run: .moment).actions.contains { $0.job == .startEarlier }, "\(stage)")
            XCTAssertFalse(card(.yours, stage, press: .playMarginNow).actions.contains { $0.job == .startEarlier }, "\(stage)")
        }
    }

    func testNotInACantPlayListeningWhichHasNoRunUp() {
        XCTAssertEqual(titles(card(.speaking, press: .skipVoice, chains: true)), ["Skip this Margin", "Stop Margins"])
    }

    func testNotWhenTheModelFoundNothingEarlierToStartFrom() {
        // Already at the episode's start (`StartEarlier.plan` is nil): no dead button.
        XCTAssertEqual(titles(card(.speaking, offered: false)), ["Skip this Margin"])
        XCTAssertEqual(titles(card(.comingUp(msRemaining: 8_000), press: .playMarginNow, offered: false)), ["Skip to Sam now", "Stop Margins"])
        XCTAssertEqual(titles(card(.comingUp(msRemaining: 8_000), run: .moment, offered: false)), ["Skip to Sam now", "Keep listening"])
    }

    func testNotInAnyOtherStageEvenWhenOffered() {
        let others: [PinnedMarginCard.Stage] = [
            .reading, .voicePaused, .loading, .failed, .waitingForTap,
            .upNext(msRemaining: 90_000, arrival: .playsByItself), .upNext(msRemaining: 90_000, arrival: .onRequest),
            .silentHere(words: "hi", isApproximate: false), .answerSaved(atMs: 1_000, sentTo: "Sam"), .lastMargin(senders: 1),
        ]
        for stage in others {
            for run in [PinnedMarginCard.Run.none, .moment, .review] {
                XCTAssertFalse(
                    card(stage, press: .playMarginNow, run: run).actions.contains { $0.job == .startEarlier }, "\(stage) in \(run)")
            }
        }
    }

    // MARK: Large text

    func testAtAccessibility3AndAboveTheCardLeavesItOffAndKeepsEveryOtherButton() {
        let cards = [
            card(.speaking), card(.comingUp(msRemaining: 8_000), press: .playMarginNow),
            card(.comingUp(msRemaining: 8_000), run: .moment),
        ]
        for c in cards {
            XCTAssertEqual(c.shownActions(atAccessibility3OrLarger: false), c.actions, "\(c.stage)")
            let large = c.shownActions(atAccessibility3OrLarger: true)
            XCTAssertEqual(large, c.actions.filter { $0.job != .startEarlier }, "\(c.stage)")
            XCTAssertEqual(large.count, c.actions.count - 1, "\(c.stage): it was there to drop")
        }
        // A card without it is unchanged at every size.
        let plain = card(.failed)
        XCTAssertEqual(plain.shownActions(atAccessibility3OrLarger: true), plain.actions)
    }

    // MARK: The press and the card after a restart (fresh review of PR 3b)

    /// What the model builds for the card from a running review at `position`: the press context and the plan.
    private func cardInReview(_ sequence: MarginMomentSequence, at position: Int) -> PinnedMarginCard {
        let press = NextMarginPress.press(.momentLeadIn(
            isReview: true, positionMs: position, targetMs: sequence.target.mediaTimeMs,
            targetLeadInMs: sequence.target.leadInMs, runUpStartMs: sequence.targetRunUpStartMediaTimeMs))
        return card(
            .comingUp(msRemaining: sequence.msUntilTarget(currentMediaTimeMs: position)), press: press,
            offered: sequence.startEarlierPlan(currentMediaTimeMs: position) != nil)
    }

    /// The defect: the press read the anchor's own length (none, so 20 sec) and offered "Skip to just before Sam", a hop a
    /// minute forward, right after the listener asked for more. With the review's run-up start it is the run-up, and every
    /// press adds another minute.
    func testAfterEachPressInAReviewTheCardStaysInTheLongerRunUpAndOffersItAgain() throws {
        let sam = MarginMomentAnchor(marginId: "a", mediaTimeMs: 900_000, label: "Sam")
        var sequence = try XCTUnwrap(MarginMomentSequence(itemId: "item", reviewing: [sam, MarginMomentAnchor(marginId: "b", mediaTimeMs: 1_500_000, label: "Sam")]))
        var position = 885_000
        XCTAssertEqual(titles(cardInReview(sequence, at: position)), ["Skip to Sam now", title, "Stop Margins"])
        for (press, start) in [(1, 820_000), (2, 760_000), (3, 700_000)] {
            let plan = try XCTUnwrap(sequence.startEarlierPlan(currentMediaTimeMs: position), "press \(press)")
            XCTAssertEqual(sequence.restartLonger(marginId: plan.marginId, leadInMs: plan.leadInMs), start)
            XCTAssertEqual(sequence.targetRunUpStartMediaTimeMs, start)
            position = start
            XCTAssertEqual(titles(cardInReview(sequence, at: position)), ["Skip to Sam now", title, "Stop Margins"], "press \(press)")
        }
        // Without the run-up start, the press falls back to the anchor's length and hops forward: the bug.
        XCTAssertEqual(
            NextMarginPress.press(.momentLeadIn(isReview: true, positionMs: 700_000, targetMs: 900_000)),
            .seekToLeadIn(mediaTimeMs: 880_000))
    }

    /// Past five minutes the run-up is longer than any sender may ask for; the press still reads it whole.
    func testARunUpLongerThanASenderMayChooseStillReadsAsTheRunUp() throws {
        var sequence = try XCTUnwrap(MarginMomentSequence(itemId: "item", reviewing: [MarginMomentAnchor(marginId: "a", mediaTimeMs: 3_600_000, label: "Sam")]))
        var position = 3_590_000
        for _ in 0..<6 {
            let plan = try XCTUnwrap(sequence.startEarlierPlan(currentMediaTimeMs: position))
            position = try XCTUnwrap(sequence.restartLonger(marginId: plan.marginId, leadInMs: plan.leadInMs))
        }
        XCTAssertEqual(position, 3_220_000, "20 sec and six minutes")
        XCTAssertEqual(titles(cardInReview(sequence, at: position)), ["Skip to Sam now", title, "Stop Margins"])
    }

    /// A Margin playing by itself: the one-Margin review starts a minute before it, and its card is the run-up's.
    func testTheReviewStartedFromAMarginPlayingByItselfShowsTheRunUpCard() throws {
        let sam = MarginMomentAnchor(marginId: "a", mediaTimeMs: 900_000, label: "Sam", leadInMs: 120_000)
        let plan = try XCTUnwrap(StartEarlier.plan(for: sam, runUpMs: 0))
        let sequence = try XCTUnwrap(StartEarlier.review(itemId: "item", margin: sam, plan: plan))
        XCTAssertEqual(sequence.targetRunUpStartMediaTimeMs, 840_000)
        XCTAssertEqual(titles(cardInReview(sequence, at: 840_000)), ["Skip to Sam now", title, "Stop Margins"])
        XCTAssertNil(sequence.placeToReturnToWhenStopped(sourceAtMediaTimeMs: 845_000), "Stop in the run-up stays where it is")
    }

    func testAPlainMomentAndACantPlayListeningGiveNoRunUpStart() throws {
        let plain = MarginMomentSequence(itemId: "item", target: MarginMomentAnchor(marginId: "a", mediaTimeMs: 900_000), otherMargins: [])
        XCTAssertNil(plain.targetRunUpStartMediaTimeMs)
        let cantPlay = try XCTUnwrap(MarginMomentSequence(itemId: "item", reviewing: [MarginMomentAnchor(marginId: "a", mediaTimeMs: 0)], leadInMs: 0))
        XCTAssertNil(cantPlay.targetRunUpStartMediaTimeMs)
    }
}
