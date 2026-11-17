import SessionKit
import XCTest

/// Folding a chapter of the Timeline rail hides its rows and leaves every chapter row (#3895).
final class TimelineChapterFoldingTests: XCTestCase {
    private typealias Row = TimelineChapterFolding.Row

    /// Beginning, two chapters of a scientific PDF (the first dense with figures and tables), a chapter with
    /// nothing under it, and a last chapter that holds a shared Margin the listener hasn't heard.
    private let rows: [Row] = [
        Row(id: "beginning", isChapter: false),
        Row(id: "ch1", isChapter: true),
        Row(id: "fig1", isChapter: false),
        Row(id: "tab1", isChapter: false),
        Row(id: "foot1", isChapter: false),
        Row(id: "ch2", isChapter: true),
        Row(id: "fig2", isChapter: false),
        Row(id: "ch3", isChapter: true),
        Row(id: "ch4", isChapter: true),
        Row(id: "shared", isChapter: false, isNew: true),
    ]

    private func ids(_ rows: [Row]) -> [String] { rows.map(\.id) }

    func testNothingFoldedShowsEveryRow() {
        let folding = TimelineChapterFolding()
        XCTAssertEqual(folding.visibleRows(in: rows), rows)
    }

    func testFoldingAChapterHidesOnlyItsRowsAndKeepsEveryChapterRow() {
        var folding = TimelineChapterFolding()
        folding.toggle("ch1", in: rows)

        XCTAssertEqual(ids(folding.visibleRows(in: rows)), ["beginning", "ch1", "ch2", "fig2", "ch3", "ch4", "shared"])
        XCTAssertTrue(folding.isFolded("ch1"))
    }

    func testFoldingTwiceUnfolds() {
        var folding = TimelineChapterFolding()
        folding.toggle("ch2", in: rows)
        folding.toggle("ch2", in: rows)

        XCTAssertFalse(folding.isFolded("ch2"))
        XCTAssertEqual(folding.visibleRows(in: rows), rows)
    }

    func testSeveralChaptersFoldIndependently() {
        var folding = TimelineChapterFolding()
        folding.toggle("ch1", in: rows)
        folding.toggle("ch4", in: rows)

        XCTAssertEqual(ids(folding.visibleRows(in: rows)), ["beginning", "ch1", "ch2", "fig2", "ch3", "ch4"])
    }

    func testRowsBeforeTheFirstChapterAreNeverHidden() {
        var folding = TimelineChapterFolding()
        folding.toggle("ch1", in: rows)
        folding.toggle("ch2", in: rows)
        folding.toggle("ch4", in: rows)

        XCTAssertTrue(folding.visibleRows(in: rows).contains { $0.id == "beginning" })
    }

    func testAChapterWithNothingUnderItCannotFold() {
        var folding = TimelineChapterFolding()
        folding.toggle("ch3", in: rows)

        XCTAssertFalse(folding.isFolded("ch3"))
        XCTAssertFalse(TimelineChapterFolding.canFold("ch3", in: rows))
        XCTAssertTrue(TimelineChapterFolding.canFold("ch1", in: rows))
    }

    func testANonChapterRowCannotFold() {
        var folding = TimelineChapterFolding()
        folding.toggle("fig1", in: rows)
        folding.toggle("beginning", in: rows)

        XCTAssertEqual(folding.foldedChapterIDs, [])
    }

    func testAnUnknownIdIsIgnored() {
        var folding = TimelineChapterFolding()
        folding.toggle("nope", in: rows)

        XCTAssertEqual(folding.foldedChapterIDs, [])
    }

    func testFoldedChapterHidingReportsTheChapterOnlyForHiddenRows() {
        var folding = TimelineChapterFolding()
        folding.toggle("ch1", in: rows)

        XCTAssertEqual(folding.foldedChapterHiding("tab1", in: rows), "ch1")
        XCTAssertNil(folding.foldedChapterHiding("ch1", in: rows), "a chapter row is never hidden by its own fold")
        XCTAssertNil(folding.foldedChapterHiding("fig2", in: rows), "the next chapter's rows stay visible")
        XCTAssertNil(folding.foldedChapterHiding("beginning", in: rows))
        XCTAssertNil(folding.foldedChapterHiding("unknown", in: rows))
    }

