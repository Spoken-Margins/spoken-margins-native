import XCTest
@testable import SessionKit
import SessionKitPersistence

/// Moved from the app test target (#318): the loader needs only SessionKit and the SQLite store, so the
/// tests call it directly instead of through `Gate1AppModel.loadItemDetail`, and run on Linux.
final class ItemDetailLoaderTests: XCTestCase {
    func testSnapshotForAnotherItemCannotSelectThisItemsOlderSession() throws {
        try withFixture { fixture, store, _ in
            try seedSessions(store)
            fixture.setSnapshot(item: "B", session: "A-old")
            let detail = try fixture.load("A", store)
            assertSelected(detail, session: "A-new")
        }
    }

    func testSnapshotSessionMustBelongToTheLoadedItem() throws {
        try withFixture { fixture, store, _ in
            try seedSessions(store)
            fixture.setSnapshot(item: "A", session: "B-session")
            let detail = try fixture.load("A", store)
            assertSelected(detail, session: "A-new")
        }
    }

    func testValidOlderSessionIsKeptAndAbsentOrMissingSnapshotsUseNewest() throws {
        try withFixture { fixture, store, _ in
            try seedSessions(store)
            let cases: [(String?, String?, String)] = [
                ("A", "A-old", "A-old"),
                ("A", "A-new", "A-new"),
                (nil, nil, "A-new"),
                ("A", nil, "A-new"),
                ("A", "missing", "A-new")
            ]
            for (item, session, expected) in cases {
                fixture.setSnapshot(item: item, session: session)
                let detail = try fixture.load("A", store)
                XCTAssertEqual(detail.sessions.map(\.id), ["A-new", "A-old"])
                assertSelected(detail, session: expected)
            }
        }
    }

    func testOnlyActiveMarginsAppearAndSessionRowsKeepTheirOwnActiveFilter() throws {
        try withFixture { fixture, store, _ in
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

            let detail = try fixture.load("A", store)
            XCTAssertEqual(Set(detail.interjections.map(\.id)), ["note-A-new", "zz-blank-cleaned"])
            let row = try XCTUnwrap(detail.sessionRows.first { $0.id == "A-new" })
            XCTAssertEqual(row.interjectionCount, 2)
            XCTAssertEqual(row.interjectionPreview, "Cleaned note")
            XCTAssertEqual(detail.sessionRows.first { $0.id == "A-old" }?.interjectionCount, 1)
        }
    }

    func testSummaryTurnsRequireEveryReferencedMarginToRemainActive() throws {
        try withFixture { fixture, store, _ in
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

            let detail = try fixture.load("A", store)
            XCTAssertEqual(Set(detail.turns.map(\.id)),
                           ["turn-A-new", "summary-active", "summary-empty", "ordinary-missing-source"])
        }
    }

    func testDerivedMapIsReturnedAndPersistedThroughAnotherConnection() throws {
        try withFixture { fixture, store, database in
            try seedCanonical(store)
            XCTAssertNil(try store.loadListeningMap(itemId: "A"))
            let detail = try fixture.load("A", store)
            XCTAssertEqual(detail.navigation.map(\.id), ["chapter-one", "chapter-two"])
            assertChapters(detail.chapters)
            let reader = try SQLiteSessionStore(path: database.path)
            let saved = try XCTUnwrap(reader.loadListeningMap(itemId: "A"))
            XCTAssertEqual(saved.id, "canonical-navigation-A")
            assertChapters(saved.chapters)
        }
    }

    func testStrictTimelineFailurePropagatesAfterTheDerivedMapWasSaved() throws {
        try withFixture { fixture, store, database in
            try seedCanonical(store)
            try executeSQL([
                "INSERT INTO records(kind,id,item_id,payload) VALUES('source_transcript_timeline','bad-timeline','A','not json')",
                """
                CREATE TRIGGER refuse_timeline_quarantine BEFORE INSERT ON quarantined_records
                WHEN NEW.kind = 'source_transcript_timeline'
                BEGIN SELECT RAISE(ABORT, 'loader strict fixture'); END
                """
            ], database: database)

            XCTAssertThrowsError(try fixture.load("A", store)) { error in
                XCTAssertEqual(error as? SessionKitError, .persistenceFailed("step_quarantine"))
            }
            let reader = try SQLiteSessionStore(path: database.path)
            assertChapters(try XCTUnwrap(reader.loadListeningMap(itemId: "A")).chapters)
        }
    }

