import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2509: the reads and the save behind automatic episode-map queueing, on a real SQLite Library.
final class AutomaticEpisodeMapJobsTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteSessionStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("auto-map-jobs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func item(_ id: String, media: ItemMedia?) -> Item {
        Item(id: id, title: "Title \(id)", mediaType: media == nil ? "article" : "audio", text: media == nil ? "Body." : nil,
             externalReference: "https://example.com/\(id)", status: "ready", media: media, author: nil)
    }

    private func episode(_ id: String, _ type: AudioSourceType = .nativeMediaFile) throws {
        try store.saveItem(item(id, media: ItemMedia(sourceType: type, url: "https://cdn.example.com/\(id).mp3", durationMs: 600_000)))
    }

    func testCandidatesAreEpisodesWithoutAMapInTheOrderGiven() throws {
        try episode("ep-b")
        try episode("ep-a", .remoteStream)
        try store.saveItem(item("article-1", media: nil))
        try episode("ep-mapped")
        try store.saveEditionFingerprintSpine(spine(itemId: "ep-mapped"))

        let ids = ["ep-b", "article-1", "ep-mapped", "missing", "ep-a"]
        XCTAssertEqual(AutomaticEpisodeMapJobs.candidates(itemIds: ids, store: store), ["ep-b", "ep-a"])
        XCTAssertEqual(AutomaticEpisodeMapJobs.candidates(itemIds: [], store: store), [])
    }

    func testEnqueueSavesOneJobPerItemUnderAStableId() throws {
        let saved = AutomaticEpisodeMapJobs.enqueue(itemIds: ["ep-1", "ep/2 odd"], policy: .whileCharging, store: store)
        XCTAssertEqual(saved, ["ep-1", "ep/2 odd"])
        let job = try XCTUnwrap(store.loadEpisodeMapPreparationJob(id: "episode-map-job-ep-1"))
        XCTAssertEqual(job.itemId, "ep-1")
        XCTAssertEqual(job.policy, .whileCharging)
        XCTAssertEqual(AutomaticEpisodeMapJobs.jobId(itemId: "ep/2 odd"), "episode-map-job-ep-2-odd")
        XCTAssertNotNil(try store.loadEpisodeMapPreparationJob(id: "episode-map-job-ep-2-odd"))
    }

    func testALiveJobIsKeptAndACancelledOneIsReplaced() throws {
        var live = EpisodeMapPreparationJob(id: AutomaticEpisodeMapJobs.jobId(itemId: "ep-live"), itemId: "ep-live", policy: .explicit,
                                            stage: .verifySource, nextUnitIndex: 7)
        try store.saveEpisodeMapPreparationJob(live)
        var cancelled = EpisodeMapPreparationJob(id: AutomaticEpisodeMapJobs.jobId(itemId: "ep-cancelled"), itemId: "ep-cancelled", policy: .explicit,
                                                 nextUnitIndex: 3, isCancelled: true)
        try store.saveEpisodeMapPreparationJob(cancelled)

        let saved = AutomaticEpisodeMapJobs.enqueue(itemIds: ["ep-live", "ep-cancelled"], policy: .whileCharging, store: store)

        XCTAssertEqual(saved, ["ep-cancelled"])
        live = try XCTUnwrap(store.loadEpisodeMapPreparationJob(id: live.id))
        XCTAssertEqual(live.policy, .explicit, "a live job is not overwritten")
        XCTAssertEqual(live.nextUnitIndex, 7)
        cancelled = try XCTUnwrap(store.loadEpisodeMapPreparationJob(id: cancelled.id))
        XCTAssertFalse(cancelled.isCancelled)
        XCTAssertEqual(cancelled.policy, .whileCharging)
        XCTAssertEqual(cancelled.nextUnitIndex, 0)
    }

    /// The audit of #3077: a map that finishes after `candidates` ran must not get a fresh job saved over it.
    func testAMapSavedAfterTheCandidateReadGetsNoJob() throws {
        try episode("ep-1")
        try episode("ep-2")
        let candidates = AutomaticEpisodeMapJobs.candidates(itemIds: ["ep-1", "ep-2"], store: store)
        XCTAssertEqual(candidates, ["ep-1", "ep-2"])
        try store.saveEditionFingerprintSpine(spine(itemId: "ep-1"))

        let saved = AutomaticEpisodeMapJobs.enqueue(itemIds: candidates, policy: .whileCharging, store: store)

        XCTAssertEqual(saved, ["ep-2"])
        XCTAssertNil(try store.loadEpisodeMapPreparationJob(id: AutomaticEpisodeMapJobs.jobId(itemId: "ep-1")))
    }

    func testQueueingTwiceLeavesOneJob() throws {
        AutomaticEpisodeMapJobs.enqueue(itemIds: ["ep-1"], policy: .whileCharging, store: store)
        let second = AutomaticEpisodeMapJobs.enqueue(itemIds: ["ep-1"], policy: .whileCharging, store: store)
        XCTAssertEqual(second, [])
        XCTAssertEqual(try store.loadEpisodeMapPreparationJobs().count, 1)
    }

    /// Off the main thread the result is the same, and the main actor stays free while it runs (the point of #2509).
    func testTheSameResultFromABackgroundTask() async throws {
        try episode("ep-1")
        let store = store!
        let saved = try await StoreReader(store).read { store in
            let candidates = AutomaticEpisodeMapJobs.candidates(itemIds: ["ep-1"], store: store)
            return AutomaticEpisodeMapJobs.enqueue(itemIds: candidates, policy: .whileCharging, store: store)
        }
        XCTAssertEqual(saved, ["ep-1"])
    }

    private func spine(itemId: String) -> EditionFingerprintSpineArtifact {
        EditionFingerprintSpineArtifact(id: "spine-\(itemId)", itemId: itemId, landmarks: [])
    }
}
