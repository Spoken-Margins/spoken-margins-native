import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitFeeds

/// #4920: Select All / Deselect All, search and A to Z order on the import preview.
final class OPMLImportSelectionTests: XCTestCase {
    // MARK: - Bulk ticks

    /// The issue's required test: a 100-row preview unticked in one step leaves Follow disabled and nothing followed.
    func testDeselectAllOnAHundredRowsLeavesNothingTickedAndFollowsNothing() async throws {
        let preview = try Self.preview(count: 100)
        var selection = OPMLImportSelection(preview: preview)
        XCTAssertEqual(selection.tickedCount, 100)
        selection.deselectAll(selection.matches(""))
        XCTAssertTrue(selection.ticked.isEmpty)
        XCTAssertFalse(selection.canDeselectAll(selection.matches("")))
        XCTAssertTrue(selection.canSelectAll(selection.matches("")))

        var calls = 0
        var reported: [(Int, Int)] = []
        let result = await OPMLImportRunner.follow(preview, selected: selection.ticked, progress: { reported.append(($0, $1)) }) { _ in calls += 1 }
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(result.followed.isEmpty)
        XCTAssertEqual(reported.last?.0, 0)
        XCTAssertEqual(reported.last?.1, 0)
    }

    func testSelectAllAfterAPartialUntickTicksEveryRow() throws {
        var selection = OPMLImportSelection(preview: try Self.preview(count: 100))
        for row in selection.newRows.prefix(40) { selection.setTicked(row.id, false) }
        XCTAssertEqual(selection.tickedCount, 60)
        let all = selection.matches("")
        XCTAssertTrue(selection.canSelectAll(all))
        XCTAssertTrue(selection.canDeselectAll(all))
        selection.selectAll(all)
        XCTAssertEqual(selection.tickedCount, 100)
        XCTAssertFalse(selection.canSelectAll(all))
        selection.setTicked(selection.newRows[0].id, false)
        XCTAssertTrue(selection.canSelectAll(all))
        XCTAssertTrue(selection.canDeselectAll(all))
    }

    func testDeselectAllDuringASearchChangesOnlyTheShownRows() throws {
        var lines = (1...98).map { "Show \($0) https://feeds.example.com/\($0).xml" }
        lines += ["Hard Fork https://feeds.example.com/hf.xml", "Forked Up https://feeds.example.com/fu.xml"]
        var selection = OPMLImportSelection(preview: try Self.preview(lines))
        let search = selection.matches("fork")
        XCTAssertEqual(search.new.map(\.title), ["Forked Up", "Hard Fork"])
        selection.deselectAll(search)
        XCTAssertEqual(selection.tickedCount, 98)
        XCTAssertEqual(selection.hiddenTickedCount(search), 98)
        XCTAssertFalse(selection.canDeselectAll(search))
        XCTAssertEqual(selection.hiddenTickedCount(selection.matches("")), 0, "No search hides nothing")
    }

    func testTickedCountMatchesTheRunnersTotal() async throws {
        let preview = try Self.preview(count: 100)
        var selection = OPMLImportSelection(preview: preview)
        for row in selection.newRows.prefix(40) { selection.setTicked(row.id, false) }
        var total = -1
        _ = await OPMLImportRunner.follow(preview, selected: selection.ticked, progress: { total = $1 }) { _ in }
        XCTAssertEqual(total, selection.tickedCount)

        selection.selectAll(selection.matches(""))
        selection.deselectAll(selection.matches("Show 1"))
        var followed = 0
        _ = await OPMLImportRunner.follow(preview, selected: selection.ticked, progress: { total = $1 }) { _ in followed += 1 }
        XCTAssertEqual(total, selection.tickedCount)
        XCTAssertEqual(followed, selection.tickedCount)
    }

    // MARK: - Order

    func testSortTable() throws {
        let names = ["banana", "Apple", "apple", "Élan", "Elan", "Show 10", "Show 2", "99 Invisible", "🎧 Gear"]
        let lines = names.enumerated().map { "\($0.element) https://feeds.example.com/\($0.offset).xml" }
        let selection = OPMLImportSelection(preview: try Self.preview(lines))
        XCTAssertEqual(selection.newRows.map(\.title), ["99 Invisible", "Apple", "apple", "banana", "Elan", "Élan", "Show 2", "Show 10", "🎧 Gear"])
    }

    func testDecomposedAccentsSortWithComposedOnes() {
        let decomposed = "E\u{301}lan"
        let sorted = OPMLImportOrder.sorted(["Zed", decomposed, "Elan"], title: { $0 }, feedURL: { _ in nil })
        XCTAssertEqual(sorted.map { $0.precomposedStringWithCanonicalMapping }, ["Elan", "Élan", "Zed"])
    }

