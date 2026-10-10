import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// Schema 3 stored a Margin, turn or AI job under the id the session gave it
/// (`turn-response-001`), and `records` has a `(kind, id)` primary key, so a second
/// session's `turn-response-001` replaced the first session's. Schema 4 keys those three
/// kinds as `<sessionId>::<id>`; opening a v3 library must rewrite the key of every
/// existing row, otherwise the next save of the same record adds a second row next to the
/// old one and the listener sees every old turn, Margin and job twice.
///
/// The test in SQLiteSessionStoreSafetyTests only saves the migrated turn into a
/// different session, which works whether or not the migration ran.
final class SQLiteVersionThreeMigrationTests: XCTestCase {
    private var path = ""

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory.appending(path: "sessionkit-v3-\(UUID().uuidString).sqlite").path
        try seedVersionThreeLibrary()
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    func testOpeningAVersionThreeLibraryScopesTheKeyOfEveryTurnMarginAndJobAndNothingElse() throws {
        let turnPayload = try XCTUnwrap(try StoreRawSQL.rows("SELECT payload FROM records WHERE id = 'turn-response-001';", at: path).first?[0])
        _ = try SQLiteSessionStore(path: path)

        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), 5)
        XCTAssertEqual(try StoreRawSQL.ids(kind: "turn", at: path),
                       ["orphan-turn-without-session", "session-one::turn-response-001", "session-two::turn-response-002"],
                       "a turn row with no session_id column value has no scope to add and keeps its key")
        XCTAssertEqual(try StoreRawSQL.ids(kind: "interjection", at: path), ["session-one::note-001", "session-one::note-002"],
                       "note-001 is scoped; note-002 was scoped by an earlier, interrupted run and must not become session-one::session-one::note-002")
        XCTAssertEqual(try StoreRawSQL.ids(kind: "ai_job", at: path), ["session-one::job-001"])
        XCTAssertEqual(try StoreRawSQL.ids(kind: "item", at: path), ["item-v3"], "only the three session-scoped kinds get a new key")
        XCTAssertEqual(try StoreRawSQL.rows("SELECT payload FROM records WHERE id = 'session-one::turn-response-001';", at: path).first?[0], turnPayload,
                       "the migration changes the row's key, not the payload (the turn still says id turn-response-001)")
    }

    func testSavingAMigratedTurnMarginOrJobAgainUpdatesItInsteadOfAddingASecondRow() throws {
        let store = try SQLiteSessionStore(path: path)

        var turn = try XCTUnwrap(try store.loadTurns(sessionId: "session-one").first)
        turn.text = "Edited response."
        try store.saveTurn(turn)

        var margin = try XCTUnwrap(try store.loadInterjections(sessionId: "session-one").first { $0.id == "note-001" })
        margin.transcript = "Edited note."
        try store.saveInterjection(margin)

        var job = try XCTUnwrap(try store.loadAIJobs(sessionId: "session-one").first)
        job.messages = ["Edited request."]
        try store.saveAIJob(job)

        XCTAssertEqual(try store.loadTurns(sessionId: "session-one").map(\.text), ["Edited response."])
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-one").compactMap(\.transcript).sorted(), ["Edited note.", "Half-migrated note."])
        XCTAssertEqual(try store.loadAIJobs(sessionId: "session-one").flatMap(\.messages), ["Edited request."])
        XCTAssertEqual(try StoreRawSQL.ids(kind: "turn", at: path).filter { $0.hasSuffix("turn-response-001") }, ["session-one::turn-response-001"])
        XCTAssertEqual(try StoreRawSQL.ids(kind: "interjection", at: path).filter { $0.contains("note-001") }, ["session-one::note-001"])
        XCTAssertEqual(try StoreRawSQL.ids(kind: "ai_job", at: path).filter { $0.contains("job-001") }, ["session-one::job-001"])
    }

    // MARK: Fixture

    private func seedVersionThreeLibrary() throws {
        let turn: (String, String, String) -> String = { id, session, text in
            #"{"id":"\#(id)","sessionId":"\#(session)","role":"assistant","turnType":"assistant_response","status":"complete","text":"\#(text)","sourceInterjectionIds":[]}"#
        }
        let margin: (String, String) -> String = { id, words in
            #"{"id":"\#(id)","sessionId":"session-one","itemId":"item-v3","targetType":"item","targetId":"item-v3","status":"active","audioStatus":"none","transcriptionStatus":"transcribed","transcript":"\#(words)","displayText":"\#(words)","roughPercent":10,"createdAt":"2025-09-16T05:21:40Z","anchor":{"anchorType":"text","startChar":1,"endChar":4,"anchorBefore":"","anchorAfter":"","playbackRateObserved":1}}"#
        }
        let job = #"{"id":"job-001","kind":"summary","itemId":"item-v3","sessionId":"session-one","providerType":"test","model":"m","status":"complete","attempts":1,"messages":["First request."]}"#
        try StoreRawSQL.execute([
            "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
            "INSERT INTO metadata(key,value) VALUES('schema_version','3');",
            "CREATE TABLE records (kind TEXT NOT NULL, id TEXT NOT NULL, session_id TEXT, item_id TEXT, payload TEXT NOT NULL, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(kind,id));",
            "CREATE TABLE quarantined_records (kind TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, decode_error TEXT NOT NULL, quarantined_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(kind,id));"
        ], at: path)
        let rows: [(kind: String, id: String, session: String?, item: String?, payload: String)] = [
            ("turn", "turn-response-001", "session-one", nil, turn("turn-response-001", "session-one", "Existing response.")),
            ("turn", "turn-response-002", "session-two", nil, turn("turn-response-002", "session-two", "Other session.")),
            ("turn", "orphan-turn-without-session", nil, nil, turn("orphan-turn-without-session", "session-one", "No session column.")),
            ("interjection", "note-001", "session-one", "item-v3", margin("note-001", "Existing note.")),
            ("interjection", "session-one::note-002", "session-one", "item-v3", margin("note-002", "Half-migrated note.")),
            ("ai_job", "job-001", "session-one", "item-v3", job),
            ("item", "item-v3", nil, "item-v3", #"{"id":"item-v3","title":"Old item","mediaType":"text","text":"Body.","status":"ready"}"#)
        ]
        for row in rows {
            try StoreRawSQL.execute("INSERT INTO records(kind,id,session_id,item_id,payload) VALUES(?,?,?,?,?);",
                                    bindings: [row.kind, row.id, row.session, row.item, row.payload], at: path)
        }
    }
}
