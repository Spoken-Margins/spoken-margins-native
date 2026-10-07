import XCTest
@testable import SessionKit

final class SourceAudioWorkQueueTests: XCTestCase {
    /// Download Again schedules a full transcript plus one window per not-ready Margin.
    /// Suspending inside each job catches a reentrant actor that admits all the decoders at once.
    func testDownloadAgainFanoutKeepsOnlyOneSourceAudioJobActive() async throws {
        let queue = SourceAudioWorkQueue()
        let probe = SourceAudioWorkProbe()
        let completed = try await withThrowingTaskGroup(of: Int.self) { group in
            for job in 0..<33 {
                group.addTask {
                    try await queue.run {
                        await probe.begin()
                        try await Task.sleep(for: .milliseconds(5))
                        await probe.end()
                        return job
                    }
                }
            }
            var completed: [Int] = []
            for try await job in group { completed.append(job) }
            return completed.sorted()
        }
        let peak = await probe.peak
        XCTAssertEqual(peak, 1, "Full-episode and Margin-window decoders must not overlap")
        XCTAssertEqual(completed, Array(0..<33), "Queued source context must still finish")
    }

    func testFailureReleasesPermit() async throws {
        let queue = SourceAudioWorkQueue()
        do {
            let _: Int = try await queue.run { throw SourceAudioWorkTestError.expected }
            XCTFail("The operation's failure was lost")
        } catch SourceAudioWorkTestError.expected {}
        let result = try await queue.run { 42 }
        XCTAssertEqual(result, 42)
    }

    func testCancelledWaiterFinishesWithoutWaitingForActiveDecoder() async throws {
        let queue = SourceAudioWorkQueue()
        let held = SourceAudioWorkHold()
        let started = expectation(description: "first decoder started")
        let active = Task {
            try await queue.run {
                started.fulfill()
                await held.wait()
                return 1
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let cancelledFinished = expectation(description: "cancelled waiter removed")
        let cancelled = Task {
            defer { cancelledFinished.fulfill() }
            do {
                return try await queue.run { 2 }
            } catch is CancellationError {
                return -1
            }
        }
        // Confirm this exercises removal of an enqueued waiter, rather than only a pre-cancelled task.
        let deadline = Date().addingTimeInterval(2)
        while await queue.waitingJobCount == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let waitingCount = await queue.waitingJobCount
        XCTAssertEqual(waitingCount, 1)
        cancelled.cancel()
        await fulfillment(of: [cancelledFinished], timeout: 2)
        await held.release()
        let cancelledResult = try await cancelled.value
        let activeResult = try await active.value
        let nextResult = try await queue.run { 3 }
        XCTAssertEqual(cancelledResult, -1)
        XCTAssertEqual(activeResult, 1, "Cancelling a waiter must not release the active permit")
        XCTAssertEqual(nextResult, 3)
    }
}

private enum SourceAudioWorkTestError: Error { case expected }

private actor SourceAudioWorkProbe {
    private var active = 0
    private(set) var peak = 0
    func begin() { active += 1; peak = max(peak, active) }
    func end() { active -= 1 }
}

private actor SourceAudioWorkHold {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
