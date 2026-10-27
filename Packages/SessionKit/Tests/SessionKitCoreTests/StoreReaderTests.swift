import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

final class StoreReaderTests: XCTestCase {
    private func makeStore() throws -> SQLiteSessionStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("store-reader-\(UUID().uuidString).sqlite").path
        return try SQLiteSessionStore(path: path)
    }

    /// The point of the type (#2507): a read that is still running must not hold the main actor.
    /// The read waits on a gate, not a clock, so the check doesn't depend on how fast the machine is (#2764):
    /// the main actor gets past "the read has started" only if the read is off it, and the read is let go after.
    /// A read that held the main actor never lets this test see it start, so it ends after the gate's 10 s limit
    /// with the gate reported as timed out.
    @MainActor
    func testARunningReadDoesNotBlockTheMainActor() async throws {
        let reader = StoreReader(try makeStore())
        let gate = Gate()
        let readTask = Task {
            try await reader.read { _ -> Int in
                gate.markStarted()
                return gate.waitForRelease(timeout: 10) ? 42 : -1
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while !gate.started && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(gate.started, "the read never started while the main actor was free")
        gate.release()
        let value = try await readTask.value
        XCTAssertEqual(value, 42, "the read was still waiting for its gate: the main actor was blocked")
    }

    func testAReadSeesAWriteMadeEarlierInTheSameClosure() async throws {
        let reader = StoreReader(try makeStore())
        let seen = try await reader.read { store -> Int in
            try store.saveFeedSubscription(FeedSubscription(id: "s", source: SourceIdentity(
                id: "x", kind: .articleFeed, canonicalURL: "https://x.example/feed", host: "x.example", title: "X"),
                lastRefreshAt: Date()))
            return try store.loadFeedSubscriptions().count
        }
        XCTAssertEqual(seen, 1)
    }

    func testAnErrorInTheReadIsThrownToTheCaller() async throws {
        struct Boom: Error {}
        let reader = StoreReader(try makeStore())
        do {
            _ = try await reader.read { _ -> Int in throw Boom() }
            XCTFail("expected the read's error")
        } catch is Boom {}
    }

    /// A screen's `.task` that is cancelled before its read starts must not run the read (or its writes).
    /// The sleep's error is swallowed so the cancelled task does reach `read`.
    func testACancelledCallerNeverStartsTheRead() async throws {
        let reader = StoreReader(try makeStore())
        let ran = Ran()
        let task = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertTrue(Task.isCancelled)
            return try await reader.read { _ in ran.mark() }
        }
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(ran.value)
    }

    /// Cancelling the caller while the read is waiting to run reaches the read's own task.
    func testCancellingTheCallerReachesTheReadsTask() async throws {
        let reader = StoreReader(try makeStore())
        let task = Task {
            try await reader.read { _ -> Bool in
                Thread.sleep(forTimeInterval: 0.2)
                return Task.isCancelled
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let sawCancel = try await task.value
        XCTAssertTrue(sawCancel, "a long read can check Task.isCancelled and stop early")
    }

    /// An older answer that arrives after a newer request started is dropped; the newest one is kept.
    func testOnlyTheNewestRequestForAKeyKeepsItsValue() async throws {
        let reader = StoreReader(try makeStore())
        async let older: Int? = reader.readLatest("library") { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return 1
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let newer = try await reader.readLatest("library") { _ in 2 }
        XCTAssertEqual(newer, 2)
        let olderValue = try await older
        XCTAssertNil(olderValue, "the first request finished after the second began, so it is stale")
        let other = try await reader.readLatest("margins") { _ in 3 }
        XCTAssertEqual(other, 3, "another key is independent")
    }
}

private final class Ran: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func mark() { lock.lock(); flag = true; lock.unlock() }
}

/// Holds a read open until the test lets it go, so no test needs a wall-clock budget.
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
