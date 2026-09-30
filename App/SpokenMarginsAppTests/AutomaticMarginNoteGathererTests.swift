import Foundation
import SessionKit
import SessionKitPersistence
import XCTest
@testable import SpokenMarginsApp

final class AutomaticMarginNoteGathererTests: XCTestCase {
    func testBuildsOneNotePerTranscribedActiveMarginOffTheMainActor() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "margin-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SQLiteSessionStore(path: root.appending(path: "library.sqlite").path)
        try store.saveItem(Item(
            id: "article", title: "A Notes Test Article", mediaType: "text",
            text: "Opening sentence. A second sentence the Margin is about.", externalReference: nil, status: "ready"
        ))
        try store.saveSession(Session(
            id: "session-a", itemId: "article", createdAt: Date(), updatedAt: Date(), status: "active",
            phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: "article",
            position: Position(charOffset: 18), completionPercent: 30, playbackRate: 1
        ))
        for (id, transcript, status) in [("ij-001", "This is the Margin to save.", "active"),
                                         ("ij-002", "   ", "active"),
                                         ("ij-003", "A deleted Margin.", "deleted")] {
            try store.saveInterjection(Interjection(
                id: id, itemId: "article", sessionId: "session-a", targetType: .item, targetId: "article",
                createdAt: Date(timeIntervalSince1970: 1_790_000_000), roughPercent: 30,
                anchor: Anchor(anchorType: .text, startChar: 18, endChar: 30, anchorBefore: "Opening sentence.", anchorAfter: "A second"),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "complete",
                transcript: transcript, cleanedTranscript: nil, displayText: transcript, status: status
            ))
        }

        let result = try await AutomaticMarginNoteGatherer.gather(store: store)

        XCTAssertEqual(result.sessionCount, 1)
        XCTAssertEqual(result.notes.map(\.id), ["session-a:ij-001"], "blank and deleted Margins are skipped")
        XCTAssertTrue(result.notes.first?.markdown.contains("This is the Margin to save.") == true)
        XCTAssertTrue(result.notes.first?.markdown.contains("A Notes Test Article") == true)

        // "Share as Markdown" (#493): the shared temp file holds the same note the notes folder gets.
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "margin-output", displayName: "Margin output", capabilities: [:]),
            repository: store
        )
        let margins = try store.loadInterjections(sessionId: "session-a")
        let saved = try XCTUnwrap(margins.first { $0.id == "ij-001" })
        let shared = try XCTUnwrap(try MarginMarkdownShare.file(for: saved, engine: engine))
        let url = try MarginMarkdownShare.write(shared, under: root.appending(path: "share"))
        XCTAssertEqual(url.pathExtension, "md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), result.notes.first?.markdown)
        // The item's file carries only that note too: the others are blank or deleted.
        let itemFile = try XCTUnwrap(try MarginMarkdownShare.file(forItemMargins: margins, engine: engine))
        XCTAssertEqual(itemFile.fileName, "Margins - A Notes Test Article.md")
        XCTAssertEqual(itemFile.markdown, result.notes.first?.markdown)
    }
}
