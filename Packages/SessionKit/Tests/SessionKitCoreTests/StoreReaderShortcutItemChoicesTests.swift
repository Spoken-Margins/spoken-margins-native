import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

final class StoreReaderShortcutItemChoicesTests: XCTestCase {
    private func makeStore() throws -> SQLiteSessionStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("shortcut-choices-\(UUID().uuidString).sqlite").path
        return try SQLiteSessionStore(path: path)
    }

    private func item(_ id: String, _ title: String, deleted: Bool = false) -> Item {
        Item(id: id, title: title, mediaType: "text", text: "Text.", externalReference: nil, status: "ready",
             deletedAt: deleted ? Date(timeIntervalSince1970: 1_000) : nil)
    }

    private func session(_ itemId: String) -> Session {
        Session(
            id: "s-\(itemId)", itemId: itemId, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: itemId, position: Position(), completionPercent: 10, playbackRate: 1)
    }

    /// The real database gives the same answer as the pure policy over the same rows, and the picker/lookup split holds:
    /// a picker (`startedOnly`) leaves out an item with no session, a saved shortcut's lookup keeps it, and Recently
    /// Deleted is never offered.
    func testReadsTheDatabaseAndAppliesTheShortcutRules() async throws {
        let store = try makeStore()
        for entry in [item("a", "Alpha"), item("b", "Bravo"), item("d", "Delta", deleted: true), item("e", "Echo")] {
            try store.saveItem(entry)
        }
        for id in ["a", "b", "d"] { try store.saveSession(session(id)) }
        let reader = StoreReader(store)

        let picker = try await reader.shortcutItemChoices(startedOnly: true)
        XCTAssertEqual(Set(picker.map(\.id)), ["a", "b"], "Echo was never started and Delta is deleted")
        let lookup = try await reader.shortcutItemChoices(startedOnly: false)
        XCTAssertEqual(Set(lookup.map(\.id)), ["a", "b", "e"])
        let expected = StoredSessionMargin.itemChoices(
            items: try store.listItemSummaries(), sessions: try store.loadSessions(), startedOnly: false)
        XCTAssertEqual(lookup, expected)
    }

    func testAQueryKeepsMatchingTitlesOnly() async throws {
        let store = try makeStore()
        for entry in [item("a", "Café culture"), item("b", "Tea")] {
            try store.saveItem(entry)
            try store.saveSession(session(entry.id))
        }
        let found = try await StoreReader(store).shortcutItemChoices(startedOnly: true, matching: "CAFE")
        XCTAssertEqual(found.map(\.id), ["a"])
    }
}
