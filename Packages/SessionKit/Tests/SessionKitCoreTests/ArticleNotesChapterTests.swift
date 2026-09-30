import Foundation
import XCTest
@testable import SessionKit

/// #124: an article that ends in a long run of footnotes or references (arXiv's HTML pages) got
/// "6 Discussion — part 2…5" chapters that were really the notes. The adaptive map now ends the
/// last section where the notes start and gives the notes one chapter that is never split.
final class ArticleNotesChapterTests: XCTestCase {
    private func words(_ count: Int, _ word: String) -> String {
        Array(repeating: word, count: count).joined(separator: " ") + "."
    }

    /// Six sections of about 400 words, then "6 Discussion" of about 300 words.
    private var authoredSections: String {
        let sections = (1...5).map { "## \($0) Section \($0)\n\n" + words(400, "argument") }
        return "---\ntitle: AI Safety for Everyone\n---\n\n## Abstract\n\n" + words(400, "summary") + "\n\n"
            + sections.joined(separator: "\n\n")
            + "\n\n## 6 Discussion and future research\n\n" + words(300, "discussion")
    }

    private func assertNotesChapter(
        _ parsed: ParsedObsidianMarkdown, startingAt notesStart: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-arxiv"), file: file, line: line)
        let titles = map.chapters.map(\.title)
        XCTAssertEqual(titles.last, "Notes and references", "\(titles)", file: file, line: line)
        XCTAssertEqual(map.chapters.last?.startChar, notesStart, file: file, line: line)
        XCTAssertEqual(map.chapters.last?.endChar, parsed.text.count, file: file, line: line)
        let discussion = try XCTUnwrap(map.chapters.first { $0.title == "6 Discussion and future research" }, file: file, line: line)
        XCTAssertEqual(discussion.endChar, notesStart, "the last section ends where the notes start", file: file, line: line)
        XCTAssertFalse(titles.contains { $0.contains("— part") }, "\(titles)", file: file, line: line)
        XCTAssertEqual(map.chapters.filter { $0.startChar >= notesStart }.count, 1, "one chapter holds all the notes", file: file, line: line)
        XCTAssertTrue(zip(map.chapters, map.chapters.dropFirst()).allSatisfy { $0.endChar == $1.startChar }, file: file, line: line)
        XCTAssertEqual(map.chapters.first?.startChar, 0, file: file, line: line)
    }

    func testClosingFootnoteDefinitionsBecomeOneNotesChapter() throws {
        let definitions = (1...60).map { "[^\($0)]: " + words(30, "citation") }
        let markdown = authoredSections + "\n\n" + definitions.joined(separator: "\n\n")

        let parsed = try ObsidianMarkdownParser.parse(fileName: "2502.09288v2.md", contents: markdown)
        let notesStart = try XCTUnwrap(parsed.text.range(of: "[^1]:").map { parsed.text.distance(from: parsed.text.startIndex, to: $0.lowerBound) })
        try assertNotesChapter(parsed, startingAt: notesStart)
    }

    func testFootnotesWithIndentedContinuationsStayOneRun() throws {
        let definitions = (1...60).map { "[^\($0)]: " + words(20, "citation") + "\n    " + words(10, "continued") }
        let markdown = authoredSections + "\n\n" + definitions.joined(separator: "\n")

        let parsed = try ObsidianMarkdownParser.parse(fileName: "continued.md", contents: markdown)
        let notesStart = try XCTUnwrap(parsed.text.range(of: "[^1]:").map { parsed.text.distance(from: parsed.text.startIndex, to: $0.lowerBound) })
        try assertNotesChapter(parsed, startingAt: notesStart)
    }

    func testClosingReferencesSectionBecomesOneNotesChapter() throws {
        let entries = (1...60).map { "\($0). " + words(30, "reference") }
        let markdown = authoredSections + "\n\n## References\n\n" + entries.joined(separator: "\n\n")

        let parsed = try ObsidianMarkdownParser.parse(fileName: "references.md", contents: markdown)
        let heading = try XCTUnwrap(parsed.headings.last)
        XCTAssertEqual(heading.title, "References")
        try assertNotesChapter(parsed, startingAt: heading.startChar)
    }

    func testFootnotesFollowedByMoreProseAreNotANotesTail() throws {
        let definitions = (1...5).map { "[^\($0)]: " + words(10, "citation") }
        let markdown = authoredSections + "\n\n" + definitions.joined(separator: "\n\n") + "\n\n" + words(40, "afterword")

        let parsed = try ObsidianMarkdownParser.parse(fileName: "afterword.md", contents: markdown)
        XCTAssertNil(parsed.notesStartChar)
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-afterword"))
        XCTAssertFalse(map.chapters.contains { $0.title == "Notes and references" })
    }

    /// Done-when 2: an ordinary long section still splits into "— part N" chapters.
    func testLongOrdinarySectionWithoutNotesStillSplits() throws {
        let paragraph = words(300, "substantive")
        let markdown = "---\ntitle: Long Read\n---\n\n## Main argument\n\n" + Array(repeating: paragraph, count: 8).joined(separator: "\n\n")

        let parsed = try ObsidianMarkdownParser.parse(fileName: "long-read.md", contents: markdown)
        XCTAssertNil(parsed.notesStartChar)
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-long-read"))
        XCTAssertEqual(map.chapters.map(\.title), ["Main argument", "Main argument — part 2"])
    }

    /// PDFs and other canonical maps keep their authored headings, References included.
    func testCanonicalHeadingsKeepTheirReferencesHeading() throws {
        let entries = (1...60).map { "\($0). " + words(30, "reference") }
        let markdown = authoredSections + "\n\n## References\n\n" + entries.joined(separator: "\n\n")

        let parsed = try ObsidianMarkdownParser.parse(fileName: "references.md", contents: markdown)
        let map = try XCTUnwrap(parsed.deterministicListeningMap(itemId: "item-pdf", policy: .canonicalHeadings))
        XCTAssertEqual(map.chapters.last?.title, "References")
        XCTAssertFalse(map.chapters.contains { $0.title == "Notes and references" })
    }
}
