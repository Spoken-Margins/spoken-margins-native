import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence

private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// What trashing, restoring and permanently deleting an item does to everything the item owns.
///
/// The older lifecycle tests in `SessionKitCoreTests` save one kind of related record, a Session, and
/// check only that. A delete that left the item's Margins behind, or took a neighbour's records with
/// it, passed them. These tests give two items a full graph of records in a real SQLite file, then
/// read every kind back (and the raw `records` table) after each operation.
///
/// Turns are deliberately not part of the target item's graph here: a turn carries only a session id,
/// no item id, so it is outside what the item-scoped delete matches.
final class SQLiteItemDeletionGraphTests: XCTestCase {
    private var paths: [String] = []

    override func tearDown() {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
        paths = []
        super.tearDown()
    }

    // MARK: Trash and restore

    func testMovingAnItemToTrashKeepsEveryRecordItOwnsAndRestoreBringsBackTheSameItem() throws {
        let (store, _) = try makeStore()
        let target = ItemGraph(itemId: "item-1", withTurn: true)
        let neighbour = ItemGraph(itemId: "item-10", withTurn: true)
        try target.seed(into: store)
        try neighbour.seed(into: store)
        let before = try target.snapshot(from: store)
        let neighbourBefore = try neighbour.snapshot(from: store)
        before.assertEveryKindIsPopulated()

        let trashedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.moveItemToTrash(id: target.itemId, at: trashedAt)

        var trashed = try target.snapshot(from: store)
        XCTAssertEqual(trashed.item?.deletedAt, trashedAt)
        trashed.item?.deletedAt = nil
        XCTAssertEqual(trashed, before, "Trash may only mark the item; its Margins, map, transcript, document and shared layers must all still be there")
        XCTAssertEqual(try neighbour.snapshot(from: store), neighbourBefore, "Trashing one item leaves the next item alone")

        try store.restoreItem(id: target.itemId)

        XCTAssertEqual(try target.snapshot(from: store), before, "Restore brings the item back exactly as it was")
        XCTAssertEqual(try neighbour.snapshot(from: store), neighbourBefore)
    }

    // MARK: Permanent delete

    func testPermanentDeleteRemovesTheWholeGraphOfThatItemAndNothingOfItsNeighbours() throws {
        let (store, path) = try makeStore()
        // "item-1" is a prefix of "item-10": a delete that matched by prefix would take the neighbour too.
        let target = ItemGraph(itemId: "item-1")
        let neighbour = ItemGraph(itemId: "item-10", withTurn: true)
        let other = ItemGraph(itemId: "item-other")
        try target.seed(into: store)
        try neighbour.seed(into: store)
        try other.seed(into: store)
        let neighbourBefore = try neighbour.snapshot(from: store)
        let otherBefore = try other.snapshot(from: store)
        try target.snapshot(from: store).assertEveryKindIsPopulated()
        neighbourBefore.assertEveryKindIsPopulated()
        XCTAssertFalse(try rows(in: path, ownedBy: target).isEmpty)

        try store.moveItemToTrash(id: target.itemId)
        try store.deleteItem(id: target.itemId)

        XCTAssertEqual(try target.snapshot(from: store), ItemGraph.Snapshot.empty,
                       "Nothing the deleted item owned may still load")
        XCTAssertEqual(try rows(in: path, ownedBy: target), [],
                       "Nor may any row remain in the database: this is the owner's own recordings and words")
        XCTAssertEqual(try neighbour.snapshot(from: store), neighbourBefore)
        XCTAssertEqual(try other.snapshot(from: store), otherBefore)
        XCTAssertEqual(try store.listItems(includeDeleted: true).map(\.id).sorted(), ["item-10", "item-other"])
    }

    func testPermanentDeleteOfAnItemThatWasNeverTrashedStillRemovesItsMargins() throws {
        // The store does not enforce the trash boundary (the app checks it first). Whatever calls it,
        // the delete itself must be complete.
        let (store, path) = try makeStore()
        let target = ItemGraph(itemId: "item-solo")
        try target.seed(into: store)

        try store.deleteItem(id: target.itemId)

        XCTAssertEqual(try target.snapshot(from: store), ItemGraph.Snapshot.empty)
        XCTAssertEqual(try rows(in: path, ownedBy: target), [])
    }

