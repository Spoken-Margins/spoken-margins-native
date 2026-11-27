import Foundation
import SQLite3
import XCTest
import SessionKit
import SessionKitPersistence
import SessionKitTestInputs

/// #4675: a reply box is its own record kind, `reply_box`, beside the Library, without changing the database the
/// previous build opens (the #4309 rule). The real Build 29 reader opens a database holding one through
/// `Build29DatabaseFixtureTests` and scripts/check-build29-database.sh.
final class ReplyBoxStoreTests: XCTestCase {
    private func date(_ days: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + days * 86_400) }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory.appending(path: "reply-boxes-\(UUID().uuidString).sqlite").path
    }

    private func sample(created: Double = 1, item: String = "item-1") -> ReplyBoxRecord {
        ReplyBoxRecord(
            box: .random(), linkId: "0123456789abcdef0123456789abcdef", itemId: item, sharedPackageDigest: "sha256:shared",
            createdAt: date(created), expiresAt: date(created + 30), cursor: 3, closed: true, closedAt: date(created + 2),
            lastChecked: date(created + 1), answers: [.init(seq: 2, layerId: "layer-2"), .init(seq: 3, layerId: "layer-3")]
        )
    }

    func testARecordSurvivesARelaunchWithEveryFieldAndItsKey() throws {
        let path = temporaryDatabasePath()
        let record = sample()
        let older = sample(created: 0)
        do {
            let store = try SQLiteSessionStore(path: path)
            try store.saveReplyBox(record)
            try store.saveReplyBox(older)
        }
        let store = try SQLiteSessionStore(path: path)
        let loaded = try store.loadReplyBoxes()
        XCTAssertEqual(loaded.map(\.boxId), [older.boxId, record.boxId], "oldest first")
        XCTAssertEqual(loaded.last, record)
        XCTAssertEqual(loaded.last?.box, record.box, "K comes back and still opens the box")
        XCTAssertEqual(try store.loadReplyBox(id: record.boxId), record)
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }

    func testUpdateAndDeleteTouchOnlyThatRecord() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        let first = sample(), second = sample(created: 2)
        try store.saveReplyBox(first)
        try store.saveReplyBox(second)
        let updated = try store.updateReplyBox(id: first.boxId) { $0.cursor = 9; $0.answers.append(.init(seq: 9, layerId: "l9")) }
        XCTAssertEqual(updated?.cursor, 9)
        XCTAssertEqual(try store.loadReplyBox(id: first.boxId)?.answers.last, .init(seq: 9, layerId: "l9"))
        XCTAssertEqual(try store.loadReplyBox(id: second.boxId), second)
        XCTAssertNil(try store.updateReplyBox(id: "missing") { $0.cursor = 1 }, "no record, nothing made")
        try store.deleteReplyBox(id: first.boxId)
        XCTAssertEqual(try store.loadReplyBoxes(), [second])
    }

    func testAnItemDeleteLeavesTheRecordAndARecordIsInvisibleToEveryOtherRead() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        try store.saveItem(Item(id: "item-1", title: "Shared", mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        try store.saveReplyBox(sample())
        try store.deleteItem(id: "item-1")
        XCTAssertEqual(try store.loadReplyBoxes().count, 1, "deleting the shared item never deletes its box; retention does")
        XCTAssertEqual(try store.listItems(includeDeleted: true).filter { $0.deletedAt == nil }, [])
        XCTAssertEqual(try store.loadItemCollections(), [])
        XCTAssertEqual(try store.loadFollowLists(), [])
        XCTAssertEqual(try store.loadPaperSources(), [])
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }

    func testReplyBoxesLeaveTheSchemaOfBuild29Unchanged() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(Item(id: "article", title: "Article", mediaType: "text", text: "Body text", externalReference: nil, status: "ready"))
        for index in 0..<5 { try store.saveReplyBox(sample(created: Double(index))) }
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), 5)
        let build29Schema = try Self.build29SchemaObjects()
        XCTAssertEqual(try Self.schemaObjects(atPath: path), build29Schema, "no table, column or index is added")
        XCTAssertEqual(try SQLiteSessionStore(path: path).listItems().map(\.id), ["article"])
    }

    func testTheShippedBuildsDatabaseOpensWithABoxAddedAndKeepsEveryRow() throws {
        let fixture = try TestInputs.url(.contracts, "fixtures/persistence/build29.sqlite")
        let copy = FileManager.default.temporaryDirectory.appending(path: "build29-reply-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: fixture, to: copy)
        let before = try SQLiteSessionStore(path: copy.path).listItems(includeDeleted: true).map(\.id)
        do {
            let store = try SQLiteSessionStore(path: copy.path)
            try store.saveReplyBox(sample())
        }
        let reopened = try SQLiteSessionStore(path: copy.path)
        XCTAssertEqual(try reopened.listItems(includeDeleted: true).map(\.id), before)
        XCTAssertEqual(try reopened.loadReplyBoxes().count, 1)
        XCTAssertEqual(try reopened.quarantinedRecordCount(), 0)
        XCTAssertEqual(try Self.recordKinds(atPath: copy.path).filter { $0 == ReplyBoxRecord.recordKind }.count, 1)
    }

    func testTheRecordKindIsTheOneTheDesignNames() {
        XCTAssertEqual(ReplyBoxRecord.recordKind, "reply_box")
    }

    // MARK: Schema

    static func recordKinds(atPath path: String) throws -> [String] {
        try rows(atPath: path, sql: "SELECT kind FROM records;", columns: 1)
    }

    static func schemaObjects(atPath path: String) throws -> [String] {
        try rows(atPath: path, sql: "SELECT type, name, tbl_name, COALESCE(sql, '') FROM sqlite_master ORDER BY type, name;", columns: 4)
    }

    private static func rows(atPath path: String, sql: String, columns: Int32) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw NSError(domain: "ReplyBoxStoreTests", code: 1)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "ReplyBoxStoreTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        var objects: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            objects.append((0..<columns).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }.joined(separator: " | "))
        }
        return objects
    }

    private static func build29SchemaObjects() throws -> [String] {
        let fixture = try TestInputs.url(.contracts, "fixtures/persistence/build29.sqlite")
        let copy = FileManager.default.temporaryDirectory.appending(path: "build29-schema-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: fixture, to: copy)
        return try schemaObjects(atPath: copy.path)
    }
}
