import Foundation
import SQLite3

/// Plain SQLite access to the file a `SQLiteSessionStore` wrote, so a test can look at the
/// rows themselves (their key, columns and bytes) instead of asking the store, which would
/// answer through the code under test.
enum StoreRawSQL {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Runs one statement on its own connection. `?` placeholders take `bindings` in order; nil binds NULL.
    static func execute(_ sql: String, bindings: [String?] = [], at path: String) throws {
        let database = try open(path)
        defer { sqlite3_close(database) }
        let statement = try prepare(sql, bindings: bindings, database: database)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw Failure(description: "\(String(cString: sqlite3_errmsg(database))): \(sql)")
        }
    }

    static func execute(_ statements: [String], at path: String) throws {
        for sql in statements { try execute(sql, at: path) }
    }

    /// Every row of a SELECT as optional text, one array per row, in the order SQLite returns them.
    static func rows(_ sql: String, bindings: [String?] = [], at path: String) throws -> [[String?]] {
        let database = try open(path)
        defer { sqlite3_close(database) }
        let statement = try prepare(sql, bindings: bindings, database: database)
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_type(statement, column) == SQLITE_NULL
                    ? nil
                    : sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
        }
        return rows
    }

    /// The `id` column of every row of one kind, sorted.
    static func ids(kind: String, at path: String) throws -> [String] {
        try rows("SELECT id FROM records WHERE kind = ? ORDER BY id;", bindings: [kind], at: path).compactMap { $0[0] }
    }

    private static func open(_ path: String) throws -> OpaquePointer {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw Failure(description: "cannot open \(path)")
        }
        sqlite3_busy_timeout(database, 2_000)
        return database
    }

    private static func prepare(_ sql: String, bindings: [String?], database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(description: "\(String(cString: sqlite3_errmsg(database))): \(sql)")
        }
        for (offset, value) in bindings.enumerated() {
            if let value {
                sqlite3_bind_text(statement, Int32(offset + 1), value, -1, transient)
            } else {
                sqlite3_bind_null(statement, Int32(offset + 1))
            }
        }
        return statement
    }
}
