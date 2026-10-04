import Foundation
import XCTest
@testable import SessionKit

/// #493: "Share as Markdown" hands the share sheet a named `.md` file holding the notes-folder note.
final class MarginMarkdownShareTests: XCTestCase {
    private let createdAt = Date(timeIntervalSince1970: 1_777_000_000)

    func testOneMarginIsTheNotesFolderNoteInAFileNamedForItsPosition() throws {
        let item = item(title: "Episode 12: \"Queues\" / clocks 🎧")
        let margin = margin("m1", item: item, mediaTimeMs: 754_000, percent: 21)
        let engine = engine(item: item, margins: [margin])
        let file = try XCTUnwrap(try MarginMarkdownShare.file(for: margin, engine: engine))

        XCTAssertEqual(file.fileName, "Margin - Episode 12- -Queues- - clocks 🎧 - 12m34s.md")
        // Built exactly as the notes-folder gatherer builds it.
        let folderNote = SessionExportMarkdownRenderer.renderMargin(
            try engine.buildExport(options: ExportOptions(
                sessionId: margin.sessionId,
                includeFullText: false, includeReference: true, includeListeningMap: false,
                includeInterjections: true, includeTurns: false,
                scope: "selected_interjections", interjectionIds: [margin.id]
            )),
            createdAt: margin.createdAt
        )
        XCTAssertEqual(file.markdown, folderNote)
        XCTAssertTrue(file.markdown.contains("Thought m1."))
    }

    func testAnItemsMarginsAreJoinedInSourceOrder() throws {
        let item = item(title: "An essay")
        let margins = [
            margin("late", item: item, mediaTimeMs: nil, percent: 80),
            margin("early", item: item, mediaTimeMs: nil, percent: 10),
            margin("deleted", item: item, mediaTimeMs: nil, percent: 20, status: "deleted"),
            margin("untranscribed", item: item, mediaTimeMs: nil, percent: 30, transcript: "  \n"),
            margin("blank", item: item, mediaTimeMs: nil, percent: 40, transcript: "  \n", captureKind: .written),
        ]
        let file = try XCTUnwrap(try MarginMarkdownShare.file(forItemMargins: margins, engine: engine(item: item, margins: margins)))

        XCTAssertEqual(file.fileName, "Margins - An essay.md")
        let notes = file.markdown.components(separatedBy: MarginMarkdownShare.separator)
        XCTAssertEqual(notes.count, 3, "deleted and empty written Margins have no note, as in the notes folder (#171)")
        XCTAssertTrue(notes[0].contains("Thought early."))
        XCTAssertTrue(notes[1].contains(SessionExportMarkdownRenderer.transcriptNotAvailableYet), notes[1])
        XCTAssertTrue(notes[2].contains("Thought late."))
        XCTAssertFalse(file.markdown.contains("Thought deleted."))
    }

