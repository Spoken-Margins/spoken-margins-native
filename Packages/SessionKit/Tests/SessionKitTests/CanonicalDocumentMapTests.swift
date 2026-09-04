import XCTest
@testable import SessionKit

final class CanonicalDocumentMapTests: XCTestCase {
    func testCanonicalHeadingPolicyDoesNotInventFrontMatterForDocumentTitleAlone() throws {
        let parsed = try ObsidianMarkdownParser.parse(
            fileName: "Structured Report.md",
            contents: """
            # A Structured Report

            ## Context
            Context body.

            ## Evidence
            Evidence body.
            """
        )

        let map = try XCTUnwrap(parsed.deterministicListeningMap(
            itemId: "item-structured-report",
            policy: .canonicalHeadings
        ))

        XCTAssertEqual(map.chapters.map(\.title), ["Context", "Evidence"])
        XCTAssertEqual(map.chapters.first?.startChar, 0)
    }

    func testCanonicalHeadingPolicyPreservesFrontMatterAndAllTwentyChapters() throws {
        let expectedTitles = (1...20).map { "Story \($0)" }
        var markdown = """
        # Collected Stories

        Edited by Example Author

        Contents

        """
        markdown += expectedTitles.joined(separator: "\n")
        for title in expectedTitles {
            markdown += "\n\n## \(title)\n\nBody text for \(title)."
        }

        let parsed = try ObsidianMarkdownParser.parse(
            fileName: "Collected Stories.md",
            contents: markdown
        )
        let map = try XCTUnwrap(parsed.deterministicListeningMap(
            itemId: "item-collected-stories",
            policy: .canonicalHeadings
        ))

        XCTAssertEqual(map.chapters.count, 21)
        XCTAssertEqual(map.chapters.map(\.title), ["Front Matter"] + expectedTitles)
        XCTAssertEqual(map.chapters.first?.startChar, 0)
        XCTAssertGreaterThan(map.chapters[1].startChar, 0)
        XCTAssertEqual(map.chapters.last?.endChar, parsed.text.count)
        XCTAssertTrue(zip(map.chapters, map.chapters.dropFirst()).allSatisfy {
            $0.endChar == $1.startChar
        })
    }

    func testPDFBrowserHandoffSelectsCanonicalHeadingPolicy() throws {
        let expectedTitles = (1...20).map { "Story \($0)" }
        var markdown = "Edited by Example Author\n\nContents\n\n"
        markdown += expectedTitles.joined(separator: "\n")
        for title in expectedTitles {
            markdown += "\n\n## \(title)\n\nBody text for \(title)."
        }
        let profile = RuntimeCapabilityProfile(
            id: "browser-pdf",
            displayName: "Browser PDF",
            capabilities: ["sync": ["browser_session_handoff"]]
        )
        let repository = InMemorySessionRepository()
        let engine = SessionEngine(profile: profile, repository: repository)
        let handoff = BrowserTextHandoff(
            itemId: "item-browser-pdf",
            captureMode: .markdownFile,
            source: BrowserTextSource(
                url: "file:///imports/Collected%20Stories.pdf",
                title: "Collected Stories"
            ),
            text: markdown,
            contentFormat: .markdown
        )

        _ = try engine.importBrowserText(handoff)
        let map = try XCTUnwrap(repository.loadListeningMap(itemId: "item-browser-pdf"))

        XCTAssertEqual(map.chapters.map(\.title), ["Front Matter"] + expectedTitles)
        XCTAssertEqual(try repository.loadItem(id: "item-browser-pdf").mediaType, "pdf")
    }

    func testCanonicalPDFProjectionKeepsUsefulTopLevelSectionsWithoutNestedTimelineNoise() throws {
        var markdown = """
        # GPT-6 Astra System Card

        OpenAI
        September 2026

        Contents

        """
        let sections = [
            "Safety Overview: GPT-6 Astra",
            "Model Data and Training",
            "Internal Deployment of Astra",
            "Model Safety",
            "Robustness",
            "Health",
            "Hallucinations",
            "Alignment",
            "Monitorability",
            "Preparedness"
        ]
        for (index, section) in sections.enumerated() {
            markdown += "# \(index + 1) \(section)\n\nBody for \(section).\n\n"
            markdown += "## \(index + 1).1 Nested evidence\n\nNested body.\n\n"
        }

        let parsed = try ObsidianMarkdownParser.parse(
            fileName: "gpt-6-astra.pdf",
            contents: markdown
        )
        let map = try XCTUnwrap(parsed.deterministicListeningMap(
            itemId: "item-astra",
            policy: .canonicalHeadings
        ))

        XCTAssertEqual(
            map.chapters.map(\.title),
            ["Front Matter"] + sections.enumerated().map { "\($0.offset + 1) \($0.element)" }
        )
        XCTAssertFalse(map.chapters.contains(where: { $0.title.contains("Nested evidence") }))
    }
}