    /// #2073: opening an item that has a Listening Map and a full transcript decoded every saved transcript segment
    /// (several MB of JSON) on the main thread, only to read the chapter list. The record here has intact chapters
    /// but segments the full decoder rejects: if the loader decodes them the record is quarantined and the chapters
    /// are lost, so this fails before the fix and passes once the loader reads only the chapters and duration.
    func testItemDetailReadsTheChaptersWithoutDecodingTheTranscriptSegments() throws {
        try withFixture { fixture, store, database in
            try store.saveItem(item("A"))
            try executeSQL([
                """
                INSERT INTO records(kind,id,item_id,payload,updated_at) VALUES('source_transcript_timeline','t','A',
                '{"id":"t","itemId":"A","createdAt":0,"timeline":{"segments":"not a list","durationMs":3600000,"chapters":[{"id":"ch-0","title":"Intro","description":"","startMs":0,"transcriptSegmentId":"seg-0"},{"id":"ch-1","title":"Interview","description":"","startMs":600000,"transcriptSegmentId":"seg-0"}]}}',
                '2026-01-01 00:00:00')
                """
            ], database: database)

            let detail = try fixture.load("A", store)
            XCTAssertEqual(detail.mediaChapters.map(\.title), ["Intro", "Interview"])
            XCTAssertEqual(detail.mediaDurationMs, 3_600_000)
            XCTAssertEqual(try store.quarantinedRecordCount(), 0)
        }
    }

    /// #2102: every tap that reloaded a mapped episode's Item screen decoded its whole transcript again (several MB)
    /// to name the words around each media-timed Margin. The words are kept per timeline record: the first load
    /// decodes once, a repeat load decodes nothing, and a new timeline is read again.
    func testRepeatLoadsOfAMappedEpisodeDecodeItsTranscriptOnce() throws {
        try withFixture { fixture, store, _ in
            var episode = item("A")
            episode.media = ItemMedia(sourceType: .nativeMediaFile, url: "file:///A.mp3", durationMs: 600_000)
            try store.saveItem(episode)
            try store.saveSession(Session(id: "S", itemId: "A",
                createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1),
                status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS,
                currentTargetId: "A", position: Position(), completionPercent: 0, playbackRate: 1))
            var margin = note("m1", session: "S", item: "A", time: 10)
            margin.anchor = Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 60_000)
            try store.saveInterjection(margin)
            func saveTimeline(id: String, text: String) throws {
                try store.saveTranscriptTimeline(SourceTranscriptTimeline(id: id, itemId: "A",
                    createdAt: Date(timeIntervalSince1970: 5),
                    timeline: TranscriptTimeline(segments: [
                        MediaTimelineSegment(id: "seg", startMs: 30_000, endMs: 90_000, text: text)
                    ], chapters: [], durationMs: 600_000)))
            }
            try saveTimeline(id: "t1", text: "The first transcript.")

            let first = try fixture.load("A", store)
            XCTAssertEqual(first.interjections.first?.anchorContextStatus, .ready)
            XCTAssertEqual(store.anchorTimelineDecodes, 1)
            let again = try fixture.load("A", store)
            XCTAssertEqual(again.interjections.first?.anchor, first.interjections.first?.anchor)
            XCTAssertEqual(store.anchorTimelineDecodes, 1, "A repeat load must not decode the transcript again")

