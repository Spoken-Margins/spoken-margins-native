import XCTest
@testable import SessionKit

/// The text rules from the Design comment on #1770 (revised by the Opus review).
final class BetaInviteShareTests: XCTestCase {
    private var text: String { BetaInviteShare.text }

    func testContainsTheJoinLinkExactlyOnceAndNoOtherURL() {
        XCTAssertEqual(text.components(separatedBy: "https://spokenmargins.com/join").count - 1, 1)
        // Every link-like token is the join link: no second scheme, no bare host.
        XCTAssertEqual(text.components(separatedBy: "http").count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: "://").count - 1, 1)
        XCTAssertFalse(text.lowercased().contains("testflight.apple.com"))
        XCTAssertEqual(BetaInviteShare.joinURL, "https://spokenmargins.com/join")
    }

    func testNamesTapStepTwoAndTheRedeemCaseInThePagesWords() {
        XCTAssertTrue(text.contains("tap step 2"))
        XCTAssertTrue(text.contains("\"Redeem\""))
        XCTAssertTrue(text.contains("You don't need a code"))
        // The link is the page, not the invitation: the message must not tell anyone to tap "the link" again.
        XCTAssertFalse(text.lowercased().contains("tap the link again"))
        XCTAssertFalse(text.lowercased().contains("tap the same"))
    }

    func testMakesNoPromiseOfAPlaceOrACapacity() {
        for phrase in ["limited", "spots", "spot ", "you're invited", "you are invited", "invitation", "invite link",
                       "ask me", "ask your friend", "capacity", "full", "everyone", "takes a minute", "minutes"] {
            XCTAssertFalse(text.lowercased().contains(phrase), "message must not say \"\(phrase)\"")
        }
    }

    func testCarriesNoListenerOrBuildData() {
        XCTAssertFalse(text.lowercased().contains("build"))
        XCTAssertFalse(text.lowercased().contains("library"))
        // The message is a constant: reading it twice gives the same words.
        XCTAssertEqual(BetaInviteShare.text, BetaInviteShare.text)
    }

    func testFitsOneSMSAndAMessengerPreview() {
        XCTAssertLessThan(text.count, 600)
        XCTAssertEqual(text.count, 412)
    }

    func testHasNoLeadingOrTrailingWhitespaceFromTheLiteral() {
        XCTAssertEqual(text, text.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertFalse(text.contains("  "))
    }
}