    // MARK: Bulk delete

    func testBulkDeleteRemovesEverySelectedGraphAndKeepsActiveAndUnselectedTrashedItems() throws {
        let (store, path) = try makeStore()
        let first = ItemGraph(itemId: "item-trash-one")
        let second = ItemGraph(itemId: "item-trash-two")
        let unselectedTrash = ItemGraph(itemId: "item-trash-three", withTurn: true)
        let active = ItemGraph(itemId: "item-active", withTurn: true)
        for graph in [first, second, unselectedTrash, active] { try graph.seed(into: store) }
        let activeBefore = try active.snapshot(from: store)
        let unselectedBefore = try unselectedTrash.snapshot(from: store)
        try store.moveItemToTrash(id: first.itemId)
        try store.moveItemToTrash(id: second.itemId)
        try store.moveItemToTrash(id: unselectedTrash.itemId)

        try store.deleteItems(ids: [first.itemId, second.itemId, first.itemId])

        XCTAssertEqual(try first.snapshot(from: store), ItemGraph.Snapshot.empty)
        XCTAssertEqual(try second.snapshot(from: store), ItemGraph.Snapshot.empty)
        XCTAssertEqual(try rows(in: path, ownedBy: first), [])
        XCTAssertEqual(try rows(in: path, ownedBy: second), [])
        XCTAssertEqual(try active.snapshot(from: store), activeBefore, "The active item keeps its whole graph, not just its Item row")
        var unselected = try unselectedTrash.snapshot(from: store)
        XCTAssertNotNil(unselected.item?.deletedAt, "A trashed item that was not selected stays in Recently Deleted")
        unselected.item?.deletedAt = nil
        XCTAssertEqual(unselected, unselectedBefore)
        XCTAssertEqual(try store.listItems().map(\.id), [active.itemId])
        XCTAssertEqual(try store.listDeletedItems().map(\.id), [unselectedTrash.itemId])
    }

    /// `deleteItems` promises that emptying Recently Deleted never leaves a partial selection. SQLite can
    /// only refuse a delete part-way through if something makes it; a trigger on the database file does,
    /// the way a full disk or a locked database would in the field.
    func testBulkDeleteThatFailsPartWayLeavesEveryItemIntactAndCanBeRetried() throws {
        let (store, path) = try makeStore()
        // Deleted in sorted order: "item-a" first, then "item-b" which the trigger refuses.
        let first = ItemGraph(itemId: "item-a")
        let second = ItemGraph(itemId: "item-b")
        try first.seed(into: store)
        try second.seed(into: store)
        let firstBefore = try first.snapshot(from: store)
        let secondBefore = try second.snapshot(from: store)
        try store.moveItemToTrash(id: first.itemId)
        try store.moveItemToTrash(id: second.itemId)
        try execute("""
        CREATE TRIGGER refuse_item_b_delete BEFORE DELETE ON records
        WHEN OLD.item_id = 'item-b'
        BEGIN SELECT RAISE(ABORT, 'refused for the test'); END;
        """, at: path)

        XCTAssertThrowsError(try store.deleteItems(ids: [first.itemId, second.itemId]))

        for (graph, original) in [(first, firstBefore), (second, secondBefore)] {
            var current = try graph.snapshot(from: store)
            XCTAssertNotNil(current.item?.deletedAt, "\(graph.itemId) is still in Recently Deleted")
            current.item?.deletedAt = nil
            XCTAssertEqual(current, original, "\(graph.itemId): a failed bulk delete must not remove part of the selection")
        }

        try execute("DROP TRIGGER refuse_item_b_delete;", at: path)
        try store.deleteItems(ids: [first.itemId, second.itemId])

        XCTAssertEqual(try first.snapshot(from: store), ItemGraph.Snapshot.empty)
        XCTAssertEqual(try second.snapshot(from: store), ItemGraph.Snapshot.empty)
        XCTAssertEqual(try rows(in: path, ownedBy: first), [])
        XCTAssertEqual(try rows(in: path, ownedBy: second), [])
    }

