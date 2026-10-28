import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2505: the Preparing Audio lists are worked out from the rows a Library reload already read, so the reload doesn't
/// go back to the store on the main thread for them.
final class AudioPreparationPresentationTests: XCTestCase {
    private func summary(_ id: String, title: String? = nil, trashed: Bool = false, finished: Bool = false) -> LibraryItemSummary {
        LibraryItemSummary(
            id: id, title: title ?? "Title \(id)", mediaType: "text", status: "ready",
            deletedAt: trashed ? Date(timeIntervalSince1970: 50) : nil,
            sourceCompletedAt: finished ? Date(timeIntervalSince1970: 60) : nil, hasListenableText: true, textCharacterCount: 100)
    }

    private func job(_ item: String, policy: PreparationJobPolicy = .whileCharging, at seconds: TimeInterval = 0) -> AudioPreparationJob {
        AudioPreparationJob(
            id: "job-\(item)", itemId: item, manifestId: "manifest-\(item)", policy: policy,
            requestedAt: Date(timeIntervalSince1970: seconds))
    }

    private func manifest(_ item: String, updatedAt seconds: TimeInterval) -> PreparedAudioManifest {
        let source = SourceLocator(documentId: "doc", spineItemId: nil, segmentId: "seg", utf8Start: 0, utf8End: 10)
        let chunk = PreparedAudioChunk(
            id: "chunk-\(item)", index: 0, sourceRange: source, relativePath: "c.m4a", byteCount: 1, checksumSHA256: "x", durationMs: 1000)
        return PreparedAudioManifest(
            id: "manifest-\(item)", itemId: item, sourcePackageId: "source",
            signature: TTSRenderSignature(
                engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v",
                synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: "digest"),
            state: .readyOffline, plannedChunkCount: 1, chunks: [chunk],
            artifact: PreparedAudioArtifact(relativePath: "a.m4a", byteCount: 1, checksumSHA256: "x", durationMs: 90_000),
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: seconds))
    }

    func testAJobForATrashedOrFinishedOrMissingItemIsStaleAndNotListed() {
        let presentation = AudioPreparationPresentation(
            items: [summary("live"), summary("trashed", trashed: true), summary("done", finished: true)],
            sessions: [],
            manifests: [],
            jobs: [job("live", at: 4), job("trashed", at: 3), job("done", at: 2), job("gone", at: 1)],
            activeItemId: nil)
        XCTAssertEqual(presentation.queue.map(\.itemId), ["live"])
        XCTAssertEqual(Set(presentation.staleJobIds), ["job-trashed", "job-done", "job-gone"])
    }

    func testAnExplicitRequestForAFinishedItemStays() {
        let presentation = AudioPreparationPresentation(
            items: [summary("done", finished: true)], sessions: [], manifests: [],
            jobs: [job("done", policy: .explicit)], activeItemId: nil)
        XCTAssertEqual(presentation.queue.map(\.itemId), ["done"])
        XCTAssertTrue(presentation.staleJobIds.isEmpty)
    }

    func testTitlesComeFromLiveItemsAndTheActiveItemIsPinnedFirst() {
        let presentation = AudioPreparationPresentation(
            items: [summary("a", title: "Alpha"), summary("b", title: "Beta")], sessions: [],
            manifests: [manifest("a", updatedAt: 9)], jobs: [job("a", at: 5), job("b", at: 1)], activeItemId: "b")
        XCTAssertEqual(presentation.queue.map(\.title), ["Beta", "Alpha"])
        XCTAssertEqual(presentation.queue.first?.isActivePlaybackItem, true)
        XCTAssertEqual(presentation.recentlyPrepared.map(\.title), ["Alpha"])
    }

    func testSnapshotAndLooseRowsGiveTheSameAnswer() {
        let items = [summary("a"), summary("b", trashed: true)]
        let jobs = [job("a", at: 2), job("b", at: 1)]
        let manifests = [manifest("a", updatedAt: 3), manifest("b", updatedAt: 4)]
        let snapshot = LibraryReadSnapshot(
            items: items, sessions: [], manifests: manifests, jobs: jobs, downloads: [])
        XCTAssertEqual(
            AudioPreparationPresentation(snapshot: snapshot, activeItemId: "a"),
            AudioPreparationPresentation(items: items, sessions: [], manifests: manifests, jobs: jobs, activeItemId: "a"))
    }

    func testAJobRequeuedAfterTheReloadReadIsNotDeleted() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("stale-jobs-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        try store.seed(item: Item(id: "trashed", title: "T", mediaType: "text", text: "Some words to read.", externalReference: nil, status: "ready"))
        try store.moveItemToTrash(id: "trashed")
        try store.seed(item: Item(id: "other", title: "O", mediaType: "text", text: "More words.", externalReference: nil, status: "ready"))
        try store.saveAudioPreparationJob(job("trashed"))
        try store.saveAudioPreparationJob(job("other", policy: .explicit))
        let read = AudioPreparationPresentation(
            items: try store.listItemSummaries(), sessions: try store.loadSessions(),
            manifests: [], jobs: try store.loadAudioPreparationJobs(), activeItemId: nil)
        XCTAssertEqual(read.staleJobIds, ["job-trashed"])

        // Between the read and the delete, the listener restores the item and queues it again under the same job id.
        try store.restoreItem(id: "trashed")
        XCTAssertEqual(try store.deleteStaleAudioPreparationJobs(among: read.staleJobIds), [])
        XCTAssertEqual(Set(try store.loadAudioPreparationJobs().map(\.id)), ["job-trashed", "job-other"])

        // Still trashed at delete time: it goes, and a job that was never a candidate stays.
        try store.moveItemToTrash(id: "trashed")
        XCTAssertEqual(try store.deleteStaleAudioPreparationJobs(among: read.staleJobIds), ["job-trashed"])
        XCTAssertEqual(try store.loadAudioPreparationJobs().map(\.id), ["job-other"])
    }

    /// #2507: the app's Library reload builds the Preparing Audio lists from its own snapshot instead of reading the
    /// items, sessions, manifests and jobs a second time. The two must agree on a real store, or the shortcut changes
    /// what the queue shows and which jobs are deleted.
    func testTheLibrarySnapshotOfARealStoreGivesTheSameListsAsTheFourSeparateReads() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-lists-\(UUID().uuidString).sqlite").path
        let store = try SQLiteSessionStore(path: path)
        for id in ["live", "trashed", "second"] {
            try store.seed(item: Item(id: id, title: "Title \(id)", mediaType: "text", text: "Some words to read.", externalReference: nil, status: "ready"))
        }
        try store.moveItemToTrash(id: "trashed")
        try store.saveAudioPreparationJob(job("live", at: 2))
        try store.saveAudioPreparationJob(job("second", policy: .explicit, at: 3))
        try store.saveAudioPreparationJob(job("trashed", at: 1))
        try store.savePreparedAudioManifest(manifest("live", updatedAt: 5))

        for active in [nil, "second"] {
            let fromSnapshot = AudioPreparationPresentation(snapshot: try LibraryReadSnapshot.read(store: store), activeItemId: active)
            let fromReads = AudioPreparationPresentation(
                items: try store.listItemSummaries(), sessions: try store.loadSessions(),
                manifests: try store.loadPreparedAudioManifests(), jobs: try store.loadAudioPreparationJobs(), activeItemId: active)
            XCTAssertEqual(fromSnapshot, fromReads)
            XCTAssertEqual(fromSnapshot.staleJobIds, ["job-trashed"])
            XCTAssertEqual(Set(fromSnapshot.queue.map(\.itemId)), ["live", "second"])
            XCTAssertEqual(fromSnapshot.recentlyPrepared.map(\.title), ["Title live"])
        }
    }
}
