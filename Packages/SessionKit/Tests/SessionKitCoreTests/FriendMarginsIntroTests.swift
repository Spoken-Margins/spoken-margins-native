import XCTest
@testable import SessionKit

/// The item screen's top while a friend's Margins wait (#3219): who, how many and how long, and what a Margin is.
final class FriendMarginsIntroTests: XCTestCase {
    private func spoken(_ seconds: Int, from name: String = "Cole") -> ItemListeningChoices.WaitingMargin {
        .init(senderName: name, audioDurationMs: seconds * 1_000, transcript: "")
    }

    private func written(words: Int, from name: String = "Cole") -> ItemListeningChoices.WaitingMargin {
        .init(senderName: name, audioDurationMs: nil, transcript: Array(repeating: "word", count: words).joined(separator: " "))
    }

    func testNoFriendMarginsShowsNothing() {
        XCTAssertNil(FriendMarginsIntro(unheardFriendMargins: []))
    }

    /// The owner's reviewed screen: two spoken and one written, about two minutes, the written-Margin explanation.
    func testColesThreeReadAsTheReviewedScreen() throws {
        let intro = try XCTUnwrap(FriendMarginsIntro(unheardFriendMargins: [spoken(40), spoken(40), written(words: 100)]))
        XCTAssertEqual(intro.senderLine, "From Cole")
        XCTAssertEqual(intro.countLine, "3 Margins · about 2 min")
        XCTAssertEqual(
            intro.explanation,
            "A Margin is a note Cole left at a moment in this episode. You'll hear each one there."
        )
    }

    /// "Two versions" (owner, 2026-11-02): "voice note" only when every Margin is spoken.
    func testExplanationSaysVoiceNoteOnlyWhenEveryMarginIsSpoken() throws {
        let allSpoken = try XCTUnwrap(FriendMarginsIntro(unheardFriendMargins: [spoken(30), spoken(30)]))
        XCTAssertEqual(allSpoken.explanation, "A Margin is a voice note Cole left at a moment in this episode.")
        let oneWritten = try XCTUnwrap(FriendMarginsIntro(unheardFriendMargins: [written(words: 20)]))
        XCTAssertTrue(oneWritten.explanation?.hasPrefix("A Margin is a note Cole left") == true)
    }

    /// No single name: a phrase that is never wrong, in the sender line and the explanation alike.
    func testSenderWithoutOneNameIsAFriend() throws {
        for margins in [[spoken(30, from: "")], [spoken(30, from: "Cole"), spoken(30, from: "Sam")], [spoken(30, from: "  ")]] {
            let intro = try XCTUnwrap(FriendMarginsIntro(unheardFriendMargins: margins))
            XCTAssertEqual(intro.senderLine, "From a friend", "\(margins.map(\.senderName))")
            XCTAssertEqual(intro.explanation, "A Margin is a voice note your friend left at a moment in this episode.")
        }
        XCTAssertEqual(FriendMarginsIntro(unheardFriendMargins: [spoken(30, from: " Zoë ")])?.senderLine, "From Zoë")
    }

    func testCountLineIsSingularForOneAndNeverUnderAMinute() {
        XCTAssertEqual(FriendMarginsIntro(unheardFriendMargins: [spoken(5)])?.countLine, "1 Margin · about 1 min")
        XCTAssertEqual(
            FriendMarginsIntro(unheardFriendMargins: Array(repeating: spoken(90), count: 4))?.countLine,
            "4 Margins · about 6 min"
        )
    }

    // MARK: Replies coming back (#3889)

    private func reply(_ seconds: Int = 30, from name: String = "Sam", to parent: String = "mine-1") -> ItemListeningChoices.WaitingMargin {
        .init(senderName: name, audioDurationMs: seconds * 1_000, transcript: "", replyToYouParentId: parent)
    }

    private func writtenReply(words: Int = 20, from name: String = "Sam", to parent: String = "mine-1") -> ItemListeningChoices.WaitingMargin {
        .init(senderName: name, audioDurationMs: nil,
              transcript: Array(repeating: "word", count: words).joined(separator: " "), replyToYouParentId: parent)
    }

