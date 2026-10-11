import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #1052: an older build opened the shared database, couldn't decode a newer build's Margin, and moved it from
/// `records` to `quarantined_records`. When this build opens the file and can read the row, it goes back.
///
/// The older build is played by `quarantineLikeAnOlderBuild`, which does what `SQLiteSessionStore.quarantine` does
/// on a decode failure: copies the row's bytes and the decoder's error to `quarantined_records`, and deletes it
/// from `records`. The current store can't play it: it decodes whatever this build knows.
final class SQLiteQuarantineRestoreTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appending(path: "library.sqlite").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "sessionkit-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private let item = #"{"id":"item-1","title":"Article","mediaType":"text","text":"Body.","status":"ready"}"#
    private let session = #"{"id":"session-1","itemId":"item-1","status":"in_progress","phase":"item_playback","currentTargetType":"item_text_tts","currentTargetId":"item-1","playbackRate":1,"completionPercent":10,"position":{"charOffset":3}}"#
    private func margin(_ id: String, captureKind: String = "written") -> String {
        #"{"id":"\#(id)","sessionId":"session-1","itemId":"item-1","targetType":"item","targetId":"item-1","status":"active","audioStatus":"none","transcriptionStatus":"transcribed","transcript":"A note.","displayText":"A note.","roughPercent":10,"createdAt":"2026-01-02T03:04:05Z","captureKind":"\#(captureKind)","anchor":{"anchorType":"text","startChar":1,"endChar":4,"anchorBefore":"","anchorAfter":"","playbackRateObserved":1}}"#
    }

    private func seed(margins: [(id: String, payload: String)]) throws {
        _ = try SQLiteSessionStore(path: path)
        try insert(kind: "item", id: "item-1", sessionId: nil, itemId: "item-1", payload: item)
        try insert(kind: "session", id: "session-1", sessionId: "session-1", itemId: "item-1", payload: session)
        for margin in margins {
            try insert(kind: "interjection", id: "session-1::\(margin.id)", sessionId: "session-1", itemId: "item-1", payload: margin.payload)
        }
    }

    private func insert(kind: String, id: String, sessionId: String?, itemId: String?, payload: String, updatedAt: String = "2026-01-02 03:04:05") throws {
        try StoreRawSQL.execute("INSERT INTO records(kind,id,session_id,item_id,payload,updated_at) VALUES(?,?,?,?,?,?);",
                                bindings: [kind, id, sessionId, itemId, payload, updatedAt], at: path)
    }

    private func quarantineLikeAnOlderBuild(kind: String, id: String, error: String = "dataCorrupted: Cannot initialize InterjectionCaptureKind from invalid String value written") throws {
        try StoreRawSQL.execute("""
            INSERT INTO quarantined_records(kind, id, payload, decode_error, quarantined_at)
            SELECT kind, id, payload, ?, '2026-02-03 04:05:06' FROM records WHERE kind = ? AND id = ?;
            """, bindings: [error, kind, id], at: path)
        try StoreRawSQL.execute("DELETE FROM records WHERE kind = ? AND id = ?;", bindings: [kind, id], at: path)
    }

    private func quarantinedRows() throws -> [[String?]] {
        try StoreRawSQL.rows("SELECT kind, id, payload, decode_error, quarantined_at FROM quarantined_records ORDER BY kind, id;", at: path)
    }

    private func liveRows() throws -> [[String?]] {
        try StoreRawSQL.rows("SELECT kind, id, session_id, item_id, payload, updated_at FROM records ORDER BY kind, id;", at: path)
    }

    func testAMarginAnOlderBuildSetAsideIsBackInTheLibraryWhenThisBuildOpensIt() throws {
        let payload = margin("note-1")
        try seed(margins: [("note-1", payload)])
        let before = try liveRows()
        try quarantineLikeAnOlderBuild(kind: "interjection", id: "session-1::note-1")
        XCTAssertEqual(try quarantinedRows().count, 1)
        XCTAssertEqual(try StoreRawSQL.ids(kind: "interjection", at: path), [], "the older build deleted it from records")

        let store = try SQLiteSessionStore(path: path)

        XCTAssertEqual(try store.loadInterjections(sessionId: "session-1").map(\.id), ["note-1"])
        XCTAssertEqual(try store.loadInterjections(itemId: "item-1").map(\.id), ["note-1"], "it is found by item too")
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
        let after = try liveRows()
        XCTAssertEqual(after.map { Array($0[0...4]) }, before.map { Array($0[0...4]) },
                       "same kind, id, session, item and bytes as before it was set aside")
        XCTAssertEqual(after.first { $0[0] == "interjection" }?[5], "2026-02-03 04:05:06", "ordered by when it was set aside, the time the file still has")
    }

    func testARowThisBuildStillCannotReadStaysQuarantinedByteForByteAndIsNotRetriedIntoAnything() throws {
        try seed(margins: [])
        let unreadable = #"{"id":"future","sessionId":"session-1","anchor":{"anchorType":{"a":"shape this build lacks"}}}"#
        try StoreRawSQL.execute("INSERT INTO quarantined_records(kind,id,payload,decode_error,quarantined_at) VALUES('interjection','session-1::future',?,'older error','2026-02-03 04:05:06');",
                                bindings: [unreadable], at: path)
        try StoreRawSQL.execute("INSERT INTO quarantined_records(kind,id,payload,decode_error,quarantined_at) VALUES('future_kind','fk',?,'no such kind','2026-02-03 04:05:07');",
                                bindings: [#"{"valid":"json for a kind this build has no rule for"}"#], at: path)
        let quarantinedBefore = try quarantinedRows()
        let liveBefore = try liveRows()

        for _ in 0..<3 { _ = try SQLiteSessionStore(path: path) }

        XCTAssertEqual(try quarantinedRows(), quarantinedBefore, "payload, error text and time are exactly as they were")
        XCTAssertEqual(try liveRows(), liveBefore, "nothing was added to records")
    }

    func testOnlyTheRowsThisBuildCanReadComeBackFromAMixedQuarantine() throws {
        try seed(margins: [("good", margin("good")), ("bad", margin("bad"))])
        try quarantineLikeAnOlderBuild(kind: "interjection", id: "session-1::good")
        try quarantineLikeAnOlderBuild(kind: "interjection", id: "session-1::bad")
        // This one stays unreadable for this build too.
        try StoreRawSQL.execute("UPDATE quarantined_records SET payload = ? WHERE id = 'session-1::bad';",
                                bindings: [margin("bad", captureKind: "somethingFromTheFuture")], at: path)
        let badRow = try quarantinedRows().first { $0[1] == "session-1::bad" }

        let store = try SQLiteSessionStore(path: path)

        XCTAssertEqual(try store.loadInterjections(sessionId: "session-1").map(\.id), ["good"])
        XCTAssertEqual(try quarantinedRows(), [try XCTUnwrap(badRow)])
        XCTAssertEqual(try store.quarantinedRecordCount(), 1)
    }

    func testALiveRowSavedAfterTheQuarantineIsNotOverwrittenByTheOldOne() throws {
        try seed(margins: [("note-1", margin("note-1"))])
        try quarantineLikeAnOlderBuild(kind: "interjection", id: "session-1::note-1")
        let newer = margin("note-1").replacingOccurrences(of: "A note.", with: "The newer words.")
        try insert(kind: "interjection", id: "session-1::note-1", sessionId: "session-1", itemId: "item-1", payload: newer, updatedAt: "2026-03-04 05:06:07")
        let liveBefore = try liveRows()
        let quarantinedBefore = try quarantinedRows()

        _ = try SQLiteSessionStore(path: path)

        XCTAssertEqual(try liveRows(), liveBefore, "the newer save is untouched")
        XCTAssertEqual(try quarantinedRows(), quarantinedBefore, "and the older bytes are kept, not discarded")
    }

    func testItemsSessionsAndImportedMarginsComeBackWithTheColumnsTheirSavePathSets() throws {
        let writer = try SQLiteSessionStore(path: path)
        try insert(kind: "item", id: "item-1", sessionId: nil, itemId: "item-1", payload: item)
        try insert(kind: "session", id: "session-1", sessionId: "session-1", itemId: "item-1", payload: session)
        let layer = ImportedCommentaryLayer(
            id: "layer-1", itemId: "item-1", packageDigest: "digest-1", packageId: "package-1",
            itemIdentity: SharedItemIdentity(itemType: .pdf, title: "Article", durationMs: nil),
            importedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let imported = ImportedCommentaryInterjection(
            id: "imported-1", layerId: layer.id, packageScopedId: "m1", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "Look at the methods."
        )
        _ = try writer.importCommentaryLayer(layer, interjections: [imported])
        let before = try liveRows()
        for row in before { try quarantineLikeAnOlderBuild(kind: try XCTUnwrap(row[0]), id: try XCTUnwrap(row[1])) }
        XCTAssertEqual(try liveRows().count, 0)

        let store = try SQLiteSessionStore(path: path)

        XCTAssertEqual(try liveRows().map { Array($0[0...4]) }, before.map { Array($0[0...4]) })
        XCTAssertEqual(try store.listItems().map(\.id), ["item-1"])
        XCTAssertEqual(try store.loadSessions().map(\.id), ["session-1"])
        XCTAssertEqual(try store.loadImportedCommentaryInterjections(layerId: "layer-1").map(\.id), ["imported-1"])
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }

    func testRestoringChangesNeitherTheSchemaVersionNorAnyTableShape() throws {
        try seed(margins: [("note-1", margin("note-1"))])
        try quarantineLikeAnOlderBuild(kind: "interjection", id: "session-1::note-1")
        let shapeSQL = "SELECT name, sql FROM sqlite_master WHERE type IN ('table','index') AND name NOT LIKE 'sqlite_%' ORDER BY name;"
        let versionSQL = "SELECT key, value FROM metadata ORDER BY key;"
        let shapeBefore = try StoreRawSQL.rows(shapeSQL, at: path)
        let versionBefore = try StoreRawSQL.rows(versionSQL, at: path)

        _ = try SQLiteSessionStore(path: path)

        XCTAssertEqual(try StoreRawSQL.rows(shapeSQL, at: path), shapeBefore, "no table, column or index was added")
        XCTAssertEqual(try StoreRawSQL.rows(versionSQL, at: path), versionBefore)
        XCTAssertEqual(versionBefore, [["schema_version", "5"]])
    }

    func testASessionMarginWithTheOldUnprefixedIdIsLeftInQuarantine() throws {
        try seed(margins: [])
        try insert(kind: "interjection", id: "note-legacy", sessionId: "session-1", itemId: "item-1", payload: margin("note-legacy"))
        try quarantineLikeAnOlderBuild(kind: "interjection", id: "note-legacy")
        let quarantinedBefore = try quarantinedRows()

        _ = try SQLiteSessionStore(path: path)

        XCTAssertEqual(try quarantinedRows(), quarantinedBefore, "a bare id would sit beside the session::id row later saves write")
        XCTAssertEqual(try StoreRawSQL.ids(kind: "interjection", at: path), [])
    }

    func testAPacketImportedAgainWhileItsLayerWasSetAsideIsNotShownTwice() throws {
        let writer = try SQLiteSessionStore(path: path)
        try insert(kind: "item", id: "item-1", sessionId: nil, itemId: "item-1", payload: item)
        func layer(_ id: String) -> ImportedCommentaryLayer {
            ImportedCommentaryLayer(id: id, itemId: "item-1", packageDigest: "digest-1", packageId: "package-1",
                                    itemIdentity: SharedItemIdentity(itemType: .pdf, title: "Article", durationMs: nil),
                                    importedAt: Date(timeIntervalSince1970: 1_700_000_000))
        }
        func margin(_ id: String, layer: String) -> ImportedCommentaryInterjection {
            ImportedCommentaryInterjection(id: id, layerId: layer, packageScopedId: "m1", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                           anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "Words.")
        }
        _ = try writer.importCommentaryLayer(layer("layer-old"), interjections: [margin("margin-old", layer: "layer-old")])
        try quarantineLikeAnOlderBuild(kind: "imported_commentary_layer", id: "layer-old")
        try quarantineLikeAnOlderBuild(kind: "imported_commentary_interjection", id: "margin-old")
        _ = try writer.importCommentaryLayer(layer("layer-new"), interjections: [margin("margin-new", layer: "layer-new")])

        let store = try SQLiteSessionStore(path: path)

        XCTAssertEqual(try store.loadImportedCommentaryLayers().map(\.id), ["layer-new"])
        XCTAssertEqual(try quarantinedRows().map { $0[1] }, ["margin-old", "layer-old"], "set aside, not deleted")
    }
}
