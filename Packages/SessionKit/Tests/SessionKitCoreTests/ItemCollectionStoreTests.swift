import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence
import SessionKitTestInputs

/// #489: named collections of Library items, stored without changing the database Build 29 opens.
final class ItemCollectionStoreTests: XCTestCase {
    func testSaveRenameReorderAndDeleteSurviveAReopen() throws {
        let path = temporaryDatabasePath()
        var course = ItemCollection(id: "course", name: "Course", itemIDs: ["a", "b", "c"], createdAt: date(1))
        let club = ItemCollection(id: "club", name: "Book club", itemIDs: ["b"], createdAt: date(2))
        do {
            let store = try SQLiteSessionStore(path: path)
            try store.saveItemCollection(course)
            try store.saveItemCollection(club)
        }
        do {
            let store = try SQLiteSessionStore(path: path)
            XCTAssertEqual(try store.loadItemCollections(), [course, club])
            course.name = "Spring course"
            course.itemIDs = ["c", "a", "b", "a"]
            course.updatedAt = date(3)
            try store.saveItemCollection(course)
        }
        do {
            let store = try SQLiteSessionStore(path: path)
            let reopened = try store.loadItemCollections()
            XCTAssertEqual(reopened.map(\.name), ["Spring course", "Book club"])
            XCTAssertEqual(reopened.first?.itemIDs, ["c", "a", "b"], "reordered, and an item appears once")
            XCTAssertEqual(reopened.first?.updatedAt, date(3))
            try store.deleteItemCollection(id: "course")
        }
        let store = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try store.loadItemCollections(), [club])
    }

    func testAnItemCanBeInTwoCollections() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        let course = ItemCollection(id: "course", name: "Course", itemIDs: ["shared", "only-course"], createdAt: date(1))
        let club = ItemCollection(id: "club", name: "Club", itemIDs: ["shared"], createdAt: date(2))
        try store.saveItemCollection(course)
        try store.saveItemCollection(club)
        let holding = try store.loadItemCollections().filter { ItemCollectionScope($0).contains(itemID: "shared") }
        XCTAssertEqual(holding.map(\.id), ["course", "club"])
    }

    func testDeletingACollectionNeverDeletesItsItemsOrMargins() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        try seedLibrary(store)
        try store.saveItemCollection(ItemCollection(id: "course", name: "Course", itemIDs: ["article"], createdAt: date(1)))
        try store.deleteItemCollection(id: "course")

        XCTAssertEqual(try store.loadItem(id: "article").title, "Article")
        XCTAssertEqual(try store.loadSessions(itemId: "article").map(\.id), ["session"])
        XCTAssertEqual(try store.loadInterjections(sessionId: "session").map(\.id), ["margin"])
        XCTAssertEqual(try store.loadImportedCommentaryInterjections(layerId: "layer").map(\.id), ["shared-margin"])

        // Deleting an item leaves the collection in place, too.
        try store.saveItemCollection(ItemCollection(id: "club", name: "Club", itemIDs: ["article"], createdAt: date(2)))
        try store.deleteItem(id: "article")
        XCTAssertEqual(try store.loadItemCollections().map(\.id), ["club"])
    }

    func testCollectionsLeaveTheSchemaAndEveryExistingReadUnchanged() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        try seedLibrary(store)
        let before = existingReads(store)

        for index in 0..<5 {
            try store.saveItemCollection(ItemCollection(id: "collection-\(index)", name: "C\(index)", itemIDs: ["article"], createdAt: date(Double(index))))
        }
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), 5)
        XCTAssertEqual(SQLiteSessionStore.currentSchemaVersion, 5)
        // The version number alone would pass a new column or index. The tables and indexes must be
        // exactly what Build 29 wrote (#1048), read from a database its own code created.
        XCTAssertEqual(try Self.schemaObjects(atPath: path), try Self.build29SchemaObjects(),
                       "collections add no table, column or index")
        XCTAssertEqual(existingReads(store), before)
        XCTAssertEqual(before.count, 45, "every load API the store had before collections")
        XCTAssertEqual(existingReads(try SQLiteSessionStore(path: path)), before, "and after a reopen")
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }

    func testScopeAnswersMembership() {
        let scope = ItemCollectionScope(ItemCollection(id: "c", name: "C", itemIDs: ["a", "b"], createdAt: date(0)))
        XCTAssertEqual(scope.collectionID, "c")
        XCTAssertTrue(scope.contains(itemID: "a"))
        XCTAssertTrue(scope.contains(itemID: "b"))
        XCTAssertFalse(scope.contains(itemID: "z"))
        XCTAssertFalse(ItemCollectionScope(ItemCollection(id: "empty", name: "Empty", createdAt: date(0))).contains(itemID: "a"))
    }

    // MARK: Fixtures

    private func seedLibrary(_ store: SQLiteSessionStore) throws {
        try store.saveItem(Item(id: "article", title: "Article", mediaType: "text", text: "Body text", externalReference: nil, status: "ready"))
        try store.saveSession(Session(
            id: "session", itemId: "article", status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: "article", position: Position(charOffset: 3),
            completionPercent: 10, playbackRate: 1
        ))
        try store.saveInterjection(Interjection(
            id: "margin", itemId: "article", sessionId: "session", targetType: .item, targetId: "article",
            createdAt: date(1), roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "A written Margin", status: "active"
        ))
        try store.saveImportedCommentaryLayer(ImportedCommentaryLayer(
            id: "layer", itemId: "article", packageDigest: "digest", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .text, title: "Article"), importedAt: date(1)
        ))
        try store.saveImportedCommentaryInterjection(ImportedCommentaryInterjection(
            id: "shared-margin", layerId: "layer", packageScopedId: "shared-margin", createdAt: date(1),
            anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "Shared words"
        ))
    }

    /// Every public load API the store had before collections, keyed to the seeded records
    /// where it takes an id. A read that throws is compared by its error, so it still counts.
    private func existingReads(_ store: SQLiteSessionStore) -> [String] {
        func read(_ name: String, _ load: () throws -> Any) -> String {
            do { return "\(name): \(try load())" } catch { return "\(name) threw: \(error)" }
        }
        return [
            read("item") { try store.loadItem(id: "article") },
            read("library") { try store.listItems() },
            read("libraryWithDeleted") { try store.listDeletedItems() },
            read("listeningMap") { try store.loadListeningMap(itemId: "article") as Any },
            read("session") { try store.loadSession(id: "session") as Any },
            read("sessionsForItem") { try store.loadSessions(itemId: "article") },
            read("sessions") { try store.loadSessions() },
            read("interjections") { try store.loadInterjections(sessionId: "session") },
            read("shareRevisions") { try store.loadInterjectionShareRevisions(interjectionId: "margin") },
            read("layerById") { try store.loadImportedCommentaryLayer(id: "layer") as Any },
            read("layerByDigest") { try store.loadImportedCommentaryLayer(packageDigest: "digest") as Any },
            read("layers") { try store.loadImportedCommentaryLayers() },
            read("layersForItem") { try store.loadImportedCommentaryLayers(itemId: "article") },
            read("sharedMargins") { try store.loadImportedCommentaryInterjections(layerId: "layer") },
            read("turns") { try store.loadTurns(sessionId: "session") },
            read("aiJobs") { try store.loadAIJobs(sessionId: "session") },
            read("watchPackage") { try store.loadWatchAudioPackage(id: "article") as Any },
            read("watchPackages") { try store.loadWatchAudioPackages(itemId: "article") },
            read("watchSyncEvents") { try store.loadWatchSyncEvents(sessionId: "session") },
            read("watchSyncEvent") { try store.loadWatchSyncEvent(id: "session") as Any },
            read("watchRequests") { try store.loadWatchPackageRequests(itemId: "article") },
            read("timelineById") { try store.loadTranscriptTimeline(id: "article") as Any },
            read("timelineForItem") { try store.loadTranscriptTimeline(itemId: "article") as Any },
            read("audioAssets") { try store.loadAudioAssets(itemId: "article") },
            read("podcastDownload") { try store.loadPodcastDownload(itemId: "article") as Any },
            read("podcastDownloads") { try store.loadPodcastDownloads() },
            read("canonicalSource") { try store.loadCanonicalSource(itemId: "article") as Any },
            read("preparedManifest") { try store.loadPreparedAudioManifest(id: "article") as Any },
            read("preparedManifestsForItem") { try store.loadPreparedAudioManifests(itemId: "article") },
            read("preparedManifests") { try store.loadPreparedAudioManifests() },
            read("preparationJobs") { try store.loadAudioPreparationJobs() },
            read("fingerprintSpine") { try store.loadEditionFingerprintSpine(itemId: "article") as Any },
            read("phraseSketch") { try store.loadTranscriptPhraseSketch(itemId: "article") as Any },
            read("mapProposals") { try store.loadPortableListeningMapProposals(itemId: "article") },
            read("mapProjection") { try store.loadResolvedListeningMapProjection(itemId: "article") as Any },
            read("episodeMapJobs") { try store.loadEpisodeMapPreparationJobs() },
            read("storageBudget") { try store.loadOfflineStorageBudget() },
            read("ownedAssets") { try store.loadOwnedOfflineAssets() },
            read("reservations") { try store.loadOfflineStorageReservations() },
            read("feedSubscriptions") { try store.loadFeedSubscriptions() },
            read("feedEntries") { try store.loadFeedEntries(subscriptionId: nil) },
            read("feedRefreshState") { try store.loadFeedRefreshState(subscriptionId: "feed") as Any },
            read("suggestionDecision") { try store.loadSourceSuggestionDecision(sourceId: "feed") as Any },
            read("structuredDocument") { try store.loadStructuredDocument(itemId: "article") as Any },
            read("structuredDocumentIds") { try store.loadStructuredDocumentItemIds() },
        ]
    }

    /// Every table and index in the database, as SQLite stores its definition.
    private static func schemaObjects(atPath path: String) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw NSError(domain: "ItemCollectionStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot open \(path)"])
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT type, name, tbl_name, COALESCE(sql, '') FROM sqlite_master ORDER BY type, name;", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "ItemCollectionStoreTests", code: 2)
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

    /// The schema of Contracts/fixtures/persistence/build29.sqlite, written by Build 29's own code.
    /// Read from a copy, so opening it leaves no WAL files in the checkout.
    private static func build29SchemaObjects() throws -> [String] {
        let fixture = try TestInputs.url(.contracts, "fixtures/persistence/build29.sqlite")
        let copy = FileManager.default.temporaryDirectory.appending(path: "build29-schema-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: fixture, to: copy)
        return try schemaObjects(atPath: copy.path)
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds) }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory.appending(path: "item-collections-\(UUID().uuidString).sqlite").path
    }
}
