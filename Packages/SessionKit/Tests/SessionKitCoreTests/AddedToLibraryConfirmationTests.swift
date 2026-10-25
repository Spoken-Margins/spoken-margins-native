import Foundation
import SessionKit
import XCTest

final class AddedToLibraryConfirmationTests: XCTestCase {
    func testPlayNowIsOfferedOnlyWhenNowPlayingIsEmpty() {
        let empty = AddedToLibraryConfirmation(title: "The Long Article", nowPlayingIsEmpty: true)
        XCTAssertEqual(empty.message, "Added The Long Article to Library.")
        XCTAssertTrue(empty.offersPlayNow)

        let busy = AddedToLibraryConfirmation(title: "The Long Article", nowPlayingIsEmpty: false)
        XCTAssertEqual(busy.message, "Added The Long Article to Library without changing Now Playing.",
                       "With something in Now Playing, today's message stays as it is")
        XCTAssertFalse(busy.offersPlayNow)
    }

    /// #828: several Safari shares imported together get one message, never a Play now.
    func testSeveralItemsGetOneMessage() {
        XCTAssertEqual(AddedToLibraryConfirmation.message(addedCount: 3, nowPlayingIsEmpty: true), "Added 3 items to Library.")
        XCTAssertEqual(
            AddedToLibraryConfirmation.message(addedCount: 2, nowPlayingIsEmpty: false),
            "Added 2 items to Library without changing Now Playing."
        )
    }

    func testAnOpenSessionHoldsNowPlayingUntilItEnds() {
        XCTAssertTrue(AddedToLibraryConfirmation.nowPlayingIsEmpty(sessionId: nil, phase: .idle))
        for phase in [SessionPhase.idle, .itemPlayback, .recordingInterjection, .summaryPlayback, .conversation] {
            XCTAssertFalse(AddedToLibraryConfirmation.nowPlayingIsEmpty(sessionId: "session-1", phase: phase), "\(phase)")
        }
        XCTAssertTrue(AddedToLibraryConfirmation.nowPlayingIsEmpty(sessionId: "session-1", phase: .finished))
        XCTAssertTrue(AddedToLibraryConfirmation.nowPlayingIsEmpty(sessionId: "session-1", phase: .abandoned))
    }

    func testVoiceOverNamesTheItem() {
        XCTAssertEqual(AddedToLibraryConfirmation.playNowAccessibilityLabel(title: "Episode 12"), "Play now, Episode 12")
    }

    func testAConfirmationWithAnActionStaysLongEnoughToReach() {
        XCTAssertEqual(FeedbackBannerPolicy.autoDismissSeconds(for: .success), 3)
        XCTAssertEqual(FeedbackBannerPolicy.autoDismissSeconds(for: .success, offersAction: true), 8)
        XCTAssertNil(FeedbackBannerPolicy.autoDismissSeconds(for: .error, offersAction: true))
    }
}

// proof