    // MARK: Fixtures

    private func makeStore() throws -> (SQLiteSessionStore, String) {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "sessionkit-deletion-graph-\(UUID().uuidString).sqlite").path
        paths.append(path)
        return (try SQLiteSessionStore(path: path), path)
    }

    /// Every row in `records` that belongs to the item by its item id or by one of its sessions.
    private func rows(in path: String, ownedBy graph: ItemGraph) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteItemDeletionGraphTests", code: 1)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = "SELECT kind || ' ' || id FROM records WHERE item_id = ? OR session_id = ? ORDER BY kind, id;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteItemDeletionGraphTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, graph.itemId, -1, transientDestructor)
        sqlite3_bind_text(statement, 2, graph.sessionId, -1, transientDestructor)
        var found: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 0) { found.append(String(cString: raw)) }
        }
        return found
    }

    private func execute(_ sql: String, at path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            throw NSError(domain: "SQLiteItemDeletionGraphTests", code: 3)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteItemDeletionGraphTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))])
        }
    }
}

/// One item and one record of every item-owned kind the Library keeps for it.
private struct ItemGraph {
    var itemId: String
    var withTurn = false
    var sessionId: String { "session-of-\(itemId)" }
    let savedAt = Date(timeIntervalSince1970: 1_690_000_000)