            try saveTimeline(id: "t2", text: "A replaced transcript.")
            let replaced = try fixture.load("A", store)
            XCTAssertEqual(store.anchorTimelineDecodes, 2)
            XCTAssertNotEqual(replaced.interjections.first?.anchor.anchorBefore, first.interjections.first?.anchor.anchorBefore)
        }
    }

    /// #2506: the Item screen's `body` asked the store three questions on every render (the layers, the proposal ids,
    /// the timeline's chapters) to decide whether to show "A shared map couldn't be placed". The loader works the
    /// answer out once, and the screen reads it from the detail. Each row ends in what the old three reads said.
    func testTheDetailCarriesWhyASharedMapWasRefusedUntilTheListenerHasAMapOfTheirOwn() throws {
        enum Own { case none, communityMap, ownMap, publisherChapters }
        let reason = "The shared map has no audio to match near scene 1 (Opening)."
        let rows: [(own: Own, refusal: String?, expected: String?)] = [
            (.none, reason, reason),
            (.none, nil, nil),
            (.communityMap, reason, reason),   // a community map never blocks a friend's (#553)
            (.ownMap, reason, nil),
            (.publisherChapters, reason, nil)
        ]
        for (index, row) in rows.enumerated() {
            try withFixture { fixture, store, _ in
                try store.saveItem(item("A"))
                try store.saveImportedCommentaryLayer(ImportedCommentaryLayer(
                    id: "layer", itemId: "A", packageDigest: "d", packageId: "p",
                    itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
                    importedAt: Date(timeIntervalSince1970: 10), sharedMapRefusalReason: row.refusal))
                func proposal(_ id: String) -> PortableListeningMapProposalArtifact {
                    PortableListeningMapProposalArtifact(id: id, createdAt: Date(timeIntervalSince1970: 1), generator: "test", scenes: [])
                }
                switch row.own {
                case .none: break
                case .communityMap:
                    try store.savePortableListeningMapProposal(proposal(CommunityMapConverter.proposalIdPrefix + "x"), itemId: "A")
                case .ownMap:
                    try store.savePortableListeningMapProposal(proposal("my-map"), itemId: "A")
                case .publisherChapters:
                    try store.saveTranscriptTimeline(SourceTranscriptTimeline(id: "t", itemId: "A", createdAt: Date(timeIntervalSince1970: 5),
                        timeline: TranscriptTimeline(segments: [
                            MediaTimelineSegment(id: "seg", startMs: 0, endMs: 1_000, text: "Hello.")
                        ], chapters: [MediaTimelineChapter(id: "ch", title: "Intro", startMs: 0, transcriptSegmentId: "seg")])))
                }
                let detail = try fixture.load("A", store)
                XCTAssertEqual(detail.sharedMapRefusalReason, row.expected, "row \(index)")
                // The same answer the old per-render reads gave.
                let oldAnswer = SharedListeningMapPlacement.storedRefusalReason(
                    layers: try store.loadImportedCommentaryLayers(itemId: "A"),
                    listenerHasMap: SharedListeningMapPlacement.listenerHasMap(
                        proposalIds: try store.portableListeningMapProposalIds(itemId: "A"),
                        hasTimelineChapters: try !store.loadTranscriptTimelineChapters(itemId: "A").isEmpty))
                XCTAssertEqual(detail.sharedMapRefusalReason, oldAnswer, "row \(index)")
            }
        }
    }

    func testOptionalTurnReadFailureReturnsNoTurnsAfterAHealthyControl() throws {
        try withFixture { fixture, store, database in
            try seedSessions(store)
            assertSelected(try fixture.load("A", store), session: "A-new")
            try executeSQL([
                "INSERT INTO records(kind,id,session_id,payload) VALUES('turn','bad-turn','A-new','not json')",
                """
                CREATE TRIGGER refuse_turn_quarantine BEFORE INSERT ON quarantined_records
                WHEN NEW.kind = 'turn'
                BEGIN SELECT RAISE(ABORT, 'loader optional fixture'); END
                """
            ], database: database)

            let detail = try fixture.load("A", store)
            XCTAssertTrue(detail.turns.isEmpty)
            XCTAssertEqual(detail.interjections.map(\.id), ["note-A-new"])
        }
    }

    func testPlacementPassUsesDecodedItemIdentityWhenStoredKeyDiffers() throws {
        try withFixture { _, store, database in
            try store.saveItem(item("A"))
            try executeSQL(["UPDATE records SET id = 'alias' WHERE kind = 'item' AND id = 'A'"], database: database)
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

    func testItemScreenCarriesTheReadableDateAndDescriptionOnlyWhenTheFeedGaveThem() throws {
        try withFixture { _, store, _ in
            var episode = item("episode")
            episode.publishedAt = "Tue, 29 Sep 2026 10:00:00 GMT"
            episode.descriptionText = String(repeating: "A long description. ", count: 200)
            try store.saveItem(episode)
            try store.saveItem(item("pasted"))
            var garbage = item("garbage")
            garbage.publishedAt = "not a date"
            try store.saveItem(garbage)

            let present = try ItemDetailLoader.load(id: "episode", store: store, snapshotItemId: nil, snapshotSessionId: nil, placementPasses: SharedMarginPlacementPasses())
            XCTAssertEqual(present.publishedDateText?.contains("2026"), true)
            XCTAssertEqual(present.descriptionText, episode.descriptionText, "the stored text is whole; the screen cuts the preview")
            let missing = try ItemDetailLoader.load(id: "pasted", store: store, snapshotItemId: nil, snapshotSessionId: nil, placementPasses: SharedMarginPlacementPasses())
            XCTAssertNil(missing.publishedDateText)
            XCTAssertNil(missing.descriptionText)
            let unreadable = try ItemDetailLoader.load(id: "garbage", store: store, snapshotItemId: nil, snapshotSessionId: nil, placementPasses: SharedMarginPlacementPasses())
            XCTAssertNil(unreadable.publishedDateText, "an unreadable date is omitted, not shown as written")
        }
    }

    /// #1167: the Item screen's "Open Original Source" shows for an item added by link and not for one
    /// imported from a file, a feed link that may hold a secret, or an item with no address.
    func testOriginalSourceIsOfferedOnlyForAPublicWebAddress() throws {
        try withFixture { fixture, store, _ in
            let rows: [(id: String, reference: String?, type: String?, expected: String?)] = [
                ("link", "https://example.com/essay", "url", "https://example.com/essay"),
                ("file", "/var/mobile/Documents/essay.md", "file", nil),
                ("manual", "manual-import", "manual", nil),
                ("private", "https://feeds.supercast.com/podcasts/123/abc?token=abc", "url", nil),
                ("none", nil, nil, nil)
            ]
            for row in rows {
                var saved = item(row.id)
                saved.externalReference = row.reference
                saved.externalReferenceType = row.type
                try store.saveItem(saved)
                let detail = try fixture.load(row.id, store)
                XCTAssertEqual(detail.originalSourceURL?.absoluteString, row.expected, row.id)
            }
        }
    }

    /// What the app model passes in beside the id: the snapshot's selected item and session.
    private final class Fixture {
        var snapshotItemId: String?
        var snapshotSessionId: String?

        func setSnapshot(item: String?, session: String?) {
            snapshotItemId = item
            snapshotSessionId = session
        }

        func load(_ id: String, _ store: SQLiteSessionStore) throws -> ItemDetailState {
            try ItemDetailLoader.load(id: id, store: store, snapshotItemId: snapshotItemId,
                snapshotSessionId: snapshotSessionId, placementPasses: SharedMarginPlacementPasses())
        }
    }

    private func withFixture(_ body: (Fixture, SQLiteSessionStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("item-detail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("library.sqlite")
        // This scope releases the SQLite owner before the directory is removed.
        do {
            let store = try SQLiteSessionStore(path: database.path)
            try body(Fixture(), store, database)
        }
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

    private func executeSQL(_ statements: [String], database: URL) throws {
        try StoreRawSQL.execute(statements, at: database.path)
    }
}
