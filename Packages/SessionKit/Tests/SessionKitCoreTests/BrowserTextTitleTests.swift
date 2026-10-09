import Foundation
import XCTest
import SessionKit

/// An X post imported through the Safari extension gets a short title, and the post stays in the item's text (#885).
final class BrowserTextTitleTests: XCTestCase {
    private let postURL = "https://x.com/sebkrier/status/2107478899529527563"
    private let postTitle = "Séb Krier on X: \"I haven't posted in a while so here are 20 takes about AI, in no particular order. 1. It's very telling that the default question in tech and journalism is \"how worried are you about X\" ... https://t.co/dySw7tFEly\""
    private let postBody = "I haven't posted in a while so here are 20 takes about AI, in no particular order.\n\n1. It's very telling that the default question in tech and journalism is \"how worried are you about X\"."

    // MARK: The rule

    func testPostPagesGetTheAuthorAndSiteAsTheirTitle() {
        let cases: [(name: String, title: String, url: String, expected: String?)] = [
            ("the reported post", postTitle, postURL, "Séb Krier on X"),
            ("twitter.com", "Ann Lee on Twitter: \"Hello there.\"", "https://twitter.com/ann/status/1", "Ann Lee on Twitter"),
            ("www.x.com", "Ann Lee on X: \"Hello there.\"", "https://www.x.com/ann/status/1", "Ann Lee on X"),
            ("mobile.x.com", "Ann Lee on X: \"Hello there.\"", "https://mobile.x.com/ann/status/1", "Ann Lee on X"),
            ("mobile.twitter.com", "Ann Lee on Twitter: \"Hello there.\"", "https://mobile.twitter.com/ann/status/1", "Ann Lee on Twitter"),
            ("upper-case host", "Ann Lee on X: \"Hello there.\"", "https://X.COM/ann/status/1", "Ann Lee on X"),
            ("curly quotes", "Ann Lee on X: \u{201C}Hello there.\u{201D}", "https://x.com/ann/status/1", "Ann Lee on X"),
            ("a closing quote that curls the other way", "Ann Lee on X: \u{201D}Hello there.\u{201D}", "https://x.com/ann/status/1", "Ann Lee on X"),
            ("a handle in the name", "Ann Lee (@ann) on X: \"Hello there.\"", "https://x.com/ann/status/1", "Ann Lee (@ann) on X"),
            ("a dot in the name", "Dr. Ann Lee on X: \"Hello there\"", "https://x.com/ann/status/1", "Dr. Ann Lee on X"),
            ("an empty post", "Ann Lee on X: \"\"", "https://x.com/ann/status/1", "Ann Lee on X"),
            ("an unfinished quote", "Ann Lee on X: \"Hello there", "https://x.com/ann/status/1", "Ann Lee on X"),
            ("a trailing / X", "Ann Lee on X: \"Hello there.\" / X", "https://x.com/ann/status/1", "Ann Lee on X"),
            ("a quote post", "Ann Lee on X: \"Bob Ray on X: \"Hello there.\" Agreed.\"", "https://x.com/ann/status/1", "Ann Lee on X"),
            ("a post of several lines", "Ann Lee on X: \"One.\nTwo.\nThree.\"", "https://x.com/ann/status/1", "Ann Lee on X"),
            ("a very long post", "Ann Lee on X: \"" + String(repeating: "word ", count: 2_000) + "\"", "https://x.com/ann/status/1", "Ann Lee on X"),
            ("spaces around the title", "  Ann Lee on X: \"Hello there.\"  \n", "https://x.com/ann/status/1", "Ann Lee on X"),

            // Not a post title: left to the caller unchanged.
            ("a profile page", "Séb Krier (@sebkrier) / X", "https://x.com/sebkrier", nil),
            ("an X page with no quoted text", "Ann Lee on X: Hello there", "https://x.com/ann/status/1", nil),
            ("the home page", "Home / X", "https://x.com/home", nil),
            ("no name", " on X: \"Hello there.\"", "https://x.com/ann/status/1", nil),
            ("an empty title", "", "https://x.com/ann/status/1", nil),
            ("the same shape on another site", "Ann Lee on X: \"Hello there.\"", "https://example.com/ann", nil),
            ("a look-alike host", "Ann Lee on X: \"Hello there.\"", "https://notx.com/ann/status/1", nil),
            ("a host that only starts with x.com", "Ann Lee on X: \"Hello there.\"", "https://x.com.example.org/ann", nil),
            ("a page that is not a URL", "Ann Lee on X: \"Hello there.\"", "not a url", nil),
            ("an article about X on another site", "Why I left X: \"a note\"", "https://blog.example/why-i-left-x", nil),
            ("a colon and quotes on another site", "Notes: \"A quote\" and more", "https://blog.example/notes", nil),
            ("a colon and quotes on an X page that is not a post", "Lists: \"Reading\" / X", "https://x.com/i/lists/1", nil),
        ]
        for testCase in cases {
            XCTAssertEqual(
                BrowserTextTitle.postTitle(pageTitle: testCase.title, url: testCase.url),
                testCase.expected,
                testCase.name
            )
        }
    }

