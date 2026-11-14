import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #4284: the feed links the "Follow Podcasts in Spoken Margins" Shortcut action hands over give the same
/// preview an OPML file listing the same feeds gives.
final class FeedLinkListTests: XCTestCase {
    func testTenLinksGiveTheSamePreviewAsTheSameFeedsInAnOPMLFile() throws {
        // The first five arrive as one text (a Shortcut's list joined into lines), the rest one per entry.
        let entries = [
            """
            Pod One https://feeds.example.com/pod1.xml
            Pod Two: https://feeds.example.com/pod2.xml

            https://feeds.example.com/pod3.xml
            Followed Show — https://feeds.example.com/followed.xml
            Old Show http://feeds.example.com/old.xml
            """,
            "Pod One again https://Feeds.Example.com/pod1.xml/",
            "not a podcast link",
            "Apple Only https://podcasts.apple.com/us/podcast/apple-only/id123456",
            "A Blog <https://feeds.example.com/blog.xml>",
            "Pod Ten\thttps://feeds.example.com/pod10.xml",
        ]
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0"><body>
          <outline type="rss" text="Pod One" xmlUrl="https://feeds.example.com/pod1.xml"/>
          <outline type="rss" text="Pod Two" xmlUrl="https://feeds.example.com/pod2.xml"/>
          <outline type="rss" xmlUrl="https://feeds.example.com/pod3.xml"/>
          <outline type="rss" text="Followed Show" xmlUrl="https://feeds.example.com/followed.xml"/>
          <outline type="rss" text="Old Show" xmlUrl="http://feeds.example.com/old.xml"/>
          <outline type="rss" text="Pod One again" xmlUrl="https://Feeds.Example.com/pod1.xml/"/>
          <outline type="rss" text="not a podcast link"/>
          <outline type="rss" text="Apple Only"/>
          <outline type="rss" text="A Blog" xmlUrl="https://feeds.example.com/blog.xml"/>
          <outline type="rss" text="Pod Ten" xmlUrl="https://feeds.example.com/pod10.xml"/>
        </body></opml>
        """
        let existing = [Self.subscription("Followed Show", "https://feeds.example.com/followed.xml")]

        let fromLinks = OPMLImportPlanner.preview(try FeedLinkListParser.parse(entries), existing: existing)
        let fromFile = OPMLImportPlanner.preview(try OPMLParser.parse(Data(opml.utf8)), existing: existing)

        XCTAssertEqual(fromLinks, fromFile)
        XCTAssertEqual(fromLinks.toFollow.map(\.title), ["Pod One", "Pod Two", "https://feeds.example.com/pod3.xml", "Old Show", "A Blog", "Pod Ten"])
        XCTAssertEqual(fromLinks.toFollow.first { $0.title == "Old Show" }?.feed?.url, "https://feeds.example.com/old.xml", "http is offered over https")
        XCTAssertEqual(fromLinks.alreadyFollowed.map(\.title), ["Followed Show"])
        XCTAssertEqual(fromLinks.duplicatesInFile.map(\.title), ["Pod One again"])
        XCTAssertEqual(fromLinks.unusableOutlineCount, 2, "the junk line and the store page; the blank line isn't counted")
    }

    /// Neighbouring inputs for one line: what is read as the feed link and the show's name.
    func testEachLineReadsItsFeedLinkAndNameOrCountsAsUnusable() throws {
        let rows: [(line: String, title: String?, url: String?)] = [
            ("https://feeds.example.com/a.xml", "https://feeds.example.com/a.xml", "https://feeds.example.com/a.xml"),
            ("HTTPS://FEEDS.EXAMPLE.COM/a.xml", "HTTPS://FEEDS.EXAMPLE.COM/a.xml", "HTTPS://FEEDS.EXAMPLE.COM/a.xml"),
            ("  Show A   https://feeds.example.com/a.xml  ", "Show A", "https://feeds.example.com/a.xml"),
            ("Show A\u{00A0}https://feeds.example.com/a.xml\r", "Show A", "https://feeds.example.com/a.xml"),
            ("https://feeds.example.com/a.xml Show A", "Show A", "https://feeds.example.com/a.xml"),
            ("Show A | https://feeds.example.com/a.xml", "Show A", "https://feeds.example.com/a.xml"),
            ("\"Show A\", \"https://feeds.example.com/a.xml\"", "Show A", "https://feeds.example.com/a.xml"),
            ("(https://feeds.example.com/a.xml)", "https://feeds.example.com/a.xml", "https://feeds.example.com/a.xml"),
            ("Café Écoute https://feeds.example.com/caf%C3%A9.xml", "Café Écoute", "https://feeds.example.com/caf%C3%A9.xml"),
            ("Show A https://podcasts.apple.com/us/podcast/a/id1 https://feeds.example.com/a.xml", "Show A", "https://feeds.example.com/a.xml"),
            ("Show A https://podcasts.apple.com/us/podcast/a/id1", nil, nil),
            ("Show A https://itunes.apple.com/us/podcast/id1", nil, nil),
            ("Show A https://geo.itunes.apple.com/us/podcast/id1", nil, nil),
            ("Show A feed://feeds.example.com/a.xml", nil, nil),
            ("Show A itpc://feeds.example.com/a.xml", nil, nil),
            ("Show A ftp://feeds.example.com/a.xml", nil, nil),
            ("https://", nil, nil),
            ("javascript:alert(1)", nil, nil),
            ("Show A", nil, nil),
        ]
        for row in rows {
            let document = try FeedLinkListParser.parse([row.line])
            if let url = row.url {
                XCTAssertEqual(document.feeds.map(\.feedURL), [url], row.line)
                XCTAssertEqual(document.feeds.map(\.title), [row.title].compactMap { $0 }, row.line)
                XCTAssertEqual(document.unusableOutlineCount, 0, row.line)
            } else {
                XCTAssertTrue(document.feeds.isEmpty, row.line)
                XCTAssertEqual(document.unusableOutlineCount, 1, row.line)
            }
        }
    }

    func testEmptyInputGivesAnEmptyListAndHugeInputIsRefused() throws {
        for empty in [[], [""], ["   ", "\n\n", "\t"]] as [[String]] {
            let document = try FeedLinkListParser.parse(empty)
            XCTAssertTrue(document.feeds.isEmpty)
            XCTAssertEqual(document.unusableOutlineCount, 0)
        }
        let tooMany = (0...5_000).map { "https://feeds.example.com/\($0).xml" }
        XCTAssertThrowsError(try FeedLinkListParser.parse(tooMany)) { XCTAssertEqual($0 as? OPMLError, .tooManyOutlines) }
        let tooBig = [String(repeating: "x", count: OPMLLimits().maximumBytes + 1)]
        XCTAssertThrowsError(try FeedLinkListParser.parse(tooBig)) { XCTAssertEqual($0 as? OPMLError, .tooLarge) }
        XCTAssertEqual(try FeedLinkListParser.parse(Array(tooMany.dropLast())).feeds.count, 5_000, "the OPML limit itself is allowed")
    }

    private static func subscription(_ title: String, _ url: String) -> FeedSubscription {
        let host = URLComponents(string: url)?.host ?? "unknown"
        return FeedSubscription(id: "subscription-\(title)", source: SourceIdentity(id: "source-\(title)", kind: .podcastFeed, canonicalURL: url, host: host, title: title))
    }
}
