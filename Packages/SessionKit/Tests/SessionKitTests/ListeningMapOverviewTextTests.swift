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
        for policy in [DeterministicListeningMapPolicy.canonicalHeadings, .authoredSections] {
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

    /// Codex audit on #362: a real summary that happens to open like an old app sentence must
    /// keep its text. Only the full shape of each old sentence is replaced.
    func testASummaryThatOpensLikeAnOldSentenceKeepsItsText() {
        let summaries = [
            "Structured into three experiments, the study finds that judges disagree.",
            "Structured into 3 parts: setup, results and limits.",
            "Generated Listening Map outputs are compared with human judges.",
            "Publisher-provided chapters for podcasts are often wrong, the author argues.",
            "Authored navigation from editors helps readers.",
        ]
        for summary in summaries {
            XCTAssertEqual(
                ListeningMapOverviewText.spokenPreface(overview: summary, title: "Evaluation Agents", chapterCount: 2),
                "Overview. \(summary)\n\n",
                summary
            )
        }
    }

    func testOldSentencesWithTheCountSpelledOutAreStillReplaced() {
        XCTAssertEqual(
            ListeningMapOverviewText.spokenPreface(
                overview: "Structured into eight listening chapters from canonical document headings in Evaluation Agents.",
                title: "Evaluation Agents",
                chapterCount: 8
            ),
            "Evaluation Agents. 8 chapters.\n\n"
        )
        XCTAssertEqual(
            ListeningMapOverviewText.spokenPreface(overview: "Generated Listening Map for Evaluation Agents.", title: "Evaluation Agents", chapterCount: 0),
            "Evaluation Agents.\n\n"
        )
    }

    /// #1144: the owner heard the title twice at the start of every PDF, once in the preface and
    /// once as the printed title. The preface drops the title when the text opens with it.
    func testThePrefaceLeavesOutTheTitleWhenTheTextOpensWithIt() {
        let title = "Evaluation Agents"
        let opensWithTitle = [
            "Evaluation Agents\n\nAbstract. We study …",
            "evaluation agents. We study …",
            "EVALUATION AGENTS",
            "  \n Evaluation   Agents\nAbstract",
            "Evaluation\nAgents\nAbstract",
            "# Evaluation Agents\n\n## Context",
            "Evaluation Agents: a field guide",
            "Ｅｖａｌｕａｔｉｏｎ Agents. Wide letters from a PDF text layer.",
        ]
        for opening in opensWithTitle {
            XCTAssertEqual(
                ListeningMapOverviewText.spokenPreface(overview: "Evaluation Agents. 8 chapters.", title: title, chapterCount: 8, textOpening: opening),
                "8 chapters.\n\n",
                opening
            )
        }
        let doesNotOpenWithTitle = [
            "",
            "Abstract. Evaluation Agents are …",
            "Evaluation of agents",
            "Evaluation Agentsia",
            "Evaluation",
            "The Evaluation Agents",
            String(repeating: "word ", count: 5_000),
        ]
        for opening in doesNotOpenWithTitle {
            XCTAssertEqual(
                ListeningMapOverviewText.spokenPreface(overview: "Evaluation Agents. 8 chapters.", title: title, chapterCount: 8, textOpening: opening),
                "Evaluation Agents. 8 chapters.\n\n",
                String(opening.prefix(40))
            )
        }
    }

    func testAccentsAndPunctuationInTheTitleStillMatch() {
        XCTAssertEqual(
            ListeningMapOverviewText.spokenPreface(overview: "Café Société? 2 chapters.", title: "Café Société?", chapterCount: 2, textOpening: "CAFE\u{301} SOCIETE — a history"),
            "2 chapters.\n\n"
        )
        XCTAssertEqual(
            ListeningMapOverviewText.spokenPreface(overview: "Why? 1 chapter.", title: "Why?", chapterCount: 1, textOpening: "Why. Because."),
            "1 chapter.\n\n"
        )
    }

    func testAMapWithNoChaptersSaysNothingWhenTheTextOpensWithTheTitle() {
        XCTAssertEqual(
            ListeningMapOverviewText.spokenPreface(overview: "Untitled.", title: "Untitled", chapterCount: 0, textOpening: "Untitled\nBody"),
            ""
        )
    }

    func testStoredLegacyOverviewsAlsoDropTheRepeatedTitle() {
        XCTAssertEqual(
            ListeningMapOverviewText.spokenPreface(
                overview: "Generated Listening Map with 8 chapters for Evaluation Agents.",
                title: "Evaluation Agents",
                chapterCount: 8,
                textOpening: "Evaluation Agents\nAbstract"
            ),
            "8 chapters.\n\n"
        )
    }

    func testRealSummariesAndTitlelessItemsAreUnchanged() {
        XCTAssertEqual(
            ListeningMapOverviewText.spokenPreface(overview: "This item contrasts one with two.", title: "Evaluation Agents", chapterCount: 2, textOpening: "Evaluation Agents\nBody"),
            "Overview. This item contrasts one with two.\n\n"
        )
        XCTAssertFalse(ListeningMapOverviewText.textOpens("Anything", with: ""))
        XCTAssertFalse(ListeningMapOverviewText.textOpens("— …", with: "?!"))
    }
}
