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

    func testTwentyTwoJobsNeverRunMoreThanTwoAtOnceAndAllFinish() async {
        let queue = SourceWindowJobQueue()
        let probe = Probe()
        for index in 0..<22 {
            let id = "margin-\(index)"
            queue.enqueue(id: id, anchorMediaTimeMs: index * 60_000, playheadMediaTimeMs: 0) {
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
            queue.enqueue(id: id, anchorMediaTimeMs: anchor, playheadMediaTimeMs: 100_000) {
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
            queue.enqueue(id: id, anchorMediaTimeMs: anchor, playheadMediaTimeMs: nil) {
                probe.begin(id)
                probe.end(id)
            }
        }
        await queue.waitUntilIdle()
        XCTAssertEqual(probe.started, ["early", "middle", "late"])
    }

    func testDuplicateIdWhileQueuedIsIgnored() async {
        let queue = SourceWindowJobQueue(maxConcurrent: 1)
        let probe = Probe()
        let first = queue.enqueue(id: "b", anchorMediaTimeMs: 1, playheadMediaTimeMs: 0) { probe.begin("b"); probe.end("b") }
        let second = queue.enqueue(id: "b", anchorMediaTimeMs: 1, playheadMediaTimeMs: 0) { probe.begin("b"); probe.end("b") }
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
        queue.enqueue(id: "a", anchorMediaTimeMs: 0, playheadMediaTimeMs: 0) {
            await running.open()
            await release.wait()
        }
        await running.wait()
        let again = queue.enqueue(id: "a", anchorMediaTimeMs: 0, playheadMediaTimeMs: 0) { probe.begin("again"); probe.end("again") }
        XCTAssertTrue(again)
        await release.open()
        await queue.waitUntilIdle()
        XCTAssertEqual(probe.finished, ["again"])
        XCTAssertEqual(queue.runningCount, 0)
    }

    func testAJobThatTakesTooLongGivesUpItsSlotButIsNotCancelled() async {
        let queue = SourceWindowJobQueue(maxConcurrent: 1, jobTimeout: .milliseconds(50))
        let probe = Probe()
        let hold = AsyncGate()
        let slowEnded = AsyncGate()
        let wasCancelled = Flag()
        queue.enqueue(id: "slow", anchorMediaTimeMs: 0, playheadMediaTimeMs: 0) {
            probe.begin("slow")
            await hold.wait()
            wasCancelled.value = Task.isCancelled
            probe.end("slow")
            await slowEnded.open()
        }
        queue.enqueue(id: "after", anchorMediaTimeMs: 1, playheadMediaTimeMs: 0) { probe.begin("after"); probe.end("after") }
        await queue.waitUntilIdle()
        XCTAssertEqual(probe.finished, ["after"], "the second job ran although the first had not returned")
        XCTAssertEqual(queue.timedOutCount, 1)
        XCTAssertEqual(probe.peak, 2, "the slow job was still running when the next one started")

        await hold.open()
        await slowEnded.wait()
        XCTAssertEqual(probe.finished, ["after", "slow"], "the slow job was left to finish")
        XCTAssertFalse(wasCancelled.value, "a slow job (a first speech-model download) is not a stalled one")
        XCTAssertEqual(queue.runningCount, 0, "its late finish must not free a slot twice")

        let later = queue.enqueue(id: "later", anchorMediaTimeMs: 2, playheadMediaTimeMs: 0) { probe.begin("later"); probe.end("later") }
        XCTAssertTrue(later)
        await queue.waitUntilIdle()
        XCTAssertEqual(probe.finished, ["after", "slow", "later"])
        XCTAssertEqual(queue.queuedCount, 0)
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
