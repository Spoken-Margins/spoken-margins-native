import XCTest
@testable import SessionKit
import SessionKitPersistence

final class ItemMetadataTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-16T12:00:00Z")!
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let english = Locale(identifier: "en_US")

    private func date(_ raw: String?) -> String? {
        ItemMetadata.publishedDateText(raw, now: now, locale: english, timeZone: utc)
    }

    func testPublishedDateReadsEveryFormatTheAppStores() {
        for (name, raw) in [("ISO 8601", "2026-09-29T10:00:00Z"), ("ISO with fractional seconds", "2026-09-29T10:00:00.123Z"),
                            ("ISO with an offset", "2026-09-29T12:00:00+02:00"), ("RFC 822 with GMT", "Tue, 29 Sep 2026 10:00:00 GMT"),
                            ("RFC 822 with a numeric zone", "Tue, 29 Sep 2026 10:00:00 +0000"),
                            ("RFC 822 without seconds", "Tue, 29 Sep 2026 10:00 GMT"),
                            ("RFC 822 with a one-digit day", "Tue, 9 Sep 2026 10:00:00 GMT"),
                            ("date only", "2026-09-29")] {
            let shown = date(raw)
            XCTAssertNotNil(shown, name)
            XCTAssertEqual(shown, name.contains("one-digit") ? "September 9, 2026" : "September 29, 2026", name)
        }
    }

    func testPublishedDateIgnoresSurroundingWhitespaceAndKeepsTheCalendarDayOfADateOnlyValue() {
        XCTAssertEqual(date("  2026-09-29T10:00:00Z \n"), "September 29, 2026")
        // A date with no time names a calendar day in any zone; a timestamp is shown in the viewer's zone.
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(ItemMetadata.publishedDateText("2026-09-29", now: now, locale: english, timeZone: tokyo), "September 29, 2026")
        XCTAssertEqual(ItemMetadata.publishedDateText("2026-09-29T20:00:00Z", now: now, locale: english, timeZone: tokyo), "September 30, 2026")
    }

    func testPublishedDateForSortingAgreesWithTheTextShown() {
        // #1867: the Published sort and the Item header read one date. Whatever the header refuses sorts as undated.
        XCTAssertEqual(ItemMetadata.publishedDate("2026-09-29T10:00:00Z", now: now),
                       ISO8601DateFormatter().date(from: "2026-09-29T10:00:00Z"))
        XCTAssertEqual(ItemMetadata.publishedDate("Tue, 29 Sep 2026 10:00:00 GMT", now: now),
                       ISO8601DateFormatter().date(from: "2026-09-29T10:00:00Z"))
        for raw in [nil, "", "   ", "not a date", "2999-01-01T00:00:00Z", "1850-01-01"] as [String?] {
            XCTAssertNil(ItemMetadata.publishedDate(raw, now: now), raw ?? "nil")
            XCTAssertNil(date(raw), raw ?? "nil")
        }
    }

    func testPublishedDateIsNilForEmptyGarbageAndImplausibleText() {
        for (name, raw) in [("nil", nil), ("empty", ""), ("spaces", "   "), ("garbage", "not a date"),
                            ("a number", "1790675200"), ("month 13", "2026-13-40"), ("half a date", "2026-09"),
                            ("far future", "2999-01-01T00:00:00Z"), ("far future RFC 822", "Mon, 01 Jan 2999 00:00:00 GMT"),
                            ("before 1970", "1850-01-01"), ("year zero", "0001-01-01T00:00:00Z")] as [(String, String?)] {
            XCTAssertNil(date(raw), name)
        }
        // A post scheduled for tomorrow is not garbage.
        XCTAssertNotNil(date("2026-10-17T09:00:00Z"))
    }

    func testDescriptionIsPlainTextWithParagraphsKept() {
        let html = "<p>First   paragraph with <b>bold</b> &amp; a &quot;quote&quot;.</p><p>Second&nbsp;paragraph.</p><ul><li>One</li><li>Two</li></ul>"
        XCTAssertEqual(ItemMetadata.plainDescription(from: html),
                       "First paragraph with bold & a \"quote\".\n\nSecond paragraph.\n\nOne\n\nTwo")
    }

    func testInlineTagsLeaveNoStraySpaces() {
        XCTAssertEqual(ItemMetadata.plainDescription(from: "Visit <a href=\"https://example.com\">example.com</a>."), "Visit example.com.")
        XCTAssertEqual(ItemMetadata.plainDescription(from: "<em>S</em>tart, <STRONG class=x>bold</STRONG>, <span>a</span><i>b</i>"), "Start, bold, ab")
        // Block tags and <br> still break lines, and a tag that only starts with an inline name is not inline.
        XCTAssertEqual(ItemMetadata.plainDescription(from: "One<br>Two<p>Three</p><abbr>x</abbr>"), "One\nTwo\nThree\nx")
    }

    func testDescriptionDecodesEntitiesAndLeavesLookalikesAlone() {
        XCTAssertEqual(ItemMetadata.plainDescription(from: "Tom &amp; Jerry &#8212; a caf&#xE9; &lt;3"), "Tom & Jerry — a café <3")
        XCTAssertEqual(ItemMetadata.plainDescription(from: "AT&T and R&D; fish & chips"), "AT&T and R&D; fish & chips")
        XCTAssertEqual(ItemMetadata.plainDescription(from: "&#0; &#xD800; &bogus;"), "&#0; &#xD800; &bogus;")
    }

    func testDescriptionIsNilWhenNothingReadableIsLeft() {
        for (name, raw) in [("nil", nil), ("empty", ""), ("spaces", "  \n\t "), ("only tags", "<p> </p><br/><div></div>"),
                            ("only a script", "<script>alert(1)</script>"), ("only a style", "<style>p{}</style>")] as [(String, String?)] {
            XCTAssertNil(ItemMetadata.plainDescription(from: raw), name)
        }
    }

    func testVeryLongDescriptionIsCutOnAWordBoundary() throws {
        let long = String(repeating: "word ", count: 1_000)
        let cut = try XCTUnwrap(ItemMetadata.plainDescription(from: long))
        XCTAssertLessThanOrEqual(cut.count, ItemMetadata.descriptionLimit + 1)
        XCTAssertTrue(cut.hasSuffix("word…"), String(cut.suffix(10)))
        // Exactly at the limit is kept whole; one character over is cut.
        let exact = String(repeating: "a", count: ItemMetadata.descriptionLimit)
        XCTAssertEqual(ItemMetadata.plainDescription(from: exact), exact)
        XCTAssertEqual(ItemMetadata.plainDescription(from: exact + "b")?.count, ItemMetadata.descriptionLimit + 1, "one unbroken word is cut at the limit")
    }

    func testNeedsExpansionOffersMoreOnlyWhenThePreviewHidesText() {
        XCTAssertFalse(ItemMetadata.needsExpansion("A short line."))
        XCTAssertFalse(ItemMetadata.needsExpansion("One\nTwo\nThree"))
        XCTAssertTrue(ItemMetadata.needsExpansion("One\nTwo\nThree\nFour"))
        XCTAssertTrue(ItemMetadata.needsExpansion(String(repeating: "x", count: 200)))
        // A 100-character paragraph can be cut at 3 lines at the largest text sizes, so it offers More.
        XCTAssertTrue(ItemMetadata.needsExpansion(String(repeating: "word ", count: 20)))
        XCTAssertTrue(ItemMetadata.needsExpansion(String(repeating: "word ", count: 80)))
    }

    // MARK: Storage

    func testFeedEntrySummaryBecomesTheItemsDescriptionAndAnExistingValueIsKept() {
        let entry = FeedEntry(id: "entry", subscriptionId: "s", canonicalURL: "https://media.example.com/one.mp3",
                              title: "Episode One", summary: "<p>The show notes &amp; links.</p>")
        var item = Item(id: "item", title: "Episode One", mediaType: "transcript_backed_media", text: nil, externalReference: nil, status: "ready")
        entry.fillEpisodeIdentity(of: &item, showTitle: "Show")
        XCTAssertEqual(item.descriptionText, "The show notes & links.")

        var kept = item
        kept.descriptionText = "What the listener's source gave."
        entry.fillEpisodeIdentity(of: &kept, showTitle: "Show")
        XCTAssertEqual(kept.descriptionText, "What the listener's source gave.")

        // No summary, or one with nothing readable, invents nothing.
        var bare = Item(id: "bare", title: "t", mediaType: "text", text: nil, externalReference: nil, status: "ready")
        FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://e.example/1", title: "t").fillEpisodeIdentity(of: &bare, showTitle: nil)
        FeedEntry(id: "e", subscriptionId: "s", canonicalURL: "https://e.example/1", title: "t", summary: "<br/>").fillEpisodeIdentity(of: &bare, showTitle: nil)
        XCTAssertNil(bare.descriptionText)
    }

    func testItemsSavedBeforeTheFieldStillDecodeAndTheFieldSurvivesTheStore() throws {
        let legacy = Data(#"{"id":"legacy","title":"Legacy","mediaType":"text","status":"ready","publishedAt":"2026-09-29T10:00:00Z"}"#.utf8)
        let old = try JSONDecoder().decode(Item.self, from: legacy)
        XCTAssertNil(old.descriptionText)
        XCTAssertEqual(old.publishedAt, "2026-09-29T10:00:00Z")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("item-metadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        var item = Item(id: "episode", title: "Episode", mediaType: "transcript_backed_media", text: nil, externalReference: nil, status: "ready")
        item.descriptionText = "Notes for the episode."
        try store.saveItem(item)
        XCTAssertEqual(try store.loadItem(id: "episode").descriptionText, "Notes for the episode.")
        // Saving the old item again does not invent a description.
        try store.saveItem(old)
        XCTAssertNil(try store.loadItem(id: "legacy").descriptionText)
    }
}
