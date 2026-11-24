import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #4858: what the import preview's rows and sections say, from the real parser and planner, so a Shortcut
/// list leads with show names and never shows a whole feed URL as a row title.
final class OPMLImportPreviewWordsTests: XCTestCase {
    private func preview(_ lines: [String], existing: [FeedSubscription] = []) throws -> OPMLImportPreview {
        OPMLImportPlanner.preview(try FeedLinkListParser.parse(lines), existing: existing)
    }

    private func rows(_ preview: OPMLImportPreview, _ source: OPMLImportPreviewWords.Source = .shortcut) -> [OPMLImportPreviewWords.Row] {
        preview.toFollow.map { OPMLImportPreviewWords.row($0, source: source) }
    }

    func testANamedRowLeadsWithTheNameAndShowsTheHostBelow() throws {
        let row = try XCTUnwrap(rows(try preview(["Hard Fork https://feeds.Simplecast.com/l2i9YnTd"])).first)
        XCTAssertEqual(row.title, "Hard Fork")
        XCTAssertEqual(row.detail, "feeds.simplecast.com")
        XCTAssertEqual(row.accessibilityLabel, "Hard Fork, feeds.simplecast.com")
        XCTAssertTrue(row.hasName)
        XCTAssertFalse(row.isHomeNetwork)
    }

    func testAGluedNameShowsTheNameNotUnusable() throws {
        let p = try preview(["Hard Forkhttps://feeds.example.com/a.xml"])
        XCTAssertEqual(rows(p).map(\.title), ["Hard Fork"])
        XCTAssertNil(OPMLImportPreviewWords.unusableSection(p, source: .shortcut))
    }

    func testANamelessRowNeverShowsItsWholeURL() throws {
        let lines = [
            "https://feeds.simplecast.com/the-daily",
            "http://feeds.example.com/show/feed.xml",
            "https://anchor.fm/s/1a2b3c4d5e6f7a8b/podcast/rss",
        ]
        let p = try preview(lines)
        let shown = rows(p)
        XCTAssertEqual(shown.map(\.title), ["feeds.simplecast.com/the-daily", "feeds.example.com", "anchor.fm"])
        for (row, line) in zip(shown, lines) {
            XCTAssertNotEqual(row.title, line)
            XCTAssertFalse(row.title.contains("://"), row.title)
            XCTAssertEqual(row.detail, "No name passed in")
            XCTAssertTrue(row.accessibilityLabel.hasPrefix("No name, "), row.accessibilityLabel)
            XCTAssertFalse(row.hasName)
        }
        XCTAssertEqual(OPMLImportPreviewWords.row(p.toFollow[0], source: .file).detail, "No name in the file")
    }

    func testAHomeNetworkRowIsMarked() throws {
        let p = try preview(["My NAS http://nas.local/podcast.xml", "http://192.168.1.2/feed"])
        let shown = rows(p)
        XCTAssertEqual(shown.map(\.title), ["My NAS", "192.168.1.2"])
        XCTAssertEqual(shown.map(\.detail), [OPMLImportPreviewWords.homeNetworkDetail, OPMLImportPreviewWords.homeNetworkDetail])
        XCTAssertEqual(shown[0].accessibilityLabel, "My NAS, nas.local, home network address")
        XCTAssertEqual(shown[1].accessibilityLabel, "No name, 192.168.1.2, home network address")
        XCTAssertTrue(p.defaultSelection.isEmpty, "home-network rows start unticked")
    }

    func testTheShortcutFooterCountsNamelessRowsOnlyForAShortcut() throws {
        let p = try preview(["Named https://feeds.example.com/a.xml", "https://feeds.example.com/b.xml", "https://feeds.example.com/c.xml"])
        XCTAssertEqual(
            OPMLImportPreviewWords.newFooter(p, source: .shortcut),
            "2 shows came in without a name, so they show their web address. In Shortcuts, make the Text step the show's Name, a space, then its Feed URL."
        )
        XCTAssertNil(OPMLImportPreviewWords.newFooter(p, source: .file))
        XCTAssertNil(OPMLImportPreviewWords.newFooter(p, source: .assistant))
        let one = try preview(["https://feeds.example.com/b.xml"])
        XCTAssertEqual(
            OPMLImportPreviewWords.newFooter(one, source: .shortcut),
            "1 show came in without a name, so it shows its web address. In Shortcuts, make the Text step the show's Name, a space, then its Feed URL."
        )
        XCTAssertNil(OPMLImportPreviewWords.newFooter(try preview(["Named https://feeds.example.com/a.xml"]), source: .shortcut))
    }