    /// The design's table (#3889), row by row: sender line, count line, and whether the explanation shows.
    func testRepliesReadAsRepliesToYourMargins() throws {
        let table: [(String, [ItemListeningChoices.WaitingMargin], String, String, Bool)] = [
            ("all replies", [reply(30), reply(30, to: "mine-2")], "Replies from Sam", "2 replies to your Margins · about 1 min", false),
            ("one reply", [reply(60)], "Replies from Sam", "1 reply to your Margin · about 1 min", false),
            ("two replies to one Margin", [reply(30), writtenReply(words: 50)], "Replies from Sam", "2 replies to your Margin · about 1 min", false),
            ("mixed", [reply(30), spoken(30, from: "Sam")], "From Sam", "1 reply and 1 new Margin · about 1 min", false),
            ("mixed, several new", [reply(30), spoken(30, from: "Sam"), spoken(30, from: "Sam")], "From Sam", "1 reply and 2 new Margins · about 2 min", false),
            ("mixed, several replies", [reply(30), reply(30, to: "mine-2"), spoken(30, from: "Sam")], "From Sam", "2 replies and 1 new Margin · about 2 min", false),
            ("replies, no name", [reply(30, from: ""), reply(30, from: "  ")], "Replies from a friend", "2 replies to your Margin · about 1 min", false),
            ("replies, several senders", [reply(30, from: "Sam"), reply(30, from: "Ana", to: "mine-2"), reply(30, from: "Sam", to: "mine-3")],
             "Replies from friends", "3 replies to your Margins · about 2 min", false),
            ("replies, one named and one unnamed sender", [reply(30, from: "Sam"), reply(30, from: "", to: "mine-2")],
             "Replies from friends", "2 replies to your Margins · about 1 min", false),
            ("mixed, several senders", [reply(30, from: "Sam"), spoken(30, from: "Ana"), spoken(30, from: "Ana")],
             "From friends", "1 reply and 2 new Margins · about 2 min", false),
            ("mixed, no name", [reply(30, from: ""), spoken(30, from: "")], "From a friend", "1 reply and 1 new Margin · about 1 min", false),
            ("no replies to you", [spoken(30, from: "Sam"), spoken(30, from: "Sam")], "From Sam", "2 Margins · about 1 min", true),
        ]
        for (name, margins, sender, count, explained) in table {
            let intro = try XCTUnwrap(FriendMarginsIntro(unheardFriendMargins: margins), name)
            XCTAssertEqual(intro.senderLine, sender, name)
            XCTAssertEqual(intro.countLine, count, name)
            XCTAssertEqual(intro.explanation != nil, explained, name)
        }
    }

    /// None of these words reach a sender, and a first-time friend's explanation never reaches a reply.
    func testRepliesNeverCarryTheFirstTimeFriendsWords() throws {
        for margins in [[reply()], [reply(), spoken(30, from: "Sam")], [writtenReply()], [reply(from: "")]] {
            let intro = try XCTUnwrap(FriendMarginsIntro(unheardFriendMargins: margins))
            let words = [intro.senderLine, intro.countLine, intro.explanation ?? ""].joined(separator: " ")
            XCTAssertNil(intro.explanation, words)
            XCTAssertFalse(words.contains("A Margin is"), words)
            XCTAssertFalse(words.contains("your friend"), words)
            XCTAssertTrue(intro.countLine.contains("repl"), words)
        }
    }

    /// A Margin that is not a reply to the listener's own (a reply to someone else's, or whose parent is not here)
    /// carries no parent id, so it reads as a new Margin and the first-time intro stays.
    func testAMarginThatDoesNotAnswerTheListenerIsNew() throws {
        let intro = try XCTUnwrap(FriendMarginsIntro(unheardFriendMargins: [spoken(30, from: "Sam")]))
        XCTAssertEqual(intro.senderLine, "From Sam")
        XCTAssertEqual(intro.countLine, "1 Margin · about 1 min")
        XCTAssertNotNil(intro.explanation)
    }
}
