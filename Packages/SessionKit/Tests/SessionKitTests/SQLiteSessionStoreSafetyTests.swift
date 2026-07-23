import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence

final class SQLiteSessionStoreSafetyTests: XCTestCase {
    func testStoreWritesCurrentSchemaVersion() throws {
        let path = temporaryDatabasePath()
        _ = try SQLiteSessionStore(path: path)

        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), SQLiteSessionStore.currentSchemaVersion)
    }

    func testCorruptRecordIsMovedToQuarantineWithoutHidingHealthyItems() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        let healthy = Item(
            id: "healthy",
            title: "Healthy",
            mediaType: "text",
            text: "Readable.",
            externalReference: nil,
            status: "ready"
        )
        try store.saveItem(healthy)
        try insertCorruptItem(path: path)

        XCTAssertEqual(try store.listItems().map(\.id), [healthy.id])
        XCTAssertEqual(try store.quarantinedRecordCount(), 1)
        XCTAssertEqual(try store.listItems().map(\.id), [healthy.id])
    }

    func testVersionTwoMigrationBackfillsSessionTimestampsWithoutLosingTheSession() throws {
        let path = temporaryDatabasePath()
        try createVersionTwoSessionDatabase(path: path)

        let store = try SQLiteSessionStore(path: path)
        let sessions = try store.loadSessions(itemId: "item-legacy")
        let session = try XCTUnwrap(sessions.first)

        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), 3)
        XCTAssertEqual(session.id, "session-legacy")
        XCTAssertNotNil(session.createdAt)
        XCTAssertNotNil(session.updatedAt)
        XCTAssertNil(session.completedAt)
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "sessionkit-safety-\(UUID().uuidString).sqlite")
            .path
    }

    private func insertCorruptItem(path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            throw NSError(domain: "SQLiteSessionStoreSafetyTests", code: 1)
        }
        defer { sqlite3_close(database) }
        let sql = "INSERT INTO records(kind,id,item_id,payload) VALUES('item','corrupt','corrupt','{not-json');"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteSessionStoreSafetyTests", code: 2)
        }
    }

    private func createVersionTwoSessionDatabase(path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            throw NSError(domain: "SQLiteSessionStoreSafetyTests", code: 3)
        }
        defer { sqlite3_close(database) }
        let statements = [
            "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
            "INSERT INTO metadata(key,value) VALUES('schema_version','2');",
            "CREATE TABLE records (kind TEXT NOT NULL, id TEXT NOT NULL, session_id TEXT, item_id TEXT, payload TEXT NOT NULL, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(kind,id));",
            "CREATE TABLE quarantined_records (kind TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, decode_error TEXT NOT NULL, quarantined_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(kind,id));",
            "INSERT INTO records(kind,id,session_id,item_id,payload,updated_at) VALUES('session','session-legacy','session-legacy','item-legacy','{\"id\":\"session-legacy\",\"itemId\":\"item-legacy\",\"status\":\"in_progress\",\"phase\":\"item_playback\",\"currentTargetType\":\"item_text_tts\",\"currentTargetId\":\"item-legacy\",\"position\":{\"charOffset\":12},\"completionPercent\":25,\"playbackRate\":1}','2026-07-20 12:34:56');"
        ]
        for sql in statements {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLiteSessionStoreSafetyTests", code: 4)
            }
        }
    }
}
