import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence
import SessionKitTestInputs

/// #3769: a Library folder's record, kept as its own record kind beside the collection, without changing the database the
/// previous build opens.
final class LibraryFolderRecordStoreTests: XCTestCase {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds) }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory.appending(path: "library-folders-\(UUID().uuidString).sqlite").path
    }

    private func sample(id: String = "folder", imported: Double = 1) -> LibraryFolderRecord {
        LibraryFolderRecord(
            id: id, sourcePath: "/Users/x/Documents/Daily Brief", bookmark: Data([1, 2, 3]),
            source: .quickFolder(name: "Clippings"), importedAt: date(imported), trashedAt: nil,
            skippedOtherCount: 2, adoptedCount: 1, capped: true,
            notAdded: [.init(key: "p.spokenmargins", name: "p.spokenmargins", reason: "Margins packets open on their own")],
            members: [
                .init(key: "1.pdf", kind: .pdf, name: "1.pdf", sha256: "abc", itemID: "i1", addedAt: date(1), state: .added),
                .init(key: "2.pdf", kind: .pdf, name: "2.pdf", sha256: "def", itemID: "i2", addedAt: date(1), state: .failed,
                      reason: "Couldn't be opened", retryable: true),
                .init(key: "2.pdf#updated-2", kind: .pdf, name: "2.pdf", sha256: "ghi", itemID: "i3", addedAt: date(2),
                      state: .adding, updatedCopyOf: "2.pdf"),
                .init(key: "list.json#001", kind: .link, name: "A page", address: "https://example.com/a", addedAt: date(1),
                      state: .removed),
            ])
    }

    func testARecordSurvivesAReopenAndDeletingItLeavesTheCollection() throws {
        let path = temporaryDatabasePath()
        var folder = sample()
        let collection = ItemCollection(id: "folder", name: "Daily Brief", itemIDs: ["i1"], createdAt: date(1))
        do {
            let store = try SQLiteSessionStore(path: path)
            try store.saveItemCollection(collection)
            try store.saveLibraryFolder(folder)
            try store.saveLibraryFolder(sample(id: "other", imported: 0))
        }
        do {
            let store = try SQLiteSessionStore(path: path)
            XCTAssertEqual(try store.loadLibraryFolders().map(\.id), ["other", "folder"], "oldest import first")
            XCTAssertEqual(try store.loadLibraryFolders().last, folder, "every field comes back, including the member table")
            folder.trashedAt = date(9)
            folder.members[0].state = .removed
            try store.saveLibraryFolder(folder)
        }
        do {
            let store = try SQLiteSessionStore(path: path)
            let reopened = try XCTUnwrap(try store.loadLibraryFolders().last)
            XCTAssertEqual(reopened.trashedAt, date(9))
            XCTAssertTrue(reopened.isTrashed)
            XCTAssertEqual(reopened.members[0].state, .removed)
            try store.deleteLibraryFolder(id: "other")
            try store.deleteLibraryFolder(id: "folder")
            XCTAssertEqual(try store.loadLibraryFolders(), [])
            XCTAssertEqual(try store.loadItemCollections(), [collection], "only the record goes")
        }
    }

    func testACollectionSavedWithoutAFolderRecordStillLoadsAsAnOrdinaryCollection() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        let plain = ItemCollection(id: "plain", name: "Course", itemIDs: ["a"], createdAt: date(1))
        try store.saveItemCollection(plain)
        XCTAssertEqual(try store.loadItemCollections(), [plain])
        XCTAssertEqual(try store.loadLibraryFolders(), [])
    }

    func testAFolderRecordIsInvisibleToTheCollectionRead() throws {
        // The previous build reads collections by their own kind, so a folder record must never show up there.
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        try store.saveLibraryFolder(sample())
        XCTAssertEqual(try store.loadItemCollections(), [])
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }

    func testOrphanCleanUpDropsOnlyTheRecordWhenAnOlderBuildDeletedTheCollection() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        try store.saveItem(Item(id: "i1", title: "One", mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        try store.saveItemCollection(ItemCollection(id: "kept", name: "Kept", itemIDs: ["i1"], createdAt: date(1)))
        try store.saveItemCollection(ItemCollection(id: "gone", name: "Gone", itemIDs: ["i1"], createdAt: date(2)))
        try store.saveLibraryFolder(sample(id: "kept"))
        try store.saveLibraryFolder(sample(id: "gone"))
        try store.deleteItemCollection(id: "gone") // what an older build does from its collection screen

        let orphans = LibraryFolderOrphanRule.orphanedFolderIDs(folders: try store.loadLibraryFolders(), collections: try store.loadItemCollections())
        XCTAssertEqual(orphans, ["gone"])
        for id in orphans { try store.deleteLibraryFolder(id: id) }

        XCTAssertEqual(try store.loadLibraryFolders().map(\.id), ["kept"])
        XCTAssertEqual(try store.loadItem(id: "i1").title, "One", "the items stay")
    }

    func testDeletingAnItemOrACollectionNeverTouchesTheFolderRecordsOfOthers() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        try store.saveItem(Item(id: "i1", title: "One", mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        try store.saveItemCollection(ItemCollection(id: "folder", name: "Brief", itemIDs: ["i1"], createdAt: date(1)))
        try store.saveLibraryFolder(sample())
        try store.deleteItem(id: "i1")
        XCTAssertEqual(try store.loadLibraryFolders().map(\.id), ["folder"], "an item delete leaves the record, whose members name it")
    }

    func testFolderRecordsLeaveTheSchemaAndTheOtherReadsUnchanged() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(Item(id: "article", title: "Article", mediaType: "text", text: "Body text", externalReference: nil, status: "ready"))
        let libraryBefore = try store.listItems().map(\.id)
        for index in 0..<5 {
            try store.saveLibraryFolder(sample(id: "folder-\(index)"))
        }
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), 5)
        XCTAssertEqual(SQLiteSessionStore.currentSchemaVersion, 5)
        let schemaNow = try Self.schemaObjects(atPath: path)
        let schemaOfBuild29 = try Self.build29SchemaObjects()
        XCTAssertEqual(schemaNow, schemaOfBuild29, "no table, column or index is added")
        XCTAssertEqual(try store.listItems().map(\.id), libraryBefore)
        XCTAssertEqual(try SQLiteSessionStore(path: path).listItems().map(\.id), libraryBefore, "and after a reopen")
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }

    func testTheRecordKindIsTheOneTheDesignNames() {
        XCTAssertEqual(LibraryFolderRecord.recordKind, "library_folder")
    }

    // MARK: Schema

    private static func schemaObjects(atPath path: String) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw NSError(domain: "LibraryFolderRecordStoreTests", code: 1)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT type, name, tbl_name, COALESCE(sql, '') FROM sqlite_master ORDER BY type, name;", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "LibraryFolderRecordStoreTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        var objects: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            objects.append((0..<4).map { column in
                sqlite3_column_text(statement, Int32(column)).map { String(cString: $0) } ?? ""
            }.joined(separator: " | "))
        }
        return objects
    }

    /// The schema of Contracts/fixtures/persistence/build29.sqlite, written by Build 29's own code, read from a copy.
    private static func build29SchemaObjects() throws -> [String] {
        let fixture = try TestInputs.url(.contracts, "fixtures/persistence/build29.sqlite")
        let copy = FileManager.default.temporaryDirectory.appending(path: "build29-schema-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: fixture, to: copy)
        return try schemaObjects(atPath: copy.path)
    }
}
