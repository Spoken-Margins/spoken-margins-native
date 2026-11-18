import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds
import SessionKitTestInputs

/// #4046 PR 4: OPML read and write for follow lists: `category`, folders, `podcast:guid`, `include` rows and our
/// `sm:` attributes.
final class OPMLListsTests: XCTestCase {
    func testFoldersGiveEveryEnclosingFolderAsAListName() throws {
        let document = try OPMLParser.parse(Self.fixture("lists-folders"))
        XCTAssertEqual(document.feeds.map(\.title), ["The Daily", "Radiolab", "Hard Fork", "Darknet Diaries", "Loose show"])
        XCTAssertEqual(document.feeds.map(\.listNames), [["News"], ["News"], ["Tech", "AI"], ["Tech"], []])
        XCTAssertEqual(document.includes, [])
    }

    func testCategoriesGiveListNamesWithoutTheLeadingSlash() throws {
        let document = try OPMLParser.parse(Self.fixture("lists-categories"))
        XCTAssertEqual(document.feeds.map(\.categories), [["News", "Daily habits"], ["Tech/AI", "News"], ["News"], []])
        XCTAssertEqual(document.feeds[1].podcastGUID, "6a7b9c1e-0000-5000-8000-000000000001", "a GUID is trimmed")
        XCTAssertEqual(document.feeds[2].sm, OPMLSpokenMarginsAttributes(skip: ["rerun*", "best of*"], more: ["deep dive*"], via: nil))
        XCTAssertEqual(document.feeds[3].sm, OPMLSpokenMarginsAttributes())
        XCTAssertNil(document.feeds[0].podcastGUID)
    }

