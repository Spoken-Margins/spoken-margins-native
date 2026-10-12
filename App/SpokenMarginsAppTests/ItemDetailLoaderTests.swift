import XCTest
import SQLite3
@testable import SessionKit
import SessionKitPersistence
@testable import SpokenMarginsApp

@MainActor
final class ItemDetailLoaderTests: XCTestCase {
    func testSnapshotForAnotherItemCannotSelectThisItemsOlderSession() throws {
        try withFixture { model, store, _ in
            try seedSessions(store)
            setSnapshot(model, item: "B", session: "A-old")
            let detail = try model.loadItemDetail(id: "A", store: store)
            assertSelected(detail, session: "A-new")
        }
    }

    func testSnapshotSessionMustBelongToTheLoadedItem() throws {
        try withFixture { model, store, _ in
            try seedSessions(store)
            setSnapshot(model, item: "A", session: "B-session")
            let detail = try model.loadItemDetail(id: "A", store: store)
            assertSelected(detail, session: "A-new")
        }
    }

    func testValidOlderSessionIsKeptAndAbsentOrMissingSnapshotsUseNewest() throws {
        try withFixture { model, store, _ in
            try seedSessions(store)
            let cases: [(String?, String?, String)] = [
                ("A", "A-old", "A-old"),
                ("A", "A-new", "A-new"),
                (nil, nil, "A-new"),
                ("A", nil, "A-new"),
                ("A", "missing", "A-new")
            ]
            for (item, session, expected) in cases {
                setSnapshot(model, item: item, session: session)
                let detail = try model.loadItemDetail(id: "A", store: store)
                XCTAssertEqual(detail.sessions.map(\.id), ["A-new", "A-old"])
                assertSelected(detail, session: expected)
            }
        }
    }

    func testOnlyActiveMarginsAppearAndSessionRowsKeepTheirOwnActiveFilter() throws {
        try withFixture { model, store, _ in
            try seedSessions(store)
            var active = note("note-A-new", session: "A-new", item: "A", time: 200)
            active.cleanedTranscript = "  Cleaned note  "
            try store.saveInterjection(active)
            var blank = note("zz-blank-cleaned", session: "A-new", item: "A", time: 250)
            blank.cleanedTranscript = " \n "
            blank.transcript = "Must not replace blank cleaned text"
            try store.saveInterjection(blank)
            var deleted = note("deleted", session: "A-new", item: "A", time: 300)
            deleted.status = "deleted"
            try store.saveInterjection(deleted)
            XCTAssertEqual(try store.loadInterjections(sessionId: "A-new")
                .filter { $0.status == "active" }.map(\.id), ["note-A-new", "zz-blank-cleaned"],
                "The blank cleaned note must be considered first by the reverse-order preview lookup")

            let detail = try model.loadItemDetail(id: "A", store: store)
            XCTAssertEqual(Set(detail.interjections.map(\.id)), ["note-A-new", "zz-blank-cleaned"])
            let row = try XCTUnwrap(detail.sessionRows.first { $0.id == "A-new" })
            XCTAssertEqual(row.interjectionCount, 2)
            XCTAssertEqual(row.interjectionPreview, "Cleaned note")
            XCTAssertEqual(detail.sessionRows.first { $0.id == "A-old" }?.interjectionCount, 1)
        }
    }

    func testSummaryTurnsRequireEveryReferencedMarginToRemainActive() throws {
        try withFixture { model, store, _ in
            try seedSessions(store)
            var deleted = note("deleted", session: "A-new", item: "A", time: 300)
            deleted.status = "deleted"
            try store.saveInterjection(deleted)
            let references: [(String, [String])] = [
                ("summary-active", ["note-A-new"]),
                ("summary-deleted", ["deleted"]),
                ("summary-missing", ["missing"]),
                ("summary-mixed", ["note-A-new", "deleted"]),
                ("summary-empty", [])
            ]
            for (id, sources) in references {
                try store.saveTurn(turn(id, session: "A-new", type: "interjection_summary", sources: sources))
            }
            try store.saveTurn(turn("ordinary-missing-source", session: "A-new", sources: ["missing"]))

            let detail = try model.loadItemDetail(id: "A", store: store)
            XCTAssertEqual(Set(detail.turns.map(\.id)),
                           ["turn-A-new", "summary-active", "summary-empty", "ordinary-missing-source"])
        }
    }

