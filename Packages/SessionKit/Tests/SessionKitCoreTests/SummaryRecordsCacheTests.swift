import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

@MainActor
final class SummaryRecordsCacheTests: XCTestCase {
    /// Polls instead of using XCTestExpectation, whose non-Sendable value cannot cross into the cache's callbacks.
    private func waitForLoads(_ cache: SummaryRecordsCache, _ count: Int) async {
        for _ in 0..<500 where cache.loads < count { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testManyRendersWithOneKeyReadOnce() async throws {
        let cache = SummaryRecordsCache()
        let counter = Counter()
        for _ in 0..<50 {
            _ = cache.current(key: "s1", load: { counter.bump(); return SummaryRetryRecords(jobs: [], turns: [], interjections: []) }, onLoaded: {})
        }
        await waitForLoads(cache, 1)
        for _ in 0..<50 {
            _ = cache.current(key: "s1", load: { counter.bump(); return nil }, onLoaded: {})
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(counter.value, 1, "50 renders before and 50 after the answer arrived read the store once")
        XCTAssertEqual(cache.loads, 1)
    }

    func testANewKeyReadsAgainAndKeepsTheOldAnswerMeanwhile() async throws {
        let cache = SummaryRecordsCache()
        let counter = Counter()
        let firstRecords = SummaryRetryRecords(jobs: [], turns: [], interjections: [])
        _ = cache.current(key: "a", load: { firstRecords }, onLoaded: {})
        await waitForLoads(cache, 1)

        let during = cache.current(key: "b", load: { nil }, onLoaded: {})
        XCTAssertEqual(during, firstRecords, "the previous answer stays on screen while the new one loads")
        await waitForLoads(cache, 2)
        XCTAssertNil(cache.current(key: "b", load: { counter.bump(); return nil }, onLoaded: {}))
        XCTAssertEqual(counter.value, 0, "an already-loaded key is not read again")
        XCTAssertEqual(cache.loads, 2)
    }

    /// #2747: a Summarize tap right after a summary failed must see the failure, not the "pending" answer
    /// the cache is still showing from before.
    func testSettleAnswersForTheNewKeyNotTheOldAnswer() async throws {
        let cache = SummaryRecordsCache()
        let counter = Counter()
        let pending = SummaryRetryRecords(jobs: [Self.job("1", "pending")], turns: [], interjections: [])
        let failed = SummaryRetryRecords(jobs: [Self.job("1", "retryable")], turns: [], interjections: [])
        _ = cache.current(key: "pending", load: { pending }, onLoaded: {})
        await waitForLoads(cache, 1)

        XCTAssertEqual(cache.current(key: "failed", load: { counter.bump(); return failed }, onLoaded: {}), pending)
        XCTAssertFalse(cache.isSettled(key: "failed"))
        let settled = await cache.settle(key: "failed", load: { counter.bump(); return failed }, onLoaded: {})
        XCTAssertEqual(settled, failed)
        XCTAssertTrue(cache.isSettled(key: "failed"))
        XCTAssertEqual(cache.current(key: "failed", load: { nil }, onLoaded: {}), failed)
        XCTAssertEqual(counter.value, 1, "settle joins the read the render already started")
    }

    func testSettleOnASettledKeyDoesNotRead() async throws {
        let cache = SummaryRecordsCache()
        let counter = Counter()
        let records = SummaryRetryRecords(jobs: [], turns: [], interjections: [])
        let first = await cache.settle(key: "a", load: { counter.bump(); return records }, onLoaded: {})
        let second = await cache.settle(key: "a", load: { counter.bump(); return nil }, onLoaded: {})
        XCTAssertEqual(first, records)
        XCTAssertEqual(second, records)
        XCTAssertEqual(counter.value, 1)
    }

    private static func job(_ id: String, _ status: String) -> AIJob {
        AIJob(id: id, kind: "interjection_summary", itemId: "i", sessionId: "s", turnId: "t-\(id)", providerType: "p", model: "m", status: status, attempts: 0, lastError: nil, messages: [], playbackMode: nil)
    }

    func testLatestPendingPicksTheNewestWaitingJobOfThatKind() {
        func job(_ id: String, _ kind: String, _ status: String) -> AIJob {
            AIJob(id: id, kind: kind, itemId: "i", sessionId: "s", turnId: "t-\(id)", providerType: "p", model: "m", status: status, attempts: 0, lastError: nil, messages: [], playbackMode: nil)
        }
        let jobs = [job("1", "interjection_summary", "pending"), job("2", "interjection_summary", "deferred"),
                    job("3", "interjection_summary", "complete"), job("4", "assistant_response", "pending")]
        XCTAssertEqual(SummaryRetryRecords.latestPending(in: jobs, kind: "interjection_summary")?.id, "2")
        XCTAssertEqual(SummaryRetryRecords.latestPending(in: jobs, kind: "assistant_response")?.id, "4")
        XCTAssertNil(SummaryRetryRecords.latestPending(in: jobs, kind: "other"))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