    func testALeadingTheCountsAndSameNamesOrderByHost() throws {
        let selection = OPMLImportSelection(preview: try Self.preview([
            "The Daily https://feeds.example.com/daily.xml",
            "Same Name https://b.com/feed.xml",
            "Same Name https://a.com/feed.xml",
            "Search Engine https://feeds.example.com/se.xml",
        ]))
        XCTAssertEqual(selection.newRows.map(\.title), ["Same Name", "Same Name", "Search Engine", "The Daily"])
        XCTAssertEqual(selection.newRows.prefix(2).compactMap { $0.feed?.url }, ["https://a.com/feed.xml", "https://b.com/feed.xml"])
    }

    func testNamelessRowsComeLastSortedByAddress() throws {
        let selection = OPMLImportSelection(preview: try Self.preview([
            "https://z.example.com/feed.xml",
            "Zebra https://feeds.example.com/zebra.xml",
            "http://a.example.com/feed.xml",
            "Aardvark https://feeds.example.com/aardvark.xml",
        ]))
        XCTAssertEqual(selection.newRows.map(\.title), [
            "Aardvark", "Zebra", "http://a.example.com/feed.xml", "https://z.example.com/feed.xml",
        ])
        XCTAssertTrue(OPMLImportOrder.isNameless(title: "http://a.example.com/feed.xml", feedURL: "https://a.example.com/feed.xml"))
        XCTAssertFalse(OPMLImportOrder.isNameless(title: "https://other.example.org", feedURL: "https://feeds.example.com/web-titled.xml"),
                       "A title that is a different web address from its feed is a name")
        XCTAssertFalse(OPMLImportOrder.isNameless(title: "Zebra", feedURL: nil))
    }

    func testIDsDoNotChangeWithTheDisplayOrder() throws {
        let preview = try Self.preview(["Zed https://feeds.example.com/z.xml", "Abe https://feeds.example.com/a.xml"])
        let selection = OPMLImportSelection(preview: preview)
        XCTAssertEqual(selection.newRows.map(\.id), [preview.toFollow[1].id, preview.toFollow[0].id])
    }

    // MARK: - Search

    func testSearchTable() throws {
        let subs = [Self.subscription("Followed Fork", "https://simplecast.example.com/ff.xml")]
        let selection = OPMLImportSelection(preview: try Self.preview([
            "Hard Fork https://feeds.simplecast.example.com/hf.xml",
            "Élan Vital https://feeds.example.com/elan.xml",
            "Other https://feeds.example.com/other.xml",
            "Followed Fork https://simplecast.example.com/ff.xml",
        ], existing: subs))

        XCTAssertEqual(selection.matches("simplecast").new.map(\.title), ["Hard Fork"], "New rows match their host")
        XCTAssertTrue(selection.matches("simplecast").alreadyFollowed.isEmpty, "Already followed rows match on title only")
        XCTAssertEqual(selection.matches("fork").alreadyFollowed.map(\.feed.title), ["Followed Fork"])
        XCTAssertEqual(selection.matches("elan").new.map(\.title), ["Élan Vital"])
        XCTAssertEqual(selection.matches("ÉLAN").new.map(\.title), ["Élan Vital"])
        XCTAssertNil(selection.matches("   ").query)
        XCTAssertNil(selection.matches(" \n").query)
        XCTAssertEqual(selection.matches("   ").new.count, 3)
        XCTAssertEqual(selection.matches(" fork ").new.map(\.title), ["Hard Fork"])
        XCTAssertEqual(selection.matches("ard Fo").new.map(\.title), ["Hard Fork"])
        XCTAssertTrue(selection.matches(String(repeating: "x", count: 500)).new.isEmpty)

        let empty = OPMLImportSelection(preview: try Self.preview([]))
        let none = empty.matches("anything")
        XCTAssertTrue(none.new.isEmpty && none.alreadyFollowed.isEmpty && none.repeated.isEmpty)
    }

    func testRepeatedRowsAreSortedAndSearchable() throws {
        let selection = OPMLImportSelection(preview: try Self.preview([
            "Zulu https://feeds.example.com/z.xml",
            "Alpha https://feeds.example.com/a.xml",
            "Zulu again https://feeds.example.com/z.xml",
            "Alpha again https://feeds.example.com/a.xml",
        ]))
        XCTAssertEqual(selection.repeated.map(\.feed.title), ["Alpha again", "Zulu again"])
        XCTAssertEqual(selection.matches("zulu").repeated.map(\.feed.title), ["Zulu again"])
    }

    // MARK: - Buttons

    func testButtonsAndBurst() throws {
        XCTAssertFalse(OPMLImportSelection(preview: try Self.preview(count: 1)).showsBulkButtons)
        XCTAssertTrue(OPMLImportSelection(preview: try Self.preview(count: 2)).showsBulkButtons)
        XCTAssertFalse(OPMLImportSelection(preview: try Self.preview(count: 10)).showsSearch)
        XCTAssertTrue(OPMLImportSelection(preview: try Self.preview(count: 11)).showsSearch)

        var selection = OPMLImportSelection(preview: try Self.preview(count: 12))
        let noMatch = selection.matches("nothing like this")
        XCTAssertFalse(selection.canSelectAll(noMatch))
        XCTAssertFalse(selection.canDeselectAll(noMatch))

        let all = selection.matches("")
        selection.deselectAll(all)
        let once = selection
        selection.deselectAll(all)
        XCTAssertEqual(selection, once)
        selection.selectAll(all)
        let selectedOnce = selection
        selection.selectAll(all)
        XCTAssertEqual(selection, selectedOnce)
    }

