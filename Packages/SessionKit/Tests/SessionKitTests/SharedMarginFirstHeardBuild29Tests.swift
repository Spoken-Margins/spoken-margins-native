import Foundation
import SQLite3
import XCTest
import ShippedSessionKit
@testable import SessionKit
import SessionKitPersistence

/// #469: a shared Margin's record gains `firstHeardAt`. Build 29 must still read the record,
/// so the database it opens keeps working after the listener hears a shared Margin.
final class SharedMarginFirstHeardBuild29Tests: XCTestCase {
    func testBuild29DecodesAnInterjectionRecordSavedWithFirstHeardAt() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "first-heard-b29-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = try SQLiteSessionStore(path: path)
        let layer = SessionKit.ImportedCommentaryLayer(
            id: "layer", itemId: "item", packageDigest: "digest", packageId: "package",
            itemIdentity: SessionKit.SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 1_800_000),
            importedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let margin = SessionKit.ImportedCommentaryInterjection(
            id: "heard", layerId: "layer", packageScopedId: "heard", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            anchorEvidence: SessionKit.PortableAnchorEvidence(anchorType: .text), approvedTranscript: "Listen to this part.",
            audioPath: "ImportedCommentary/heard.m4a", audioDurationMs: 4_000
        )
        _ = try store.importCommentaryLayer(layer, interjections: [margin])
        let heardAt = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(try store.markImportedCommentaryInterjectionHeard(id: "heard", at: heardAt)?.firstHeardAt, heardAt)

        let payload = try storedPayload(path: path, kind: "imported_commentary_interjection", id: "heard")
        XCTAssertTrue(String(decoding: payload, as: UTF8.self).contains("firstHeardAt"), "the record carries the new key")
        // Build 29's store decodes records with an ISO 8601 JSONDecoder.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let shipped = try decoder.decode(ShippedSessionKit.ImportedCommentaryInterjection.self, from: payload)
        XCTAssertEqual(shipped.id, "heard")
        XCTAssertEqual(shipped.layerId, "layer")
        XCTAssertEqual(shipped.approvedTranscript, margin.approvedTranscript)
        XCTAssertEqual(shipped.audioPath, margin.audioPath)
        XCTAssertEqual(shipped.createdAt, margin.createdAt)
    }

    private func storedPayload(path: String, kind: String, id: String) throws -> Data {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else { throw XCTSkip("could not open the database") }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = "SELECT payload FROM records WHERE kind = '\(kind)' AND id = '\(id)';"
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let text = try XCTUnwrap(sqlite3_column_text(statement, 0))
        return Data(String(cString: text).utf8)
    }
}
