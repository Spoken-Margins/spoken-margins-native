import XCTest
import SessionKit
@testable import SpokenMarginsApp

final class SessionMarkdownFileWriterTests: XCTestCase {
    func testFileNameUsesItemTitleAndSessionDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let writer = SessionMarkdownFileWriter(calendar: calendar)
        let date = Date(timeIntervalSince1970: 1_769_068_800) // 2026-01-22 08:00 UTC

        XCTAssertEqual(
            writer.fileBaseName(itemTitle: "Critical / Reading: Notes", sessionDate: date, sessionId: "session-1"),
            "Critical Reading Notes — 2026-01-22 0800"
        )
    }

    func testFileNameFallsBackToSessionIdentifierWhenTimestampIsMissing() {
        let writer = SessionMarkdownFileWriter()

        XCTAssertEqual(
            writer.fileBaseName(itemTitle: "Untimed", sessionDate: nil, sessionId: "abcdefgh-1234"),
            "Untimed — Session abcdefgh"
        )
    }

    func testWriterDoesNotOverwriteAnExistingExport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-export-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let writer = SessionMarkdownFileWriter(calendar: calendar)
        let date = Date(timeIntervalSince1970: 1_769_068_800)

        let first = try writer.write(
            markdown: "first",
            itemTitle: "An Item",
            sessionDate: date,
            sessionId: "session-1",
            to: root
        )
        let second = try writer.write(
            markdown: "second",
            itemTitle: "An Item",
            sessionDate: date,
            sessionId: "session-2",
            to: root
        )

        XCTAssertEqual(first.lastPathComponent, "An Item — 2026-01-22 0800.md")
        XCTAssertEqual(second.lastPathComponent, "An Item — 2026-01-22 0800 (2).md")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
    }
}

@MainActor
final class BatchSessionExportWorkflowTests: XCTestCase {
    func testBatchExportDefaultsToSessionsWithInterjectionsAndWritesSelectedMarkdown() throws {
        let defaults = UserDefaults.standard
        let bookmarkKey = "batchExportFolderBookmark"
        let nameKey = "batchExportFolderName"
        let priorBookmark = defaults.data(forKey: bookmarkKey)
        let priorName = defaults.string(forKey: nameKey)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-session-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            if let priorBookmark {
                defaults.set(priorBookmark, forKey: bookmarkKey)
            } else {
                defaults.removeObject(forKey: bookmarkKey)
            }
            if let priorName {
                defaults.set(priorName, forKey: nameKey)
            } else {
                defaults.removeObject(forKey: nameKey)
            }
        }

        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.importTitle = "Batch Export Article"
        model.importText = "A source passage that should survive the Markdown export."
        model.importTextItem()
        model.pause()
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)

        model.openBatchExport()

        XCTAssertEqual(model.batchExportFilter, .withInterjections)
        XCTAssertTrue(model.visibleBatchExportRows.isEmpty)
        model.batchExportFilter = .all
        XCTAssertEqual(model.visibleBatchExportRows.map(\.id), [sessionId])

        model.toggleBatchExportSelection(sessionId: sessionId)
        model.exportScope = "full_session"
        model.exportIncludesSourceText = true
        model.exportIncludesReference = false
        model.exportIncludesListeningMap = false
        model.exportIncludesInterjections = true
        model.exportIncludesTurns = true
        model.configureBatchExportFolder(url: root)
        model.exportSelectedSessionsToFolder()

        let result = try XCTUnwrap(model.batchExportResult)
        XCTAssertTrue(result.failures.isEmpty)
        let fileName = try XCTUnwrap(result.exportedFileNames.first)
        XCTAssertTrue(fileName.hasPrefix("Batch Export Article — "))
        XCTAssertTrue(fileName.hasSuffix(".md"))
        let markdown = try String(contentsOf: root.appendingPathComponent(fileName), encoding: .utf8)
        XCTAssertTrue(markdown.contains("# Spoken Margins AI Handoff: Batch Export Article"))
        XCTAssertTrue(markdown.contains("A source passage that should survive the Markdown export."))
    }
}
