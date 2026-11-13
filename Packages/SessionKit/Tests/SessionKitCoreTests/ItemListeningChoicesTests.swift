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
        }
    }

    // MARK: Replies coming back (#3889)

    private func reply(_ seconds: Int = 30, from name: String = "Sam", to parent: String = "mine-1") -> ItemListeningChoices.WaitingMargin {
        .init(senderName: name, audioDurationMs: seconds * 1_000, transcript: "", replyToYouParentId: parent)
    }

    /// The design's table (#3889): the Skip choice's title and what VoiceOver reads, row by row.
    func testSkipNamesRepliesWhenEveryWaitingMarginIsOne() {
        let table: [(String, [ItemListeningChoices.WaitingMargin], String, String)] = [
            ("all replies", [reply(30), reply(30, to: "mine-2")],
             "Skip to Sam's replies · 2 min", "Skip to Sam's replies, 2 replies to your Margins, about 2 minutes"),
            ("one reply", [reply(30)],
             "Skip to Sam's reply · 1 min", "Skip to Sam's reply, 1 reply to your Margin, about 1 minute"),
            ("two replies to one Margin", [reply(30), reply(30)],
             "Skip to Sam's replies · 2 min", "Skip to Sam's replies, 2 replies to your Margin, about 2 minutes"),
            ("replies, no name", [reply(30, from: ""), reply(30, from: "", to: "mine-2")],
             "Skip to the replies · 2 min", "Skip to the replies, 2 replies to your Margins, about 2 minutes"),
            ("one reply, no name", [reply(30, from: "")],
             "Skip to the reply · 1 min", "Skip to the reply, 1 reply to your Margin, about 1 minute"),
            ("replies, several senders", [reply(30, from: "Sam"), reply(30, from: "Ana", to: "mine-2")],
             "Skip to the replies · 2 min", "Skip to the replies, 2 replies to your Margins, about 2 minutes"),
            ("mixed", [reply(30), spoken(30, from: "Sam")],
             "Skip to Sam's Margins · 2 min", "Skip to Sam's Margins, 1 reply and 1 new Margin, about 2 minutes"),
            ("mixed, no name", [reply(30, from: ""), spoken(30, from: "")],
             "Skip to the Margins · 2 min", "Skip to the Margins, 1 reply and 1 new Margin, about 2 minutes"),
            ("mixed, several senders", [reply(30, from: "Sam"), spoken(30, from: "Ana"), spoken(30, from: "Ana")],
             "Skip to the Margins · 3 min", "Skip to the Margins, 1 reply and 2 new Margins, about 3 minutes"),
            ("no replies to you", [spoken(30, from: "Sam"), spoken(30, from: "Sam")],
             "Skip to Sam's Margins · 2 min", "Skip to Sam's Margins, 2 new Margins, about 2 minutes"),
        ]
        for (name, margins, title, label) in table {
            let result = choices(margins)
            XCTAssertEqual(result.primaryTitle, "Play", name)
            XCTAssertEqual(result.marginsOnlyTitle, title, name)
            XCTAssertEqual(result.marginsOnlyAccessibilityLabel, label, name)
        }
    }

    /// The minutes are today's computation over the waiting Margins; a reply adds no time for its parent.
    func testSkipMinutesDoNotChangeForReplies() {
        let replies = [reply(100), reply(100, to: "mine-2")]
        let plain = [spoken(100, from: "Sam"), spoken(100, from: "Sam")]
        XCTAssertEqual(ItemListeningChoices.marginsOnlyMinutes(replies), ItemListeningChoices.marginsOnlyMinutes(plain))
    }

    func testAReplyIsOneWhoseParentIsTheListenersOwn() {
        XCTAssertTrue(reply().isReplyToYou)
        XCTAssertFalse(spoken(30).isReplyToYou)
    }

    /// The one rule (#3889): only a parent that is the listener's own Margin makes a reply to them. A reply to another
    /// friend's Margin, or whose parent isn't in this Library, is a new Margin on this screen.
    func testOnlyAParentThatIsTheListenersOwnCountsAsAReplyToThem() {
        let table: [(SharedMarginReview.ReplyContext.Parent, String?)] = [
            (.yours(interjectionId: "mine-1", mediaTimeMs: 105_000), "mine-1"),
            (.yours(interjectionId: "mine-2", mediaTimeMs: nil), "mine-2"),
            (.shared(marginId: "layer::m1", label: "Ana", mediaTimeMs: 105_000), nil),
            (.missing, nil),
        ]
        for (parent, expected) in table {
            XCTAssertEqual(SharedMarginReview.ReplyContext(parent: parent).yoursParentId, expected, "\(parent)")
        }
    }
}
