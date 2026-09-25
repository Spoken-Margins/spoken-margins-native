import Foundation
import XCTest
@testable import DesktopCore
import SessionKit

final class DesktopSessionStoreTests: XCTestCase {
    func testTextSessionPersistsOffsetMarginTranscriptAndRecovery() throws {
        let databaseURL = try temporaryDatabase()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try DesktopSessionStore(databaseURL: databaseURL, now: { now })
        let created = try store.loadOrCreateTextSession(
            title: "A short note",
            text: "Read 🧭 this source slowly.",
            itemID: "item-one"
        )
        XCTAssertEqual(created.listeningMap?.chapters.first?.startChar, 0)

        let anchored = try store.sourceAnchor(sessionID: created.session.id, charOffset: 5, contextRadius: 5)
        XCTAssertEqual(anchored.anchorType, .text)
        XCTAssertEqual(anchored.startChar, 5)
        XCTAssertEqual(anchored.anchorBefore, "Read ")
        XCTAssertEqual(anchored.anchorAfter, "🧭 thi")

        let moved = try store.storePlaybackOffset(sessionID: created.session.id, charOffset: 6)
        XCTAssertEqual(moved.currentOffset, 6)
        XCTAssertEqual(moved.session.completionPercent, 23)

        let margin = try store.addMargin(
            sessionID: created.session.id,
            anchor: anchored,
            captureKind: .written
        )
        let updated = try store.updateMarginTranscript(
            sessionID: created.session.id,
            marginID: margin.id,
            transcript: "Keep this thought."
        )
        XCTAssertEqual(updated.transcript, "Keep this thought.")
        XCTAssertEqual(updated.transcriptionStatus, "transcribed")

        let reopened = try DesktopSessionStore(databaseURL: databaseURL, now: { now })
        let recovered = try XCTUnwrap(reopened.recoverLatestSession())
        XCTAssertEqual(recovered.session.id, created.session.id)
        XCTAssertEqual(recovered.currentOffset, 6)
        XCTAssertEqual(recovered.margins.count, 1)
        XCTAssertEqual(recovered.margins.first?.transcript, "Keep this thought.")
        XCTAssertEqual(recovered.listeningMap, created.listeningMap)
    }

    func testMarkdownExportIsBoundedToMarginContext() throws {
        let databaseURL = try temporaryDatabase()
        let store = try DesktopSessionStore(databaseURL: databaseURL)
        let session = try store.loadOrCreateTextSession(
            title: "Export me",
            text: "The original source should remain local.",
            itemID: "item-export"
        )
        let anchor = try store.sourceAnchor(sessionID: session.session.id, charOffset: 4, contextRadius: 12)
        _ = try store.addMargin(
            sessionID: session.session.id,
            anchor: anchor,
            transcript: "A durable desktop Margin.",
            captureKind: .written
        )

        let markdown = try store.exportMarkdown(sessionID: session.session.id)
        XCTAssertTrue(markdown.contains("# Spoken Margins AI Handoff: Export me"))
        XCTAssertTrue(markdown.contains("A durable desktop Margin."))
        XCTAssertTrue(markdown.contains("### Source Context and Listener Interjections"))
        XCTAssertTrue(markdown.contains("Source context:"))
        XCTAssertFalse(markdown.contains("The original source should remain local."))
    }

    func testLocalListeningMapChaptersKeepSeekableSourceOffsets() throws {
        let databaseURL = try temporaryDatabase()
        let store = try DesktopSessionStore(databaseURL: databaseURL)
        let text = (1...20).map { number in
            "Chapter topic \(number) explains the local source and gives enough detail to hear where this section begins."
        }.joined(separator: " ")
        let session = try store.loadOrCreateTextSession(title: "Many topics", text: text)
        let chapters = try XCTUnwrap(session.listeningMap?.chapters)
        XCTAssertGreaterThan(chapters.count, 1)
        XCTAssertEqual(chapters.first?.startChar, 0)
        XCTAssertTrue(chapters.allSatisfy { $0.startChar < $0.endChar && $0.endChar <= text.count })
        let destination = chapters[1]
        let moved = try store.storePlaybackOffset(sessionID: session.session.id, charOffset: destination.startChar)
        XCTAssertEqual(moved.currentOffset, destination.startChar)

        let reopened = try DesktopSessionStore(databaseURL: databaseURL)
        let recovered = try XCTUnwrap(reopened.recoverLatestSession())
        XCTAssertEqual(recovered.listeningMap?.chapters, chapters)
        XCTAssertEqual(recovered.currentOffset, destination.startChar)
    }

    func testPendingAudioAndSessionBoundariesSurviveReopen() throws {
        let databaseURL = try temporaryDatabase()
        let store = try DesktopSessionStore(databaseURL: databaseURL)
        let first = try store.loadOrCreateTextSession(
            title: "First",
            text: "First source text.",
            itemID: "item-first"
        )
        let second = try store.loadOrCreateTextSession(
            title: "Second",
            text: "Second source text.",
            itemID: "item-second"
        )

        let anchor = try store.sourceAnchor(sessionID: first.session.id, charOffset: 99)
        XCTAssertEqual(anchor.startChar, first.sourceText.count)
        XCTAssertEqual(anchor.endChar, first.sourceText.count)
        _ = try store.storePlaybackOffset(sessionID: first.session.id, charOffset: 99)
        XCTAssertEqual(try store.loadSession(id: first.session.id).currentOffset, first.sourceText.count)
        _ = try store.storePlaybackOffset(sessionID: second.session.id, charOffset: -4)
        XCTAssertEqual(try store.loadSession(id: second.session.id).currentOffset, 0)

        let pending = try store.addMargin(
            sessionID: first.session.id,
            anchor: anchor,
            captureKind: .audio,
            audioPath: "/tmp/desktop-margin.m4a"
        )
        XCTAssertEqual(pending.transcriptionStatus, "pending")

        let reopened = try DesktopSessionStore(databaseURL: databaseURL)
        let restoredFirst = try reopened.loadSession(id: first.session.id)
        XCTAssertEqual(restoredFirst.margins.count, 1)
        XCTAssertEqual(restoredFirst.margins.first?.audioPath, "/tmp/desktop-margin.m4a")
        XCTAssertEqual(restoredFirst.margins.first?.transcriptionStatus, "pending")
        let firstExport = try reopened.exportMarkdown(sessionID: first.session.id)
        XCTAssertTrue(firstExport.contains("First"))
        XCTAssertFalse(firstExport.contains("Second source text."))
        XCTAssertThrowsError(try reopened.loadSession(id: "missing-session"))
        XCTAssertThrowsError(try reopened.updateMarginTranscript(
            sessionID: first.session.id,
            marginID: "missing-margin",
            transcript: "No such Margin"
        ))
        XCTAssertThrowsError(try reopened.updateMarginTranscript(
            sessionID: first.session.id,
            marginID: pending.id,
            transcript: "   "
        ))
    }

    private func temporaryDatabase() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpokenMarginsDesktopCore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("sessions.sqlite")
    }
}
