import XCTest
@testable import SessionKit

/// #356: fresh starts opened with about 12 s of "Structured into eight listening chapters from
/// canonical document headings in …" before the title.
final class ListeningMapOverviewTextTests: XCTestCase {
    func testAppGeneratedOverviewIsTitleThenChapterCount() {
        XCTAssertEqual(ListeningMapOverviewText.appGenerated(title: "Evaluation Agents", chapterCount: 8), "Evaluation Agents. 8 chapters.")
        XCTAssertEqual(ListeningMapOverviewText.appGenerated(title: "Why?", chapterCount: 1), "Why? 1 chapter.")
        XCTAssertEqual(ListeningMapOverviewText.appGenerated(title: "Untitled", chapterCount: 0), "Untitled.")
    }

    func testMarkdownMapsNoLongerDescribeHowTheyWereBuilt() throws {
        let parsed = try ObsidianMarkdownParser.parse(fileName: "Report.md", contents: """
        # A Structured Report

        ## Context
        Context body.

        ## Evidence
        Evidence body.
        """)
        for policy in [DeterministicListeningMapPolicy.canonicalHeadings, .adaptiveListeningSections] {
            let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-report", policy: policy))
            XCTAssertEqual(map.overview, "A Structured Report. \(map.chapters.count) chapter\(map.chapters.count == 1 ? "" : "s").")
            XCTAssertFalse(map.overview.contains("Structured into"))
        }
    }

    func testStoredLegacyOverviewsAreSpokenAsTitleAndCount() {
        let legacy = [
            "Structured into 8 listening chapters from canonical document headings in Evaluation Agents.",
            "Structured into 8 listening chapters from the Markdown hierarchy in Evaluation Agents.",
            "Generated Listening Map with 8 chapters for Evaluation Agents.",
            "Publisher-provided chapters for Evaluation Agents.",
            "Authored navigation from Evaluation Agents.",
        ]
        for overview in legacy {
            XCTAssertEqual(
                ListeningMapOverviewText.spokenPreface(overview: overview, title: "Evaluation Agents", chapterCount: 8),
                "Evaluation Agents. 8 chapters.\n\n",
                overview
            )
        }
    }

    func testRealSummariesKeepTheirOverviewLabelAndEmptyOverviewsSayNothing() {
        XCTAssertEqual(
            ListeningMapOverviewText.spokenPreface(overview: "This item contrasts one with two.", title: "T", chapterCount: 2),
            "Overview. This item contrasts one with two.\n\n"
        )
        XCTAssertEqual(ListeningMapOverviewText.spokenPreface(overview: "  ", title: "T", chapterCount: 2), "")
    }
}
