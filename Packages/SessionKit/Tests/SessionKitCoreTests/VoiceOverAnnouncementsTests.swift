import XCTest
@testable import SessionKit

/// #3728: what VoiceOver hears when the Margin card or the Reader changes in place.
final class VoiceOverAnnouncementsTests: XCTestCase {
    private func card(_ stage: PinnedMarginCard.Stage, subject: PinnedMarginCard.Subject = .friend("Cole")) -> PinnedMarginCard {
        PinnedMarginCard(subject: subject, stage: stage)
    }

    func testAMarginWaitingForATapIsAnnouncedWithItsHeadlineAndInstruction() {
        XCTAssertEqual(
            VoiceOverAnnouncements.marginCard(from: nil, to: card(.waitingForTap)),
            "Margin from Cole is here. Tap Listen to hear it.")
        XCTAssertEqual(
            VoiceOverAnnouncements.marginCard(from: card(.comingUp(msRemaining: 3_000)), to: card(.waitingForTap)),
            "Margin from Cole is here. Tap Listen to hear it.")
    }

    func testAFailedMarginIsAnnouncedWithRetry() {
        XCTAssertEqual(
            VoiceOverAnnouncements.marginCard(from: card(.loading), to: card(.failed)),
            "Margin from Cole could not play. Tap Retry, or skip this Margin.")
        XCTAssertEqual(
            VoiceOverAnnouncements.marginCard(from: nil, to: card(.failed, subject: .friend(nil))),
            "Shared Margin could not play. Tap Retry, or skip this Margin.", "no sender name: never \"A friend\"")
    }

    func testTheSameStageAgainIsSilentSoTheCountdownTickDoesNotRepeatIt() {
        XCTAssertNil(VoiceOverAnnouncements.marginCard(from: card(.waitingForTap), to: card(.waitingForTap)))
        XCTAssertNil(VoiceOverAnnouncements.marginCard(from: card(.failed), to: card(.failed)))
    }

    func testStagesThatSpeakForThemselvesAndNoCardAreSilent() {
        let quiet: [PinnedMarginCard.Stage] = [
            .speaking, .reading, .voicePaused, .loading, .comingUp(msRemaining: 8_000), .comingUp(msRemaining: nil),
            .upNext(msRemaining: 60_000, arrival: .playsByItself), .answerSaved(atMs: 1_000, sentTo: "Cole"), .lastMargin(senders: 1),
        ]
        for stage in quiet {
            XCTAssertNil(VoiceOverAnnouncements.marginCard(from: nil, to: card(stage)), "\(stage)")
        }
        XCTAssertNil(VoiceOverAnnouncements.marginCard(from: card(.waitingForTap), to: nil), "the card going away says nothing")
    }

    func testFailureAfterWaitingIsAnnouncedBecauseItIsADifferentStage() {
        XCTAssertNotNil(VoiceOverAnnouncements.marginCard(from: card(.waitingForTap), to: card(.failed)))
        XCTAssertNotNil(VoiceOverAnnouncements.marginCard(from: card(.failed), to: card(.waitingForTap)))
    }

    func testReaderChapterStepSaysPositionAndTitle() {
        XCTAssertEqual(VoiceOverAnnouncements.readerChapter(position: (2, 7), title: "The Method"), "Chapter 2 of 7, The Method")
        XCTAssertEqual(VoiceOverAnnouncements.readerChapter(position: (7, 7), title: "  Notes \n"), "Chapter 7 of 7, Notes")
    }

    func testReaderChapterNeighbours() {
        XCTAssertEqual(VoiceOverAnnouncements.readerChapter(position: (2, 7), title: nil), "Chapter 2 of 7")
        XCTAssertEqual(VoiceOverAnnouncements.readerChapter(position: (2, 7), title: "   "), "Chapter 2 of 7")
        XCTAssertEqual(VoiceOverAnnouncements.readerChapter(position: nil, title: "Full Text"), "Full Text")
        XCTAssertEqual(VoiceOverAnnouncements.readerChapter(position: (1, 1), title: "Only"), "Only", "never \"1 of 1\"")
        XCTAssertEqual(VoiceOverAnnouncements.readerChapter(position: (9, 7), title: "Odd"), "Odd", "an impossible position is not spoken")
        XCTAssertEqual(VoiceOverAnnouncements.readerChapter(position: (0, 7), title: "Odd"), "Odd")
        XCTAssertNil(VoiceOverAnnouncements.readerChapter(position: nil, title: nil))
        XCTAssertNil(VoiceOverAnnouncements.readerChapter(position: (1, 1), title: ""))
    }

    // Audit of #3759, finding 1: a guided Margin waits 420 ms and then plays aloud, so it is never announced.
    func testAMarginThatPlaysByItselfIsSilentWhileItWaitsItsBeat() {
        XCTAssertNil(VoiceOverAnnouncements.marginCard(from: nil, to: card(.waitingForTap), playsByItself: true))
        XCTAssertNil(VoiceOverAnnouncements.marginCard(from: card(.upNext(msRemaining: 5_000, arrival: .playsByItself)),
                                                       to: card(.waitingForTap), playsByItself: true))
        // A failure is announced either way: nothing else tells the listener the voice did not start.
        XCTAssertNotNil(VoiceOverAnnouncements.marginCard(from: card(.loading), to: card(.failed), playsByItself: true))
    }

    // Audit finding 2: with VoiceOver on a tone-only card stays up, and a newly crossed Margin replaces it in the same stage.
    func testANewMarginReplacingAWaitingCardInTheSameStageIsAnnounced() {
        let cole = card(.waitingForTap, subject: .friend("Cole"))
        let dana = card(.waitingForTap, subject: .friend("Dana"))
        XCTAssertEqual(VoiceOverAnnouncements.marginCard(from: cole, to: dana, previousMarginID: "a", marginID: "b"),
                       "Margin from Dana is here. Tap Listen to hear it.", "another sender")
        XCTAssertNotNil(VoiceOverAnnouncements.marginCard(from: cole, to: cole, previousMarginID: "a", marginID: "b"),
                        "a second Margin from the same sender")
        let first = PinnedMarginCard(subject: .friend("Cole"), stage: .waitingForTap, position: "1 of 2")
        let second = PinnedMarginCard(subject: .friend("Cole"), stage: .waitingForTap, position: "2 of 2")
        XCTAssertNotNil(VoiceOverAnnouncements.marginCard(from: first, to: second, previousMarginID: "a", marginID: "a"),
                        "the position moved on")
        XCTAssertNil(VoiceOverAnnouncements.marginCard(from: cole, to: cole, previousMarginID: "a", marginID: "a"),
                     "the same card redrawn stays silent")
    }
}
