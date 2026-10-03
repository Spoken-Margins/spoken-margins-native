import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence

private let testSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteSessionStoreSafetyTests: XCTestCase {
    func testBriefIndependentWriterContentionDoesNotDropTheNextSave() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        let blocker = try SQLiteTestWriteLock(path: path)
        let released = expectation(description: "independent writer releases its transaction")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            blocker.release()
            released.fulfill()
        }
        let item = Item(id: "contended", title: "Preserved", mediaType: "text", text: "Body",
                        externalReference: nil, status: "ready")
        XCTAssertNoThrow(try store.saveItem(item))
        wait(for: [released], timeout: 2)
        XCTAssertEqual(try store.loadItem(id: item.id), item)
    }

    func testImportedLayerReadDoesNotDecodeOtherLayersAndStillQuarantinesMalformedJSON() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        let note = ImportedCommentaryInterjection(id: "wanted", layerId: "selected", packageScopedId: "wanted", createdAt: Date(), anchorEvidence: PortableAnchorEvidence(anchorType: .text), approvedTranscript: "Selected words")
        try store.saveImportedCommentaryInterjection(note)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        // The unrelated layer is valid JSON but deliberately not decodable as
        // a Margin. Reading selected must not inspect or quarantine that layer.
        let sql = """
        INSERT INTO records(kind,id,payload) VALUES('imported_commentary_interjection','other','{"layerId":"other"}');
        INSERT INTO records(kind,id,payload) VALUES('imported_commentary_interjection','malformed','{not-json');
        """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try store.loadImportedCommentaryInterjections(layerId: "selected").map(\.id), ["wanted"])
        XCTAssertEqual(try store.quarantinedRecordCount(), 1)
        XCTAssertTrue(try recordExists(path: path, kind: "imported_commentary_interjection", id: "other"))
        XCTAssertTrue(try store.loadImportedCommentaryInterjections(layerId: "other").isEmpty)
        XCTAssertEqual(try store.quarantinedRecordCount(), 2)
    }

    func testConcurrentReadsAndWritesShareOneConnectionSafely() async throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())

        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<12 {
                group.addTask {
                    for iteration in 0..<40 {
                        let id = "asset-\(worker)-\(iteration)"
                        try store.saveOwnedOfflineAsset(
                            OwnedOfflineAsset(
                                id: id,
                                category: .preparedChunk,
                                relativePath: id,
                                byteCount: 1,
                                isReproducible: true
                            )
                        )
                        _ = try store.loadOwnedOfflineAssets()
                        _ = try store.listItems()
                    }
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(try store.loadOwnedOfflineAssets().count, 480)
    }

    // #287: the ledger reconciles sizes from a read taken before it checks every file, while the
    // app toggles protections on the same rows. The size update must not undo the toggle.
    /// A malformed row met inside the update's transaction is still quarantined, as the old load-then-save
    /// path did. Quarantine used to start a second transaction, which SQLite rejects (#529 audit).
    func testOwnedOfflineAssetUpdateQuarantinesAMalformedRow() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = "INSERT INTO records(kind,id,payload) VALUES('owned_offline_asset','episode','{not-json');"
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)

        let updated = try store.updateOwnedOfflineAsset(id: "episode") { $0.protections.insert(.activePlayback) }
        XCTAssertNil(updated)
        XCTAssertEqual(try store.quarantinedRecordCount(), 1)
        XCTAssertFalse(try recordExists(path: path, kind: "owned_offline_asset", id: "episode"))
    }

    func testOwnedOfflineAssetUpdateKeepsAProtectionSavedAfterTheCallersRead() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        try assertOwnedOfflineAssetUpdateKeepsALaterProtection(store)
    }

    func testInMemoryOwnedOfflineAssetUpdateKeepsAProtectionSavedAfterTheCallersRead() throws {
        try assertOwnedOfflineAssetUpdateKeepsALaterProtection(InMemorySessionRepository())
    }

    // #530: eviction picks rows from an earlier read. The conditional delete judges the row as it is now.
    func testConditionalOwnedOfflineAssetDeleteJudgesTheCurrentRow() throws {
        try assertConditionalOwnedOfflineAssetDeleteJudgesTheCurrentRow(SQLiteSessionStore(path: temporaryDatabasePath()))
    }

    func testInMemoryConditionalOwnedOfflineAssetDeleteJudgesTheCurrentRow() throws {
        try assertConditionalOwnedOfflineAssetDeleteJudgesTheCurrentRow(InMemorySessionRepository())
    }

    private func assertOwnedOfflineAssetUpdateKeepsALaterProtection(
        _ repository: any SessionRepository, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try repository.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "episode", itemId: "item", category: .podcast, relativePath: "PodcastAudio/episode.mp3",
            byteCount: 10, isReproducible: true
        ))
        let callersRead = try XCTUnwrap(repository.loadOwnedOfflineAssets().first, file: file, line: line)
        var toggled = callersRead
        toggled.protections.insert(.activePlayback)
        try repository.saveOwnedOfflineAsset(toggled)

        let saved = try repository.updateOwnedOfflineAsset(id: callersRead.id) { $0.byteCount = 3 }

        let row = try XCTUnwrap(repository.loadOwnedOfflineAssets().first, file: file, line: line)
        XCTAssertEqual(row.byteCount, 3, file: file, line: line)
        XCTAssertEqual(row.protections, [.activePlayback], "the later protection survives", file: file, line: line)
        XCTAssertEqual(saved, row, file: file, line: line)
        XCTAssertNil(try repository.updateOwnedOfflineAsset(id: "missing") { $0.byteCount = 1 }, file: file, line: line)
        XCTAssertEqual(try repository.loadOwnedOfflineAssets().count, 1, "a missing id creates no row", file: file, line: line)
    }

    private func assertConditionalOwnedOfflineAssetDeleteJudgesTheCurrentRow(
        _ repository: any SessionRepository, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let idle = OwnedOfflineAsset(
            id: "episode", itemId: "item", category: .podcast, relativePath: "PodcastAudio/episode.mp3",
            byteCount: 3, isReproducible: true
        )
        try repository.saveOwnedOfflineAsset(idle)
        var playing = idle
        playing.protections.insert(.activePlayback)
        try repository.saveOwnedOfflineAsset(playing)

        XCTAssertFalse(try repository.deleteOwnedOfflineAsset(id: idle.id) { $0.isAutomaticallyEvictable },
                       "the protection saved after the caller's read keeps the row", file: file, line: line)
        XCTAssertEqual(try repository.loadOwnedOfflineAssets().map(\.protections), [[.activePlayback]], file: file, line: line)

        try repository.saveOwnedOfflineAsset(idle)
        XCTAssertTrue(try repository.deleteOwnedOfflineAsset(id: idle.id) { $0.isAutomaticallyEvictable },
                      file: file, line: line)
        XCTAssertTrue(try repository.loadOwnedOfflineAssets().isEmpty, file: file, line: line)
        XCTAssertFalse(try repository.deleteOwnedOfflineAsset(id: "missing") { _ in true }, file: file, line: line)
    }

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

    func testVersionFiveLibraryOpensWithoutRewritingKnownOrUnknownRecords() throws {
        let path = temporaryDatabasePath()
        try createVersionFiveLibraryDatabase(path: path)

        let store = try SQLiteSessionStore(path: path)

        XCTAssertEqual(try store.listItems().map(\.id), ["item-v5-existing"])
        try store.saveItem(Item(
            id: "item-sharing-import",
            title: "Sharing Import",
            mediaType: "text",
            text: "New text.",
            externalReference: "manual-import",
            status: "ready"
        ))

        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: path), 5)
        XCTAssertEqual(try store.listItems().map(\.id).sorted(), ["item-sharing-import", "item-v5-existing"])
        XCTAssertTrue(try rawPayload(path: path, kind: "item", id: "item-v5-existing").contains("Quality Author"))
        XCTAssertTrue(try recordExists(path: path, kind: "canonical_source", id: "canonical-v5"))
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

    private func createVersionFiveLibraryDatabase(path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            throw NSError(domain: "SQLiteSessionStoreSafetyTests", code: 7)
        }
        defer { sqlite3_close(database) }
        let statements = [
            "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
            "INSERT INTO metadata(key,value) VALUES('schema_version','5');",
            "CREATE TABLE records (kind TEXT NOT NULL, id TEXT NOT NULL, session_id TEXT, item_id TEXT, payload TEXT NOT NULL, updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(kind,id));",
            "CREATE TABLE quarantined_records (kind TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, decode_error TEXT NOT NULL, quarantined_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(kind,id));",
            "INSERT INTO records(kind,id,item_id,payload) VALUES('item','item-v5-existing','item-v5-existing','{\"id\":\"item-v5-existing\",\"title\":\"Existing Library Item\",\"mediaType\":\"text\",\"text\":\"Still here.\",\"status\":\"ready\",\"author\":\"Quality Author\",\"sourceTitle\":\"Quality Source\"}');",
            "INSERT INTO records(kind,id,item_id,payload) VALUES('canonical_source','canonical-v5','item-v5-existing','{\"schemaVersion\":\"canonical-source.v1\",\"id\":\"canonical-v5\",\"itemId\":\"item-v5-existing\"}');"
        ]
        for sql in statements {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLiteSessionStoreSafetyTests", code: 8)
            }
        }
    }

    private func rawPayload(path: String, kind: String, id: String) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            throw NSError(domain: "SQLiteSessionStoreSafetyTests", code: 9)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT payload FROM records WHERE kind = ? AND id = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteSessionStoreSafetyTests", code: 10)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, testSQLiteTransient)
        sqlite3_bind_text(statement, 2, id, -1, testSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            throw NSError(domain: "SQLiteSessionStoreSafetyTests", code: 11)
        }
        return String(cString: value)
    }

    private func recordExists(path: String, kind: String, id: String) throws -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK else {
            throw NSError(domain: "SQLiteSessionStoreSafetyTests", code: 12)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM records WHERE kind = ? AND id = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteSessionStoreSafetyTests", code: 13)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, kind, -1, testSQLiteTransient)
        sqlite3_bind_text(statement, 2, id, -1, testSQLiteTransient)
        return sqlite3_step(statement) == SQLITE_ROW
    }
}

private final class SQLiteTestWriteLock: @unchecked Sendable {
    private var database: OpaquePointer?
    init(path: String) throws {
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("test_write_lock")
        }
    }
    func release() { XCTAssertEqual(sqlite3_exec(database, "COMMIT", nil, nil, nil), SQLITE_OK) }
    deinit { sqlite3_close(database) }
}