    func testSetTickedIgnoresIDsNotInNew() throws {
        var selection = OPMLImportSelection(preview: try Self.preview(count: 2))
        selection.setTicked("opml:99:https://nowhere.example.com", true)
        XCTAssertEqual(selection.tickedCount, 2)
    }

    // MARK: - Returning listener

    func testSelectAllNeverTouchesAlreadyFollowedRows() throws {
        let lines = (1...100).map { "Show \($0) https://feeds.example.com/\($0).xml" }
        let subs = (1...30).map { Self.subscription("Show \($0)", "https://feeds.example.com/\($0).xml") }
        var selection = OPMLImportSelection(preview: try Self.preview(lines, existing: subs))
        XCTAssertEqual(selection.newRows.count, 70)
        XCTAssertEqual(selection.alreadyFollowed.count, 30)
        XCTAssertEqual(selection.alreadyFollowed.prefix(3).map(\.feed.title), ["Show 1", "Show 2", "Show 3"])
        XCTAssertEqual(selection.matches("Show 12").alreadyFollowed.map(\.feed.title), ["Show 12"])
        selection.deselectAll(selection.matches(""))
        selection.selectAll(selection.matches(""))
        XCTAssertEqual(selection.tickedCount, 70)
    }

    func testTheSameListImportedAgainHasNoButtonsAndNoSearch() throws {
        let lines = (1...100).map { "Show \($0) https://feeds.example.com/\($0).xml" }
        let subs = (1...99).map { Self.subscription("Show \($0)", "https://feeds.example.com/\($0).xml") }
        let selection = OPMLImportSelection(preview: try Self.preview(lines, existing: subs))
        XCTAssertEqual(selection.newRows.map(\.title), ["Show 100"])
        XCTAssertFalse(selection.showsBulkButtons)
        XCTAssertFalse(selection.showsSearch)
    }

    // MARK: - Long source

    func testFiveThousandRowsSortAndSearch() throws {
        let lines = (1...5000).reversed().map { "Show \($0) https://feeds.example.com/\($0).xml" }
        let selection = OPMLImportSelection(preview: try Self.preview(lines))
        XCTAssertEqual(selection.newRows.count, 5000)
        XCTAssertEqual(selection.newRows.first?.title, "Show 1")
        XCTAssertEqual(selection.newRows.last?.title, "Show 5000")
        XCTAssertEqual(selection.newRows[9].title, "Show 10")
        XCTAssertEqual(selection.matches("Show 4321").new.map(\.title), ["Show 4321"])
    }

    // MARK: - Starting ticks

    func testStartingTicksKeepLeftOutRowsUnticked() throws {
        let preview = try Self.preview(count: 10)
        let leftOut = Set(preview.toFollow.prefix(3).map(\.id))
        var selection = OPMLImportSelection(preview: preview, startingTicks: Set(preview.toFollow.map(\.id)).subtracting(leftOut).union(["not-a-row"]))
        XCTAssertEqual(selection.tickedCount, 7)
        XCTAssertTrue(leftOut.allSatisfy { !selection.isTicked($0) })
        selection.selectAll(selection.matches(""))
        XCTAssertEqual(selection.tickedCount, 10)
    }

    func testHomeNetworkRowsStartUntickedFromDefaultSelection() throws {
        let preview = try Self.preview(["Home https://192.168.1.10/feed.xml", "Away https://feeds.example.com/away.xml"])
        let selection = OPMLImportSelection(preview: preview, startingTicks: preview.defaultSelection)
        XCTAssertEqual(selection.newRows.filter { selection.isTicked($0.id) }.map(\.title), ["Away"])
    }

    // MARK: - Helpers

    private static func preview(count: Int) throws -> OPMLImportPreview {
        try preview((1...max(count, 1)).prefix(count).map { "Show \($0) https://feeds.example.com/\($0).xml" })
    }

    private static func preview(_ lines: [String], existing: [FeedSubscription] = []) throws -> OPMLImportPreview {
        OPMLImportPlanner.preview(try FeedLinkListParser.parse(lines), existing: existing)
    }

    private static func subscription(_ title: String, _ url: String) -> FeedSubscription {
        let host = URLComponents(string: url)?.host ?? "unknown"
        return FeedSubscription(id: "subscription-\(title)", source: SourceIdentity(id: "source-\(title)", kind: .podcastFeed, canonicalURL: url, host: host, title: title))
    }
}
