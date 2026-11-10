import XCTest
@testable import SessionKit

/// The item screen's start controls (#3219): two fixed choices when a friend's Margins wait, today's single button
/// otherwise.
final class ItemListeningChoicesTests: XCTestCase {
    private func spoken(_ seconds: Int, from name: String = "Cole") -> ItemListeningChoices.WaitingMargin {
        .init(senderName: name, audioDurationMs: seconds * 1_000, transcript: "")
    }

    private func written(words: Int, from name: String = "Cole") -> ItemListeningChoices.WaitingMargin {
        .init(senderName: name, audioDurationMs: nil, transcript: Array(repeating: "word", count: words).joined(separator: " "))
    }

    private func choices(
        _ margins: [ItemListeningChoices.WaitingMargin],
        finished: Bool = false, continuing: Bool = false, preparing: Bool = false
    ) -> ItemListeningChoices {
        ItemListeningChoices(
            unheardFriendMargins: margins, hasFinishedSession: finished,
            hasContinuationSession: continuing, isPreparingAudio: preparing
        )
    }

    /// Three Margins of about 40 s each plus three 20 s lead-ins: the owner's reviewed screen, "· 3 min".
    private var colesThree: [ItemListeningChoices.WaitingMargin] { [spoken(40), spoken(40), written(words: 100)] }

    /// Every state the plain button knew, with a friend's Margins waiting: the words never change, so a listener who
    /// has already heard the episode (or started it, or is waiting for its audio) still sees the same two choices.
    func testFriendMarginsGiveTheSameTwoChoicesInEveryItemState() {
        for finished in [false, true] {
            for continuing in [false, true] {
                for preparing in [false, true] {
                    let result = choices(colesThree, finished: finished, continuing: continuing, preparing: preparing)
                    let state = "finished \(finished), continuing \(continuing), preparing \(preparing)"
                    XCTAssertEqual(result.primaryTitle, "Play", state)
                    XCTAssertEqual(result.marginsOnlyTitle, "Skip to Cole's Margins · 3 min", state)
                    XCTAssertTrue(result.skipsNewMarginsQuestion, "the dialog no longer interrupts the big button: \(state)")
                }
            }
        }
    }

    func testVoiceOverHearsWhoseHowManyAndHowLong() {
        XCTAssertEqual(
            choices(colesThree).marginsOnlyAccessibilityLabel,
            "Skip to Cole's Margins, 3 new Margins, about 3 minutes"
        )
        XCTAssertEqual(
            choices([spoken(10)]).marginsOnlyAccessibilityLabel,
            "Skip to Cole's Margins, 1 new Margin, about 1 minute"
        )
    }

    /// The name only when it is one named friend; otherwise a phrase that is never wrong.
    func testWhoseMarginsNamesOneFriendOnly() {
        let table: [([ItemListeningChoices.WaitingMargin], String)] = [
            ([spoken(30, from: "Cole")], "Cole's Margins"),
            ([spoken(30, from: "  Cole \n")], "Cole's Margins"),
            ([spoken(30, from: "Cole"), spoken(30, from: "Cole")], "Cole's Margins"),
            ([spoken(30, from: "Cole"), spoken(30, from: "Sam")], "the Margins"),
            ([spoken(30, from: "")], "the Margins"),
            ([spoken(30, from: "   ")], "the Margins"),
            ([spoken(30, from: "Cole"), spoken(30, from: "")], "the Margins"),
            ([spoken(30, from: "Zoë")], "Zoë's Margins"),
        ]
        for (margins, expected) in table {
            XCTAssertEqual(ItemListeningChoices.whoseMargins(margins), expected, "\(margins.map(\.senderName))")
        }
    }

    /// Each Margin counts its 20 s lead-in; written ones are timed at the voice's pace; never under a minute.
    func testMarginsOnlyMinutes() {
        XCTAssertEqual(ItemListeningChoices.marginsOnlyMinutes([spoken(1)]), 1, "a short Margin still says 1 min")
        XCTAssertEqual(ItemListeningChoices.marginsOnlyMinutes([spoken(40), spoken(40), spoken(40)]), 3)
        XCTAssertEqual(ItemListeningChoices.marginsOnlyMinutes([written(words: 150)]), 1, "60 s read + 20 s lead-in")
        XCTAssertEqual(ItemListeningChoices.marginsOnlyMinutes([written(words: 0)]), 1)
        XCTAssertEqual(ItemListeningChoices.marginsOnlyMinutes(Array(repeating: spoken(100), count: 10)), 20)
        XCTAssertEqual(
            ItemListeningChoices.marginsOnlyMinutes([.init(senderName: "Cole", audioDurationMs: -5_000, transcript: "")]), 1,
            "a bad negative duration doesn't shorten the total"
        )
    }

    /// Items without a friend's Margins look as they did: one button, today's words, no second choice.
    func testNoFriendMarginsKeepTheSingleButtonAndItsWords() {
        XCTAssertEqual(choices([]).primaryTitle, "Start listening")
        XCTAssertEqual(choices([], continuing: true).primaryTitle, "Continue")
        XCTAssertEqual(choices([], finished: true, continuing: true).primaryTitle, "Replay")
        XCTAssertEqual(choices([], continuing: true, preparing: true).primaryTitle, "Listen now")
        XCTAssertEqual(choices([], finished: true, continuing: true, preparing: true).primaryTitle, "Listen now")
        for continuing in [false, true] {
            let result = choices([], continuing: continuing)
            XCTAssertNil(result.marginsOnlyTitle)
            XCTAssertNil(result.marginsOnlyAccessibilityLabel)
            XCTAssertFalse(result.skipsNewMarginsQuestion, "Continue keeps its question where it still has one to ask")
        }
    }
}
