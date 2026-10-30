import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// The audio-preparation queue's edits leave the main actor (#2507). They run in order and each in one transaction.
final class AudioPreparationQueueEditsTests: XCTestCase {
    private func makeStore() throws -> SQLiteSessionStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("queue-edits-\(UUID().uuidString).sqlite").path
        return try SQLiteSessionStore(path: path)
    }

    private func item(_ id: String) -> Item {
        Item(id: id, title: "Title \(id)", mediaType: "text", text: "Words to read aloud.", externalReference: nil, status: "ready")
    }

    private func job(_ id: String, item: String, at seconds: Double, cancelled: Bool = false) -> AudioPreparationJob {
        AudioPreparationJob(id: id, itemId: item, manifestId: "m-\(id)", policy: .demandWindow,
                            requestedAt: Date(timeIntervalSince1970: seconds), maximumChunkCount: 2, isCancelled: cancelled)
    }

    /// Two quick taps each read the queue and save it. With plain `read` they run at once, each reading the rows
    /// before the other's save, and one edit is lost; `readInOrder` runs them one after the other.
    func testOrderedRequestsDoNotLoseAnUpdate() async throws {
        let store = try makeStore()
        try store.saveItem(item("a"))
        try store.saveAudioPreparationJob(job("counter", item: "a", at: 0))
        let reader = StoreReader(store)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await reader.readInOrder("counter-test") { store in
                        var row = try XCTUnwrap(store.loadAudioPreparationJob(id: "counter"))
                        Thread.sleep(forTimeInterval: 0.002) // widens the gap a second request would land in
                        row.nextChunkIndex += 1
                        try store.saveAudioPreparationJob(row)
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(try store.loadAudioPreparationJob(id: "counter")?.nextChunkIndex, 20)
    }

    /// The next request in line does not start while the one before it is still running.
    func testALaterRequestWaitsForTheOneBeforeIt() async throws {
        let reader = StoreReader(try makeStore())
        let gate = Gate()
        let second = Ran()
        let first = Task { try await reader.readInOrder("wait-test") { _ -> Int in
            gate.markStarted()
            return gate.waitForRelease(timeout: 10) ? 1 : -1
        } }
        while !gate.started { try await Task.sleep(nanoseconds: 1_000_000) }
        let later = Task { try await reader.readInOrder("wait-test") { _ -> Int in second.mark(); return 2 } }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(second.value, "the second request ran while the first was still open")
        gate.release()
        let values = try await [first.value, later.value]
        XCTAssertEqual(values, [1, 2])
        XCTAssertTrue(second.value)
    }

    func testPrioritizePinsOnlyTheSelectedJob() throws {
        let store = try makeStore()
        for id in ["old", "selected"] { try store.saveItem(item(id)) }
        try store.saveAudioPreparationJob(job("old", item: "old", at: 1))
        try store.saveAudioPreparationJob(job("selected", item: "selected", at: 0))
        XCTAssertTrue(try AudioPreparationQueueEdits.prioritize(id: "selected", in: store))
        XCTAssertFalse(try AudioPreparationQueueEdits.prioritize(id: "missing", in: store))
        XCTAssertNil(try store.loadAudioPreparationJob(id: "old")?.userPriority)
        XCTAssertNotNil(try store.loadAudioPreparationJob(id: "selected")?.userPriority)
    }

    func testMoveSwapsWithinTheTierAndKeepsEachJobsProgress() throws {
        let store = try makeStore()
        for id in ["a", "b"] { try store.saveItem(item(id)) }
        var a = job("a", item: "a", at: 0)
        a.nextChunkIndex = 1
        try store.saveAudioPreparationJob(a)
        try store.saveAudioPreparationJob(job("b", item: "b", at: 1))
        // The newest opening buffer comes first, so "b" leads until "a" moves ahead of it.
        XCTAssertTrue(try AudioPreparationQueueEdits.move(id: "a", by: -1, activeItemId: nil, in: store))
        let ordered = try store.loadAudioPreparationJobs().sorted { LibraryAudioPreparationQueue.precedes($0, $1, activeItemId: nil) }
        XCTAssertEqual(ordered.map(\.id), ["a", "b"])
        XCTAssertEqual(try store.loadAudioPreparationJob(id: "a")?.nextChunkIndex, 1)
        XCTAssertFalse(try AudioPreparationQueueEdits.move(id: "a", by: -1, activeItemId: nil, in: store), "already first")
    }

    func testSkipDeletesEveryJobOfTheItemAndNamesIt() throws {
        let store = try makeStore()
        for id in ["a", "b"] { try store.saveItem(item(id)) }
        try store.saveAudioPreparationJob(job("a1", item: "a", at: 0))
        try store.saveAudioPreparationJob(job("a2", item: "a", at: 1))
        try store.saveAudioPreparationJob(job("b1", item: "b", at: 2))
        let skipped = try AudioPreparationQueueEdits.skipItem(ofJob: "a2", in: store)
        XCTAssertEqual(skipped, .init(itemId: "a", title: "Title a"))
        XCTAssertEqual(try store.loadAudioPreparationJobs().map(\.id), ["b1"])
        XCTAssertNil(try AudioPreparationQueueEdits.skipItem(ofJob: "a1", in: store))
    }

    func testClearLeavesCancelledJobsAndCountsTheRest() throws {
        let store = try makeStore()
        for id in ["a", "b"] { try store.saveItem(item(id)) }
        try store.saveAudioPreparationJob(job("a1", item: "a", at: 0))
        try store.saveAudioPreparationJob(job("b1", item: "b", at: 1))
        try store.saveAudioPreparationJob(job("gone", item: "b", at: 2, cancelled: true))
        XCTAssertEqual(try AudioPreparationQueueEdits.clear(in: store), .init(count: 2, itemIds: ["a", "b"]))
        XCTAssertEqual(try store.loadAudioPreparationJobs().map(\.id), ["gone"])
    }

    func testThePresentationReadDeletesJobsWhoseItemIsGone() throws {
        let store = try makeStore()
        try store.saveItem(item("live"))
        try store.saveAudioPreparationJob(job("live", item: "live", at: 0))
        try store.saveAudioPreparationJob(job("orphan", item: "never-saved", at: 1))
        let presentation = try AudioPreparationPresentation.readDeletingStaleJobs(from: store, activeItemId: nil)
        XCTAssertEqual(presentation.queue.map(\.id), ["live"])
        XCTAssertEqual(presentation.staleJobIds, ["orphan"])
        XCTAssertEqual(try store.loadAudioPreparationJobs().map(\.id), ["live"])
    }
}

private final class Ran: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func mark() { lock.lock(); flag = true; lock.unlock() }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var startedFlag = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return startedFlag }
    func markStarted() { lock.lock(); startedFlag = true; lock.unlock() }
    func release() { semaphore.signal() }
    func waitForRelease(timeout seconds: Double) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }
}
