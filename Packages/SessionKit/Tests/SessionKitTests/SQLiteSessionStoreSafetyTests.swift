import Foundation
import SQLite3
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

private let testSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteSessionStoreSafetyTests: XCTestCase {
    func testRecipientRecoveryCheckpointSurvivesReopenAndRejectsSupersededWriter() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "store.sqlite").path
        let store = try SQLiteSessionStore(path: path)
        try store.saveItem(Item(id: "episode", title: "Episode", mediaType: "podcast", text: "",
                                externalReference: "test", status: "ready"))
        var job = RecipientTranscriptRecoveryJob(
            itemId: "episode", editionSHA256: String(repeating: "a", count: 64),
            durationMs: 400_000, localSourcePath: "/private/episode.m4a",
            windows: [.init(startMs: 0, endMs: 210_000), .init(startMs: 190_000, endMs: 400_000)])
        job.windows[0].timeline = TranscriptTimeline(
            segments: [MediaTimelineSegment(id: "first", startMs: 2_000, endMs: 3_000, text: "Earlier words")],
            chapters: [], durationMs: 400_000)
        try store.saveRecipientTranscriptRecoveryJob(job)
        let reopened = try SQLiteSessionStore(path: path)
        let restored = try XCTUnwrap(reopened.loadRecipientTranscriptRecoveryJob(itemId: "episode"))
        XCTAssertEqual(restored, job)
        XCTAssertNotNil(restored.windows[0].timeline)
        XCTAssertNil(restored.windows[1].timeline)
        XCTAssertFalse(restored.matches(editionSHA256: String(repeating: "b", count: 64), durationMs: 400_000))
        let replacement = RecipientTranscriptRecoveryJob(
            itemId: "episode", editionSHA256: String(repeating: "b", count: 64),
            durationMs: 400_000, localSourcePath: job.localSourcePath, windows: job.windows.map {
                .init(startMs: $0.startMs, endMs: $0.endMs)
            })
        try reopened.saveRecipientTranscriptRecoveryJob(replacement, replacingExisting: true)
        XCTAssertThrowsError(try store.saveRecipientTranscriptRecoveryJob(job))
        XCTAssertEqual(try reopened.loadRecipientTranscriptRecoveryJob(itemId: "episode"), replacement)
        try reopened.deleteItem(id: "episode")
        XCTAssertTrue(try reopened.loadRecipientTranscriptRecoveryJobs().isEmpty)
        XCTAssertThrowsError(try store.saveRecipientTranscriptRecoveryJob(job))
    }

    func testRecipientRecoveryRejectsInvalidBoundsAndPersistsServiceSuspension() throws {
        let store = try SQLiteSessionStore(path: ":memory:")
        try store.saveItem(Item(id: "episode", title: "Episode", mediaType: "podcast", text: "",
                                externalReference: "test", status: "ready"))
        var job = RecipientTranscriptRecoveryJob(
            itemId: "episode", editionSHA256: String(repeating: "a", count: 64),
            durationMs: 10_000, localSourcePath: "/private/episode.m4a",
            windows: [.init(startMs: 0, endMs: 20_000)])
        XCTAssertThrowsError(try store.saveRecipientTranscriptRecoveryJob(job))
        job.windows = [.init(startMs: 0, endMs: 10_000)]
        job.status = .suspended
        job.failureReason = "speech_service_unavailable"
        try store.saveRecipientTranscriptRecoveryJob(job)
        XCTAssertEqual(try store.loadRecipientTranscriptRecoveryJob(itemId: "episode")?.status, .suspended)
    }

    func testPodcastEvidenceAndOwnedAssetRollbackTogetherAfterInjectedFailure() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        let base = Interjection(
            id: "capture", itemId: "episode", sessionId: "session",
            targetType: .item, targetId: "episode", createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 20,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0,
                           anchorBefore: "before", anchorAfter: "after", mediaTimeMs: 20_000),
            audioPath: "voice.m4a", audioStatus: "saved", transcriptionStatus: "pending",
            transcript: nil, cleanedTranscript: nil, displayText: nil, status: "active"
        )
        try store.saveInterjection(base)
        let relativePath = "SpokenMargins/AnchorEvidence/session/capture/anchor-session-capture-stream-pre.shazamsignature"
        let digest = String(repeating: "a", count: 64)
        var committed = base
        committed.podcastAnchorEvidence = [CapturedPodcastAnchorEvidence(
            id: "anchor-session-capture-stream-pre",
            localPath: "/private/app-support/" + relativePath,
            durationMs: 12_000, anchorOffsetMs: 12_000,
            provenance: .observedDecodedPlayback, windowRole: .preInterjection,
            byteCount: 42, checksumSHA256: digest
        )]
        let asset = OwnedOfflineAsset(
            id: "anchor-evidence-session-capture-anchor-session-capture-stream-pre",
            itemId: "episode", category: .fingerprintMap,
            relativePath: relativePath, byteCount: 42,
            checksumSHA256: digest, isReproducible: false,
            protections: [.interjection],
            lastAccessedAt: Date(timeIntervalSince1970: 1),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertThrowsError(try store.commitPodcastAnchorEvidence(committed, ownedAssets: []))
        var mismatchedAsset = asset
        mismatchedAsset.relativePath = "SpokenMargins/AnchorEvidence/elsewhere.shazamsignature"
        XCTAssertThrowsError(try store.commitPodcastAnchorEvidence(committed, ownedAssets: [mismatchedAsset]))
        XCTAssertEqual(try store.loadInterjections(sessionId: "session"), [base])
        XCTAssertTrue(try store.loadOwnedOfflineAssets().isEmpty)
        XCTAssertThrowsError(try store.commitPodcastAnchorEvidence(
            committed, ownedAssets: [asset],
            afterLedgerWrites: { throw SessionKitError.persistenceFailed("injected_capture_commit_failure") }
        ))
        let reopened = try SQLiteSessionStore(path: path)
        XCTAssertEqual(try reopened.loadInterjections(sessionId: "session"), [base])
        XCTAssertTrue(try reopened.loadOwnedOfflineAssets().isEmpty)

        try reopened.commitPodcastAnchorEvidence(committed, ownedAssets: [asset])
        XCTAssertEqual(try reopened.loadInterjections(sessionId: "session"), [committed])
        XCTAssertEqual(try reopened.loadOwnedOfflineAssets(), [asset])
        try reopened.commitPodcastAnchorEvidence(committed, ownedAssets: [asset])
        XCTAssertEqual(try reopened.loadOwnedOfflineAssets(), [asset])
        try reopened.commitPodcastAnchorEvidence(committed, ownedAssets: [])
        XCTAssertEqual(try reopened.loadOwnedOfflineAssets(), [asset])

        var legacy = base
        legacy.id = "legacy"
        legacy.podcastAnchorEvidence = committed.podcastAnchorEvidence
        try reopened.saveInterjection(legacy)
        XCTAssertNoThrow(try reopened.commitPodcastAnchorEvidence(legacy, ownedAssets: []))
        XCTAssertEqual(try reopened.loadInterjections(sessionId: "session").count, 2)
    }

    func testIndeterminateEvidenceReadPreservesCommittedReferenceAcrossReopen() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        let evidence = CapturedPodcastAnchorEvidence(
            id: "capture-pre", localPath: "/private/app-support/capture-pre.shazamsignature",
            durationMs: 11_700, anchorOffsetMs: 12_000,
            provenance: .observedDecodedPlayback, windowRole: .preInterjection,
            byteCount: 42, checksumSHA256: String(repeating: "a", count: 64)
        )
        let margin = Interjection(
            id: "capture", itemId: "episode", sessionId: "session",
            targetType: .item, targetId: "episode", createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 20,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0,
                           anchorBefore: "before", anchorAfter: "after", mediaTimeMs: 20_000),
            audioPath: "voice.m4a", audioStatus: "saved", transcriptionStatus: "pending",
            transcript: nil, cleanedTranscript: nil, displayText: nil, status: "active",
            podcastAnchorEvidence: [evidence],
            podcastAnchorCaptureWindows: [
                .init(role: .preInterjection, state: .committed, attempt: 1, anchorMediaTimeMs: 20_000)
            ]
        )
        try store.saveInterjection(margin)
        let reopened = try SQLiteSessionStore(path: path)
        let stored = try XCTUnwrap(reopened.loadInterjections(sessionId: "session").first)
        let indeterminate = PodcastAnchorEvidenceIntegrityReconciler.reconcile(
            stored, interruptedJobs: true,
            readFile: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: 13) },
            signatureIsValid: { !$0.isEmpty }
        )
        XCTAssertEqual(indeterminate.indeterminateReadCount, 1)
        XCTAssertEqual(indeterminate.interjection, stored)
        try reopened.saveInterjection(indeterminate.interjection)
        let reopenedAgain = try SQLiteSessionStore(path: path)
        let retained = try XCTUnwrap(reopenedAgain.loadInterjections(sessionId: "session").first)
        XCTAssertEqual(retained.podcastAnchorEvidence, [evidence])
        XCTAssertEqual(retained.podcastAnchorEvidence?.first?.anchorOffsetMs, 12_000)
        XCTAssertEqual(retained.podcastAnchorEvidence?.first?.provenance, .observedDecodedPlayback)
        XCTAssertEqual(retained.podcastAnchorCaptureWindows?.first?.state, .committed)

        let missing = PodcastAnchorEvidenceIntegrityReconciler.reconcile(
            retained, interruptedJobs: false,
            readFile: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: 2) },
            signatureIsValid: { _ in true }
        )
        XCTAssertTrue(missing.interjection.podcastAnchorEvidence?.isEmpty == true)
        XCTAssertEqual(missing.interjection.podcastAnchorCaptureWindows?.first?.state, .retryableFailure)
        let corrupt = PodcastAnchorEvidenceIntegrityReconciler.reconcile(
            retained, interruptedJobs: false,
            readFile: { _ in Data() }, signatureIsValid: { _ in false }
        )
        XCTAssertTrue(corrupt.interjection.podcastAnchorEvidence?.isEmpty == true)
    }

    func testAgedPodcastEvidenceOrphanCleanupIsIdempotentAndPreservesOtherFiles() throws {
        let support = FileManager.default.temporaryDirectory
            .appending(path: "podcast-evidence-orphans-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let store = try SQLiteSessionStore(path: support.appending(path: "store.sqlite").path)
        let session = Session(
            id: "session", itemId: "episode", status: "finished", phase: .finished,
            currentTargetType: .transcriptBackedMedia, currentTargetId: "episode",
            position: Position(mediaTimeMs: 20_000), completionPercent: 20, playbackRate: 1
        )
        try store.saveSession(session)
        let root = support.appending(path: "SpokenMargins/AnchorEvidence", directoryHint: .isDirectory)
        let marginDirectory = root.appending(path: "session/capture", directoryHint: .isDirectory)
        let unrelatedDirectory = root.appending(path: "unknown/capture", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: marginDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: true)
        func file(_ name: String, in directory: URL) throws -> URL {
            let url = directory.appending(path: name)
            try Data("signature".utf8).write(to: url)
            return url
        }
        let prefix = "anchor-session-capture-"
        let orphan = try file(prefix + "local-pre.shazamsignature", in: marginDirectory)
        let referenced = try file(prefix + "stream-pre.shazamsignature", in: marginDirectory)
        let ledgerOwned = try file(prefix + "stream-post.shazamsignature", in: marginDirectory)
        let young = try file(prefix + "source-window-pre.shazamsignature", in: marginDirectory)
        let unrelated = try file("personal-notes.txt", in: marginDirectory)
        let unknownMargin = try file(prefix + "local-post.shazamsignature", in: unrelatedDirectory)
        let old = Date(timeIntervalSinceNow: -2 * PodcastAnchorEvidenceOrphanReconciler.minimumOrphanAge)
        for url in [orphan, referenced, ledgerOwned, unrelated, unknownMargin] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        var margin = Interjection(
            id: "capture", itemId: "episode", sessionId: session.id,
            targetType: .item, targetId: "episode", createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 20,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0,
                           anchorBefore: "", anchorAfter: "", mediaTimeMs: 20_000),
            audioPath: "voice.m4a", audioStatus: "saved", transcriptionStatus: "pending",
            transcript: nil, cleanedTranscript: nil, displayText: nil, status: "active"
        )
        margin.podcastAnchorEvidence = [CapturedPodcastAnchorEvidence(
            id: "pre", localPath: referenced.path, durationMs: 12_000,
            anchorOffsetMs: 12_000, provenance: .observedDecodedPlayback,
            windowRole: .preInterjection
        )]
        try store.saveInterjection(margin)
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "ledger-only", itemId: "episode", category: .fingerprintMap,
            relativePath: "SpokenMargins/AnchorEvidence/session/capture/\(ledgerOwned.lastPathComponent)",
            byteCount: 9, isReproducible: false, protections: [.interjection]
        ))
        XCTAssertEqual(try PodcastAnchorEvidenceOrphanReconciler.reclaim(in: root, store: store), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        for url in [referenced, ledgerOwned, young, unrelated, unknownMargin] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        }
        XCTAssertEqual(try PodcastAnchorEvidenceOrphanReconciler.reclaim(in: root, store: store), 0)
    }

    func testPodcastCaptureRejectsStaleAttemptAndEditionWithoutOverwritingCommittedFlank() throws {
        let store = try SQLiteSessionStore(path: temporaryDatabasePath())
        let session = Session(
            id: "capture-session", itemId: "episode", status: "finished", phase: .finished,
            currentTargetType: .transcriptBackedMedia, currentTargetId: "episode", position: Position(mediaTimeMs: 20_000),
            completionPercent: 20, playbackRate: 1
        )
        try store.saveSession(session)
        var margin = Interjection(
            id: "ij-001", itemId: "episode", sessionId: session.id,
            targetType: .item, targetId: "episode", createdAt: Date(timeIntervalSince1970: 1),
            roughPercent: 20,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 20_000),
            audioPath: "voice.m4a", audioStatus: "saved", transcriptionStatus: "pending",
            transcript: nil, cleanedTranscript: nil, displayText: nil, status: "active",
            sourceExactEditionSHA256: "edition-a",
            podcastAnchorCaptureWindows: [.init(role: .preInterjection, anchorMediaTimeMs: 20_000),
                                          .init(role: .postResume, anchorMediaTimeMs: 20_000)]
        )
        margin.updatePodcastAnchorWindow(.preInterjection) { $0.accepted() }
        margin.updatePodcastAnchorWindow(.preInterjection) { $0.accepted() }
        margin.updatePodcastAnchorWindow(.postResume) { $0.accepted() }
        try store.saveInterjection(margin)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "capture", displayName: "Capture", capabilities: [:]),
            repository: store
        )
        let newer = CapturedPodcastAnchorEvidence(
            id: "pre-new", localPath: "pre-new.shazamsignature", durationMs: 12_000,
            anchorOffsetMs: 12_000, provenance: .observedDecodedPlayback, windowRole: .preInterjection
        )
        XCTAssertThrowsError(try engine.podcastAnchorEvidenceCompleted(
            interjectionId: margin.id, sessionId: session.id, evidence: [newer],
            sourceExactEditionSHA256: nil, expectedAttemptGeneration: 1
        ))
        XCTAssertThrowsError(try engine.podcastAnchorEvidenceCompleted(
            interjectionId: margin.id, sessionId: session.id, evidence: [newer],
            sourceExactEditionSHA256: "edition-b", expectedAttemptGeneration: 2
        ))
        try engine.podcastAnchorEvidenceCompleted(
            interjectionId: margin.id, sessionId: session.id, evidence: [newer],
            sourceExactEditionSHA256: "edition-a", expectedAttemptGeneration: 2
        )
        XCTAssertThrowsError(try engine.podcastAnchorEvidenceFailed(
            interjectionId: margin.id, sessionId: session.id, reason: "late failure",
            windowRole: .preInterjection, expectedAttemptGeneration: 1
        ))
        let restored = try XCTUnwrap(store.loadInterjections(sessionId: session.id).first)
        XCTAssertEqual(restored.podcastAnchorEvidence?.map(\.id), ["pre-new"])
        XCTAssertEqual(restored.podcastAnchorCaptureWindows?.first?.state, .committed)
        XCTAssertEqual(restored.podcastAnchorCaptureWindows?.last?.state, .collecting)
        XCTAssertEqual(restored.sourceExactEditionSHA256, "edition-a")
        var missingRole = restored
        missingRole.podcastAnchorCaptureWindows = nil
        try store.saveInterjection(missingRole)
        XCTAssertThrowsError(try engine.podcastAnchorEvidenceCompleted(
            interjectionId: margin.id, sessionId: session.id, evidence: [newer],
            sourceExactEditionSHA256: "edition-a", expectedAttemptGeneration: 2
        ), "Generation-bearing callbacks must fail closed when their durable role row is missing")
    }

    func testSourceReferenceEvidenceCannotAddCaptureJobRole() throws {
        var margin = Interjection(
            id: "ij-source", itemId: "episode", sessionId: "session", targetType: .item,
            targetId: "episode", createdAt: Date(), roughPercent: 20,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 20_000),
            audioPath: "voice.m4a", audioStatus: "saved", transcriptionStatus: "pending",
            transcript: nil, cleanedTranscript: nil, displayText: nil, status: "active"
        )
        margin.updatePodcastAnchorWindow(.sourceWindowBefore) { $0.accepted() }
        margin.updatePodcastAnchorWindow(.sourceWindowAfter) { $0.accepted() }
        XCTAssertNil(margin.podcastAnchorCaptureWindows)
        margin.updatePodcastAnchorWindow(.preInterjection) { $0.accepted() }
        XCTAssertEqual(margin.podcastAnchorCaptureWindows?.map(\.role), [.preInterjection])
    }

    func testPodcastCaptureWindowsSurviveRestartAndOutOfOrderCompletionAcrossSessions() throws {
        let path = temporaryDatabasePath()
        let store = try SQLiteSessionStore(path: path)
        func makeMargin(session: String) -> Interjection {
            Interjection(
                id: "ij-001", itemId: "episode", sessionId: session,
                targetType: .item, targetId: "episode", createdAt: Date(timeIntervalSince1970: 1),
                roughPercent: 25,
                anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 20_000),
                audioPath: "voice.m4a", audioStatus: "saved", transcriptionStatus: "pending",
                transcript: nil, cleanedTranscript: nil, displayText: nil, status: "active",
                podcastAnchorCaptureWindows: [
                    .init(role: .preInterjection, anchorMediaTimeMs: 20_000),
                    .init(role: .postResume, anchorMediaTimeMs: 20_000)
                ]
            )
        }
        var first = makeMargin(session: "one")
        var second = makeMargin(session: "two")
        first.updatePodcastAnchorWindow(.postResume) { $0.accepted() }
        first.updatePodcastAnchorWindow(.preInterjection) { $0.failed("track_waiting", retryable: true) }
        second.updatePodcastAnchorWindow(.preInterjection) { $0.accepted() }
        try store.saveInterjection(first)
        try store.saveInterjection(second)

        let reopened = try SQLiteSessionStore(path: path)
        var restored = try XCTUnwrap(reopened.loadInterjections(sessionId: "one").first)
        XCTAssertEqual(restored.podcastAnchorCaptureWindows?.count, 2)
        XCTAssertEqual(restored.podcastAnchorCaptureWindows?.first?.firstFailureReason, "track_waiting")
        restored.updatePodcastAnchorWindow(.postResume) { $0.committed() }
        restored.updatePodcastAnchorWindow(.preInterjection) { $0.failed("track_still_waiting", retryable: false) }
        XCTAssertEqual(restored.podcastAnchorEvidenceCaptureStatus, .unavailable)
        XCTAssertEqual(restored.podcastAnchorCaptureWindows?.first?.firstFailureReason, "track_waiting")
        XCTAssertEqual(restored.podcastAnchorCaptureWindows?.first?.latestFailureReason, "track_still_waiting")
        try reopened.saveInterjection(restored)
        XCTAssertEqual(try reopened.loadInterjections(sessionId: "two").first?.podcastAnchorCaptureWindows?.first?.state, .collecting)
        XCTAssertEqual(try reopened.loadInterjections(sessionId: "one").first?.podcastAnchorCaptureWindows?.last?.state, .committed)
    }

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
