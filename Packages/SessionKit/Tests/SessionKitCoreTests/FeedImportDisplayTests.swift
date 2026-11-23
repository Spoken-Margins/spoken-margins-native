import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #4858: the Apple Podcasts import preview leads with the show's name. These pin the hidden rules the
/// preview's rows will use: unusable lines' names, the readable address for a nameless row, home-network
/// hosts and which rows start ticked.
final class FeedImportDisplayTests: XCTestCase {
    // MARK: Unusable names

    func testUnusableLinesKeepTheirNamesAndNamelessOnesOnlyCount() throws {
        let rows: [(line: String, name: String?)] = [
            ("Apple Only https://podcasts.apple.com/us/podcast/apple-only/id123456", "Apple Only"),
            ("Apple Onlyhttps://podcasts.apple.com/us/podcast/apple-only/id123456", "Apple Only"),
            ("Apple Only: <https://podcasts.apple.com/us/podcast/a/id1>", "Apple Only"),
            ("Show A feed://feeds.example.com/a.xml", "Show A"),
            ("Show A itpc://feeds.example.com/a.xml", "Show A"),
            ("Hard Fork:", "Hard Fork"),
            ("Re:Think https://podcasts.apple.com/us/podcast/a/id1", "Re:Think"),
            ("Star Trek:Discovery https://podcasts.apple.com/us/podcast/a/id1", "Star Trek:Discovery"),
            ("Show A HtTpS://podcasts.apple.com/us/podcast/a/id1", "Show A"),
            ("Show A", "Show A"),
            ("https://podcasts.apple.com/us/podcast/a/id1", nil),
            ("feed://feeds.example.com/a.xml", nil),
            ("javascript:alert(1)", nil),
            ("https://", nil),
            ("example.com/go?to=https://feeds.example.com/a.xml", nil),
            (" - | ", nil),
        ]
        for row in rows {
            let document = try FeedLinkListParser.parse([row.line])
            XCTAssertTrue(document.feeds.isEmpty, row.line)
            XCTAssertEqual(document.unusableOutlineCount, 1, row.line)
            XCTAssertEqual(document.unusableNames, [row.name].compactMap { $0 }, row.line)
        }
    }

    func testSeveralShowsInOneTextGiveEachRowAndTheUnusableNamesInOrder() throws {
        let text = "Pod One https://feeds.example.com/1.xml\r\nApple Only https://podcasts.apple.com/us/podcast/a/id1\r\n"
            + "https://feeds.example.com/2.xml\nSame Name https://feeds.example.com/s1.xml\n"
            + "Same Name https://feeds.example.com/s2.xml\nhttps://podcasts.apple.com/us/podcast/b/id2\nSecond Apple https://itunes.apple.com/us/podcast/id3"
        let preview = OPMLImportPlanner.preview(try FeedLinkListParser.parse([text]), existing: [])
        XCTAssertEqual(preview.toFollow.map(\.title), ["Pod One", "https://feeds.example.com/2.xml", "Same Name", "Same Name"],
                       "two shows with one name and different links are both offered")
        XCTAssertEqual(preview.unusableOutlineCount, 3)
        XCTAssertEqual(preview.unusableNames, ["Apple Only", "Second Apple"])
    }

