import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence

final class SQLiteSessionStoreSafetyTests: XCTestCase {
    func testStoreWritesCurrentSchemaVersion() throws {
        let path = temporaryDatabasePath()
        _ = try SQLiteSessionStore(path: path)

        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), SQLiteSessionStore.currentSchemaVersion)
    }

    func testCorruptRecordIsMovedToQuarantineWithoutHidingHealthyItems() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        let healthy = Item(
            id: "healthy",
            title: "Healthy",
            mediaType: "text",
            text: "Readable.",
            externalReference: nil,
            status: "ready"
        )
        try store.saveItem(healthy)
        try insertCorruptItem(path: path)

        XCTAssertEqual(try store.listItems().map(\.id), [healthy.id])
        XCTAssertEqual(try store.quarantinedRecordCount(), 1)
        XCTAssertEqual(try store.listItems().map(\.id), [healthy.id])
    }

    func testVersionTwoMigrationBackfillsSessionTimestampsWithoutLosingTheSession() throws {
        let path = temporaryDatabasePath()
        try createVersionTwoSessionDatabase(path: path)

        let store = try SQLiteSessionStore(path: path)
        let sessions = try store.loadSessions(itemId: "item-legacy")
        let session = try XCTUnwrap(sessions.first)

        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), SQLiteSessionStore.currentSchemaVersion)
        XCTAssertEqual(session.id, "session-legacy")
        XCTAssertNotNil(session.createdAt)
        XCTAssertNotNil(session.updatedAt)
        XCTAssertNil(session.completedAt)
        XCTAssertEqual(try store.quarantinedRecordCount(), 0)
    }

    func testSessionScopedLogicalIDsDoNotOverwriteRecordsFromAnotherSession() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        let firstTurn = ConversationTurn(
            id: "turn-response-001",
            sessionId: "session-one",
            role: "assistant",
            turnType: "assistant_response",
            status: "complete",
            summary: nil,
            text: "First session response.",
            rawText: nil,
            sourceInterjectionIds: []
        )
        var secondTurn = firstTurn
        secondTurn.sessionId = "session-two"
        secondTurn.text = "Second session response."
        let firstInterjection = Interjection(
            id: "ij-ai-001",
            itemId: "item-one",
            sessionId: "session-one",
            targetType: .assistantTurn,
            targetId: firstTurn.id,
            createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 100,
            anchor: Anchor(anchorType: .turn, startChar: 0, endChar: 5, anchorBefore: "First", anchorAfter: "response"),
            audioPath: nil,
            audioStatus: "none",
            transcriptionStatus: "transcribed",
            transcript: "First note.",
            cleanedTranscript: nil,
            displayText: nil,
            status: "active"
        )
        var secondInterjection = firstInterjection
        secondInterjection.itemId = "item-two"
        secondInterjection.sessionId = "session-two"
        secondInterjection.transcript = "Second note."
        let firstJob = AIJob(
            id: "job-assistant-response-001",
            kind: "assistant_response",
            itemId: "item-one",
            sessionId: "session-one",
            turnId: firstTurn.id,
            providerType: "test",
            model: "test",
            status: "complete",
            attempts: 1,
            lastError: nil,
            messages: ["First request."],
            playbackMode: nil
        )
        var secondJob = firstJob
        secondJob.itemId = "item-two"
        secondJob.sessionId = "session-two"
        secondJob.messages = ["Second request."]

        try store.saveTurn(firstTurn)
        try store.saveInterjection(firstInterjection)
        try store.saveAIJob(firstJob)
        try store.saveTurn(secondTurn)
        try store.saveInterjection(secondInterjection)
        try store.saveAIJob(secondJob)

        XCTAssertEqual(try store.loadTurns(sessionId: "session-one").map(\.text), ["First session response."])
        XCTAssertEqual(try store.loadTurns(sessionId: "session-two").map(\.text), ["Second session response."])
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-one").map(\.transcript), ["First note."])
        XCTAssertEqual(try store.loadInterjections(sessionId: "session-two").map(\.transcript), ["Second note."])
        XCTAssertEqual(try store.loadAIJobs(sessionId: "session-one").flatMap(\.messages), ["First request."])
        XCTAssertEqual(try store.loadAIJobs(sessionId: "session-two").flatMap(\.messages), ["Second request."])
    }

    func testVersionThreeMigrationScopesExistingSessionRecordKeys() throws {
        let path = temporaryDatabasePath()
        try createVersionThreeTurnDatabase(path: path)

        let store = try SQLiteSessionStore(path: path)
        var laterTurn = try XCTUnwrap(try store.loadTurns(sessionId: "session-one").first)
        laterTurn.sessionId = "session-two"
        laterTurn.text = "Later session response."
        try store.saveTurn(laterTurn)

        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), 5)
        XCTAssertEqual(try store.loadTurns(sessionId: "session-one").map(\.text), ["Existing response."])
        XCTAssertEqual(try store.loadTurns(sessionId: "session-two").map(\.text), ["Later session response."])
    }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "sessionkit-safety-\(UUID().uuidString).sqlite")
            .path
    }

    private func insertCorruptItem(path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            throw NSError(domain: "SQLiteSessionStoreSafetyTests", code: 1)
        }
        defer { sqlite3_close(database) }
        let sql = "INSERT INTO records(kind,id,item_id,payload) VALUES('item','corrupt','corrupt','{not-json');"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteSessionStoreSafetyTests", code: 2)
        }
    }

    private func createVersionTwoSessionDatabase(path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            throw NSError(domain: "SQLiteSessionStoreSafetyTests", code: 3)
        }
        defer { sqlite3_close(database) }
        let statements = [
            "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
            "INSERT INTO metadata(key,value) VALUES('schema_version','2');",
            "CREATE TABLE records (kind TEXT NOT NULL, id TEXT NOT NULL, session_id TEXT, item_id TEXT, payload TEXT NOT NULL, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(kind,id));",
            "CREATE TABLE quarantined_records (kind TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, decode_error TEXT NOT NULL, quarantined_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(kind,id));",
            "INSERT INTO records(kind,id,session_id,item_id,payload,updated_at) VALUES('session','session-legacy','session-legacy','item-legacy','{\"id\":\"session-legacy\",\"itemId\":\"item-legacy\",\"status\":\"in_progress\",\"phase\":\"item_playback\",\"currentTargetType\":\"item_text_tts\",\"currentTargetId\":\"item-legacy\",\"position\":{\"charOffset\":12},\"completionPercent\":25,\"playbackRate\":1}','2026-07-20 12:34:56');"
        ]
        for sql in statements {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLiteSessionStoreSafetyTests", code: 4)
            }
        }
    }

    private func createVersionThreeTurnDatabase(path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            throw NSError(domain: "SQLiteSessionStoreSafetyTests", code: 5)
        }
        defer { sqlite3_close(database) }
        let statements = [
            "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
            "INSERT INTO metadata(key,value) VALUES('schema_version','3');",
            "CREATE TABLE records (kind TEXT NOT NULL, id TEXT NOT NULL, session_id TEXT, item_id TEXT, payload TEXT NOT NULL, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(kind,id));",
            "CREATE TABLE quarantined_records (kind TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, decode_error TEXT NOT NULL, quarantined_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(kind,id));",
            "INSERT INTO records(kind,id,session_id,payload) VALUES('turn','turn-response-001','session-one','{\"id\":\"turn-response-001\",\"sessionId\":\"session-one\",\"role\":\"assistant\",\"turnType\":\"assistant_response\",\"status\":\"complete\",\"text\":\"Existing response.\",\"sourceInterjectionIds\":[]}');"
        ]
        for sql in statements {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLiteSessionStoreSafetyTests", code: 6)
            }
        }
    }
}
