import XCTest
@testable import SessionKitAudio

@MainActor
final class SourceWindowJobQueueTests: XCTestCase {
    @MainActor
    private final class Probe {
        var running = 0
        var peak = 0
        var finished: [String] = []
        var started: [String] = []
        func begin(_ id: String) { running += 1; peak = max(peak, running); started.append(id) }
        func end(_ id: String) { running -= 1; finished.append(id) }
    }

    /// Where the listener is in the episode. Tests move it to simulate a seek.
    @MainActor
    private final class Playhead {
        var ms: Int?
        init(_ ms: Int?) { self.ms = ms }
    }

    func testTwentyTwoJobsNeverRunMoreThanTwoAtOnceAndAllFinish() async {
        let queue = SourceWindowJobQueue()
        let probe = Probe()
        for index in 0..<22 {
            let id = "margin-\(index)"
            queue.enqueue(id: id, anchorMediaTimeMs: index * 60_000, playhead: { 0 }) {
                probe.begin(id)
                try? await Task.sleep(nanoseconds: 5_000_000)
                probe.end(id)
            }
        }
        await queue.waitUntilIdle()
        XCTAssertEqual(probe.peak, 2, "two at a time: never more, and the bound isn't one")
        XCTAssertEqual(Set(probe.finished).count, 22)
        XCTAssertEqual(queue.peakRunning, 2)
        XCTAssertEqual(queue.runningCount, 0)
        XCTAssertEqual(queue.queuedCount, 0)
    }

    func testTheNearestToThePlayheadStartsFirstEvenWhenItIsQueuedLast() async {
        let queue = SourceWindowJobQueue(maxConcurrent: 1)
        let probe = Probe()
        // Queued in one burst, as a finished download does. Nothing may start before all four are in line.
        for (id, anchor) in [("far", 3_000_000), ("mid", 900_000), ("behind", 40_000), ("near", 110_000)] {
            queue.enqueue(id: id, anchorMediaTimeMs: anchor, playhead: { 100_000 }) {
                probe.begin(id)
                probe.end(id)
            }
        }
        await queue.waitUntilIdle()
        XCTAssertEqual(probe.started, ["near", "behind", "mid", "far"])
    }

    func testAJobWithNoPlayheadIsOrderedFromTheStartOfTheEpisode() async {
        let queue = SourceWindowJobQueue(maxConcurrent: 1)
        let probe = Probe()
        for (id, anchor) in [("late", 3_000_000), ("early", 20_000), ("middle", 900_000)] {
            queue.enqueue(id: id, anchorMediaTimeMs: anchor, playhead: { nil }) {
                probe.begin(id)
                probe.end(id)
            }
        }
        await queue.waitUntilIdle()
        XCTAssertEqual(probe.started, ["early", "middle", "late"])
    }

    func testASeekWhileJobsWaitIsFollowedWhenTheNextOneIsPicked() async {
        let queue = SourceWindowJobQueue(maxConcurrent: 1)
        let probe = Probe()
        let playhead = Playhead(0)
        let blockerStarted = AsyncGate()
        let release = AsyncGate()
        queue.enqueue(id: "blocker", anchorMediaTimeMs: 0, playhead: { playhead.ms }) {
            probe.begin("blocker")
            await blockerStarted.open()
            await release.wait()
            probe.end("blocker")
        }
        for (id, anchor) in [("five-minutes", 300_000), ("ninety-minutes", 5_400_000)] {
            queue.enqueue(id: id, anchorMediaTimeMs: anchor, playhead: { playhead.ms }) {
                probe.begin(id)
                probe.end(id)
            }
        }
        await blockerStarted.wait()
        // At 0:00 the five-minute Margin is the nearer. The listener then seeks to 90:00 while the blocker runs.
        playhead.ms = 5_400_000
        await release.open()
        await queue.waitUntilIdle()
        XCTAssertEqual(probe.started, ["blocker", "ninety-minutes", "five-minutes"])
    }

    func testDuplicateIdWhileQueuedIsIgnored() async {
        let queue = SourceWindowJobQueue(maxConcurrent: 1)
        let probe = Probe()
        let first = queue.enqueue(id: "b", anchorMediaTimeMs: 1, playhead: { 0 }) { probe.begin("b"); probe.end("b") }
        let second = queue.enqueue(id: "b", anchorMediaTimeMs: 1, playhead: { 0 }) { probe.begin("b"); probe.end("b") }
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        await queue.waitUntilIdle()
        XCTAssertEqual(probe.finished, ["b"])
    }

    func testAnIdThatIsRunningCanBeQueuedAgain() async {
        // The app's own pending flag stops duplicates. A request that lands just as its job ends must not be
        // dropped, or that flag would never clear.
        let queue = SourceWindowJobQueue(maxConcurrent: 1)
        let running = AsyncGate()
        let release = AsyncGate()
        let probe = Probe()
        queue.enqueue(id: "a", anchorMediaTimeMs: 0, playhead: { 0 }) {
            await running.open()
            await release.wait()
        }
        await running.wait()
        let again = queue.enqueue(id: "a", anchorMediaTimeMs: 0, playhead: { 0 }) { probe.begin("again"); probe.end("again") }
        XCTAssertTrue(again)
        await release.open()
        await queue.waitUntilIdle()
        XCTAssertEqual(probe.finished, ["again"])
        XCTAssertEqual(queue.runningCount, 0)
    }

    func testAJobThatRunsTooLongIsCancelledAndTheNextStartsOnlyAfterItReturns() async {
        let queue = SourceWindowJobQueue(maxConcurrent: 1, jobTimeout: .milliseconds(50))
        let probe = Probe()
        let wasCancelled = Flag()
        queue.enqueue(id: "stuck", anchorMediaTimeMs: 0, playhead: { 0 }) {
            probe.begin("stuck")
            // Far longer than the timeout, but it wakes early when the queue cancels it.
            try? await Task.sleep(for: .seconds(60))
            wasCancelled.value = Task.isCancelled
            probe.end("stuck")
        }
        queue.enqueue(id: "after", anchorMediaTimeMs: 1, playhead: { 0 }) { probe.begin("after"); probe.end("after") }
        await queue.waitUntilIdle()
        XCTAssertTrue(wasCancelled.value, "a job that watches for cancellation was asked to stop")
        XCTAssertEqual(queue.timedOutCount, 1)
        XCTAssertEqual(probe.finished, ["stuck", "after"])
        XCTAssertEqual(probe.peak, 1, "the next job started only once the stuck one had returned")
    }

    func testAJobThatIgnoresCancellationKeepsItsSlotSoTheLimitHolds() async {
        let queue = SourceWindowJobQueue(maxConcurrent: 1, jobTimeout: .milliseconds(50))
        let probe = Probe()
        let hold = AsyncGate()
        queue.enqueue(id: "stuck", anchorMediaTimeMs: 0, playhead: { 0 }) {
            probe.begin("stuck")
            await hold.wait()
            probe.end("stuck")
        }
        queue.enqueue(id: "after", anchorMediaTimeMs: 1, playhead: { 0 }) { probe.begin("after"); probe.end("after") }
        // Well past the timeout: the stuck job has been asked to stop and has not, so nothing else may start.
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(queue.timedOutCount, 1)
        XCTAssertEqual(probe.started, ["stuck"])
        XCTAssertEqual(queue.runningCount, 1)
        XCTAssertEqual(queue.queuedCount, 1)

        await hold.open()
        await queue.waitUntilIdle()
        XCTAssertEqual(probe.finished, ["stuck", "after"])
        XCTAssertEqual(probe.peak, 1)
    }
}

@MainActor
private final class Flag {
    var value = false
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