    func testRevealUnfoldsOnlyTheChapterThatHidesTheRow() {
        var folding = TimelineChapterFolding()
        folding.toggle("ch1", in: rows)
        folding.toggle("ch2", in: rows)

        XCTAssertTrue(folding.reveal("foot1", in: rows))
        XCTAssertFalse(folding.isFolded("ch1"))
        XCTAssertTrue(folding.isFolded("ch2"))
        XCTAssertFalse(folding.reveal("foot1", in: rows), "already visible: nothing changes")
        XCTAssertFalse(folding.reveal("ch2", in: rows), "a chapter row is already visible")
    }

    func testVisibleIDForAHiddenRowIsItsFoldedChapter() {
        var folding = TimelineChapterFolding()
        folding.toggle("ch1", in: rows)

        XCTAssertEqual(folding.visibleID(for: "tab1", in: rows), "ch1")
        XCTAssertEqual(folding.visibleID(for: "fig2", in: rows), "fig2")
        XCTAssertEqual(folding.visibleID(for: "ch1", in: rows), "ch1")
    }

    func testSummaryCountsHiddenRowsAndFlagsTheCurrentOne() {
        var folding = TimelineChapterFolding()
        folding.toggle("ch1", in: rows)

        let playing = folding.summary(forChapter: "ch1", in: rows, currentIDs: ["tab1"])
        XCTAssertEqual(playing, .init(hiddenCount: 3, hasNew: false, containsCurrent: true))
        XCTAssertEqual(playing?.text, "3 rows hidden")

        let elsewhere = folding.summary(forChapter: "ch1", in: rows, currentIDs: ["fig2"])
        XCTAssertEqual(elsewhere?.containsCurrent, false)
        XCTAssertNil(folding.summary(forChapter: "ch2", in: rows, currentIDs: []), "a chapter that isn't folded has no summary")
    }

    func testSummaryDoesNotBuryNewSharedMargins() {
        var folding = TimelineChapterFolding()
        folding.toggle("ch4", in: rows)

        let summary = folding.summary(forChapter: "ch4", in: rows, currentIDs: [])
        XCTAssertEqual(summary, .init(hiddenCount: 1, hasNew: true, containsCurrent: false))
        XCTAssertEqual(summary?.text, "1 row hidden, new inside")
    }

    func testPruneDropsChaptersThatLeftTheRailOrEmptied() {
        var folding = TimelineChapterFolding(foldedChapterIDs: ["ch1", "gone", "ch3"])
        folding.prune(to: rows)

        XCTAssertEqual(folding.foldedChapterIDs, ["ch1"], "ch3 has nothing under it and gone is not on the rail")
    }

    func testPruneKeepsAFoldWhenARowArrivesInTheChapter() {
        var folding = TimelineChapterFolding()
        folding.toggle("ch1", in: rows)
        var more = rows
        more.insert(Row(id: "mine", isChapter: false), at: 3)
        folding.prune(to: more)

        XCTAssertTrue(folding.isFolded("ch1"))
        XCTAssertEqual(folding.summary(forChapter: "ch1", in: more, currentIDs: [])?.hiddenCount, 4)
    }

    func testAnEmptyRailAndARailWithNoChaptersFoldNothing() {
        var folding = TimelineChapterFolding()
        folding.toggle("a", in: [])
        XCTAssertEqual(folding.visibleRows(in: []), [])

        let flat = [Row(id: "a", isChapter: false), Row(id: "b", isChapter: false)]
        folding.toggle("a", in: flat)
        XCTAssertEqual(folding.visibleRows(in: flat), flat)
    }

    func testFoldingASectionInTheMiddleLeavesTheOnesAroundItVisible() {
        var folding = TimelineChapterFolding()
        folding.toggle("ch2", in: rows)

        XCTAssertEqual(ids(folding.visibleRows(in: rows)), ["beginning", "ch1", "fig1", "tab1", "foot1", "ch2", "ch3", "ch4", "shared"])
    }
}
