import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #1435: the owner imported the phone test plan (`Test plan 744242e.md`) and its chapters were not
/// its `##` sections: the adaptive map merged the short closing "If something is wrong" section into
/// the one above it. In a Markdown file the listener picked, a section the author titled is a
/// chapter, in source order, however short. #1468 extends that to every text path: web articles and
/// pasted text too, one heading level only, and a section is split only when it is very long.
/// Layer that should have caught it: the host test on `ObsidianMarkdownParser`, which had no case for
/// a file of short authored sections.
final class MarkdownHeadingChapterTests: XCTestCase {
    private func words(_ count: Int, _ word: String = "word") -> String {
        Array(repeating: word, count: count).joined(separator: " ") + "."
    }

    private func repositoryRoot() -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appending(path: "Contracts").path) {
            root.deleteLastPathComponent()
        }
        return root
    }

    private func titles(
        _ markdown: String, policy: DeterministicListeningMapPolicy = .authoredSections
    ) throws -> [String] {
        let parsed = try ObsidianMarkdownParser.parse(fileName: "notes.md", contents: markdown)
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-1", policy: policy), "no map for \(markdown)")
        assertContiguous(map, textCount: parsed.text.count)
        return map.chapters.map(\.title)
    }

    private func assertContiguous(
        _ map: ListeningMap, textCount: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(map.chapters.first?.startChar, 0, file: file, line: line)
        XCTAssertEqual(map.chapters.last?.endChar, textCount, file: file, line: line)
        XCTAssertTrue(
            zip(map.chapters, map.chapters.dropFirst()).allSatisfy { $0.endChar == $1.startChar },
            "\(map.chapters.map(\.title))", file: file, line: line
        )
    }

    /// The plan's `#` title heads its preamble (the build line, what changed), so it is the first
    /// chapter, and "Try these" starts at its own heading, not at 0 (#1435).
    private let testPlanSections = [
        "Phone build 744242e: what to try",
        "Try these (about ten minutes)",
        "Also waiting on your check (not in the ten minutes)",
        "Also changed (not in the ten minutes)",
        "Waiting on another change or a test file (not in the ten minutes)",
        "Also changed (no phone check written)",
        "If something is wrong"
    ]

    func testPhoneTestPlanChaptersAreItsSectionHeadings() throws {
        let contents = try String(
            contentsOf: repositoryRoot().appending(path: "Contracts/fixtures/markdown/test-plan-744242e.md"),
            encoding: .utf8
        )
        let parsed = try ObsidianMarkdownParser.parse(fileName: "Test plan 744242e.md", contents: contents)
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-test-plan", policy: .authoredSections))

        XCTAssertEqual(map.chapters.map(\.title), testPlanSections)
        assertContiguous(map, textCount: parsed.text.count)
        assertEachChapterStartsAtItsHeading(map, text: parsed.text)
    }

    /// The phone check on build 32 `c9f8bbc` (#1435): six headings, an `#` title, a preamble before
    /// the first `##`. Each chapter starts at its own heading line, the first at 0.
    func testPhoneTestPlanC9f8bbcHasSixChaptersAtTheirHeadings() throws {
        let contents = try String(
            contentsOf: repositoryRoot().appending(path: "Contracts/fixtures/markdown/test-plan-c9f8bbc.md"),
            encoding: .utf8
        )
        let parsed = try ObsidianMarkdownParser.parse(fileName: "Test plan c9f8bbc.md", contents: contents)
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-test-plan", policy: .authoredSections))

        XCTAssertEqual(map.chapters.map(\.title), [
            "Phone build c9f8bbc: what to try",
            "Try these (about ten minutes)",
            "Also waiting on your check",
            "Also changed (not in the ten minutes)",
            "Also changed (no phone check written)",
            "If something is wrong"
        ])
        assertContiguous(map, textCount: parsed.text.count)
        assertEachChapterStartsAtItsHeading(map, text: parsed.text)
        // "Try these" does not start before its heading: the preamble belongs to the title chapter.
        let trySection = map.chapters[1]
        XCTAssertGreaterThan(trySection.startChar, 100)
        XCTAssertTrue(parsed.text.prefix(trySection.startChar).contains("Settings > Version ends with"))
    }

    /// Every chapter after a lead starts on the line of its own title, found independently of the parser.
    private func assertEachChapterStartsAtItsHeading(
        _ map: ListeningMap, text: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let lines = text.components(separatedBy: "\n")
        var offsets: [String: Int] = [:]
        var running = 0
        for textLine in lines {
            if offsets[textLine] == nil { offsets[textLine] = running }
            running += textLine.count + 1
        }
        for chapter in map.chapters {
            XCTAssertEqual(Optional(chapter.startChar), chapter.startChar == 0 ? 0 : offsets[chapter.title], "\(chapter.title) starts at its heading line", file: file, line: line)
            let start = text.index(text.startIndex, offsetBy: chapter.startChar)
            XCTAssertTrue(text[start...].hasPrefix(chapter.title), "\(chapter.title) starts at its heading", file: file, line: line)
        }
        XCTAssertEqual(map.chapters.first?.startChar, 0, file: file, line: line)
    }

    func testImportedFileBecomesTheSameChapters() throws {
        let contents = try String(
            contentsOf: repositoryRoot().appending(path: "Contracts/fixtures/markdown/test-plan-744242e.md"),
            encoding: .utf8
        )
        let prepared = try SourceFileItemBuilder.prepare(
            ImportedSourceText(text: contents, documentStructure: nil),
            fileURL: URL(fileURLWithPath: "/Test plan 744242e.md"),
            itemId: "item-obsidian-1-0-test-plan-744242e",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(prepared.item.title, "Phone build `744242e`: what to try")
        XCTAssertEqual(prepared.listeningMap?.chapters.map(\.title), testPlanSections)
    }

    // MARK: neighbouring inputs

    func testShortAuthoredSectionsAreNotMergedAway() throws {
        let markdown = "# A note\n\n" + (1...7).map { "## Section \($0)\n\n\(words(12))" }.joined(separator: "\n\n")
        XCTAssertEqual(try titles(markdown), (1...7).map { "Section \($0)" })
    }

    func testShortFinalSectionStaysAChapter() throws {
        let markdown = (1...5).map { "## Part \($0)\n\n\(words(400))" }.joined(separator: "\n\n")
            + "\n\n## Last word\n\nThanks for listening."
        XCTAssertEqual(try titles(markdown), (1...5).map { "Part \($0)" } + ["Last word"])
    }

    func testNestedNumberedItemsWithBoldTitlesAreNotChapters() throws {
        let items = (1...3).map {
            "\($0). **Fix number \($0) (#58\($0))** (found on your phone)\n   - Check: \(words(30))\n   - Links: [PR #\($0)](https://example.com/\($0))"
        }.joined(separator: "\n\n")
        let markdown = (1...6).map { "## Group \($0)\n\n\(items)" }.joined(separator: "\n\n")
        XCTAssertEqual(try titles(markdown), (1...6).map { "Group \($0)" })
    }

    func testHeadingWithBackticksAndParenthesesKeepsItsText() throws {
        let markdown = "## Build `744242e` (found on your phone)\n\n\(words(20))\n\n## Use `swift test` (not Xcode)\n\n\(words(20))"
        XCTAssertEqual(try titles(markdown), ["Build 744242e (found on your phone)", "Use swift test (not Xcode)"])
    }

    func testHeadingLevelsAboveTheTitleAreKept() throws {
        let markdown = "---\ntitle: Field notes\n---\n\n# Morning\n\n\(words(30))\n\n## Coffee\n\n\(words(30))\n\n# Evening\n\n\(words(30))"
        // One level only (#1468): `Coffee` is a sub-heading of `Morning`, not a third chapter.
        XCTAssertEqual(try titles(markdown), ["Morning", "Evening"])
    }

    func testSetextHeadingsAreChapters() throws {
        let markdown = "Opening\n=======\n\n\(words(30))\n\nMiddle\n------\n\n\(words(30))\n\nClosing\n-------\n\n\(words(6))\n\nEpilogue\n--------\n\n\(words(6))"
        // The lone top heading heads the opening (30 words) that comes before the first section.
        XCTAssertEqual(try titles(markdown), ["Opening", "Middle", "Closing", "Epilogue"])
    }

    func testTitleHeadingAloneMakesNoChapters() throws {
        let parsed = try ObsidianMarkdownParser.parse(fileName: "notes.md", contents: "# Just a title\n\n\(words(60))")
        XCTAssertNil(
            parsed.deterministicListeningMap(itemId: "item-1", policy: .authoredSections),
            "the engine's generated map takes over"
        )
    }

    func testTitleHeadingDoesNotBecomeAChapter() throws {
        let markdown = "# Notes\n\n\(words(10))\n\n## One\n\n\(words(10))\n\n## Two\n\n\(words(10))"
        XCTAssertEqual(try titles(markdown), ["One", "Two"])
    }

    // MARK: #1435: the title heading and the text before the first section

    func testTitleHeadingWithASubstantialPreambleIsTheFirstChapter() throws {
        let markdown = "# Notes\n\n\(words(30))\n\n## One\n\n\(words(10))\n\n## Two\n\n\(words(10))"
        let parsed = try ObsidianMarkdownParser.parse(fileName: "notes.md", contents: markdown)
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-1"))
        XCTAssertEqual(map.chapters.map(\.title), ["Notes", "One", "Two"])
        assertContiguous(map, textCount: parsed.text.count)
        assertEachChapterStartsAtItsHeading(map, text: parsed.text)
    }

    func testPreambleWithoutATitleHeadingIsNamedByTheItemTitle() throws {
        let markdown = "---\ntitle: Field notes\n---\n\n\(words(40))\n\n## One\n\n\(words(10))\n\n## Two\n\n\(words(10))"
        XCTAssertEqual(try titles(markdown), ["Field notes", "One", "Two"])
    }

    func testAShortPreambleIsFoldedIntoTheFirstChapter() throws {
        let markdown = "# Notes\n\nThree words here.\n\n## One\n\n\(words(10))\n\n## Two\n\n\(words(10))"
        let parsed = try ObsidianMarkdownParser.parse(fileName: "notes.md", contents: markdown)
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-1"))
        XCTAssertEqual(map.chapters.map(\.title), ["One", "Two"])
        XCTAssertEqual(map.chapters.first?.startChar, 0)
    }

    func testTitleHeadingAndTheSectionsOfAPlanWithNoPreambleStayAsTheyWere() throws {
        // "# Title" directly above the first `##`: no preamble, so no chapter for the title alone.
        let markdown = "# Title\n\n## One\n\n\(words(30))\n\n## Two\n\n\(words(30))"
        XCTAssertEqual(try titles(markdown), ["One", "Two"])
    }

    func testASectionHeadingAtTheStartIsNotATitleSoItsIntroStaysWithItsFirstSubsection() throws {
        let markdown = (1...2).map { group in
            "## Group \(group)\n\n\(words(20))\n\n" + (1...3).map { "### Detail \(group).\($0)\n\n\(words(15))" }.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
        XCTAssertEqual(try titles(markdown), ["Detail 1.1", "Detail 1.2", "Detail 1.3", "Detail 2.1", "Detail 2.2", "Detail 2.3"])
    }

    func testThereIsNoChapterCap() throws {
        let markdown = (1...30).map { "## Section \($0)\n\n\(words(10 + $0))" }.joined(separator: "\n\n")
        XCTAssertEqual(try titles(markdown), (1...30).map { "Section \($0)" })
    }

    func testWebArticlesKeepShortCalloutsToo() throws {
        let markdown = (1...6).map { "## Section \($0)\n\n\(words($0 == 6 ? 12 : 400))" }.joined(separator: "\n\n")
        XCTAssertEqual(try titles(markdown), (1...6).map { "Section \($0)" })
    }

    // MARK: #1468: one level, bold lines, very long sections

    func testTheChapterLevelIsTheShallowestWithThreeHeadings() throws {
        let sections = (1...4).map { section in
            "## Part \(section)\n\n\(words(40))\n\n" + (1...8).map { "### Part \(section) detail \($0)\n\n\(words(40))" }.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
        XCTAssertEqual(try titles("# Title\n\n" + sections), (1...4).map { "Part \($0)" })
    }

    func testHeadingLevelsAreNeverMixed() throws {
        // Two `#` parts and five `##` sections: the five are the chapters; the parts are not interleaved.
        let markdown = "---\ntitle: A book\n---\n\n# Part one\n\n" + (1...3).map { "## One \($0)\n\n\(words(20))" }.joined(separator: "\n\n")
            + "\n\n# Part two\n\n" + (1...2).map { "## Two \($0)\n\n\(words(20))" }.joined(separator: "\n\n")
        XCTAssertEqual(try titles(markdown), ["One 1", "One 2", "One 3", "Two 1", "Two 2"])
    }

    func testTwoHeadingsAtTheTopLevelAreEnoughWhenNothingHasThree() throws {
        let markdown = "---\ntitle: Memo\n---\n\n## One\n\n\(words(20))\n\n### Detail\n\n\(words(20))\n\n## Two\n\n\(words(20))"
        XCTAssertEqual(try titles(markdown), ["One", "Two"])
    }

    func testASingleHeadingLeavesTheChaptersToTheGeneratedMap() throws {
        let parsed = try ObsidianMarkdownParser.parse(fileName: "notes.md", contents: "Intro.\n\n## Only one\n\n\(words(40))")
        XCTAssertNil(parsed.deterministicListeningMap(itemId: "item-1"))
    }

    func testBoldLinesAreNotChaptersWhenTheTextHasRealHeadings() throws {
        let markdown = (1...4).map { "## Section \($0)\n\n**Key point:**\n\n\(words(30))\n\n**Takeaway**\n\n\(words(30))" }.joined(separator: "\n\n")
        XCTAssertEqual(try titles(markdown), (1...4).map { "Section \($0)" })
    }

    func testBoldLinesAreChaptersWhenTheTextHasNoRealHeadings() throws {
        let markdown = "Notes\n\n" + ["Budget", "Timeline", "Risks"].map { "**\($0)**\n\n\(words(30))" }.joined(separator: "\n\n")
        XCTAssertEqual(try titles(markdown), ["Budget", "Timeline", "Risks"])
    }

    func testAnInlineBoldLeadInIsNeverAChapter() throws {
        let markdown = (1...3).map { "## Section \($0)\n\n**Key point:** \(words(30))" }.joined(separator: "\n\n")
        XCTAssertEqual(try titles(markdown), (1...3).map { "Section \($0)" })
    }

    func testASectionJustUnderTwentyMinutesIsNotSplit() throws {
        let markdown = "## Short\n\n\(words(100))\n\n## Long\n\n\(words(3500))\n\n## Last\n\n\(words(100))"
        XCTAssertEqual(try titles(markdown), ["Short", "Long", "Last"])
    }

    func testAVeryLongSectionIsSplitAtItsSubheadingsAndNamedByThem() throws {
        let long = "## Short\n\n\(words(100))\n\n## The long one\n\n\(words(200))\n\n"
            + ["Early days", "The middle", "Looking back"].map { "### \($0)\n\n\(words(1500))" }.joined(separator: "\n\n")
            + "\n\n## Last\n\n\(words(100))"
        XCTAssertEqual(try titles(long), ["Short", "The long one", "Early days", "The middle", "Looking back", "Last"])
    }

    func testAVeryLongSectionWithoutSubheadingsIsSplitInEqualParts() throws {
        let markdown = "## Short\n\n\(words(100))\n\n## The long one\n\n"
            + (1...5400 / 90).map { _ in words(89) }.joined(separator: "\n\n")
            + "\n\n## Last\n\n\(words(100))"
        let parsed = try ObsidianMarkdownParser.parse(fileName: "notes.md", contents: markdown)
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-1"))
        assertContiguous(map, textCount: parsed.text.count)
        XCTAssertEqual(map.chapters.map(\.title), ["Short", "The long one", "The long one — part 2", "The long one — part 3", "Last"])
        let sizes = map.chapters[1...3].map { $0.endChar - $0.startChar }
        XCTAssertLessThan(Double(sizes.max()!) / Double(sizes.min()!), 1.2, "\(sizes)")
    }

    func testBoldLinesAreChaptersUnderATitleHeadingWhenNothingElseIsAHeading() throws {
        let markdown = "# Planning call\n\n" + ["Budget", "Timeline", "Risks"].map { "**\($0)**\n\n\(words(30))" }.joined(separator: "\n\n")
        XCTAssertEqual(try titles(markdown), ["Budget", "Timeline", "Risks"])
    }

    func testALongSectionThatOpensWithASubheadingHasNoNearEmptyLeadChapter() throws {
        let markdown = "## Short\n\n\(words(100))\n\n## Big\n\n### One\n\n\(words(2000))\n\n### Two\n\n\(words(2000))\n\n## Last\n\n\(words(100))"
        let parsed = try ObsidianMarkdownParser.parse(fileName: "notes.md", contents: markdown)
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-1"))
        assertContiguous(map, textCount: parsed.text.count)
        XCTAssertEqual(map.chapters.map(\.title), ["Short", "One", "Two", "Last"])
        XCTAssertTrue(map.chapters.allSatisfy { $0.endChar - $0.startChar > 100 })
    }

    func testAHugeSingleSectionIsSplitInLinearTime() throws {
        let markdown = "## Short\n\n\(words(100))\n\n## Transcript\n\n" + (1...(120_000 / 90)).map { _ in words(89) }.joined(separator: "\n\n")
            + "\n\n## Last\n\n\(words(100))"
        let parsed = try ObsidianMarkdownParser.parse(fileName: "notes.md", contents: markdown)
        let started = Date()
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-1"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        assertContiguous(map, textCount: parsed.text.count)
        XCTAssertGreaterThan(map.chapters.count, 40)
    }

    func testAnArticleWithAReferencesTailKeepsEverySectionAndOneNotesChapter() throws {
        let markdown = "# Title\n\n" + (1...4).map { "## Part \($0)\n\n\(words(20))" }.joined(separator: "\n\n")
            + "\n\n## References\n\n1. A source.\n2. Another.\n3. A third."
        XCTAssertEqual(try titles(markdown), (1...4).map { "Part \($0)" } + ["Notes and references"])
    }

    func testAMarkdownFileHandedOverFromTheShareSheetKeepsItsSections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "test", displayName: "Test", capabilities: ["sync": ["canonical_persistence"]]),
            repository: store
        )
        let text = "# Plan\n\n" + (1...6).map { "## Step \($0)\n\n\(words($0 == 6 ? 8 : 150))" }.joined(separator: "\n\n")
        for (mode, expected) in [(BrowserTextCaptureMode.markdownFile, 6), (.readablePage, 6)] {
            let item = try engine.importBrowserTextInBackground(BrowserTextHandoff(
                captureMode: mode,
                source: BrowserTextSource(url: "https://example.com/\(expected)", title: "Plan"),
                text: text,
                contentFormat: .markdown
            ))
            XCTAssertEqual(try store.loadListeningMap(itemId: item.id)?.chapters.count, expected, "\(mode)")
        }
    }

    func testAPickedTextFileKeepsItsSectionsToo() throws {
        let text = (1...6).map { "## Section \($0)\n\n\(words($0 == 6 ? 12 : 400))" }.joined(separator: "\n\n")
        for (name, expected) in [("notes.md", 6), ("notes.markdown", 6), ("notes.txt", 6)] {
            let prepared = try SourceFileItemBuilder.prepare(
                ImportedSourceText(text: text, documentStructure: nil),
                fileURL: URL(fileURLWithPath: "/\(name)"), itemId: "item-1", createdAt: Date(timeIntervalSince1970: 1)
            )
            XCTAssertEqual(prepared.listeningMap?.chapters.count, expected, name)
        }
    }
}
