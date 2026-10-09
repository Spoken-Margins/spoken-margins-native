import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// A conversation turn is saved with the session id only (no item id), so deleting an item
/// has to find it through the item's sessions. Without that, the AI summary of the listener's
/// Margins and their own questions stay in the database file after "Delete Permanently" (#975).
final class PermanentDeleteTurnsTests: XCTestCase {
    private var path = ""

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory
            .appending(path: "sessionkit-turns-\(UUID().uuidString).sqlite").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
    }

    func testPermanentDeleteRemovesTheTurnsOfTheItemsSessionsOnly() throws {
        let store = try SQLiteSessionStore(path: path)
        try seed(store, itemId: "item-1", sessionIds: ["session-1a", "session-1b"], secret: "SECRET-ONE")
        try seed(store, itemId: "item-10", sessionIds: ["session-10"], secret: "SECRET-TEN")

        try store.moveItemToTrash(id: "item-1")
        try store.deleteItem(id: "item-1")

        XCTAssertEqual(try turnRows(containing: "SECRET-ONE"), [])
        XCTAssertEqual(try store.loadTurns(sessionId: "session-1a").count, 0)
        XCTAssertEqual(try store.loadTurns(sessionId: "session-1b").count, 0)
        // `item-1` is a prefix of `item-10`: the neighbour must keep its turn.
        XCTAssertEqual(try store.loadTurns(sessionId: "session-10").count, 1)
        XCTAssertEqual(try turnRows(containing: "SECRET-TEN").count, 1)
    }

    func testBulkPermanentDeleteRemovesTheTurnsOfEverySelectedItem() throws {
        let store = try SQLiteSessionStore(path: path)
        try seed(store, itemId: "item-a", sessionIds: ["session-a"], secret: "SECRET-A")
        try seed(store, itemId: "item-b", sessionIds: ["session-b1", "session-b2"], secret: "SECRET-B")
        try seed(store, itemId: "item-keep", sessionIds: ["session-keep"], secret: "SECRET-KEEP")

        try store.deleteItems(ids: ["item-a", "item-b"])

        XCTAssertEqual(try turnRows(containing: "SECRET-A"), [])
        XCTAssertEqual(try turnRows(containing: "SECRET-B"), [])
        XCTAssertEqual(try store.loadTurns(sessionId: "session-b2").count, 0)
        XCTAssertEqual(try store.loadTurns(sessionId: "session-keep").count, 1)
        XCTAssertEqual(try turnRows(containing: "SECRET-KEEP").count, 1)
    }

    func testTrashAndRestoreKeepTheTurns() throws {
        let store = try SQLiteSessionStore(path: path)
        try seed(store, itemId: "item-1", sessionIds: ["session-1"], secret: "SECRET-ONE")

        try store.moveItemToTrash(id: "item-1")
        XCTAssertEqual(try store.loadTurns(sessionId: "session-1").count, 1, "Trash is not a delete")
        try store.restoreItem(id: "item-1")

        XCTAssertEqual(try store.loadTurns(sessionId: "session-1").count, 1)
        XCTAssertEqual(try turnRows(containing: "SECRET-ONE").count, 1)
    }

    /// The turns go in their own statement before the item's other rows (#1218: on SQLite 3.37 a
    /// single DELETE removed the session rows first and left the turns behind). That makes the
    /// delete two statements, so it has to stay one transaction: when the item row cannot be
    /// deleted, the turns that were already removed must come back.
    func testFailedPermanentDeleteLeavesTheTurnsInPlace() throws {
        let store = try SQLiteSessionStore(path: path)
        try seed(store, itemId: "item-1", sessionIds: ["session-1a", "session-1b"], secret: "SECRET-ONE")
        try execute("""
        CREATE TRIGGER refuse_item_delete BEFORE DELETE ON records
        WHEN old.kind = 'item' BEGIN SELECT RAISE(ABORT, 'refused'); END;
        """)

        XCTAssertThrowsError(try store.deleteItem(id: "item-1"))

        XCTAssertEqual(try store.loadSessions(itemId: "item-1").count, 2)
        XCTAssertEqual(try store.loadTurns(sessionId: "session-1a").count, 1)
        XCTAssertEqual(try store.loadTurns(sessionId: "session-1b").count, 1)
        XCTAssertEqual(try turnRows(containing: "SECRET-ONE").count, 2)

        try execute("DROP TRIGGER refuse_item_delete;")
        try store.deleteItem(id: "item-1")
        XCTAssertEqual(try turnRows(containing: "SECRET-ONE"), [])
    }

    // MARK: - Helpers

    private func seed(_ store: SQLiteSessionStore, itemId: String, sessionIds: [String], secret: String) throws {
        try store.saveItem(Item(
            id: itemId, title: itemId, mediaType: "text", text: "Source.", externalReference: nil, status: "ready"
        ))
        for sessionId in sessionIds {
            try store.saveSession(Session(
                id: sessionId, itemId: itemId, status: "in_progress", phase: .itemPlayback,
                currentTargetType: .itemTextTTS, currentTargetId: itemId,
                position: Position(), completionPercent: 0, playbackRate: 1
            ))
            try store.saveTurn(ConversationTurn(
                id: "turn-\(sessionId)", sessionId: sessionId, role: "assistant", turnType: "summary",
                status: "complete", summary: secret, text: secret, rawText: secret, sourceInterjectionIds: []
            ))
        }
    }

    private func execute(_ sql: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
    }

    /// Raw `records` rows of kind `turn` whose payload mentions `needle`, read from a second
    /// connection so the check does not depend on the store's own query helpers.
    private func turnRows(containing needle: String) throws -> [String] {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(database, "SELECT id, payload FROM records WHERE kind = 'turn';", -1, &statement, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            let payload = String(cString: sqlite3_column_text(statement, 1))
            if payload.contains(needle) { rows.append(id) }
        }
        return rows
    }
}