    func testAnOPMLFileKeepsTheNamesOfItsUnusableFeedOutlines() throws {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0"><body>
          <outline type="rss" text="Good" xmlUrl="https://feeds.example.com/good.xml"/>
          <outline type="rss" text="No Link"/>
          <outline type="rss" text="Bad Link" xmlUrl="feed://feeds.example.com/bad.xml"/>
          <outline type="rss" xmlUrl="itpc://feeds.example.com/nameless.xml"/>
        </body></opml>
        """
        let document = try OPMLParser.parse(Data(opml.utf8))
        XCTAssertEqual(document.unusableOutlineCount, 3)
        XCTAssertEqual(document.unusableNames, ["No Link", "Bad Link"])
    }

    func testTheUnusableListStopsAtTwentyNamesAndCountsTheRest() throws {
        let lines = (1...23).map { "Apple \($0) https://podcasts.apple.com/us/podcast/a/id\($0)" } + ["https://podcasts.apple.com/us/podcast/x/id99"]
        let preview = OPMLImportPlanner.preview(try FeedLinkListParser.parse(lines), existing: [])
        let list = preview.unusableNameList()
        XCTAssertEqual(OPMLImportPreview.unusableNameLimit, 20)
        XCTAssertEqual(list.names, (1...20).map { "Apple \($0)" })
        XCTAssertEqual(list.moreNamed, 3)
        XCTAssertEqual(preview.unusableOutlineCount, 24, "the nameless line adds to the count only")
        XCTAssertEqual(OPMLImportPreview.unusableNameLimit, preview.unusableNameList(limit: 20).names.count)
        XCTAssertEqual(preview.unusableNameList(limit: 0).moreNamed, 23)
    }

    func testUnusableNamesKeepTheLineLimit() throws {
        let lines = (0..<5_000).map { "Apple \($0) https://podcasts.apple.com/us/podcast/a/id\($0)" }
        XCTAssertEqual(try FeedLinkListParser.parse(lines).unusableNames.count, 5_000)
        XCTAssertThrowsError(try FeedLinkListParser.parse(lines + ["One more"])) { XCTAssertEqual($0 as? OPMLError, .tooManyOutlines) }
    }

    // MARK: Readable address for a nameless row

    func testANamedRowShowsItsNameAndANamelessRowNeverShowsItsWholeURL() {
        XCTAssertEqual(FeedDisplayName(title: "Hard Fork", feedURL: "https://feeds.example.com/a.xml"), FeedDisplayName(text: "Hard Fork", hasName: true))
        XCTAssertEqual(FeedDisplayName(title: "  Hard Fork ", feedURL: "https://feeds.example.com/a.xml").text, "Hard Fork")
        // Both parsers use the URL as a nameless row's title.
        let fromLinks = try! FeedLinkListParser.parse(["https://feeds.simplecast.com/the-daily"]).feeds[0]
        XCTAssertEqual(FeedDisplayName(title: fromLinks.title, feedURL: fromLinks.feedURL), FeedDisplayName(text: "feeds.simplecast.com/the-daily", hasName: false))
        let opml = #"<opml version="2.0"><body><outline type="rss" xmlUrl="https://feeds.simplecast.com/the-daily"/></body></opml>"#
        let fromFile = try! OPMLParser.parse(Data(opml.utf8)).feeds[0]
        XCTAssertEqual(FeedDisplayName(title: fromFile.title, feedURL: fromFile.feedURL), FeedDisplayName(text: "feeds.simplecast.com/the-daily", hasName: false))
        XCTAssertEqual(FeedDisplayName(title: "   ", feedURL: "https://feeds.example.com/show").hasName, false)
    }

    func testANamelessHTTPRowStaysNamelessAfterThePlannerOffersItOverHTTPS() throws {
        let preview = OPMLImportPlanner.preview(try FeedLinkListParser.parse([
            "http://feeds.example.com/the-show.xml", "HTTP://Feeds.Example.com/other/", "Named http://feeds.example.com/named.xml",
        ]), existing: [])
        let names = preview.toFollow.map { FeedDisplayName(title: $0.title, feedURL: $0.feed?.url ?? "") }
        XCTAssertEqual(preview.toFollow.map { $0.feed?.url }, ["https://feeds.example.com/the-show.xml", "https://Feeds.Example.com/other/", "https://feeds.example.com/named.xml"])
        XCTAssertEqual(names, [
            FeedDisplayName(text: "feeds.example.com/the-show", hasName: false),
            FeedDisplayName(text: "feeds.example.com/other", hasName: false),
            FeedDisplayName(text: "Named", hasName: true),
        ])
    }

    func testTheReadableAddressKeepsAShortMeaningfulLastPartAndDropsPlumbing() {
        let rows: [(url: String, expected: String)] = [
            ("https://feeds.simplecast.com/the-daily", "feeds.simplecast.com/the-daily"),
            ("https://Feeds.Example.COM/Hard-Fork.xml", "feeds.example.com/Hard-Fork"),
            ("https://feeds.example.com/show.XML", "feeds.example.com/show"),
            ("https://feeds.example.com/show.rss", "feeds.example.com/show"),
            ("https://feeds.example.com/show.atom", "feeds.example.com/show"),
            ("https://feeds.example.com/show.json", "feeds.example.com/show"),
            ("https://feeds.example.com/show/", "feeds.example.com/show"),
            ("https://feeds.example.com/show?format=rss", "feeds.example.com/show"),
            ("https://feeds.example.com/", "feeds.example.com"),
            ("https://feeds.example.com", "feeds.example.com"),
            ("https://example.com/podcast/feed", "example.com"),
            ("https://example.com/rss", "example.com"),
            ("https://example.com/feeds", "example.com"),
            ("https://example.com/atom.xml", "example.com"),
            ("https://example.com/PODCAST", "example.com"),
            ("https://example.com/a%2Fb", "example.com/a/b"),
            ("https://example.com/%C2%BD", "example.com/½"),
            ("https://example.com/feed.xml", "example.com"),
            ("https://example.com/index.xml", "example.com"),
            ("https://example.com/Podcasts", "example.com"),
            ("https://example.com/xml", "example.com"),
            ("https://example.com/a/1234567", "example.com"),
            ("https://example.com/" + String(repeating: "x", count: 28), "example.com/" + String(repeating: "x", count: 28)),
            ("https://example.com/" + String(repeating: "x", count: 29), "example.com"),
            ("https://example.com/abcdef12345", "example.com/abcdef12345"),
            ("https://example.com/abcdef123456", "example.com"),
            ("https://anchor.fm/s/1a2b3c4d-5e6f/podcast/rss", "anchor.fm"),
            ("https://example.com/1a2b3c4d-5e6f", "example.com"),
            ("https://example.com/caf%C3%A9-talk", "example.com/café-talk"),
            ("not a url", "not a url"),
        ]
        for row in rows {
            XCTAssertEqual(FeedDisplayName.readableAddress(row.url), row.expected, row.url)
        }
    }

    // MARK: Home-network hosts and the default ticks

    func testHomeNetworkHostsAreMarkedAndLookalikesAreNot() {
        let home = [
            "localhost", "LOCALHOST", "nas", "nas.", "plex.local", "Plex.Local.", "media.localhost",
            "10.0.0.5", "10.255.255.255", "172.16.0.1", "172.31.255.255", "192.168.1.20", "127.0.0.1", "169.254.10.1",
            "::1", "[::1]", "0:0:0:0:0:0:0:1", "fc00::1", "fd12:3456::1", "fe80::1", "[fe80::1%en0]", "febf::1", "::ffff:192.168.1.10",
        ]
        let away = [
            "feeds.example.com", "192.169.0.1", "10.example.com", "172.15.0.1", "172.32.0.1", "11.0.0.1", "169.253.1.1",
            "128.0.0.1", "8.8.8.8", "2001:db8::1", "fec0::1", "::ffff:8.8.8.8", "256.1.1.1", "1.2.3", "local.example.com", "",
        ]
        for host in home { XCTAssertTrue(FeedHostClass.isHomeNetwork(host: host), host) }
        for host in away { XCTAssertFalse(FeedHostClass.isHomeNetwork(host: host), host) }
        XCTAssertTrue(FeedHostClass.isHomeNetwork(url: "http://nas.local:8080/feed.xml"))
        XCTAssertTrue(FeedHostClass.isHomeNetwork(url: "https://[::1]:8443/feed.xml"))
        XCTAssertFalse(FeedHostClass.isHomeNetwork(url: "http://feeds.example.com/feed.xml"), "plain http on a public host is not marked")
        XCTAssertFalse(FeedHostClass.isHomeNetwork(url: nil))
    }

    func testAHomeNetworkRowStartsUntickedAndEveryOtherNewRowStartsTicked() throws {
        let lines = [
            "Public https://feeds.example.com/a.xml",
            "Plain http http://feeds.example.com/b.xml",
            "My NAS http://nas.local/podcast.xml",
            "Router 192.168.1.2 https://192.168.1.2/feed",
            "Followed https://feeds.example.com/followed.xml",
        ]
        let existing = [FeedSubscription(id: "s", source: SourceIdentity(id: "src", kind: .podcastFeed, canonicalURL: "https://feeds.example.com/followed.xml", host: "feeds.example.com", title: "Followed"))]
        let preview = OPMLImportPlanner.preview(try FeedLinkListParser.parse(lines), existing: existing)
        XCTAssertEqual(preview.toFollow.map(\.title), ["Public", "Plain http", "My NAS", "Router 192.168.1.2"])
        let ticked = preview.toFollow.filter { preview.defaultSelection.contains($0.id) }.map(\.title)
        XCTAssertEqual(ticked, ["Public", "Plain http"])
        XCTAssertEqual(preview.defaultSelection.count, 2)
    }

    func testThePreviewFetchesNothing() async throws {
        // Parsing and planning are pure: the only way to the network is the follow closure, which the preview
        // never calls; following nothing ticked calls it zero times.
        let preview = OPMLImportPlanner.preview(try FeedLinkListParser.parse((1...100).map { "Show \($0) https://feeds.example.com/\($0).xml" }), existing: [])
        XCTAssertEqual(preview.defaultSelection.count, 100)
        var calls = 0
        _ = await OPMLImportRunner.follow(preview, selected: []) { _ in calls += 1 }
        XCTAssertEqual(calls, 0)
    }
}
