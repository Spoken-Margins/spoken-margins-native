import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

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
        let before = try existingReads(store)

        for index in 0..<5 {
            try store.saveItemCollection(ItemCollection(id: "collection-\(index)", name: "C\(index)", itemIDs: ["article"], createdAt: date(Double(index))))
        }
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), 5)
        XCTAssertEqual(SQLiteSessionStore.currentSchemaVersion, 5)
        XCTAssertEqual(try existingReads(store), before)
        XCTAssertEqual(try existingReads(try SQLiteSessionStore(path: path)), before, "and after a reopen")
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

    /// Every existing read that spans a whole record kind, plus the per-item and per-session ones.
    private func existingReads(_ store: SQLiteSessionStore) throws -> [String] {
        [
            "\(try store.loadItem(id: "article"))",
            "\(try store.loadSessions())",
            "\(try store.loadSessions(itemId: "article"))",
            "\(try store.loadInterjections(sessionId: "session"))",
            "\(try store.loadImportedCommentaryLayers())",
            "\(try store.loadImportedCommentaryLayers(itemId: "article"))",
            "\(try store.loadImportedCommentaryInterjections(layerId: "layer"))",
            "\(try store.loadPodcastDownloads())",
            "\(try store.loadPreparedAudioManifests())",
            "\(try store.loadAudioPreparationJobs())",
            "\(try store.loadEpisodeMapPreparationJobs())",
            "\(try store.loadOfflineStorageBudget())",
            "\(try store.loadOwnedOfflineAssets())",
            "\(try store.loadOfflineStorageReservations())",
            "\(try store.loadFeedSubscriptions())",
            "\(try store.loadStructuredDocumentItemIds())",
        ]
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + seconds) }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory.appending(path: "item-collections-\(UUID().uuidString).sqlite").path
    }
}
