import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2507: the launch sequence reads the Library once and takes the live items and the sessions from that read
/// instead of reading the item and session tables again. That is only the same answer if the snapshot agrees with the
/// separate reads, including with an item in Recently Deleted.
final class LibraryReadSnapshotReuseTests: XCTestCase {
    func testTheSnapshotHoldsTheLiveItemsAndSessionsTheSeparateReadsReturn() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-reuse-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        for id in ["item-a", "item-trashed", "item-b"] {
            try store.saveItem(Item(id: id, title: id, mediaType: "text", text: "Some words to read.", externalReference: nil, status: "ready"))
            try store.saveSession(Session(
                id: "session-\(id)", itemId: id, status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS,
                currentTargetId: id, position: Position(), completionPercent: 0, playbackRate: 1))
        }
        try store.moveItemToTrash(id: "item-trashed")

        let snapshot = try LibraryReadSnapshot.read(store: store)

        XCTAssertEqual(snapshot.items.count, 3, "the snapshot keeps the trashed item for Recently Deleted")
        XCTAssertEqual(snapshot.liveItems, try store.listItemSummaries())
        XCTAssertEqual(Set(snapshot.liveItems.map(\.id)), ["item-a", "item-b"])
        XCTAssertEqual(snapshot.sessions.map(\.id), try store.loadSessions().map(\.id))
    }
}
