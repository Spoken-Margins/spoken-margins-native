import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #3769: the Library's first read carries the collections and the imported-folder records, so a collection's items are
/// never drawn flat in the first frame, even while another writer holds the store. Kept from the retired folder listing's
/// tests (owner, 2026-11-20); the listing is now `LibraryCollectionListEngine`.
final class LibraryReadSnapshotFolderTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func folder(_ id: String, items: [String]) -> LibraryFolderRecord {
        LibraryFolderRecord(
            id: id, sourcePath: "/x/\(id)", importedAt: base, trashedAt: nil, notAdded: [],
            members: items.enumerated().map { index, itemID in
                LibraryFolderRecord.Member(key: "\(index + 1).pdf", kind: .pdf, name: "\(index + 1).pdf", itemID: itemID,
                                           addedAt: base, state: .added)
            })
    }

    func testTheSnapshotCarriesCollectionsAndFolderRecordsWhileAWriterHoldsTheStore() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "folder-query-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        for index in 1...3 {
            try store.saveItem(Item(id: "i\(index)", title: "Item \(index)", mediaType: "text", text: "Body", externalReference: nil, status: "ready"))
        }
        try store.saveItemCollection(ItemCollection(id: "f", name: "Daily Brief", itemIDs: ["i1", "i2"], createdAt: base))
        try store.saveLibraryFolder(folder("f", items: ["i1", "i2"]))

        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &writer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK, "another writer holds the store")
        defer { sqlite3_exec(writer, "COMMIT", nil, nil, nil); sqlite3_close(writer) }

        // The writer stays open until the defer, so a read that waited for it could only end in SQLITE_BUSY after the
        // store's 1 s busy timeout: the query loop stops and returns [] (or the read throws and gives nil). Either way
        // the checks below fail on state, not on a wall-clock ceiling a busy runner can miss.
        let snapshot = try LibraryReadSnapshot.read(store: store)
        XCTAssertEqual(sqlite3_get_autocommit(writer), 0, "the writer still held the store while the Library was read")
        XCTAssertEqual(snapshot.collections?.map(\.id), ["f"], "the collections were read past the writer")
        XCTAssertEqual(snapshot.libraryFolders?.map(\.id), ["f"], "the folder records were read past the writer")

        let rows = LibraryRowBuilder.rows(from: snapshot, context: StartupAudioContext(hasAcceptedCurrentTerms: true, hasSupertonicVoice: true))
        let listing = LibraryCollectionListEngine.listing(
            rows: rows, collections: snapshot.collections ?? [], imported: snapshot.libraryFolders ?? [],
            query: LibraryQuery(), mode: .collections, currentItemID: nil)
        XCTAssertEqual(Set(listing.map(\.id)), [LibraryCollectionRow.rowID(collectionID: "f"), "i3"],
                       "the collection's items are never listed flat in the first frame")
    }

    func testASnapshotBuiltTheOldWayHasNoFolders() {
        let snapshot = LibraryReadSnapshot(items: [Item](), sessions: [], manifests: [], jobs: [], downloads: [])
        XCTAssertNil(snapshot.collections, "nothing was read")
        XCTAssertNil(snapshot.libraryFolders, "nothing was read, which is not the same as no folders")
    }
}
