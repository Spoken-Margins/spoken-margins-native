import Foundation
import XCTest
@testable import SessionKit

/// #1468: the chapters of a text item are the source's own headings. `Contracts/fixtures/chapters/`
/// holds one source per file with the chapters a listener would pick by hand (`<name>.chapters.txt`,
/// one title per line, empty when the source has none and the generated map takes over). This scorer
/// runs every text import path over them and reports, per source and path, the boundaries found
/// against the expected ones, plus the shapes a listener calls "random chapters": generic titles,
/// body snippets, "— part N" and a number said twice (#309).
///
/// The fixtures are small sources shaped like the ones the app receives (an encyclopedia page, a
/// paper, a blog post with bold lead-ins, docs, pasted text with bold or underlined headings, an
/// anthology, the phone test plan from #1435), written for the repository. Real captures of public
/// pages go in the same folder, the same way. A source with a substantial preamble before its first
/// heading starts with a chapter named by the item's title, which here is the source's file name
/// (`journal-footnotes-block`, #796: the capture of a journal page, essay first and footnotes after,
/// with Category and Subject labels and the byline as lower headings that are not chapters).
final class ChapterCorpusScorerTests: XCTestCase {
    struct Score {
        let source: String
        let path: String
        let expected: [String]
        let found: [String]
        var missing: [String] { expected.filter { !found.contains($0) } }
        var extra: [String] { found.filter { !expected.contains($0) } }
        var exact: Bool { expected == found }
        var genericTitles: Int {
            found.filter { $0.range(of: #"^(chapter|section|part)\s*\d*$"#, options: [.regularExpression, .caseInsensitive]) != nil }.count
        }
        var partSuffixes: Int { found.filter { $0.contains(" — part ") }.count }
        var doubledNumbers: Int {
            found.filter { $0.range(of: #"^(\d+(?:\.\d+)*)[.)]?\s+\1\b"#, options: .regularExpression) != nil }.count
        }
        var bodySnippets: Int {
            found.filter { $0.split(separator: " ").count > 14 || ($0.hasSuffix(".") && $0.split(separator: " ").count > 8) }.count
        }

        var row: String {
            let verdict = exact ? "ok" : "MISMATCH"
            return "\(source) [\(path)]: \(found.count) of \(expected.count) expected, \(verdict), generic \(genericTitles), part \(partSuffixes), doubled \(doubledNumbers), snippets \(bodySnippets)"
                + (exact ? "" : "\n    missing \(missing)\n    extra \(extra)")
        }
    }

    private func chaptersFolder() -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appending(path: "Contracts").path) {
            root.deleteLastPathComponent()
        }
        return root.appending(path: "Contracts/fixtures")
    }

    /// (name, source text, expected chapter titles), from the fixture folder.
    private func corpus() throws -> [(name: String, text: String, expected: [String])] {
        let folder = chaptersFolder()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "chapters").path)
            .filter { $0.hasSuffix(".chapters.txt") }
            .map { String($0.dropLast(".chapters.txt".count)) }
            .sorted()
        XCTAssertGreaterThanOrEqual(names.count, 10)
        return try names.map { name in
            let own = folder.appending(path: "chapters/\(name).md")
            let shared = folder.appending(path: "markdown/\(name).md")
            let source = FileManager.default.fileExists(atPath: own.path) ? own : shared
            let expected = try String(contentsOf: folder.appending(path: "chapters/\(name).chapters.txt"), encoding: .utf8)
                .components(separatedBy: .newlines).filter { !$0.isEmpty }
            return (name, try String(contentsOf: source, encoding: .utf8), expected)
        }
    }

    private func chapterTitles(_ map: ListeningMap?, textCount: Int, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        guard let map else { return [] }
        XCTAssertEqual(map.chapters.first?.startChar, 0, file: file, line: line)
        XCTAssertEqual(map.chapters.last?.endChar, textCount, file: file, line: line)
        XCTAssertTrue(
            zip(map.chapters, map.chapters.dropFirst()).allSatisfy { $0.endChar == $1.startChar },
            "\(map.chapters.map(\.title))", file: file, line: line
        )
        return map.chapters.map(\.title)
    }

    private func scores(for source: (name: String, text: String, expected: [String])) throws -> [Score] {
        var scores: [Score] = []
        // A Markdown file the listener picked, and a plain text file: the same parser, the same map.
        for fileName in ["\(source.name).md", "\(source.name).txt"] {
            let prepared = try SourceFileItemBuilder.prepare(
                ImportedSourceText(text: source.text, documentStructure: nil),
                fileURL: URL(fileURLWithPath: "/\(fileName)"), itemId: "item-1", createdAt: Date(timeIntervalSince1970: 1)
            )
            scores.append(Score(
                source: source.name, path: "file \((fileName as NSString).pathExtension)", expected: source.expected,
                found: chapterTitles(prepared.listeningMap, textCount: prepared.item.text?.count ?? 0)
            ))
        }
        // What the Safari extension and the share sheet hand over.
        for mode in [BrowserTextCaptureMode.readablePage, .markdownFile] {
            let repository = InMemorySessionRepository()
            let engine = SessionEngine(
                profile: RuntimeCapabilityProfile(id: "corpus", displayName: "Corpus", capabilities: ["sync": ["browser_session_handoff"]]),
                repository: repository
            )
            let item = try engine.importBrowserTextInBackground(BrowserTextHandoff(
                captureMode: mode,
                source: BrowserTextSource(url: "https://example.com/\(source.name)", title: source.name),
                text: source.text,
                contentFormat: .markdown
            ))
            scores.append(Score(
                source: source.name, path: "\(mode)", expected: source.expected,
                found: chapterTitles(try? repository.loadListeningMap(itemId: item.id), textCount: item.text?.count ?? 0)
            ))
        }
        return scores
    }

    func testEveryImportPathGivesTheSourcesOwnHeadingsAsChapters() throws {
        var all: [Score] = []
        for source in try corpus() { all += try scores(for: source) }
        print("CHAPTER CORPUS\n" + all.map(\.row).joined(separator: "\n"))
        for score in all {
            XCTAssertEqual(score.found, score.expected, "\(score.source) [\(score.path)]")
            XCTAssertEqual(score.genericTitles + score.partSuffixes + score.doubledNumbers + score.bodySnippets, 0, "\(score.row)")
        }
    }
}
