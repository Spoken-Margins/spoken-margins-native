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
}
