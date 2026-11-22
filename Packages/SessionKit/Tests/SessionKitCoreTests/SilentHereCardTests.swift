import XCTest
@testable import SessionKit

/// #4934: the pinned card for a friend's Margin the listener went to, that is never spoken.
final class SilentHereCardTests: XCTestCase {
    private let sam = PinnedMarginCard.Subject.friend("Sam")
    private let nobody = PinnedMarginCard.Subject.friend(nil)

    private func card(
        _ subject: PinnedMarginCard.Subject? = nil, words: String? = "Look at this.", approximate: Bool = false,
        noun: SourceNoun = .episode
    ) -> PinnedMarginCard {
        PinnedMarginCard(subject: subject ?? sam, stage: .silentHere(words: words, isApproximate: approximate), noun: noun)
    }

    func testTheHeadlineSaysWhoseMarginIsHere() {
        XCTAssertEqual(card(sam).headline, "Margin from Sam is here")
        XCTAssertEqual(card(nobody).headline, "Shared Margin is here", "no name, no \"A friend\"")
        XCTAssertEqual(card(sam, approximate: true).headline, "Margin from Sam is about here")
        XCTAssertEqual(card(nobody, approximate: true).headline, "Shared Margin is about here")
    }

    func testTheDetailIsTheMarginsOwnWords() {
        XCTAssertEqual(card(words: "Look at this.").detail, "Look at this.")
        XCTAssertEqual(card(words: "  padded \n").detail, "padded")
    }

    func testLongWordsAreCutAsAWaitingCardCutsThem() {
        let long = String(repeating: "word ", count: 80)
        let detail = card(words: long).detail
        XCTAssertEqual(detail, PinnedMarginCard.waitingTranscript(long, playsByItself: false))
        XCTAssertTrue(detail.hasSuffix("…"))
        XCTAssertLessThanOrEqual(detail.count, 241)
        let exact = String(repeating: "a", count: 240)
        XCTAssertEqual(card(words: exact).detail, exact, "240 characters fit whole")
    }

    func testWithNoWordsToShowTheLineSaysSoWithTheSourcesNoun() {
        let rows: [(String, String?)] = [
            ("nil", nil), ("empty", ""), ("blank", "  \n "), ("placeholder", "Voice Margin at 12:34"),
            ("placeholder with a title", "Voice Margin at 1:02:03 in “A show”"),
        ]
        for (name, words) in rows {
            XCTAssertEqual(card(words: words).detail, "Not read aloud. The episode plays on.", name)
        }
        XCTAssertEqual(card(words: nil, noun: .article).detail, "Not read aloud. The article plays on.")
        XCTAssertEqual(card(words: nil, noun: .pdf).detail, "Not read aloud. The PDF plays on.")
        XCTAssertEqual(card(words: "Voice Margin is my favourite thing").detail, "Voice Margin is my favourite thing",
                       "a note that merely begins that way is still a note")
    }

    func testTheOneButtonDismissesAndSaysTheSourceKeepsPlaying() {
        for noun in [SourceNoun.episode, .article, .pdf] {
            let actions = card(noun: noun).actions
            XCTAssertEqual(actions.map(\.job), [.dismissSilentMargin])
            XCTAssertEqual(actions.first?.title, "Dismiss")
            XCTAssertEqual(actions.first?.hint, "Hides this card. The \(noun.inSentence) keeps playing.")
            XCTAssertEqual(actions.first?.prominence, .quiet)
            XCTAssertFalse(actions.first?.job.followsNavigationLock ?? true)
        }
    }

    func testTheCardDrawsNoDetailSymbol() {
        XCTAssertNil(card().detailSymbolBefore)
        XCTAssertNil(card().detailAroundSymbol)
    }

    func testNoOtherStageOffersDismissSilentMargin() {
        let stages: [PinnedMarginCard.Stage] = [
            .speaking, .reading, .voicePaused, .loading, .failed, .comingUp(msRemaining: 1_000), .waitingForTap,
            .upNext(msRemaining: nil, arrival: .playsByItself), .answerSaved(atMs: nil, sentTo: "Sam"), .lastMargin(senders: 1),
        ]
        for stage in stages {
            let jobs = PinnedMarginCard(subject: sam, stage: stage).actions.map(\.job)
            XCTAssertFalse(jobs.contains(.dismissSilentMargin), "\(stage)")
        }
    }

    // MARK: VoiceOver

    private func key(_ card: PinnedMarginCard?, _ id: String?) -> VoiceOverAnnouncements.CardKey { .init(card: card, marginID: id) }

    func testTheCardIsAnnouncedOnceOnLanding() {
        let heard = VoiceOverAnnouncements.marginCard(from: nil, to: key(card(), "a"))
        XCTAssertEqual(heard, "Margin from Sam is here. Look at this.")
        XCTAssertNil(VoiceOverAnnouncements.marginCard(from: key(card(), "a"), to: key(card(), "a")), "the same card redrawn")
    }

    func testTwoLandingsOnMarginsFromOneSenderEachAnnounce() {
        XCTAssertNotNil(VoiceOverAnnouncements.marginCard(from: key(card(words: "One."), "a"), to: key(card(words: "One."), "b")))
    }

    func testAnnouncedWhenItReplacesAnotherStage() {
        let waiting = PinnedMarginCard(subject: sam, stage: .waitingForTap)
        XCTAssertNotNil(VoiceOverAnnouncements.marginCard(from: key(waiting, "a"), to: key(card(), "a")))
        XCTAssertNil(VoiceOverAnnouncements.marginCard(from: key(card(), "a"), to: key(nil, nil)))
    }

    func testStagesThatSpeakForThemselvesStayUnannounced() {
        let speaking = PinnedMarginCard(subject: sam, stage: .speaking)
        XCTAssertNil(VoiceOverAnnouncements.marginCard(from: key(card(), "a"), to: key(speaking, "a")))
    }
}
