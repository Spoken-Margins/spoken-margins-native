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
}
