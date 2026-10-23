import Foundation
import SessionKit
import SessionKitPersistence
import ShippedSessionKit
import SQLite3
import XCTest

/// #1819 point 4: an installed voice is a Storage row, and Build 29 must still open the database that holds
/// it. Build 29 decodes `OfflineAssetCategory` strictly, so the row is saved to real SQLite by this build
/// and its stored bytes are decoded with Build 29's frozen types (#437).
final class DownloadedVoiceShippedReaderTests: XCTestCase {
    func testBuild29DecodesTheStorageRowOfADownloadedVoice() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("voice-row-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("library.sqlite").path
        let store = try SQLiteSessionStore(path: path)
        let row = VoiceCatalogCoordinator.ledgerAsset(voiceId: "supertonic-3-int8", byteCount: 144_000_000, at: Date(timeIntervalSince1970: 1_800_000_000))
        try store.saveOwnedOfflineAsset(row)

        let payload = try XCTUnwrap(Self.storedPayload(path: path, id: row.id))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let shipped = try decoder.decode(ShippedSessionKit.OwnedOfflineAsset.self, from: payload)
        XCTAssertEqual(shipped.id, "voice-model-supertonic-3-int8")
        XCTAssertEqual(shipped.category.rawValue, row.category.rawValue)
        XCTAssertEqual(shipped.relativePath, "Voices/supertonic-3-int8")
        XCTAssertEqual(shipped.byteCount, 144_000_000)
        XCTAssertFalse(shipped.isReproducible)
    }

    private static func storedPayload(path: String, id: String) throws -> Data? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT payload FROM records WHERE kind = 'owned_offline_asset' AND id = ?;", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if sqlite3_column_type(statement, 0) == SQLITE_BLOB, let bytes = sqlite3_column_blob(statement, 0) {
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        }
        guard let text = sqlite3_column_text(statement, 0) else { return nil }
        return Data(String(cString: text).utf8)
    }
}