    func testUnusableLinesWithNamesAreListedAndCappedAtTwenty() throws {
        var lines = (1...23).map { "Apple Only \($0) https://podcasts.apple.com/us/podcast/a/id\($0)" }
        lines.append("https://podcasts.apple.com/us/podcast/a/id99")
        let p = try preview(lines)
        let section = try XCTUnwrap(OPMLImportPreviewWords.unusableSection(p, source: .shortcut))
        XCTAssertEqual(section.header, "Can't follow (24)")
        XCTAssertEqual(section.names.count, 20)
        XCTAssertEqual(section.names.first, "Apple Only 1")
        XCTAssertEqual(section.more, "and 4 more")
        XCTAssertEqual(section.note, "These have no public feed link. Shows that exist only in Apple Podcasts are like this.")
    }

    func testNamelessUnusableLinesOnlyCount() throws {
        let p = try preview(["https://podcasts.apple.com/us/podcast/a/id1", "junk", "Show https://feeds.example.com/a.xml"])
        let section = try XCTUnwrap(OPMLImportPreviewWords.unusableSection(p, source: .shortcut))
        XCTAssertEqual(section.names, ["junk"])
        XCTAssertEqual(section.more, "and 1 more")
        let nameless = try XCTUnwrap(OPMLImportPreviewWords.unusableSection(try preview(["https://podcasts.apple.com/us/podcast/a/id1"]), source: .shortcut))
        XCTAssertEqual(nameless.names, [])
        XCTAssertNil(nameless.more)
        XCTAssertEqual(nameless.note, "1 entry has no feed link Spoken Margins can use, so it's skipped.")
        XCTAssertEqual(OPMLImportPreviewWords.unusableSection(try preview(["https://podcasts.apple.com/us/podcast/a/id1"]), source: .file)?.header, "Unusable (1)")
    }

    func testEveryLineUnusableSaysToCheckTheTextStepOnlyForAShortcut() throws {
        let p = try preview(["Hard Fork", "Pivot https://podcasts.apple.com/us/podcast/a/id1"])
        XCTAssertEqual(
            OPMLImportPreviewWords.emptyNewLine(p, source: .shortcut),
            "None of these lines had a feed link. In Shortcuts, check the Text step: the show's Name, a space, then its Feed URL."
        )
        XCTAssertEqual(OPMLImportPreviewWords.emptyNewLine(p, source: .assistant), "Nothing new to follow in this list.")
        XCTAssertNil(OPMLImportPreviewWords.emptyNewLine(try preview(["Show https://feeds.example.com/a.xml"]), source: .shortcut))
    }

    func testAnAllFollowedListKeepsNothingNew() throws {
        let existing = [FeedSubscription(id: "s", source: SourceIdentity(id: "src", kind: .podcastFeed, canonicalURL: "https://feeds.example.com/a.xml", host: "feeds.example.com", title: "A"))]
        let p = try preview(["A https://feeds.example.com/a.xml", "junk"], existing: existing)
        XCTAssertEqual(OPMLImportPreviewWords.emptyNewLine(p, source: .shortcut), "Nothing new to follow in this list.")
        XCTAssertEqual(OPMLImportPreviewWords.emptyNewLine(p, source: .file), "Nothing new to follow in this file.")
    }

    func testTheListsAfterThePreviewUseTheSameTitle() throws {
        let p = try preview(["http://feeds.example.com/the-show.xml"])
        let candidate = try XCTUnwrap(p.toFollow.first)
        XCTAssertEqual(OPMLImportPreviewWords.title(candidate.title, feedURL: candidate.feed?.url), "feeds.example.com/the-show")
        XCTAssertEqual(OPMLImportPreviewWords.title("Named", feedURL: "https://feeds.example.com/a.xml"), "Named")
        XCTAssertEqual(OPMLImportPreviewWords.title("https://feeds.example.com/a.xml", feedURL: nil), "https://feeds.example.com/a.xml")
    }

    func testAnOPMLOutlineWithNoNameGetsTheReadableAddress() throws {
        let opml = Data("""
        <opml version="2.0"><body>
          <outline type="rss" xmlUrl="https://feeds.example.com/my-show.xml"/>
          <outline type="rss" text="Named" xmlUrl="https://feeds.example.com/b.xml"/>
        </body></opml>
        """.utf8)
        let p = OPMLImportPlanner.preview(try OPMLParser.parse(opml), existing: [])
        XCTAssertEqual(rows(p, .file).map(\.title), ["feeds.example.com/my-show", "Named"])
        XCTAssertNil(OPMLImportPreviewWords.newFooter(p, source: .file))
    }
}
