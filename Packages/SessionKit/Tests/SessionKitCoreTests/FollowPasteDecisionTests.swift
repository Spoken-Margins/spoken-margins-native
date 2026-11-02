import XCTest
@testable import SessionKit

/// #3205: the Follow sheet's Paste follows a copied link at once. These are the inputs around that decision.
final class FollowPasteDecisionTests: XCTestCase {
    func testACopiedFeedLinkIsFollowedWithNoFurtherTap() {
        XCTAssertEqual(
            FollowPasteDecision.decide(clipboard: "https://feeds.example.com/show.rss"),
            .follow("https://feeds.example.com/show.rss"))
    }

    func testSurroundingWhitespaceAndNewlinesAreIgnored() {
        XCTAssertEqual(
            FollowPasteDecision.decide(clipboard: "  \n https://feeds.example.com/show.rss\n"),
            .follow("https://feeds.example.com/show.rss"))
    }

    func testALinkInsideASentenceIsFound() {
        XCTAssertEqual(
            FollowPasteDecision.decide(clipboard: "Listen to this: https://feeds.example.com/show.rss (it is good)"),
            .follow("https://feeds.example.com/show.rss"))
    }

    func testBracketsAroundALinkAreDropped() {
        XCTAssertEqual(
            FollowPasteDecision.decide(clipboard: "<https://feeds.example.com/show.rss>"),
            .follow("https://feeds.example.com/show.rss"))
    }

    func testFirstOfSeveralLinksWins() {
        XCTAssertEqual(
            FollowPasteDecision.decide(clipboard: "https://a.example.com/one.rss https://b.example.com/two.rss"),
            .follow("https://a.example.com/one.rss"))
    }

    func testUppercaseSchemeIsAccepted() {
        XCTAssertEqual(
            FollowPasteDecision.decide(clipboard: "HTTPS://Feeds.Example.com/Show.rss"),
            .follow("HTTPS://Feeds.Example.com/Show.rss"))
    }

    func testFeedSchemeIsReadAsHTTPS() {
        XCTAssertEqual(
            FollowPasteDecision.decide(clipboard: "feed://feeds.example.com/show.rss"),
            .follow("https://feeds.example.com/show.rss"))
        XCTAssertEqual(
            FollowPasteDecision.decide(clipboard: "feed:https://feeds.example.com/show.rss"),
            .follow("https://feeds.example.com/show.rss"))
        XCTAssertEqual(
            FollowPasteDecision.decide(clipboard: "feeds://feeds.example.com/show.rss"),
            .follow("https://feeds.example.com/show.rss"))
    }

    func testPrivateFeedLinkKeepsItsTokenUnchanged() {
        let link = "https://feeds.example.com/private/abc123?token=s3cret&x=1"
        XCTAssertEqual(FollowPasteDecision.decide(clipboard: link), .follow(link))
    }

    func testEmptyAndMissingClipboardAreNotALink() {
        XCTAssertEqual(FollowPasteDecision.decide(clipboard: nil), .notALink)
        XCTAssertEqual(FollowPasteDecision.decide(clipboard: ""), .notALink)
        XCTAssertEqual(FollowPasteDecision.decide(clipboard: "   \n\t "), .notALink)
    }

    func testPlainTextIsNotALink() {
        XCTAssertEqual(FollowPasteDecision.decide(clipboard: "remember to buy milk"), .notALink)
        XCTAssertEqual(FollowPasteDecision.decide(clipboard: "Café — résumé ☕️"), .notALink)
    }

    func testOtherSchemesAreNotFollowed() {
        XCTAssertEqual(FollowPasteDecision.decide(clipboard: "mailto:someone@example.com"), .notALink)
        XCTAssertEqual(FollowPasteDecision.decide(clipboard: "tel:+15555550123"), .notALink)
        XCTAssertEqual(FollowPasteDecision.decide(clipboard: "file:///private/var/mobile/a.rss"), .notALink)
        XCTAssertEqual(FollowPasteDecision.decide(clipboard: "ftp://example.com/show.rss"), .notALink)
        XCTAssertEqual(FollowPasteDecision.decide(clipboard: "feed:example"), .notALink)
    }

    func testVeryLongTextWithNoLinkIsNotALink() {
        XCTAssertEqual(FollowPasteDecision.decide(clipboard: String(repeating: "word ", count: 20_000)), .notALink)
    }

    func testMessagesNeverCarryTheLink() {
        XCTAssertFalse(FollowPasteDecision.notALinkMessage.contains("http"))
        XCTAssertEqual(FollowPasteDecision.followedMessage(showTitle: "Show", wasAlreadyFollowed: false), "Following Show.")
        XCTAssertEqual(FollowPasteDecision.followedMessage(showTitle: "Show", wasAlreadyFollowed: true), "You already follow Show.")
        XCTAssertEqual(FollowPasteDecision.followedMessage(showTitle: nil, wasAlreadyFollowed: false), "Following this show.")
        XCTAssertEqual(FollowPasteDecision.followedMessage(showTitle: "  \n ", wasAlreadyFollowed: false), "Following this show.")
        XCTAssertEqual(FollowPasteDecision.undoAccessibilityLabel(showTitle: "A  Show"), "Undo Follow, A Show")
    }
}
