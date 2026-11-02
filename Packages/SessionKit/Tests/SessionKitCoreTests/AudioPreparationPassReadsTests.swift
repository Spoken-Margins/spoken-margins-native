import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// The audio-preparation passes read the job tables off the main actor, in line behind the queue's own edits (#2507).
final class AudioPreparationPassReadsTests: XCTestCase {
    private func makeStore() throws -> SQLiteSessionStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pass-reads-\(UUID().uuidString).sqlite").path
        return try SQLiteSessionStore(path: path)
    }

    private func seed(_ store: SQLiteSessionStore, item: String) throws {
        try store.saveItem(Item(id: item, title: "T", mediaType: "text", text: "Words to read aloud.", externalReference: nil, status: "ready"))
        try store.saveAudioPreparationJob(AudioPreparationJob(
            id: "job-\(item)", itemId: item, manifestId: "m-\(item)", policy: .explicit,
            requestedAt: Date(timeIntervalSince1970: 10), nextChunkIndex: 1))
    }

    func testReadJobsReturnsBothTablesAndATokenThatTracksProgress() async throws {
        let store = try makeStore()
        try seed(store, item: "a")
        let before = await AudioPreparationPassReads.readJobs(store)
        XCTAssertEqual(before.audio.map(\.id), ["job-a"])
        XCTAssertEqual(before.episode, [])
        XCTAssertEqual(before.progressToken, ["audio:job-a:1"])

        var advanced = try XCTUnwrap(store.loadAudioPreparationJob(id: "job-a"))
        advanced.nextChunkIndex = 2
        try store.saveAudioPreparationJob(advanced)
        let after = await AudioPreparationPassReads.readJobs(store)
        XCTAssertNotEqual(after.progressToken, before.progressToken, "a chunk committed between two reads is progress")
    }

    /// A pass that asks right after the listener's Prioritize sees the pin, not the queue as it was before.
    func testReadSeesAQueueEditThatFinishedBeforeIt() async throws {
        let store = try makeStore()
        try seed(store, item: "a")
        try seed(store, item: "b")
        try await StoreReader(store).readInOrder(AudioPreparationQueueEdits.orderKey) {
            try AudioPreparationQueueEdits.prioritize(id: "job-b", in: $0)
        }
        let jobs = try await AudioPreparationPassReads.audioJobs(store)
        XCTAssertNotNil(try XCTUnwrap(jobs.first { $0.id == "job-b" }).userPriority)
    }

    /// The caller is not held while the read runs: a read that blocks on the store leaves the caller's actor free.
    @MainActor
    func testTheCallerIsFreeWhileTheReadRuns() async throws {
        let store = try makeStore()
        try seed(store, item: "a")
        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled { ticks += 1; try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        var total = 0
        for _ in 0..<20 { total += try await AudioPreparationPassReads.audioJobs(store).count }
        ticker.cancel()
        XCTAssertEqual(total, 20)
        XCTAssertGreaterThan(ticks, 0)
    }
}
