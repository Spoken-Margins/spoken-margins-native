import Foundation
import XCTest
@testable import SessionKit

/// #2256: "Share as Markdown" is one call with no main-actor state, so the app can run it off the main thread.
final class MarginMarkdownShareJobTests: XCTestCase {
    private let createdAt = Date(timeIntervalSince1970: 1_777_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("margin-share-job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testOneMarginIsWrittenAsTheFileTheNotesFolderNoteMakes() throws {
        let item = item()
        let margin = margin("m1", item: item)
        let engine = engine(item: item, margins: [margin])
        let url = try XCTUnwrap(try MarginMarkdownShare.prepare(
            margins: [margin], asItem: false, engine: engine, liveSessionDirectory: nil, under: root.appendingPathComponent("share")))
        let expected = try XCTUnwrap(try MarginMarkdownShare.file(for: margin, engine: engine))
        XCTAssertEqual(url.lastPathComponent, expected.fileName)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected.markdown)
    }

    func testAnItemsMarginsAreWrittenAsOneFile() throws {
        let item = item()
        let margins = [margin("early", item: item, startChar: 100), margin("late", item: item, startChar: 900)]
        let engine = engine(item: item, margins: margins)
        let url = try XCTUnwrap(try MarginMarkdownShare.prepare(
            margins: margins, asItem: true, engine: engine, liveSessionDirectory: root, under: root.appendingPathComponent("share")))
        let expected = try XCTUnwrap(try MarginMarkdownShare.file(forItemMargins: margins, engine: engine))
        XCTAssertEqual(url.lastPathComponent, "Margins - An essay.md", "no live session record, so the ordinary export")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected.markdown)
    }

    func testNoNoteMeansNoFile() throws {
        let item = item()
        let margin = margin("deleted", item: item, status: "deleted")
        let share = root.appendingPathComponent("share")
        XCTAssertNil(try MarginMarkdownShare.prepare(
            margins: [margin], asItem: false, engine: engine(item: item, margins: [margin]), liveSessionDirectory: nil, under: share))
        XCTAssertNil(try MarginMarkdownShare.prepare(
            margins: [], asItem: true, engine: engine(item: item, margins: []), liveSessionDirectory: nil, under: share))
        XCTAssertFalse(FileManager.default.fileExists(atPath: share.path), "nothing is written when there is nothing to share")
    }

    func testAnItemFromALiveSessionSharesTheSessionsOwnMarkdown() throws {
        let item = item()
        let margin = margin("m-a", item: item)
        try liveRecord(itemId: item.id, savedMarginId: margin.id).save(in: root)
        let url = try XCTUnwrap(try MarginMarkdownShare.prepare(
            margins: [margin], asItem: true, engine: engine(item: item, margins: [margin]), liveSessionDirectory: root,
            under: root.appendingPathComponent("share")))
        XCTAssertEqual(url.lastPathComponent, "Budget sync.md")
        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Thought m-a."), markdown)
        // One Margin's share ignores the record, as the screen only offers the live session's file for an item.
        let single = try XCTUnwrap(try MarginMarkdownShare.prepare(
            margins: [margin], asItem: false, engine: engine(item: item, margins: [margin]), liveSessionDirectory: root,
            under: root.appendingPathComponent("share")))
        XCTAssertTrue(single.lastPathComponent.hasPrefix("Margin - "), single.lastPathComponent)
    }

    func testALiveSessionFileThatCannotBeWrittenSaysSo() throws {
        let item = item()
        let margin = margin("m-a", item: item)
        try liveRecord(itemId: item.id, savedMarginId: margin.id).save(in: root)
        let blocker = root.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: blocker)
        XCTAssertThrowsError(try MarginMarkdownShare.prepare(
            margins: [margin], asItem: true, engine: engine(item: item, margins: [margin]), liveSessionDirectory: root, under: blocker)
        ) { error in
            XCTAssertTrue(error is MarginMarkdownShare.LiveSessionExportFailure, "\(error)")
        }
    }

    private func liveRecord(itemId: String, savedMarginId: String) -> LiveSessionRecord {
        let start = Date(timeIntervalSince1970: 1_777_000_000)
        var live = LiveSession(id: "s", kind: .meeting, title: "Budget sync", startedAt: start, endedAt: start.addingTimeInterval(900), startPositionMs: 0)
        live.margins = [live.margin(id: "a", text: "Travel budget", markedAt: start.addingTimeInterval(170))]
        return LiveSessionRecord(itemId: itemId, session: live, transcript: nil, placed: [], savedMarginIds: ["a": savedMarginId])
    }

    private func item() -> Item {
        Item(id: "item-1", title: "An essay", mediaType: "text", text: "Source text.",
             externalReference: "https://example.com/essay", status: "ready")
    }

    private func margin(_ id: String, item: Item, status: String = "active", startChar: Int = 0) -> Interjection {
        Interjection(
            id: id, itemId: item.id, sessionId: "session-1", targetType: .item, targetId: item.id,
            createdAt: createdAt, roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: startChar, endChar: startChar + 7,
                           anchorBefore: "Before.", anchorAfter: "After.", mediaTimeMs: nil),
            audioPath: nil, audioStatus: "saved",
            transcriptionStatus: "transcribed", transcript: "Thought \(id).", cleanedTranscript: nil,
            displayText: "Thought \(id).", status: status, captureKind: nil
        )
    }

    private func engine(item: Item, margins: [Interjection]) -> SessionEngine {
        let session = Session(id: "session-1", itemId: item.id, createdAt: nil, status: "in_progress", phase: .itemPlayback,
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
