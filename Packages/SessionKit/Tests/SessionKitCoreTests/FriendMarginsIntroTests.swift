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
        XCTAssertTrue(oneWritten.explanation.hasPrefix("A Margin is a note Cole left"))
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
}
