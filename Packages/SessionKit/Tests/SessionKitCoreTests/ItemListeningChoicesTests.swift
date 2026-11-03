import XCTest
@testable import SessionKit

/// The item screen's start controls (#3219): two fixed choices when a friend's Margins wait, today's single button
/// otherwise.
final class ItemListeningChoicesTests: XCTestCase {
    private func choices(
        unheard: Int, finished: Bool = false, continuing: Bool = false, preparing: Bool = false
    ) -> ItemListeningChoices {
        ItemListeningChoices(
            unheardFriendMarginCount: unheard, hasFinishedSession: finished,
            hasContinuationSession: continuing, isPreparingAudio: preparing
        )
    }

    /// Every state the plain button knew, with a friend's Margins waiting: the words never change, so a listener who
    /// has already heard the episode (or started it, or is waiting for its audio) still sees the same two choices.
    func testFriendMarginsGiveTheSameTwoChoicesInEveryItemState() {
        for finished in [false, true] {
            for continuing in [false, true] {
                for preparing in [false, true] {
                    let result = choices(unheard: 3, finished: finished, continuing: continuing, preparing: preparing)
                    let state = "finished \(finished), continuing \(continuing), preparing \(preparing)"
                    XCTAssertEqual(result.primaryTitle, "Play episode with Margins", state)
                    XCTAssertEqual(result.marginsOnlyTitle, "Hear just the Margins", state)
                    XCTAssertTrue(result.skipsNewMarginsQuestion, "the dialog no longer interrupts the big button: \(state)")
                }
            }
        }
    }

    func testVoiceOverHearsHowManyMarginsAreWaiting() {
        XCTAssertEqual(choices(unheard: 1).marginsOnlyAccessibilityLabel, "Hear just the Margins, 1 new Margin")
        XCTAssertEqual(choices(unheard: 7).marginsOnlyAccessibilityLabel, "Hear just the Margins, 7 new Margins")
    }

    /// Items without a friend's Margins look as they did: one button, today's words, no second choice.
    func testNoFriendMarginsKeepTheSingleButtonAndItsWords() {
        XCTAssertEqual(choices(unheard: 0).primaryTitle, "Start listening")
        XCTAssertEqual(choices(unheard: 0, continuing: true).primaryTitle, "Continue")
        XCTAssertEqual(choices(unheard: 0, finished: true, continuing: true).primaryTitle, "Replay")
        XCTAssertEqual(choices(unheard: 0, continuing: true, preparing: true).primaryTitle, "Listen now")
        XCTAssertEqual(choices(unheard: 0, finished: true, continuing: true, preparing: true).primaryTitle, "Listen now")
        for continuing in [false, true] {
            let result = choices(unheard: 0, continuing: continuing)
            XCTAssertNil(result.marginsOnlyTitle)
            XCTAssertNil(result.marginsOnlyAccessibilityLabel)
            XCTAssertFalse(result.skipsNewMarginsQuestion, "Continue keeps its question where it still has one to ask")
        }
    }

    /// A negative count (it can't happen, but a bad read must not invent a second choice).
    func testANegativeCountOffersNoSecondChoice() {
        XCTAssertNil(choices(unheard: -1).marginsOnlyTitle)
    }
}
