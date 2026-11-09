import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2505: the check behind "play this Margin's moment", now one read of the Margin rather than all of the session's.
final class MarginMomentTargetTests: XCTestCase {
    private func store() throws -> SQLiteSessionStore {
        let path = FileManager.default.temporaryDirectory.appending(path: "mmt-\(UUID().uuidString).sqlite").path
        return try SQLiteSessionStore(path: path)
    }

    private func margin(id: String, item: String, session: String, status: String) -> Interjection {
        Interjection(id: id, itemId: item, sessionId: session, targetType: .item, targetId: item,
            createdAt: Date(timeIntervalSince1970: 1), roughPercent: 50,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: "x",
            cleanedTranscript: nil, displayText: nil, status: status)
    }

    func testFindsAnActiveMarginAndRefusesTheRest() throws {
        let store = try store()
        try store.saveItem(Item(id: "a", title: "A", mediaType: "text", text: "Hello", externalReference: "local", status: "ready"))
        let session = Session(id: "s1", itemId: "a", status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: "a", position: Position(charOffset: 0), completionPercent: 0, playbackRate: 1)
        try store.saveSession(session)
        try store.saveInterjection(margin(id: "live", item: "a", session: "s1", status: "active"))
        try store.saveInterjection(margin(id: "gone", item: "a", session: "s1", status: "deleted"))
        try store.saveInterjection(margin(id: "other", item: "b", session: "s1", status: "active"))

        XCTAssertEqual(try MarginMomentTarget.find(store: store, sessionId: "s1", itemId: "a", interjectionId: "live")?.interjection.id, "live")
        XCTAssertNil(try MarginMomentTarget.find(store: store, sessionId: "s1", itemId: "a", interjectionId: "gone"), "not active")
        XCTAssertNil(try MarginMomentTarget.find(store: store, sessionId: "s1", itemId: "a", interjectionId: "other"), "another item's Margin")
        XCTAssertNil(try MarginMomentTarget.find(store: store, sessionId: "s1", itemId: "b", interjectionId: "live"), "session of another item")
        XCTAssertNil(try MarginMomentTarget.find(store: store, sessionId: "nope", itemId: "a", interjectionId: "live"), "no such session")
        XCTAssertNil(try MarginMomentTarget.find(store: store, sessionId: "s1", itemId: "a", interjectionId: "missing"))
    }
}
