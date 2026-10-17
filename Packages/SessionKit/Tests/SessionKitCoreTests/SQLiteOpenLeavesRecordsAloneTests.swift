import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence
import SessionKitTestInputs

/// Opening, reading and saving something unrelated must not touch the bytes of any other
/// row. A build that normalizes records on open (decode, then encode) would drop every key
/// a newer or older build wrote, change `updated_at` (which orders lists), and rewrite the
/// whole Library the first time it is launched.
///
/// `testVersionFiveLibraryOpensWithoutRewritingKnownOrUnknownRecords` only checks that the
/// item payload still `contains("Quality Author")`, which a decode and re-encode keeps.
/// These tests compare every column of every row before and after.
final class SQLiteOpenLeavesRecordsAloneTests: XCTestCase {
    private struct Snapshot: Equatable {
        var records: [[String?]]
        var metadata: [[String?]]
        var quarantined: [[String?]]
    }

    private var directory: URL!
    private var path: String { directory.appending(path: "library.sqlite").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "sessionkit-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOpeningAndReadingALibraryLeavesEveryRowByteForByte() throws {
        try seedVersionFiveLibrary()
        let before = try snapshot()
        XCTAssertEqual(before.records.count, 6)

        let store = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try snapshot(), before, "opening a schema 5 library must not rewrite, re-key or touch any row")

        XCTAssertEqual(try store.listItems().map(\.id), ["item-v5"])
        XCTAssertEqual(try store.loadSessions().map(\.id), ["session-v5"])
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-v5").map(\.id), ["note-v5"])
        XCTAssertEqual(try snapshot(), before, "reading the Library must not write")
    }

    func testSavingSomethingUnrelatedAddsOneRowAndChangesNoOther() throws {
        try seedVersionFiveLibrary()
        let before = try snapshot()

        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(Item(id: "item-new", title: "New", mediaType: "text", text: "New text.", externalReference: "manual-import", status: "ready"))

        let after = try snapshot()
        XCTAssertEqual(after.records.filter { !before.records.contains($0) }.map { $0[1] }, ["item-new"],
                       "the only row that is new or different is the saved item")
        XCTAssertEqual(after.records.count, before.records.count + 1)
        XCTAssertEqual(after.metadata, before.metadata)
        XCTAssertEqual(after.quarantined, [], "the deliberately undecodable rows of other kinds were never read, so they are not quarantined")
    }

    func testTheKeysAnotherBuildWroteSurviveOpeningTheLibrary() throws {
        try seedVersionFiveLibrary()
        _ = try SQLiteSessionStore(path: path)

        let payload = try XCTUnwrap(try StoreRawSQL.rows("SELECT payload FROM records WHERE id = 'item-v5';", at: path).first?[0])
        XCTAssertTrue(payload.contains(#""futureField":{"nested":[1,2,{"deep":true}]}"#), "a key this build does not know is still in the stored item: \(payload)")
        XCTAssertEqual(try StoreRawSQL.rows("SELECT payload FROM records WHERE kind = 'future_kind';", at: path).first?[0], #"{"anything":"a kind this build has never heard of"}"#)
    }

    func testTheRealBuild29LibraryIsNotRewrittenByOpeningIt() throws {
        let fixture = try TestInputs.url(.contracts, "fixtures/persistence/build29.sqlite")
        try FileManager.default.copyItem(at: fixture, to: URL(fileURLWithPath: path))
        let before = try snapshot()
        XCTAssertEqual(before.records.count, 15)

        let store = try SQLiteSessionStore(path: path)
        _ = try store.listItems(includeDeleted: true)
        _ = try store.loadSessions()

        XCTAssertEqual(try snapshot(), before)
    }

    // MARK: Fixture

    private func snapshot() throws -> Snapshot {
        Snapshot(
            records: try StoreRawSQL.rows("SELECT kind, id, session_id, item_id, payload, updated_at FROM records ORDER BY kind, id;", at: path),
            metadata: try StoreRawSQL.rows("SELECT key, value FROM metadata ORDER BY key;", at: path),
            quarantined: try StoreRawSQL.rows("SELECT kind, id, payload FROM quarantined_records ORDER BY kind, id;", at: path)
        )
    }

    private func seedVersionFiveLibrary() throws {
        try StoreRawSQL.execute([
            "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
            "INSERT INTO metadata(key,value) VALUES('schema_version','5');",
            "CREATE TABLE records (kind TEXT NOT NULL, id TEXT NOT NULL, session_id TEXT, item_id TEXT, payload TEXT NOT NULL, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(kind,id));",
            "CREATE TABLE quarantined_records (kind TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, decode_error TEXT NOT NULL, quarantined_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(kind,id));"
        ], at: path)
        let item = #"{"futureField":{"nested":[1,2,{"deep":true}]},"id":"item-v5","title":"Existing","mediaType":"text","text":"Still here.","status":"ready","author":"Quality Author","sourceTitle":"Quality Source"}"#
        let session = #"{"id":"session-v5","itemId":"item-v5","status":"in_progress","phase":"item_playback","currentTargetType":"item_text_tts","currentTargetId":"item-v5","playbackRate":1.25,"completionPercent":40,"position":{"charOffset":12}}"#
        let margin = #"{"id":"note-v5","sessionId":"session-v5","itemId":"item-v5","targetType":"item","targetId":"item-v5","status":"active","audioStatus":"none","transcriptionStatus":"transcribed","transcript":"A note.","displayText":"A note.","roughPercent":10,"createdAt":"2026-01-02T03:04:05Z","anchor":{"anchorType":"text","startChar":1,"endChar":4,"anchorBefore":"","anchorAfter":"","playbackRateObserved":1}}"#
        let rows: [(String, String, String?, String?, String, String)] = [
            ("item", "item-v5", nil, "item-v5", item, "2026-01-02 03:04:05"),
            ("session", "session-v5", "session-v5", "item-v5", session, "2026-01-02 03:04:06"),
            ("interjection", "session-v5::note-v5", "session-v5", "item-v5", margin, "2026-01-02 03:04:07"),
            ("canonical_source", "canonical-v5", nil, "item-v5", #"{"schemaVersion":"canonical-source.v1","id":"canonical-v5","itemId":"item-v5"}"#, "2026-01-02 03:04:08"),
            ("turn", "session-v5::turn-bad", "session-v5", nil, "{not json", "2026-01-02 03:04:09"),
            ("future_kind", "fk-1", nil, nil, #"{"anything":"a kind this build has never heard of"}"#, "2026-01-02 03:04:10")
        ]
        for row in rows {
            try StoreRawSQL.execute("INSERT INTO records(kind,id,session_id,item_id,payload,updated_at) VALUES(?,?,?,?,?,?);",
                                    bindings: [row.0, row.1, row.2, row.3, row.4, row.5], at: path)
        }
    }
}
