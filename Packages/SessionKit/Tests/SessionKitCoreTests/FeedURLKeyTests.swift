import XCTest
@testable import SessionKit

/// #4046: the one feed-link key OPML import, the catalog and follow lists share. A table of neighbouring spellings.
final class FeedURLKeyTests: XCTestCase {
    func testKeyTable() {
        let cases: [(raw: String, key: String?)] = [
            ("https://example.com/feed", "https://example.com/feed"),
            ("http://example.com/feed", "https://example.com/feed"),
            ("HTTPS://Example.COM/feed", "https://example.com/feed"),
            ("https://example.com/feed/", "https://example.com/feed"),
            ("  https://example.com/feed \n", "https://example.com/feed"),
            ("https://example.com/feed#top", "https://example.com/feed"),
            ("https://example.com/", "https://example.com/"),
            ("https://example.com", "https://example.com"),
            ("https://example.com/Feed", "https://example.com/Feed"),            // paths keep their case
            ("https://example.com/feed?id=A1", "https://example.com/feed?id=A1"), // the query is part of the feed
            ("https://example.com:8443/feed", "https://example.com:8443/feed"),
            ("", nil),
            ("   ", nil),
            ("not a link", nil),
            ("/relative/feed", nil),
            ("mailto:me@example.com", nil),
        ]
        for (raw, key) in cases {
            XCTAssertEqual(FeedURLKey.make(raw), key, "input: \(raw.debugDescription)")
        }
    }

    func testDifferentFeedsStayDifferent() {
        XCTAssertNotEqual(FeedURLKey.make("https://example.com/feed/a"), FeedURLKey.make("https://example.com/feed/b"))
        XCTAssertNotEqual(FeedURLKey.make("https://example.com/Feed"), FeedURLKey.make("https://example.com/feed"))
        XCTAssertNotEqual(FeedURLKey.make("https://example.com/feed"), FeedURLKey.make("https://example.org/feed"))
    }
}
