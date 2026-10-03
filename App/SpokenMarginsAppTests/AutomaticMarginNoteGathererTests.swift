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
        let margins: [(String, String, String, InterjectionCaptureKind?)] = [
            ("ij-001", "This is the Margin to save.", "active", nil),
            ("ij-002", "   ", "active", nil),
            ("ij-003", "A deleted Margin.", "deleted", nil),
            ("ij-004", "  ", "active", .written),
        ]
        for (id, transcript, status, kind) in margins {
            try store.saveInterjection(Interjection(
                id: id, itemId: "article", sessionId: "session-a", targetType: .item, targetId: "article",
                createdAt: Date(timeIntervalSince1970: 1_790_000_000), roughPercent: 30,
                anchor: Anchor(anchorType: .text, startChar: 18, endChar: 30, anchorBefore: "Opening sentence.", anchorAfter: "A second"),
                audioPath: nil, audioStatus: "none", transcriptionStatus: "complete",
                transcript: transcript, cleanedTranscript: nil, displayText: transcript, status: status, captureKind: kind
            ))
        }

        let result = try await AutomaticMarginNoteGatherer.gather(store: store)

        XCTAssertEqual(result.sessionCount, 1)
        // A spoken Margin without words still gets a note (#171); deleted and empty written Margins don't.
        XCTAssertEqual(Set(result.notes.map(\.id)), ["session-a:ij-001", "session-a:ij-002"])
        let saved = try XCTUnwrap(result.notes.first { $0.id == "session-a:ij-001" })
        XCTAssertTrue(saved.markdown.contains("This is the Margin to save."))
        XCTAssertTrue(saved.markdown.contains("A Notes Test Article"))
        let untranscribed = try XCTUnwrap(result.notes.first { $0.id == "session-a:ij-002" })
        XCTAssertTrue(untranscribed.markdown.contains("Transcript not available yet."), untranscribed.markdown)
    }
}
