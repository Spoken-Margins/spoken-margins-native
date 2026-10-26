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
    func testBatchExportDefaultsToSessionsWithInterjectionsAndSharesSelectedMarkdown() async throws {
        let defaults = UserDefaults.standard
        let bookmarkKey = "batchExportFolderBookmark"
        let nameKey = "batchExportFolderName"
        let speechKeys = ["ttsVoiceSelection", "ttsMode", "speechVoiceIdentifier", "supertonicVoicePendingTermsV1"]
        let priorSpeechPreferences = Dictionary(uniqueKeysWithValues: speechKeys.map { ($0, defaults.object(forKey: $0)) })
        let priorBookmark = defaults.data(forKey: bookmarkKey)
        let priorName = defaults.string(forKey: nameKey)
        defer {
            for key in speechKeys {
                if let value = priorSpeechPreferences[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
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
        // Export requires a session, independent of persisted first-run voice consent.
        model.declineCurrentTerms()
        // #1043 APM-11: with only a session that has no Margin, a default filter that hid everything passed,
        // and an export that dropped the Margins section had nothing to drop. One session of each kind here.
        model.importTitle = "Quiet Article"
        model.importText = "A session nobody wrote a Margin on."
        model.importTextItem()
        model.pause()
        let quietSessionId = try XCTUnwrap(model.snapshot.sessionId)
        model.importTitle = "Batch Export Article"
        model.importText = "A source passage that should survive the Markdown export."
        model.importTextItem()
        model.pause()
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        let marginText = "A written Margin that must reach the exported file."
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: marginText)
        XCTAssertEqual(model.selectedItem.interjections.count, 1)

        await model.openBatchExport().value

        XCTAssertEqual(model.batchExportFilter, .withInterjections)
        XCTAssertEqual(model.visibleBatchExportRows.map(\.id), [sessionId], "the default shows exactly the sessions with Margins")
        model.batchExportFilter = .all
        XCTAssertEqual(Set(model.visibleBatchExportRows.map(\.id)), [sessionId, quietSessionId])
        model.batchExportFilter = .withInterjections

        model.toggleBatchExportSelection(sessionId: sessionId)
        model.exportScope = "full_session"
        model.exportIncludesSourceText = true
        model.exportIncludesReference = false
        model.exportIncludesListeningMap = false
        model.exportIncludesInterjections = true
        model.exportIncludesTurns = true
        model.prepareSelectedSessionsForSharing()

        // #1528: the files are built for the share sheet; nothing is written to a remembered folder or
        // called shared yet.
        let files = try XCTUnwrap(model.batchExportShare)
        XCTAssertTrue(files.failures.isEmpty)
        XCTAssertEqual(files.fileURLs.count, 1)
        XCTAssertNil(model.batchExportResult, "nothing is reported before the sheet completes")
        let fileURL = try XCTUnwrap(files.fileURLs.first)
        XCTAssertTrue(fileURL.lastPathComponent.hasPrefix("Batch Export Article — "))
        XCTAssertEqual(fileURL.pathExtension, "md")
        XCTAssertEqual(fileURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path,
                       SessionShareFiles.shareRoot().standardizedFileURL.path)
        let markdown = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("# Spoken Margins AI Handoff: Batch Export Article"))
        XCTAssertTrue(markdown.contains("A source passage that should survive the Markdown export."))
        XCTAssertTrue(markdown.contains(marginText), "the Margin reaches the exported file")
        XCTAssertEqual(defaults.data(forKey: bookmarkKey), priorBookmark, "the remembered export folder is not touched")
        XCTAssertEqual(defaults.string(forKey: nameKey), priorName)

        // Cancelled: the files go, and there is no result panel and no "saved" or "shared" message.
        model.batchShareSheetFinished(completed: false, activityType: nil)
        XCTAssertNil(model.batchExportShare)
        XCTAssertNil(model.batchExportResult)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "the temporary file is removed when the sheet closes")
        XCTAssertFalse(model.statusMessage.hasPrefix("Shared"))

        // Completed: "Shared 1 file" naming the activity iOS gives, and the onboarding step is marked.
        model.prepareSelectedSessionsForSharing()
        let again = try XCTUnwrap(model.batchExportShare)
        model.batchShareSheetFinished(completed: true, activityType: "com.apple.UIKit.activity.AirDrop")
        let result = try XCTUnwrap(model.batchExportResult)
        XCTAssertEqual(result.sharedFileNames, again.fileURLs.map(\.lastPathComponent))
        XCTAssertEqual(result.activityType, "com.apple.UIKit.activity.AirDrop")
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(model.statusMessage, "Shared 1 file with AirDrop")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(again.fileURLs.first).path))
        XCTAssertEqual(defaults.data(forKey: bookmarkKey), priorBookmark)
    }
}