    func seed(into store: SQLiteSessionStore) throws {
        try store.saveItem(Item(id: itemId, title: "Title of \(itemId)", mediaType: "pdf", text: "Text of \(itemId).",
                                externalReference: nil, status: "ready"))
        try store.saveSession(Session(
            id: sessionId, itemId: itemId, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: itemId, position: Position(),
            completionPercent: 10, playbackRate: 1
        ))
        try store.saveInterjection(margin("voice", audioPath: "Interjections/\(itemId)-voice.m4a", words: "Spoken words of \(itemId)."))
        try store.saveInterjection(margin("written", audioPath: nil, words: "Written words of \(itemId)."))
        try store.saveAIJob(AIJob(
            id: "job-\(itemId)", kind: "summary", itemId: itemId, sessionId: sessionId, turnId: nil,
            providerType: "test", model: "test", status: "complete", attempts: 1, lastError: nil,
            messages: ["Summarize \(itemId)."], playbackMode: nil
        ))
        if withTurn {
            try store.saveTurn(ConversationTurn(
                id: "turn-\(itemId)", sessionId: sessionId, role: "assistant", turnType: "summary", status: "complete",
                summary: nil, text: "Summary of the Margins on \(itemId).", rawText: nil, sourceInterjectionIds: ["voice"]
            ))
        }
        try store.saveListeningMap(ListeningMap(
            id: "map-\(itemId)", itemId: itemId, overview: "Overview of \(itemId).",
            chapters: [Chapter(id: "chapter-\(itemId)", title: "Chapter", startChar: 0, endChar: 5, percent: 0)]
        ))
        try store.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: "timeline-\(itemId)", itemId: itemId, createdAt: savedAt,
            timeline: TranscriptTimeline(
                segments: [MediaTimelineSegment(id: "segment-\(itemId)", startMs: 0, endMs: 5_000, text: "Transcript of \(itemId).")],
                chapters: [], durationMs: 5_000
            )
        ))
        try store.saveStructuredDocument(
            StructuredDocumentBuilder.build(
                lines: [StructuredDocumentLine(text: "Document of \(itemId).", role: .body, pageIndex: 0)],
                engine: "pdfkit_baseline", version: 2, pageCount: 1
            ),
            itemId: itemId
        )
        let layer = ImportedCommentaryLayer(
            id: "layer-\(itemId)", itemId: itemId, packageDigest: "digest-\(itemId)", packageId: "package-\(itemId)",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Shared \(itemId)", durationMs: 60_000),
            importedAt: savedAt
        )
        let shared = ImportedCommentaryInterjection(
            id: "shared-\(itemId)", layerId: layer.id, packageScopedId: "shared", createdAt: savedAt,
            anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "Someone else's words on \(itemId).",
            audioPath: "ImportedCommentary/\(itemId).m4a", audioDurationMs: 4_000
        )
        _ = try store.importCommentaryLayer(layer, interjections: [shared])
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "asset-\(itemId)", itemId: itemId, category: .interjection,
            relativePath: "Interjections/\(itemId)-voice.m4a", byteCount: 10, isReproducible: false
        ))
        try store.savePodcastDownload(PodcastDownloadRecord(
            id: "download-\(itemId)", itemId: itemId, remoteURL: "https://example.com/\(itemId).mp3",
            localRelativePath: "PodcastAudio/\(itemId).mp3", state: .availableOffline
        ))
    }

    private func margin(_ id: String, audioPath: String?, words: String) -> Interjection {
        Interjection(
            id: "\(itemId)-\(id)", itemId: itemId, sessionId: sessionId, targetType: .item, targetId: itemId,
            createdAt: savedAt, roughPercent: 10,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 5, anchorBefore: "Before", anchorAfter: "After"),
            audioPath: audioPath, audioStatus: audioPath == nil ? "discarded" : "saved",
            transcriptionStatus: "transcribed", transcript: words, cleanedTranscript: nil, displayText: words, status: "active",
            captureKind: audioPath == nil ? .written : nil
        )
    }

    func snapshot(from store: SQLiteSessionStore) throws -> Snapshot {
        Snapshot(
            item: try? store.loadItem(id: itemId),
            sessions: try store.loadSessions(itemId: itemId),
            margins: try store.loadInterjections(sessionId: sessionId),
            aiJobs: try store.loadAIJobs(sessionId: sessionId),
            turns: try store.loadTurns(sessionId: sessionId),
            listeningMap: try store.loadListeningMap(itemId: itemId),
            transcriptTimeline: try store.loadTranscriptTimeline(itemId: itemId),
            structuredDocument: try store.loadStructuredDocument(itemId: itemId),
            importedLayers: try store.loadImportedCommentaryLayers(itemId: itemId),
            importedMargins: try store.loadImportedCommentaryLayers(itemId: itemId).flatMap {
                try store.loadImportedCommentaryInterjections(layerId: $0.id)
            },
            ownedAssets: try store.loadOwnedOfflineAssets().filter { $0.itemId == itemId },
            podcastDownload: try store.loadPodcastDownload(itemId: itemId)
        )
    }

    struct Snapshot: Equatable {
        var item: Item?
        var sessions: [Session]
        var margins: [Interjection]
        var aiJobs: [AIJob]
        var turns: [ConversationTurn]
        var listeningMap: ListeningMap?
        var transcriptTimeline: SourceTranscriptTimeline?
        var structuredDocument: StructuredDocument?
        var importedLayers: [ImportedCommentaryLayer]
        var importedMargins: [ImportedCommentaryInterjection]
        var ownedAssets: [OwnedOfflineAsset]
        var podcastDownload: PodcastDownloadRecord?

        static let empty = Snapshot(
            item: nil, sessions: [], margins: [], aiJobs: [], turns: [], listeningMap: nil, transcriptTimeline: nil,
            structuredDocument: nil, importedLayers: [], importedMargins: [], ownedAssets: [], podcastDownload: nil
        )

        /// Guards against a fixture that quietly stopped saving a kind, which would make "nothing remains" vacuous.
        func assertEveryKindIsPopulated(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertNotNil(item, file: file, line: line)
            XCTAssertEqual(sessions.count, 1, file: file, line: line)
            XCTAssertEqual(margins.count, 2, "a spoken and a written Margin", file: file, line: line)
            XCTAssertEqual(aiJobs.count, 1, file: file, line: line)
            XCTAssertNotNil(listeningMap, file: file, line: line)
            XCTAssertNotNil(transcriptTimeline, file: file, line: line)
            XCTAssertNotNil(structuredDocument, file: file, line: line)
            XCTAssertEqual(importedLayers.count, 1, file: file, line: line)
            XCTAssertEqual(importedMargins.count, 1, file: file, line: line)
            XCTAssertEqual(ownedAssets.count, 1, file: file, line: line)
            XCTAssertNotNil(podcastDownload, file: file, line: line)
        }
    }
}