    func testDerivedMapIsReturnedAndPersistedThroughAnotherConnection() throws {
        try withFixture { model, store, database in
            try seedCanonical(store)
            XCTAssertNil(try store.loadListeningMap(itemId: "A"))
            let detail = try model.loadItemDetail(id: "A", store: store)
            XCTAssertEqual(detail.navigation.map(\.id), ["chapter-one", "chapter-two"])
            assertChapters(detail.chapters)
            let reader = try SQLiteSessionStore(path: database.path)
            let saved = try XCTUnwrap(reader.loadListeningMap(itemId: "A"))
            XCTAssertEqual(saved.id, "canonical-navigation-A")
            assertChapters(saved.chapters)
        }
    }

    func testStrictTimelineFailurePropagatesAfterTheDerivedMapWasSaved() throws {
        try withFixture { model, store, database in
            try seedCanonical(store)
            try executeSQL("""
                INSERT INTO records(kind,id,item_id,payload)
                VALUES('source_transcript_timeline','bad-timeline','A','not json');
                CREATE TRIGGER refuse_timeline_quarantine BEFORE INSERT ON quarantined_records
                WHEN NEW.kind = 'source_transcript_timeline'
                BEGIN SELECT RAISE(ABORT, 'loader strict fixture'); END;
                """, database: database)

            XCTAssertThrowsError(try model.loadItemDetail(id: "A", store: store)) { error in
                XCTAssertEqual(error as? SessionKitError, .persistenceFailed("step_quarantine"))
            }
            let reader = try SQLiteSessionStore(path: database.path)
            assertChapters(try XCTUnwrap(reader.loadListeningMap(itemId: "A")).chapters)
        }
    }

    func testOptionalTurnReadFailureReturnsNoTurnsAfterAHealthyControl() throws {
        try withFixture { model, store, database in
            try seedSessions(store)
            assertSelected(try model.loadItemDetail(id: "A", store: store), session: "A-new")
            try executeSQL("""
                INSERT INTO records(kind,id,session_id,payload)
                VALUES('turn','bad-turn','A-new','not json');
                CREATE TRIGGER refuse_turn_quarantine BEFORE INSERT ON quarantined_records
                WHEN NEW.kind = 'turn'
                BEGIN SELECT RAISE(ABORT, 'loader optional fixture'); END;
                """, database: database)

            let detail = try model.loadItemDetail(id: "A", store: store)
            XCTAssertTrue(detail.turns.isEmpty)
            XCTAssertEqual(detail.interjections.map(\.id), ["note-A-new"])
        }
    }

    func testPlacementPassUsesDecodedItemIdentityWhenStoredKeyDiffers() throws {
        try withFixture { _, store, database in
            try store.saveItem(item("A"))
            try executeSQL("UPDATE records SET id = 'alias' WHERE kind = 'item' AND id = 'A';", database: database)
            XCTAssertEqual(try store.loadItem(id: "alias").id, "A", "Only the stored key changed")
            var passes = SharedMarginPlacementPasses()
            passes.begin(.matching, itemId: "A")
            passes.begin(.transcript, itemId: "alias")
            let decodedPass = try XCTUnwrap(passes.pass(itemId: "A"))
            let requestedPass = try XCTUnwrap(passes.pass(itemId: "alias"))
            XCTAssertNotEqual(decodedPass, requestedPass)

            let detail = try ItemDetailLoader.load(id: "alias", store: store,
                snapshotItemId: nil, snapshotSessionId: nil, placementPasses: passes)
            XCTAssertEqual(detail.id, "A")
            XCTAssertEqual(detail.sharedMarginPlacement, decodedPass)
        }
    }