    func testAFolderAndACategoryOfTheSameNameAreOneList() throws {
        let opml = Self.wrap(#"<outline text="News"><outline type="rss" text="A" xmlUrl="https://a.example/feed" category="/news,/Other"/></outline>"#)
        let feed = try XCTUnwrap(try OPMLParser.parse(opml).feeds.first)
        XCTAssertEqual(feed.folders, ["News"])
        XCTAssertEqual(feed.listNames, ["News", "Other"])
    }

    func testCategoryNeighbourTable() throws {
        let nfc = "Caf\u{00E9}"
        let cases: [(attribute: String, names: [String])] = [
            ("/News", ["News"]),
            ("News", ["News"]),
            (" /News , /Tech ", ["News", "Tech"]),
            ("/Tech/AI", ["Tech/AI"]),
            ("//News", ["News"]),
            ("/", []),
            ("///", []),
            ("", []),
            (",,,", []),
            ("   ", []),
            ("/News,/News", ["News"]),
            ("/News,/news", ["News"]),
            ("/Caf\u{00E9},/Cafe\u{0301}", [nfc]),
            ("/Cafe\u{0301},/Caf\u{00E9}", ["Cafe\u{0301}"]),
            ("/\(String(repeating: "x", count: 200))", [String(repeating: "x", count: 200)]),
            ("/a b  c", ["a b  c"]),
            ("/R&amp;D", ["R&D"]),
        ]
        for (attribute, names) in cases {
            let opml = Self.wrap(#"<outline type="rss" text="A" xmlUrl="https://a.example/feed" category="\#(attribute)"/>"#)
            let parsed = try OPMLParser.parse(opml).feeds.first?.categories
            XCTAssertEqual(parsed, names, "category=\(attribute.debugDescription)")
            // String == treats NFC and NFD as equal, so compare the scalars: the first spelling is the one kept.
            XCTAssertEqual(parsed?.map { Array($0.unicodeScalars) }, names.map { Array($0.unicodeScalars) }, "scalars of category=\(attribute.debugDescription)")
        }
    }

    func testIncludeRowsAreReadAndNeverMistakenForFeeds() throws {
        let document = try OPMLParser.parse(Self.fixture("lists-includes"))
        XCTAssertEqual(document.includes, [OPMLInclude(url: "https://example.org/lists/priya-science.opml", title: "Priya's science list")])
        XCTAssertEqual(document.unusableOutlineCount, 1, "the feed: include has no web address")
        XCTAssertEqual(document.feeds.map(\.title), ["Radiolab", "Science Vs"])
        XCTAssertEqual(document.feeds.map(\.sm.via), ["Priya's science list", nil])
        XCTAssertEqual(document.title, "Sam's reading list")
    }

    func testAnIncludeRowNeverFallsThroughToAFolderOrAFeed() throws {
        // A web include is an include; a relative or feed: one is unusable. Neither opens a folder for the rows after it.
        let opml = Self.wrap("""
        <outline type="include" text="Web picks" url="https://example.org/a.opml"/>
        <outline type="include" text="Relative" url="lists/other.opml"/>
        <outline type="rss" text="After" xmlUrl="https://a.example/feed"/>
        """)
        let document = try OPMLParser.parse(opml)
        XCTAssertEqual(document.includes.map(\.title), ["Web picks"])
        XCTAssertEqual(document.unusableOutlineCount, 1)
        XCTAssertEqual(document.feeds.map(\.folders), [[]])
    }

    func testExportLeavesAGUIDThatIsATokenisedLinkOut() throws {
        let show = Self.subscription("s", "Show", "https://example.com/s.xml")
        let text = String(decoding: OPMLExporter.export([show], podcastGUIDs: ["s": "https://www.patreon.com/rss/x?auth=secret"]).data, as: UTF8.self)
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("podcast:guid"))
    }

    func testAnIncludeWithoutATitleUsesItsAddress() throws {
        let opml = Self.wrap(#"<outline type="include" url="https://example.org/l.opml"/>"#)
        XCTAssertEqual(try OPMLParser.parse(opml).includes, [OPMLInclude(url: "https://example.org/l.opml", title: "https://example.org/l.opml")])
    }

    func testEdgeFileReadsEveryRowAndKeepsEscapesIntact() throws {
        let document = try OPMLParser.parse(Self.fixture("lists-edges"))
        XCTAssertEqual(document.feeds.count, 7)
        XCTAssertEqual(document.feeds[0].categories, ["News", "Tech/AI"])
        XCTAssertEqual(document.feeds[1].categories, ["News"])
        XCTAssertEqual(document.feeds[2].categories, ["Caf\u{00E9}"], "NFC, NFD and upper case are one name")
        XCTAssertEqual(document.feeds[3].title, #"Ampersand & <angle> "quotes""#)
        XCTAssertEqual(document.feeds[3].feedURL, "https://example.com/d.xml?x=1&y=2")
        XCTAssertEqual(document.feeds[3].categories, ["R&D", #""Quoted""#])
        XCTAssertNil(document.feeds[4].podcastGUID, "a blank GUID is none")
        XCTAssertEqual(document.feeds[6].categories, [])
    }

    func testOlderFixturesReadAsBefore() throws {
        // Counts taken from the parser before lists existed (feeds, unusable outlines).
        let before: [String: (feeds: Int, unusable: Int)] = [
            "overcast": (3, 0), "pocket-casts": (4, 0), "castro": (3, 0), "antennapod": (3, 0),
        ]
        for (name, counts) in before {
            let document = try OPMLParser.parse(Self.fixture(name))
            XCTAssertEqual(document.feeds.count, counts.feeds, name)
            XCTAssertEqual(document.unusableOutlineCount, counts.unusable, name)
        }
        for name in ["overcast", "pocket-casts", "castro", "antennapod", "edge-cases"] {
            let document = try OPMLParser.parse(Self.fixture(name))
            XCTAssertTrue(document.feeds.allSatisfy { $0.categories.isEmpty && $0.podcastGUID == nil && $0.sm == OPMLSpokenMarginsAttributes() }, name)
            XCTAssertEqual(document.includes, [], name)
        }
    }

    func testExportWithListsRoundTrips() throws {
        let daily = Self.subscription("sub-daily", "The Daily", "https://feeds.simplecast.com/Sl5CSM3S")
        let fork = Self.subscription("sub-fork", "Hard Fork", "https://feeds.simplecast.com/6HKOhNgS")
        let loose = Self.subscription("sub-loose", "Loose", "https://example.com/loose.xml")
        let lists = [
            FollowList(id: "1", name: "Tech/AI", members: [ListMember(feedKey: "https://feeds.simplecast.com/6HKOhNgS")]),
            FollowList(id: "2", name: "News", members: [ListMember(feedKey: "https://feeds.simplecast.com/Sl5CSM3S"), ListMember(feedKey: "https://feeds.simplecast.com/6HKOhNgS")]),
        ]
        let export = OPMLExporter.export([daily, fork, loose], lists: lists, podcastGUIDs: ["sub-fork": " GUID-FORK "])
        let text = String(decoding: export.data, as: UTF8.self)
        XCTAssertTrue(text.contains(#"xmlns:podcast="https://podcastindex.org/namespace/1.0""#))
        XCTAssertFalse(text.contains("xmlns:sm"), "no sm attribute is written, so no namespace")
        XCTAssertEqual(export.exportedCount, 3)

        let parsed = try OPMLParser.parse(export.data)
        let byTitle = Dictionary(uniqueKeysWithValues: parsed.feeds.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["Hard Fork"]?.categories, ["News", "Tech/AI"], "chip order, and Tech/AI stays one name")
        XCTAssertEqual(byTitle["Hard Fork"]?.podcastGUID, "GUID-FORK")
        XCTAssertEqual(byTitle["The Daily"]?.categories, ["News"])
        XCTAssertEqual(byTitle["Loose"]?.categories, [])
        XCTAssertNil(byTitle["The Daily"]?.podcastGUID)
    }

    func testExportWritesIncludesAndViaAndStillListsEveryShowPlainly() throws {
        let radiolab = Self.subscription("sub-radio", "Radiolab", "https://feeds.simplecast.com/EmVW7VGp")
        let own = Self.subscription("sub-own", "Own pick", "https://example.com/own.xml")
        let export = OPMLExporter.export(
            [radiolab, own],
            includes: [OPMLExportInclude(title: "Priya & friends", url: "https://example.org/priya.opml"), OPMLExportInclude(title: "Bad", url: "ftp://example.org/x")],
            includedVia: ["sub-radio": "Priya & friends"]
        )
        let text = String(decoding: export.data, as: UTF8.self)
        XCTAssertTrue(text.contains(#"xmlns:sm="https://spokenmargins.com/ns/lists/1""#))
        let parsed = try OPMLParser.parse(export.data)
        XCTAssertEqual(parsed.includes, [OPMLInclude(url: "https://example.org/priya.opml", title: "Priya & friends")], "a non-web include is not written")
        XCTAssertEqual(parsed.feeds.map(\.title), ["Own pick", "Radiolab"], "every show is a plain row, so readers that ignore include still get it")
        XCTAssertEqual(parsed.feeds.map(\.sm.via), [nil, "Priya & friends"])
        XCTAssertEqual(parsed.unusableOutlineCount, 0)
    }

    func testExportWithNothingExtraIsExactlyWhatItWasBeforeLists() {
        let daily = Self.subscription("sub-daily", "The Daily", "https://feeds.simplecast.com/Sl5CSM3S")
        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        let text = String(decoding: OPMLExporter.export([daily], createdAt: stamp).data, as: UTF8.self)
        XCTAssertEqual(text, """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>Spoken Margins follows</title>
            <dateCreated>\(OPMLExporter.rfc822(stamp))</dateCreated>
          </head>
          <body>
            <outline type="rss" text="The Daily" title="The Daily" xmlUrl="https://feeds.simplecast.com/Sl5CSM3S"/>
          </body>
        </opml>

        """)
    }

    func testPrivateFeedsLeaveNoTraceInAListExport() throws {
        let secret = "https://example.com/feed?token=abc123secret"
        let hidden = Self.subscription("sub-secret", "Members only", secret)
        let open = Self.subscription("sub-open", "Open", "https://example.com/open.xml")
        let lists = [FollowList(id: "1", name: "Mixed", members: [ListMember(feedKey: FeedURLKey.make(secret) ?? ""), ListMember(feedKey: "https://example.com/open.xml")])]
        let export = OPMLExporter.export([hidden, open], lists: lists, podcastGUIDs: ["sub-secret": "secret-guid"], includedVia: ["sub-secret": "Somebody"])
        let text = String(decoding: export.data, as: UTF8.self)
        XCTAssertEqual(export.withheldPrivateCount, 1)
        XCTAssertFalse(text.contains("abc123secret"))
        XCTAssertFalse(text.contains("secret-guid"))
        XCTAssertFalse(text.contains("Members only"))
        XCTAssertFalse(text.contains("Somebody"))
        XCTAssertEqual(try OPMLParser.parse(export.data).feeds.map(\.title), ["Open"])
    }

    func testExportEscapesNamesThatCouldBreakTheFile() throws {
        let show = Self.subscription("s", #"Q&A <live> "now""#, "https://example.com/qa.xml?a=1&b=2")
        let list = FollowList(id: "1", name: #"R&D "lab" <x>"#, members: [ListMember(feedKey: FeedURLKey.make("https://example.com/qa.xml?a=1&b=2") ?? "")])
        let parsed = try OPMLParser.parse(OPMLExporter.export([show], lists: [list]).data)
        XCTAssertEqual(parsed.feeds.first?.title, #"Q&A <live> "now""#)
        XCTAssertEqual(parsed.feeds.first?.categories, [#"R&D "lab" <x>"#])
    }

    func testAListNameWithACommaCannotSplitIntoTwoOnTheWayOut() throws {
        // A typed name can't hold a comma, but a name that came in from a file might; the file format can't carry it.
        let show = Self.subscription("s", "Show", "https://example.com/s.xml")
        let list = FollowList(id: "1", name: "Left, Right", members: [ListMember(feedKey: "https://example.com/s.xml")])
        let parsed = try OPMLParser.parse(OPMLExporter.export([show], lists: [list]).data)
        XCTAssertEqual(parsed.feeds.first?.categories, ["Left Right"])
    }

    // MARK: Fixtures

    private static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: TestInputs.url(.contracts, "fixtures/opml/\(name).opml"))
    }

    private static func wrap(_ body: String) -> Data {
        Data(#"<?xml version="1.0"?><opml version="2.0"><head><title>t</title></head><body>\#(body)</body></opml>"#.utf8)
    }

    private static func subscription(_ id: String, _ title: String, _ url: String) -> FeedSubscription {
        FeedSubscription(
            id: id,
            source: SourceIdentity(id: "source-\(id)", kind: .podcastFeed, canonicalURL: url, host: URL(string: url)?.host ?? "example.com", title: title),
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }
}
