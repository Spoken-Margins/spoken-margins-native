import Foundation
import SessionKit
import SQLite3
import XCTest

/// The `records` rows of a temporary SQLite Library, for the tests that ask whether the last shipped build still opens
/// this build's database, or this build still opens the shipped build's (#4309). Those tests save through
/// `SQLiteSessionStore` and read the row back from the file, so a change to how the store encodes a row fails them;
/// a test that encodes the value itself only checks its own encoder.
enum StoredRecordFile {
    /// A database path in a fresh temporary directory, removed when `test` ends.
    static func temporaryPath(for test: XCTestCase) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(type(of: test))-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("library.sqlite").path
    }

    /// The payload the store wrote for a record. Read it before the store loads the record: a row the store cannot
    /// decode is moved out of `records`.
    static func payload(path: String, kind: String, id: String) throws -> Data {
        try withDatabase(path, flags: SQLITE_OPEN_READONLY) { db in
            let statement = try prepare(db, "SELECT payload FROM records WHERE kind = ? AND id = ?;", [kind, id])
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
                throw SessionKitError.persistenceFailed("no \(kind) record \(id)")
            }
            return Data(String(cString: text).utf8)
        }
    }

    /// Writes a row the way the shipped build's store did, into a database a `SQLiteSessionStore` has already opened.
    static func write(path: String, kind: String, id: String, itemId: String?, payload: Data) throws {
        try withDatabase(path, flags: SQLITE_OPEN_READWRITE) { db in
            let statement = try prepare(
                db, "INSERT INTO records(kind, id, session_id, item_id, payload) VALUES (?, ?, NULL, ?, ?);",
                [kind, id, itemId, String(decoding: payload, as: UTF8.self)]
            )
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw SessionKitError.persistenceFailed("insert \(kind) \(id)") }
        }
    }

    /// The shipped build's store reads a row with an ISO 8601 date decoder, as `ShippedPacketReader.decodeStoredRecord`
    /// does; this is for a test that checks more than the id that function returns, or a type it has no case for.
    static func decodeInShippedBuild<T: Decodable>(_ type: T.Type, from payload: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: payload)
    }

    private static func withDatabase<T>(_ path: String, flags: Int32, _ body: (OpaquePointer?) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else { throw SessionKitError.persistenceFailed("open") }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private static func prepare(_ db: OpaquePointer?, _ sql: String, _ values: [String?]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw SessionKitError.persistenceFailed("prepare") }
        for (offset, value) in values.enumerated() {
            if let value {
                sqlite3_bind_text(statement, Int32(offset + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(statement, Int32(offset + 1))
            }
        }
        return statement
    }
}
