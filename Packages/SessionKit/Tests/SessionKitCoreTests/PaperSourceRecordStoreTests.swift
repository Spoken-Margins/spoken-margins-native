import Foundation
import SQLite3
import XCTest
import SessionKit
import SessionKitPersistence
import SessionKitTestInputs

/// #4341: a followed reading list is its own record kind, `paper_source`, beside the Library, without changing the database
/// the previous build opens.
final class PaperSourceRecordStoreTests: XCTestCase {
    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds) }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory.appending(path: "paper-sources-\(UUID().uuidString).sqlite").path
    }

    private func paper(_ key: String, joined: Double?, abstract: String? = nil) -> PaperEntry {
        PaperEntry(
            id: "zotero:2205533:\(key)", provider: .zotero, title: "Paper \(key)", authors: ["Smith", "Jones", "Lee"],
            journal: "Nature", year: 2021, doi: "10.1000/\(key.lowercased())", abstract: abstract,
            storedPDFAttachmentKey: "ATTACH01", pageURL: URL(string: "https://doi.org/10.1000/\(key.lowercased())"),
            dateJoined: joined.map(date)
        )
    }

    private func sample(collection: String = "DMKBHP6P", followed: Double = 1) -> PaperSourceRecord {
        PaperSourceRecord(
            source: .zoteroGroup(groupID: 2205533, collectionKey: collection),
            link: "https://www.zotero.org/groups/2205533/test_items_library/collections/\(collection)",
            title: "APA, 6th edition", followedAt: date(followed), lastOpenedAt: date(5), lastRefreshedAt: date(6),
            isQuiet: false, totalCount: 170,
            entries: [paper("AAAA0001", joined: 3, abstract: "We studied sleep."), paper("AAAA0002", joined: 4)]
        )
    }

    func testARecordSurvivesAReopenWithEveryField() throws {
        let path = temporaryDatabasePath()
        let record = sample()
        do {
            let store = try SQLiteSessionStore(path: path)
            try store.savePaperSource(record)
            try store.savePaperSource(sample(collection: "OTHER001", followed: 0))
        }
        let store = try SQLiteSessionStore(path: path)
        let loaded = try store.loadPaperSources()
        XCTAssertEqual(loaded.map(\.id), ["zotero:group:2205533:collection:OTHER001", "zotero:group:2205533:collection:DMKBHP6P"],
                       "in the order they were followed")
        XCTAssertEqual(loaded.last, record, "every field comes back, the papers included")
        XCTAssertEqual(loaded.last?.entries.map(\.id), ["zotero:2205533:AAAA0002", "zotero:2205533:AAAA0001"], "newest joined first")
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }

    func testDeletingARecordLeavesTheLibraryAndAnItemDeleteLeavesTheRecord() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        try store.saveItem(Item(id: "i1", title: "Added paper", mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        try store.savePaperSource(sample())
        try store.deleteItem(id: "i1")
        XCTAssertEqual(try store.loadPaperSources().count, 1, "deleting an item never deletes a followed list")
        try store.saveItem(Item(id: "i2", title: "Kept", mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        try store.deletePaperSource(id: sample().id)
        XCTAssertEqual(try store.loadPaperSources(), [])
        XCTAssertEqual(try store.loadItem(id: "i2").title, "Kept", "unfollowing leaves the Library alone")
    }

    func testARecordIsInvisibleToEveryOtherRead() throws {
        // The previous build reads every record by an explicit kind, so a paper source must not show up in any of them.
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        try store.savePaperSource(sample())
        XCTAssertEqual(try store.listItems(includeDeleted: true), [])
        XCTAssertEqual(try store.loadItemCollections(), [])
        XCTAssertEqual(try store.loadLibraryFolders(), [])
        XCTAssertEqual(try store.loadFeedSubscriptions(), [])
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }

    func testPaperSourcesLeaveTheSchemaOfBuild29Unchanged() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(Item(id: "article", title: "Article", mediaType: "text", text: "Body text", externalReference: nil, status: "ready"))
        for index in 0..<5 { try store.savePaperSource(sample(collection: "COLL000\(index)")) }
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), 5)
        XCTAssertEqual(try Self.schemaObjects(atPath: path), try Self.build29SchemaObjects(), "no table, column or index is added")
        XCTAssertEqual(try SQLiteSessionStore(path: path).listItems().map(\.id), ["article"])
    }

    func testAPaperThatDoesNotReadIsDroppedAndTheListStands() throws {
        // A later build may store a paper this one can't read; the rest of the list must survive it.
        let encoded = try JSONEncoder().encode(sample())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        entries.append(["provider": "zotero"]) // no id, no title
        entries[0]["aFieldFromLater"] = ["nested": true]
        object["entries"] = entries
        object["anotherFieldFromLater"] = 3
        let decoded = try JSONDecoder().decode(PaperSourceRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.entries.count, 2)
        XCTAssertEqual(decoded.title, "APA, 6th edition")
    }

    func testTheRecordKindAndIdentityAreTheOnesTheDesignNames() {
        XCTAssertEqual(PaperSourceRecord.recordKind, "paper_source")
        XCTAssertEqual(sample().id, "zotero:group:2205533:collection:DMKBHP6P")
        XCTAssertEqual(PaperSource.zoteroUser(userID: 7, collectionKey: nil).identifier, "zotero:user:7")
        XCTAssertTrue(PaperSource.zoteroUser(userID: 7, collectionKey: "ABCD2345").needsZoteroKey)
        XCTAssertFalse(PaperSource.zoteroGroup(groupID: 7, collectionKey: nil).needsZoteroKey)
    }

    func testTheListKeepsTheNewest500AndNoPaperTwice() {
        var record = sample()
        let many = (0..<600).map { paper(String(format: "P%07d", $0), joined: Double($0)) }
        record.apply(title: nil, entries: many + [many[599]], totalCount: 600, at: date(9))
        XCTAssertEqual(record.entries.count, PaperSourceRecord.maximumEntries)
        XCTAssertEqual(record.entries.first?.id, many[599].id)
        XCTAssertEqual(record.entries.last?.id, many[100].id)
        XCTAssertEqual(record.title, "APA, 6th edition", "a read with no name keeps the old one")
        XCTAssertEqual(record.paperCount, 600)
        XCTAssertEqual(record.lastRefreshedAt, date(9))
    }

    // MARK: Schema

    private static func schemaObjects(atPath path: String) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw NSError(domain: "PaperSourceRecordStoreTests", code: 1)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT type, name, tbl_name, COALESCE(sql, '') FROM sqlite_master ORDER BY type, name;", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "PaperSourceRecordStoreTests", code: 2)
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

    private static func build29SchemaObjects() throws -> [String] {
        let fixture = try TestInputs.url(.contracts, "fixtures/persistence/build29.sqlite")
        let copy = FileManager.default.temporaryDirectory.appending(path: "build29-schema-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: fixture, to: copy)
        return try schemaObjects(atPath: copy.path)
    }
}
