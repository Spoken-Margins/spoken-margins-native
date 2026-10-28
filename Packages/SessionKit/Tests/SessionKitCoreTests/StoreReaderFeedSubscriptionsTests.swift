import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

final class StoreReaderFeedSubscriptionsTests: XCTestCase {
    private func makeStore() throws -> SQLiteSessionStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("store-reader-feeds-\(UUID().uuidString).sqlite").path
        return try SQLiteSessionStore(path: path)
    }

    private func subscription(_ name: String) -> FeedSubscription {
        FeedSubscription(id: "subscription-\(name)", source: SourceIdentity(
            id: name, kind: .articleFeed, canonicalURL: "https://\(name).example/feed", host: "\(name).example", title: name))
    }

    func testReadsAllSubscriptionsAndFindsOneByIdOrSource() async throws {
        let store = try makeStore()
        try store.saveFeedSubscription(subscription("a"))
        try store.saveFeedSubscription(subscription("b"))
        let reader = StoreReader(store)
        let all = try await reader.feedSubscriptions()
        XCTAssertEqual(Set(all.map(\.id)), ["subscription-a", "subscription-b"])
        let byId = try await reader.feedSubscription(id: "subscription-b")
        XCTAssertEqual(byId?.source.id, "b")
        let bySource = try await reader.feedSubscription(sourceId: "a")
        XCTAssertEqual(bySource?.id, "subscription-a")
        let missingId = try await reader.feedSubscription(id: "subscription-z")
        XCTAssertNil(missingId)
        let missingSource = try await reader.feedSubscription(sourceId: "z")
        XCTAssertNil(missingSource)
    }

    func testALatestReadOnAnotherStoreIsNotSupersededByThisOne() async throws {
        let first = StoreReader(try makeStore())
        let second = StoreReader(try makeStore())
        let gate = Gate()
        let older = Task {
            try await first.readLatest(StoreReader.feedSubscriptionsKey) { _ -> Int in
                gate.markStarted()
                _ = gate.waitForRelease(timeout: 10)
                return 1
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while !gate.started && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        _ = try await second.latestFeedSubscriptions()
        gate.release()
        let value = try await older.value
        XCTAssertEqual(value, 1, "another store's read with the same key must not supersede this one")
    }

    func testTwoSubscriptionsWithOneSourceIdGiveTheFirstNotACrash() async throws {
        let store = try makeStore()
        var first = subscription("a")
        first.id = "subscription-a1"
        var second = subscription("a")
        second.id = "subscription-a2"
        try store.saveFeedSubscription(first)
        try store.saveFeedSubscription(second)
        let found = try await StoreReader(store).feedSubscription(sourceId: "a")
        XCTAssertNotNil(found)
    }

    /// The point of the "latest" read: a slow read that started first must not publish over a newer one, even when
    /// the newer one comes from another `StoreReader` on the same store. The first request shares the key and is held
    /// open until the newer read has finished.
    func testAnOlderLatestReadGivesWayToANewerOne() async throws {
        let store = try makeStore()
        try store.saveFeedSubscription(subscription("a"))
        let reader = StoreReader(store)
        let gate = Gate()
        let older = Task {
            try await reader.readLatest(StoreReader.feedSubscriptionsKey) { store -> [FeedSubscription] in
                gate.markStarted()
                _ = gate.waitForRelease(timeout: 10)
                return try store.loadFeedSubscriptions()
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while !gate.started && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(gate.started)
        // A call site makes a reader for each call (#2507), so the newest-request tracking must not live in the reader.
        let newer = try await StoreReader(store).latestFeedSubscriptions()
        XCTAssertEqual(newer?.count, 1)
        gate.release()
        let olderValue = try await older.value
        XCTAssertNil(olderValue, "the older read finished after the newer one and must not publish")
    }
}

/// Holds a read open until the test lets it go, so the test needs no wall-clock budget.
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
