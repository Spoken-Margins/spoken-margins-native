import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2509: the clean-up reads and deletes behind expired and removed episode-map jobs, on a real SQLite Library.
final class EpisodeMapJobCleanupTests: XCTestCase {
    private var root: URL!
    private var store: SQLiteSessionStore!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("map-job-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func job(_ itemId: String, age: TimeInterval, cancelled: Bool = false) throws -> EpisodeMapPreparationJob {
        let job = EpisodeMapPreparationJob(
            id: AutomaticEpisodeMapJobs.jobId(itemId: itemId), itemId: itemId, policy: .whileCharging,
            requestedAt: now.addingTimeInterval(-age), isCancelled: cancelled
        )
        try store.saveEpisodeMapPreparationJob(job)
        return job
    }

    private func transientAsset(_ itemId: String, id: String) throws {
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: id, itemId: itemId, category: .transientEpisodeTranscript, relativePath: "\(id).json", byteCount: 10, isReproducible: true
        ))
    }

    func testOnlyCancelledAndOldJobsAreExpiredWithTheirMapState() throws {
        try job("fresh", age: 6 * day + 23 * 3600)
        try job("old", age: 7 * day + 60)
        try job("old-mapped", age: 8 * day)
        try job("cancelled", age: 60, cancelled: true)
        try store.saveEditionFingerprintSpine(EditionFingerprintSpineArtifact(id: "spine-old-mapped", itemId: "old-mapped", landmarks: []))

        let expired = EpisodeMapJobCleanup.expiredJobs(now: now, store: store)

        XCTAssertEqual(Set(expired.map(\.itemId)), ["old", "old-mapped", "cancelled"])
        XCTAssertEqual(expired.first { $0.itemId == "old-mapped" }?.hasMap, true)
        XCTAssertEqual(expired.first { $0.itemId == "old" }?.hasMap, false)
        XCTAssertEqual(try store.loadEpisodeMapPreparationJobs().count, 4, "reading deletes nothing")
        XCTAssertEqual(EpisodeMapJobCleanup.expiredJobs(now: now, store: try freshStore()), [])
    }

    func testDeleteExpiredRemovesTheJobsAndTheItemsTransientLedgerRowsOnly() throws {
        try job("old", age: 8 * day)
        try job("fresh", age: 60)
        try transientAsset("old", id: "asset-old-transient")
        try transientAsset("fresh", id: "asset-fresh-transient")
        try store.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "asset-old-chunk", itemId: "old", category: .preparedChunk, relativePath: "c.caf", byteCount: 10, isReproducible: true
        ))

        let expired = EpisodeMapJobCleanup.expiredJobs(now: now, store: store)
        let deleted = EpisodeMapJobCleanup.deleteExpired(expired, now: now, store: store)

        XCTAssertEqual(deleted, [AutomaticEpisodeMapJobs.jobId(itemId: "old")])
        XCTAssertEqual(try store.loadEpisodeMapPreparationJobs().map(\.itemId), ["fresh"])
        XCTAssertEqual(Set(try store.loadOwnedOfflineAssets().map(\.id)), ["asset-fresh-transient", "asset-old-chunk"])
    }

    func testAJobAskedForAgainBetweenTheReadAndTheDeleteIsKept() throws {
        try job("old", age: 8 * day)
        let expired = EpisodeMapJobCleanup.expiredJobs(now: now, store: store)
        try job("old", age: 0) // the listener asked again: the same stable id, saved over

        XCTAssertEqual(EpisodeMapJobCleanup.deleteExpired(expired, now: now, store: store), [])
        XCTAssertEqual(try store.loadEpisodeMapPreparationJobs().count, 1)
    }

    func testStillExpiredDropsAJobAskedForAgainAndRereadsTheMapState() throws {
        try job("again", age: 8 * day)
        try job("mapped-late", age: 8 * day)
        try job("stays", age: 8 * day)
        let expired = EpisodeMapJobCleanup.expiredJobs(now: now, store: store)
        XCTAssertEqual(expired.filter(\.hasMap).count, 0)

        try job("again", age: 0) // asked for again after the first read
        try store.saveEditionFingerprintSpine(EditionFingerprintSpineArtifact(id: "spine-late", itemId: "mapped-late", landmarks: []))
        try store.deleteEpisodeMapPreparationJob(id: AutomaticEpisodeMapJobs.jobId(itemId: "gone-job"))

        let confirmed = EpisodeMapJobCleanup.stillExpired(expired, now: now, store: store)

        XCTAssertEqual(Set(confirmed.map(\.itemId)), ["mapped-late", "stays"])
        XCTAssertEqual(confirmed.first { $0.itemId == "mapped-late" }?.hasMap, true, "a map saved since the first read keeps its folder")
        XCTAssertEqual(confirmed.first { $0.itemId == "stays" }?.hasMap, false)
        try store.deleteEpisodeMapPreparationJob(id: AutomaticEpisodeMapJobs.jobId(itemId: "stays"))
        XCTAssertEqual(Set(EpisodeMapJobCleanup.stillExpired(expired, now: now, store: store).map(\.itemId)), ["mapped-late"], "a job already deleted is skipped")
    }

    func testDeleteJobsRemovesOnlyThatItemsJobsIncludingSimilarlyNamedItems() throws {
        try job("ep-1", age: 0)
        try job("ep-10", age: 0)
        try job("EP-1", age: 0)
        try store.saveEpisodeMapPreparationJob(EpisodeMapPreparationJob(id: "second-job-ep-1", itemId: "ep-1", policy: .explicit))

        XCTAssertEqual(EpisodeMapJobCleanup.deleteJobs(itemId: "ep-1", store: store), 2)
        XCTAssertEqual(Set(try store.loadEpisodeMapPreparationJobs().map(\.itemId)), ["ep-10", "EP-1"])
        XCTAssertEqual(EpisodeMapJobCleanup.deleteJobs(itemId: "none", store: store), 0)
    }

    func testTheCleanUpRunsOffTheCallersActorInLineWithQueueing() async throws {
        try job("old", age: 8 * day)
        let reader = StoreReader(store)
        let now = self.now

        let expired = try await reader.readInOrder(AutomaticEpisodeMapJobs.orderKey) {
            EpisodeMapJobCleanup.expiredJobs(now: now, store: $0)
        }
        let deleted = try await reader.readInOrder(AutomaticEpisodeMapJobs.orderKey) {
            EpisodeMapJobCleanup.deleteExpired(expired, now: now, store: $0)
        }

        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(try store.loadEpisodeMapPreparationJobs(), [])
    }

    private func freshStore() throws -> SQLiteSessionStore {
        try SQLiteSessionStore(path: root.appendingPathComponent("other-\(UUID().uuidString).sqlite").path)
    }
}
