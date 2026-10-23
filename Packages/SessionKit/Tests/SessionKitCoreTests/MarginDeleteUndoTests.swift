import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #1981: deleting a Margin only hides it, so Undo has to return the very same Margin. Run against a real SQLite
/// file reopened the way a relaunch reopens it.
final class MarginDeleteUndoTests: XCTestCase {
    private var paths: [String] = []

    override func tearDown() {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
        paths = []
        super.tearDown()
    }

    func testUndoingADeleteReturnsTheSameMarginAfterReopeningTheDatabase() throws {
        let path = makePath()
        let (store, engine) = try makeEngine(path: path)
        let original = margin(id: "m1")
        try store.saveInterjection(original)
        try store.saveInterjection(margin(id: "m2"))

        _ = try engine.deleteInterjection(interjectionId: "m1", sessionId: "session-A")
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-A").first { $0.id == "m1" }?.status, "deleted")
        _ = try engine.restoreInterjection(interjectionId: "m1", sessionId: "session-A")

        let reopened = try SQLiteSessionStore(path: path)
        let all = try reopened.loadInterjections(sessionId: "session-A")
        XCTAssertEqual(all.first { $0.id == "m1" }, original, "id, recording, anchor, words and status all come back as they were")
        XCTAssertEqual(all.map(\.id), try store.loadInterjections(sessionId: "session-A").map(\.id), "the order is unchanged")
    }

    func testUndoingTwiceIsHarmless() throws {
        let (store, engine) = try makeEngine(path: makePath())
        let original = margin(id: "m1")
        try store.saveInterjection(original)
        _ = try engine.deleteInterjection(interjectionId: "m1", sessionId: "session-A")
        _ = try engine.restoreInterjection(interjectionId: "m1", sessionId: "session-A")
        _ = try engine.restoreInterjection(interjectionId: "m1", sessionId: "session-A")
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-A").first, original)
    }

    func testUndoDoesNotTouchAMarginThatWasNeverDeleted() throws {
        let (store, engine) = try makeEngine(path: makePath())
        var quarantined = margin(id: "m1")
        quarantined.status = "quarantined"
        try store.saveInterjection(quarantined)
        _ = try engine.restoreInterjection(interjectionId: "m1", sessionId: "session-A")
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-A").first?.status, "quarantined")
    }

    func testUndoInOneSessionLeavesTheSameIdMarginInAnotherDeleted() throws {
        let (store, engine) = try makeEngine(path: makePath())
        try store.saveInterjection(margin(id: "same"))
        var other = margin(id: "same")
        other.sessionId = "session-B"
        try store.saveInterjection(other)
        _ = try engine.deleteInterjection(interjectionId: "same", sessionId: "session-A")
        _ = try engine.deleteInterjection(interjectionId: "same", sessionId: "session-B")
        _ = try engine.restoreInterjection(interjectionId: "same", sessionId: "session-A")
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-A").first?.status, "active")
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-B").first?.status, "deleted")
    }

    private func makePath() -> String {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-margin-delete-undo-\(UUID().uuidString).sqlite").path
        paths.append(path)
        return path
    }

    private func makeEngine(path: String) throws -> (SQLiteSessionStore, SessionEngine) {
        let store = try SQLiteSessionStore(path: path)
        let item = Item(id: "item-text", title: "Text", mediaType: "text", text: "Source.", externalReference: nil, status: "ready")
        try store.saveItem(item)
        for id in ["session-A", "session-B"] {
            try store.saveSession(Session(
                id: id, itemId: item.id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS,
                currentTargetId: item.id, position: Position(), completionPercent: 0, playbackRate: 1
            ))
        }
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "phone-tablet-online", displayName: "Phone / Tablet Online", capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "interjection": ["record_audio", "capture_text_anchor"],
            ]),
            repository: store
        )
        return (store, engine)
    }

    private func margin(id: String) -> Interjection {
        Interjection(
            id: id, itemId: "item-text", sessionId: "session-A", targetType: .item, targetId: "item-text",
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 40,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 7, anchorBefore: "Source.", anchorAfter: ""),
            audioPath: "interjections/\(id).m4a", audioStatus: "saved", transcriptionStatus: "transcribed",
            transcript: "Spoken", cleanedTranscript: "Spoken.", displayText: "Spoken.", status: "active"
        )
    }
}
