import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence

private let quarantineTestTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A record the store cannot decode is moved to `quarantined_records` instead of being deleted, so the owner's
/// bytes are still on disk. `testCorruptRecordIsMovedToQuarantineWithoutHidingHealthyItems` checks the count
/// (`quarantinedRecordCount() == 1`) and that the source row is gone from `records`. Nothing reads what was kept.
/// A quarantine that stored an empty or shortened payload leaves the count at 1 and loses the data. These tests
/// read the quarantined row back with raw SQLite and compare it with what was in `records`.
final class SQLiteQuarantineContentTests: XCTestCase {
    private var paths: [String] = []

    override func tearDown() {
        for path in paths { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        paths = []
        super.tearDown()
    }

    private func temporaryDatabasePath() -> String {
        let path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-quarantine-\(UUID().uuidString).sqlite").path
        paths.append(path)
        return path
    }

    /// Longer than the 2000 characters kept of an error message, and not ASCII.
    private let longNonASCIIPayload = "{not json: " + String(repeating: "Margin écrit 日本語 🎧 ", count: 300)

    func testACorruptRecordIsKeptInQuarantineByteForByteWithTheReasonItFailed() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        let healthy = Item(id: "healthy", title: "Healthy", mediaType: "text", text: "Readable.", externalReference: nil, status: "ready")
        try store.saveItem(healthy)
        try execute("INSERT INTO records(kind,id,item_id,payload) VALUES('item','corrupt','corrupt',?);", binding: longNonASCIIPayload, at: path)
        XCTAssertGreaterThan(longNonASCIIPayload.count, 2_000, "fixture check: a prefix-limited copy would be caught")
        let healthyBefore = try row(in: path, table: "records", kind: "item", id: "healthy")

        XCTAssertEqual(try store.listItems().map(\.id), ["healthy"])

        let quarantined = try XCTUnwrap(try row(in: path, table: "quarantined_records", kind: "item", id: "corrupt"))
        XCTAssertEqual(quarantined.payload, longNonASCIIPayload, "the owner's bytes are kept exactly")
        XCTAssertFalse(try XCTUnwrap(quarantined.decodeError).isEmpty, "and the reason it could not be read")
        XCTAssertNil(try row(in: path, table: "records", kind: "item", id: "corrupt"), "it left the live table")
        XCTAssertEqual(try row(in: path, table: "records", kind: "item", id: "healthy"), healthyBefore,
                       "the healthy record's payload and updated_at are untouched")

        // A second read has nothing left to quarantine and must not disturb what was kept.
        XCTAssertEqual(try store.listItems().map(\.id), ["healthy"])
        XCTAssertEqual(try store.quarantinedRecordCount(), 1)
        XCTAssertEqual(try row(in: path, table: "quarantined_records", kind: "item", id: "corrupt")?.payload, longNonASCIIPayload)
    }

    /// The case that matters across builds: valid JSON from a build that knows more than this one.
    func testAValidRecordThisBuildCannotDecodeIsKeptExactlyAsWritten() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        let future = #"{"id":"from-a-newer-build","mediaType":{"future":"shape"},"extra":[1,2,{"nested":"é"}]}"#
        try execute("INSERT INTO records(kind,id,item_id,payload) VALUES('item','from-a-newer-build','from-a-newer-build',?);", binding: future, at: path)

        XCTAssertEqual(try store.listItems(), [])

        XCTAssertEqual(try row(in: path, table: "quarantined_records", kind: "item", id: "from-a-newer-build")?.payload, future)
        XCTAssertEqual(try store.quarantinedRecordCount(), 1)
    }

    /// `updateOwnedOfflineAsset` meets the bad row inside its own transaction, and quarantines it there.
    func testARecordQuarantinedInsideATransactionIsKeptByteForByte() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        try execute("INSERT INTO records(kind,id,payload) VALUES('owned_offline_asset','episode',?);", binding: longNonASCIIPayload, at: path)

        XCTAssertNil(try store.updateOwnedOfflineAsset(id: "episode") { $0.protections.insert(.activePlayback) })

        let quarantined = try XCTUnwrap(try row(in: path, table: "quarantined_records", kind: "owned_offline_asset", id: "episode"))
        XCTAssertEqual(quarantined.payload, longNonASCIIPayload)
        XCTAssertFalse(try XCTUnwrap(quarantined.decodeError).isEmpty)
        XCTAssertNil(try row(in: path, table: "records", kind: "owned_offline_asset", id: "episode"))
    }

    // MARK: Raw SQLite

    private struct StoredRow: Equatable {
        var payload: String
        var updatedAt: String?
        var decodeError: String?
    }

    private func row(in path: String, table: String, kind: String, id: String) throws -> StoredRow? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteQuarantineContentTests", code: 1)
        }
        defer { sqlite3_close(database) }
        let extra = table == "records" ? "updated_at, NULL" : "NULL, decode_error"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT payload, \(extra) FROM \(table) WHERE kind = ? AND id = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteQuarantineContentTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, quarantineTestTransient)
        sqlite3_bind_text(statement, 2, id, -1, quarantineTestTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
        return StoredRow(payload: text(0) ?? "", updatedAt: text(1), decodeError: text(2))
    }

    private func execute(_ sql: String, binding: String, at path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else { throw NSError(domain: "SQLiteQuarantineContentTests", code: 3) }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "SQLiteQuarantineContentTests", code: 4) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, binding, -1, quarantineTestTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw NSError(domain: "SQLiteQuarantineContentTests", code: 5) }
    }
}
