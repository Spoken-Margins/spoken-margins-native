import XCTest
@testable import SessionKitAudio

final class SourceWindowJobQueueTests: XCTestCase {
    private actor Probe {
        var running = 0
        var peak = 0
        var finished: [String] = []
        var started: [String] = []
        func begin(_ id: String) { running += 1; peak = max(peak, running); started.append(id) }
        func end(_ id: String) { running -= 1; finished.append(id) }
    }

    func testTwentyTwoJobsNeverRunMoreThanTwoAtOnceAndAllFinish() async {
        let queue = SourceWindowJobQueue()
        let probe = Probe()
        for index in 0..<22 {
            let id = "margin-\(index)"
            await queue.enqueue(id: id, anchorMediaTimeMs: index * 60_000, playheadMediaTimeMs: 0) {
                await probe.begin(id)
                try? await Task.sleep(nanoseconds: 5_000_000)
                await probe.end(id)
            }
        }
        await queue.waitUntilIdle()
        let peak = await probe.peak
        let finished = await probe.finished
        XCTAssertLessThanOrEqual(peak, 2)
        XCTAssertEqual(Set(finished).count, 22)
        let queuePeak = await queue.peakRunning
        XCTAssertLessThanOrEqual(queuePeak, 2)
        let running = await queue.runningCount
        let queued = await queue.queuedCount
        XCTAssertEqual(running, 0)
        XCTAssertEqual(queued, 0)
    }

    func testNearestToPlayheadStartsFirstAfterTheFirstTwo() async {
        let queue = SourceWindowJobQueue(maxConcurrent: 1)
        let probe = Probe()
        let gate = AsyncGate()
        await queue.enqueue(id: "blocker", anchorMediaTimeMs: 0, playheadMediaTimeMs: 100_000) {
            await probe.begin("blocker")
            await gate.wait()
            await probe.end("blocker")
        }
        for (id, anchor) in [("far", 3_000_000), ("near", 110_000), ("mid", 900_000)] {
            await queue.enqueue(id: id, anchorMediaTimeMs: anchor, playheadMediaTimeMs: 100_000) {
                await probe.begin(id)
                await probe.end(id)
            }
        }
        await gate.open()
        await queue.waitUntilIdle()
        let started = await probe.started
        XCTAssertEqual(started, ["blocker", "near", "mid", "far"])
    }

    func testDuplicateIdWhileQueuedIsIgnored() async {
        let queue = SourceWindowJobQueue(maxConcurrent: 1)
        let gate = AsyncGate()
        let probe = Probe()
        await queue.enqueue(id: "a", anchorMediaTimeMs: 0, playheadMediaTimeMs: 0) { await gate.wait() }
        let first = await queue.enqueue(id: "b", anchorMediaTimeMs: 1, playheadMediaTimeMs: 0) { await probe.begin("b"); await probe.end("b") }
        let second = await queue.enqueue(id: "b", anchorMediaTimeMs: 1, playheadMediaTimeMs: 0) { await probe.begin("b"); await probe.end("b") }
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        await gate.open()
        await queue.waitUntilIdle()
        let finished = await probe.finished
        XCTAssertEqual(finished, ["b"])
    }

    func testAnIdThatIsRunningCanBeQueuedAgain() async {
        // The app's own pending flag stops duplicates. A request that lands just as its job ends must not be
        // dropped, or that flag would never clear.
        let queue = SourceWindowJobQueue(maxConcurrent: 1)
        let gate = AsyncGate()
        let probe = Probe()
        await queue.enqueue(id: "a", anchorMediaTimeMs: 0, playheadMediaTimeMs: 0) { await gate.wait() }
        let again = await queue.enqueue(id: "a", anchorMediaTimeMs: 0, playheadMediaTimeMs: 0) { await probe.begin("again"); await probe.end("again") }
        XCTAssertTrue(again)
        await gate.open()
        await queue.waitUntilIdle()
        let finished = await probe.finished
        XCTAssertEqual(finished, ["again"])
        let running = await queue.runningCount
        XCTAssertEqual(running, 0)
    }
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
