import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #2507: a caller that has an item id or a job id reads that job, not every job in the queue.
final class PreparationJobsByItemTests: XCTestCase {
    private func makeStore(meter: StoreReadMeter? = nil) throws -> (SQLiteSessionStore, String) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("prep-jobs-\(UUID().uuidString).sqlite").path
        return (try SQLiteSessionStore(path: path, readMeter: meter), path)
    }

    private func audioJob(_ id: String, item: String) -> AudioPreparationJob {
        AudioPreparationJob(id: id, itemId: item, manifestId: "manifest-\(id)", policy: .explicit)
    }

    private func mapJob(_ id: String, item: String, cancelled: Bool = false) -> EpisodeMapPreparationJob {
        EpisodeMapPreparationJob(id: id, itemId: item, policy: .whileCharging, isCancelled: cancelled)
    }

    func testAudioJobsByItemReadOnlyThatItemsRowsInTheWholeReadsOrder() throws {
        let meter = StoreReadMeter()
        let (store, path) = try makeStore(meter: meter)
        defer { try? FileManager.default.removeItem(atPath: path) }
        for job in [audioJob("a1", item: "item-a"), audioJob("b1", item: "item-b"),
                    audioJob("a2", item: "item-a"), audioJob("c1", item: "item-c")] {
            try store.saveAudioPreparationJob(job)
        }

        meter.reset()
        let mine = try store.loadAudioPreparationJobs(itemId: "item-a")
        let byItem = meter.totals(for: "loadAudioPreparationJobs(itemId:)")

        XCTAssertEqual(mine.map(\.id), try store.loadAudioPreparationJobs().filter { $0.itemId == "item-a" }.map(\.id))
        XCTAssertEqual(Set(mine.map(\.id)), ["a1", "a2"])
        XCTAssertEqual(byItem.rows, 2, "the other items' jobs are not decoded")
        XCTAssertEqual(try store.loadAudioPreparationJobs(itemId: "item-none"), [])
    }

    func testAudioJobByIdReadsOneRowAndMissesCleanly() throws {
        let meter = StoreReadMeter()
        let (store, path) = try makeStore(meter: meter)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try store.saveAudioPreparationJob(audioJob("a1", item: "item-a"))
        try store.saveAudioPreparationJob(audioJob("b1", item: "item-b"))

        meter.reset()
        XCTAssertEqual(try store.loadAudioPreparationJob(id: "b1")?.itemId, "item-b")
        XCTAssertEqual(meter.totals(for: "loadAudioPreparationJob(id:)").rows, 1)
        XCTAssertNil(try store.loadAudioPreparationJob(id: "gone"))
        try store.deleteAudioPreparationJob(id: "b1")
        XCTAssertNil(try store.loadAudioPreparationJob(id: "b1"), "a deleted job is not found")
    }

    func testAnAudioJobSavedAgainForAnotherItemMovesWithIt() throws {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try store.saveAudioPreparationJob(audioJob("moved", item: "item-a"))
        try store.saveAudioPreparationJob(audioJob("moved", item: "item-b"))
        XCTAssertEqual(try store.loadAudioPreparationJobs(itemId: "item-a"), [])
        XCTAssertEqual(try store.loadAudioPreparationJobs(itemId: "item-b").map(\.id), ["moved"])
    }

    func testEpisodeMapJobsByItemKeepCancelledOnesForTheCallerToFilter() throws {
        let meter = StoreReadMeter()
        let (store, path) = try makeStore(meter: meter)
        defer { try? FileManager.default.removeItem(atPath: path) }
        for job in [mapJob("m-a", item: "item-a"), mapJob("m-b", item: "item-b"),
                    mapJob("m-a-old", item: "item-a", cancelled: true)] {
            try store.saveEpisodeMapPreparationJob(job)
        }

        meter.reset()
        let mine = try store.loadEpisodeMapPreparationJobs(itemId: "item-a")
        let byItem = meter.totals(for: "loadEpisodeMapPreparationJobs(itemId:)")

        XCTAssertEqual(mine.map(\.id), try store.loadEpisodeMapPreparationJobs().filter { $0.itemId == "item-a" }.map(\.id))
        XCTAssertEqual(Set(mine.map(\.id)), ["m-a", "m-a-old"])
        XCTAssertEqual(byItem.rows, 2)
        XCTAssertEqual(try store.loadEpisodeMapPreparationJobs(itemId: "item-none"), [])
    }

    func testEpisodeMapJobByIdReadsOneRowAndMissesCleanly() throws {
        let meter = StoreReadMeter()
        let (store, path) = try makeStore(meter: meter)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try store.saveEpisodeMapPreparationJob(mapJob("m-a", item: "item-a"))
        try store.saveEpisodeMapPreparationJob(mapJob("m-b", item: "item-b", cancelled: true))

        meter.reset()
        XCTAssertEqual(try store.loadEpisodeMapPreparationJob(id: "m-b")?.isCancelled, true)
        XCTAssertEqual(meter.totals(for: "loadEpisodeMapPreparationJob(id:)").rows, 1)
        XCTAssertNil(try store.loadEpisodeMapPreparationJob(id: "gone"))
    }
}