    // MARK: Through the import

    func testImportedPostGetsAShortTitleAndKeepsItsText() throws {
        for format in [BrowserTextContentFormat.markdown, .plainText] {
            let (engine, repo) = makeEngine()
            let item = try engine.importBrowserTextInBackground(handoff(title: postTitle, url: postURL, text: postBody, format: format))
            XCTAssertEqual(item.title, "Séb Krier on X", "\(format)")
            XCTAssertEqual(item.text, postBody, "\(format)")
            XCTAssertEqual(try repo.loadItem(id: item.id).title, "Séb Krier on X", "\(format)")
            XCTAssertEqual(item.externalReference, postURL, "\(format)")
        }
    }

    /// `browserTextItemId` is built from the page title, so a post imported before the short title existed has
    /// the id its long title gave it (worked out by hand from that rule). The short title must not change
    /// it, or importing the post again would add a second copy.
    func testPostKeepsTheItemIdItsLongTitleGave() throws {
        let longTitleId = "item-browser-séb-krier-on-x-i-haven-t-posted-in-a-while-so-he"
        let (engine, repo) = makeEngine()
        let first = try engine.importBrowserTextInBackground(handoff(title: postTitle, url: postURL, text: postBody, format: .markdown))
        XCTAssertEqual(first.id, longTitleId)
        let again = try engine.importBrowserTextInBackground(handoff(title: postTitle, url: postURL, text: postBody, format: .markdown))
        XCTAssertEqual(again.id, longTitleId)
        XCTAssertEqual(repo.items.count, 1, "no second copy of the post")
    }

    func testPostWithAHeadingKeepsTheHeadingAsItsTitle() throws {
        let (engine, _) = makeEngine()
        let item = try engine.importBrowserTextInBackground(handoff(
            title: "Ann Lee on X: \"Hello there. This is a long article…\"",
            url: "https://x.com/ann/article/1",
            text: "# Hello there\n\nThe article starts here.",
            format: .markdown
        ))
        XCTAssertEqual(item.title, "Hello there")
    }

    /// The markdown parser still rewrites some page titles on every site (a trailing quote, a dot or a
    /// double slash), so these avoid those characters and pin only what this change must not touch.
    func testOtherSitesKeepThePageTitleAsGiven() throws {
        let cases = [
            ("https://blog.example/notes", "Notes: \"A quote\" and more"),
            ("https://example.com/ann", "Ann Lee on X: \"Hello there\" says Ann"),
            ("https://x.com/sebkrier", "Séb Krier (@sebkrier) / X"),
            ("https://news.example/story", "Why we left X: a story"),
        ]
        for (url, title) in cases {
            let (engine, _) = makeEngine()
            let item = try engine.importBrowserTextInBackground(handoff(title: title, url: url, text: "Some text to read.", format: .markdown))
            XCTAssertEqual(item.title, title, url)
        }
    }

    // MARK: Helpers

    private func makeEngine() -> (SessionEngine, InMemorySessionRepository) {
        let repo = InMemorySessionRepository()
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "browser", displayName: "Browser", capabilities: ["sync": ["canonical_persistence"]]),
            repository: repo
        )
        return (engine, repo)
    }

    private func handoff(title: String, url: String, text: String, format: BrowserTextContentFormat) -> BrowserTextHandoff {
        BrowserTextHandoff(
            captureMode: .readablePage,
            source: BrowserTextSource(url: url, title: title),
            text: text,
            contentFormat: format,
            requestedContinuation: BrowserTextContinuation(startSession: false, preferredPlaybackOwner: "app")
        )
    }
}