    /// A Margin saved before #624 stores a counter as its date; the shared note is dated as the notes folder dates it.
    func testTextMarginsInTheSamePercentFollowTheirCharacterNotTheirRecordingTime() throws {
        // Recorded at character 1,080, then the listener rewinds and records at 1,020:
        // both sit at 10%, and the later recording comes first in the source.
        let item = item(title: "A long article")
        let margins = [
            margin("first-recorded", item: item, mediaTimeMs: nil, percent: 10, startChar: 1_080, createdAt: createdAt),
            margin("rewound", item: item, mediaTimeMs: nil, percent: 10, startChar: 1_020, createdAt: createdAt.addingTimeInterval(60)),
        ]
        let file = try XCTUnwrap(try MarginMarkdownShare.file(forItemMargins: margins, engine: engine(item: item, margins: margins)))
        let notes = file.markdown.components(separatedBy: MarginMarkdownShare.separator)
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes[0].contains("Thought rewound."), file.markdown)
        XCTAssertTrue(notes[1].contains("Thought first-recorded."), file.markdown)
    }

    func testAPlaceholderDateIsReadAgainstTheSessionStart() throws {
        let item = item(title: "An essay")
        var margin = margin("old", item: item, mediaTimeMs: nil, percent: 10)
        margin.createdAt = Date(timeIntervalSince1970: 2)
        let engine = engine(item: item, margins: [margin], sessionCreatedAt: createdAt)
        let session = try XCTUnwrap(try engine.loadSession(id: margin.sessionId))
        let file = try XCTUnwrap(try MarginMarkdownShare.file(for: margin, engine: engine))

        XCTAssertEqual(file.markdown, SessionExportMarkdownRenderer.renderMargin(
            try engine.buildExport(options: .marginNote(sessionId: margin.sessionId, marginId: margin.id)),
            createdAt: margin.recordedAt(in: session)
        ))
        XCTAssertTrue(file.markdown.contains(ISO8601DateFormatter().string(from: createdAt.addingTimeInterval(2))), file.markdown)
    }

    func testAnItemWithNoMarginsHasNothingToShare() throws {
        let item = item(title: "Empty")
        XCTAssertNil(try MarginMarkdownShare.file(forItemMargins: [], engine: engine(item: item, margins: [])))
        let deleted = margin("gone", item: item, mediaTimeMs: nil, percent: 5, status: "deleted")
        XCTAssertNil(try MarginMarkdownShare.file(forItemMargins: [deleted], engine: engine(item: item, margins: [deleted])))
        XCTAssertNil(try MarginMarkdownShare.file(for: deleted, engine: engine(item: item, margins: [deleted])))
    }

    func testFileNamesAreSafeAndDeterministic() {
        XCTAssertEqual(MarginMarkdownShare.safeName("a/b\\c:d*e?f\"g<h>i|j"), "a-b-c-d-e-f-g-h-i-j")
        XCTAssertEqual(MarginMarkdownShare.safeName("Line one\nLine\ttwo   three"), "Line one Line two three")
        XCTAssertEqual(MarginMarkdownShare.safeName("..hidden. "), "hidden")
        XCTAssertEqual(MarginMarkdownShare.safeName("Bell\u{7}"), "Bell-")
        XCTAssertEqual(MarginMarkdownShare.safeName("👩‍👩‍👧 Family 🎧"), "👩‍👩‍👧 Family 🎧", "emoji, including joined ones, stay whole")
        XCTAssertEqual(MarginMarkdownShare.safeName(""), "Untitled")
        XCTAssertEqual(MarginMarkdownShare.safeName("/:"), "--")
        XCTAssertEqual(MarginMarkdownShare.safeName(" . "), "Untitled")
        let long = String(repeating: "🎧", count: 100)
        XCTAssertEqual(MarginMarkdownShare.safeName(long), String(repeating: "🎧", count: 37), "150 bytes, never splitting a character")
        XCTAssertEqual(MarginMarkdownShare.safeName(String(repeating: "a", count: 300)).utf8.count, 150)

        func note(_ ms: Int?, _ percent: Int) -> ExportInterjection {
            ExportInterjection(id: "m", sessionId: "s", targetType: "item", targetId: "i", roughPercent: percent,
                               anchorBefore: "", anchorAfter: "", mediaTimeMs: ms, transcriptionStatus: "transcribed",
                               transcript: "x", audioPath: nil)
        }
        XCTAssertEqual(MarginMarkdownShare.position(of: note(754_000, 0)), "12m34s")
        XCTAssertEqual(MarginMarkdownShare.position(of: note(0, 0)), "00m00s")
        XCTAssertEqual(MarginMarkdownShare.position(of: note(3_723_999, 0)), "1h02m03s")
        XCTAssertEqual(MarginMarkdownShare.position(of: note(nil, 42)), "42%")
    }

    func testAPrivateFeedLinkNeverReachesTheFile() throws {
        let privateLink = "https://www.patreon.com/rss/show?auth=abc123SECRET456def789ghi012jkl345"
        let privateMedia = "https://c10.patreonusercontent.com/episode.mp3?token-hash=zyx987SECRET654wvu321tsr098qpo765"
        let item = Item(
            id: "item-private", title: "Members episode", mediaType: "audio", text: nil,
            externalReference: privateLink, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: privateMedia)
        )
        let margins = [margin("m1", item: item, mediaTimeMs: 1_000, percent: 1), margin("m2", item: item, mediaTimeMs: 9_000, percent: 2)]
        let engine = engine(item: item, margins: margins)
        let files = [
            try XCTUnwrap(try MarginMarkdownShare.file(for: margins[0], engine: engine)),
            try XCTUnwrap(try MarginMarkdownShare.file(forItemMargins: margins, engine: engine)),
        ]
        for file in files {
            XCTAssertFalse(file.markdown.contains("patreon"), file.markdown)
            XCTAssertFalse(file.markdown.contains("SECRET"), file.markdown)
            XCTAssertFalse(file.fileName.contains("SECRET"))
        }
    }

    func testLongTitlesInAnyScriptStillMakeAWritableFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for title in [String(repeating: "聞", count: 120), String(repeating: "👩‍👩‍👧", count: 80), String(repeating: "x", count: 400)] {
            let item = Item(id: "item-1", title: title, mediaType: "text", text: "Source text.", externalReference: nil, status: "ready")
            let margin = margin("m1", item: item, mediaTimeMs: 3_723_000, percent: 50)
            let file = try XCTUnwrap(try MarginMarkdownShare.file(for: margin, engine: engine(item: item, margins: [margin])))
            XCTAssertLessThanOrEqual(file.fileName.utf8.count, 255)
            let url = try MarginMarkdownShare.write(file, under: directory)
            XCTAssertEqual(url.lastPathComponent, file.fileName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testWrittenFilesKeepTheirNameAndNeverCollide() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = MarginMarkdownFile(fileName: "Margins - An essay 🎧.md", markdown: "# An essay\n")
        let first = try MarginMarkdownShare.write(file, under: directory)
        let second = try MarginMarkdownShare.write(file, under: directory)
        XCTAssertEqual(first.lastPathComponent, "Margins - An essay 🎧.md")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "# An essay\n")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "# An essay\n")
    }

    // MARK: - Fixtures

    private func item(title: String) -> Item {
        Item(id: "item-1", title: title, mediaType: "text", text: "Source text.",
             externalReference: "https://example.com/essay", status: "ready")
    }

    private func margin(_ id: String, item: Item, mediaTimeMs: Int?, percent: Int, status: String = "active", transcript: String? = nil,
                        captureKind: InterjectionCaptureKind? = nil, startChar: Int = 0, createdAt: Date? = nil) -> Interjection {
        Interjection(
            id: id, itemId: item.id, sessionId: "session-1", targetType: .item, targetId: item.id,
            createdAt: createdAt ?? self.createdAt, roughPercent: percent,
            anchor: Anchor(anchorType: mediaTimeMs == nil ? .text : .media, startChar: startChar, endChar: startChar + 7,
                           anchorBefore: "Before.", anchorAfter: "After.", mediaTimeMs: mediaTimeMs),
            audioPath: nil, audioStatus: "saved",
            transcriptionStatus: "transcribed", transcript: transcript ?? "Thought \(id).", cleanedTranscript: nil,
            displayText: transcript ?? "Thought \(id).", status: status, captureKind: captureKind
        )
    }

    private func engine(item: Item, margins: [Interjection], sessionCreatedAt: Date? = nil) -> SessionEngine {
        let session = Session(id: "session-1", itemId: item.id, createdAt: sessionCreatedAt, status: "in_progress", phase: .itemPlayback,
                              currentTargetType: .itemTextTTS, currentTargetId: item.id,
                              position: Position(), completionPercent: 0, playbackRate: 1)
        let repository = InMemorySessionRepository(
            items: [item.id: item], sessions: [session.id: session],
            interjections: Dictionary(uniqueKeysWithValues: margins.map { ($0.id, $0) })
        )
        return SessionEngine(
            profile: RuntimeCapabilityProfile(id: "margin-output", displayName: "Margin output", capabilities: [:]),
            repository: repository
        )
    }
}