    private func withFixture(_ body: (Gate1AppModel, SQLiteSessionStore, URL) throws -> Void) throws {
        let preferences = VoicePreferencesSnapshot.capture()
        defer { preferences.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("item-detail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("library.sqlite")
        // This scope releases both SQLite owners before the directory is removed.
        do {
            let store = try SQLiteSessionStore(path: database.path)
            let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
            model.preparationSeams.memoryBackoffActive = { true }
            try body(model, store, database)
        }
    }

    private func setSnapshot(_ model: Gate1AppModel, item: String?, session: String?) {
        var snapshot = SessionSnapshot()
        snapshot.itemId = item
        snapshot.sessionId = session
        model.snapshot = snapshot
    }

    private func assertSelected(_ detail: ItemDetailState, session: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(detail.id, "A", file: file, line: line)
        XCTAssertEqual(detail.interjections.map(\.id), ["note-\(session)"], file: file, line: line)
        XCTAssertEqual(detail.turns.map(\.id), ["turn-\(session)"], file: file, line: line)
    }

    private func assertChapters(_ chapters: [Chapter], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(chapters.map(\.id), ["chapter-one", "chapter-two"], file: file, line: line)
        XCTAssertEqual(chapters.map(\.startChar), [0, 6], file: file, line: line)
        XCTAssertEqual(chapters.map(\.endChar), [6, 10], file: file, line: line)
        XCTAssertEqual(chapters.map(\.percent), [0, 60], file: file, line: line)
    }

    private func seedSessions(_ store: SQLiteSessionStore) throws {
        try store.saveItem(item("A"))
        try store.saveItem(item("B"))
        for (id, itemID, time) in [("A-new", "A", 200.0), ("B-session", "B", 300.0), ("A-old", "A", 100.0)] {
            try store.saveSession(Session(id: id, itemId: itemID,
                createdAt: Date(timeIntervalSince1970: time), updatedAt: Date(timeIntervalSince1970: time),
                status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS,
                currentTargetId: itemID, position: Position(), completionPercent: 0, playbackRate: 1))
            try store.saveInterjection(note("note-\(id)", session: id, item: itemID, time: time))
            try store.saveTurn(turn("turn-\(id)", session: id))
        }
    }

    private func seedCanonical(_ store: SQLiteSessionStore) throws {
        try store.saveItem(item("A"))
        let first = SourceLocator(documentId: "doc", segmentId: "one", utf8Start: 0, utf8End: 4)
        let second = SourceLocator(documentId: "doc", segmentId: "two", utf8Start: 6, utf8End: 10)
        try store.saveCanonicalSource(CanonicalSourcePackage(id: "canonical-A", itemId: "A", sourceDocumentId: "doc",
            format: .plainText, title: "A", navigation: [
                CanonicalNavigationNode(id: "chapter-one", title: "One", locator: first),
                CanonicalNavigationNode(id: "chapter-two", title: "Two", locator: second)
            ], segments: [SpeakableSegment(id: "one", text: "One.", locator: first),
                          SpeakableSegment(id: "two", text: "Two.", locator: second)]))
    }

    private func item(_ id: String) -> Item {
        Item(id: id, title: id, mediaType: "text", text: "One.\n\nTwo.", externalReference: nil, status: "Ready")
    }

    private func note(_ id: String, session: String, item: String, time: Double) -> Interjection {
        Interjection(id: id, itemId: item, sessionId: session, targetType: .item, targetId: item,
            createdAt: Date(timeIntervalSince1970: time), roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 4, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "not_recorded", transcriptionStatus: "transcribed",
            transcript: id, cleanedTranscript: nil, displayText: nil, status: "active")
    }

    private func turn(_ id: String, session: String, type: String = "assistant_response", sources: [String] = []) -> ConversationTurn {
        ConversationTurn(id: id, sessionId: session, role: "assistant", turnType: type, status: "complete",
                         summary: nil, text: id, rawText: nil, chapters: nil, sourceInterjectionIds: sources)
    }

    private func executeSQL(_ sql: String, database: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(database.path, &connection) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }
            throw NSError(domain: "ItemDetailLoaderTests", code: 1)
        }
        defer { sqlite3_close(connection) }
        let result = sqlite3_exec(connection, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw NSError(domain: "ItemDetailLoaderTests", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(connection))])
        }
    }
}
