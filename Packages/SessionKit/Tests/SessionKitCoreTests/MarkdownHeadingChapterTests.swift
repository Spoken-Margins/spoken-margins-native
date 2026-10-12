import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #1435: the owner imported the phone test plan (`Test plan 744242e.md`) and its chapters were not
/// its `##` sections: the adaptive map merged the short closing "If something is wrong" section into
/// the one above it. In a Markdown file the listener picked, a section the author titled is a
/// chapter, in source order, however short. Web articles keep the adaptive merging.
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

    private let testPlanSections = [
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
        for chapter in map.chapters.dropFirst() {
            let start = parsed.text.index(parsed.text.startIndex, offsetBy: chapter.startChar)
            XCTAssertTrue(parsed.text[start...].hasPrefix(chapter.title), "\(chapter.title) starts at its heading")
        }
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
        XCTAssertEqual(try titles(markdown), ["Morning", "Coffee", "Evening"])
    }

    func testSetextHeadingsAreChapters() throws {
        let markdown = "Opening\n=======\n\n\(words(30))\n\nMiddle\n------\n\n\(words(30))\n\nClosing\n-------\n\n\(words(6))"
        XCTAssertEqual(try titles(markdown), ["Opening", "Middle", "Closing"])
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

    func testTheChapterCapStillMergesTheShortestSections() throws {
        let markdown = (1...14).map { "## Section \($0)\n\n\(words(10 + $0))" }.joined(separator: "\n\n")
        XCTAssertEqual(try titles(markdown).count, 12)
    }

    func testWebArticlesStillMergeShortCallouts() throws {
        let markdown = (1...6).map { "## Section \($0)\n\n\(words($0 == 6 ? 12 : 400))" }.joined(separator: "\n\n")
        XCTAssertEqual(try titles(markdown, policy: .adaptiveListeningSections), (1...5).map { "Section \($0)" })
        XCTAssertEqual(try titles(markdown), (1...6).map { "Section \($0)" })
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
        for (mode, expected) in [(BrowserTextCaptureMode.markdownFile, 6), (.readablePage, 5)] {
            let item = try engine.importBrowserTextInBackground(BrowserTextHandoff(
                captureMode: mode,
                source: BrowserTextSource(url: "https://example.com/\(expected)", title: "Plan"),
                text: text,
                contentFormat: .markdown
            ))
            XCTAssertEqual(try store.loadListeningMap(itemId: item.id)?.chapters.count, expected, "\(mode)")
        }
    }
}
