import XCTest
@testable import SessionKit

final class LibraryAudioPreparationQueueTests: XCTestCase {
    private func job(_ item: String, requestedAt seconds: TimeInterval, openingBuffer: Bool = true) -> AudioPreparationJob {
        var job = AudioPreparationJob(id: "job-\(item)", itemId: item, manifestId: "m-\(item)", policy: .demandWindow)
        job.requestedAt = Date(timeIntervalSince1970: seconds)
        job.maximumChunkCount = openingBuffer ? 2 : nil
        return job
    }

    func testThePlayingItemJumpsAheadOfTheQueue() {
        // #281: five Library items queued their opening audio while one was playing.
        let jobs = (1...5).map { job("item-\($0)", requestedAt: Double($0)) }
        let idle = jobs.sorted { LibraryAudioPreparationQueue.precedes($0, $1, activeItemId: nil) }
        XCTAssertEqual(idle.map(\.itemId), ["item-5", "item-4", "item-3", "item-2", "item-1"], "newest first")
        let playing = jobs.sorted { LibraryAudioPreparationQueue.precedes($0, $1, activeItemId: "item-2") }
        XCTAssertEqual(playing.first?.itemId, "item-2", "the playing item is prepared first")
        XCTAssertEqual(playing.dropFirst().map(\.itemId), ["item-5", "item-4", "item-3", "item-1"])
    }

    func testTheOrderStaysPutWhileAnItemPrepares() {
        // One item runs to its target: progress on it doesn't move another ahead.
        var first = job("a", requestedAt: 2)
        let second = job("b", requestedAt: 1)
        for next in 0...1 {
            first.nextChunkIndex = next
            XCTAssertTrue(LibraryAudioPreparationQueue.precedes(first, second, activeItemId: nil))
            XCTAssertFalse(LibraryAudioPreparationQueue.precedes(second, first, activeItemId: nil))
        }
    }

    func testTwoPassesNeverRenderAtOnce() async {
        // The foreground loop and the background task used to interleave their awaits.
        let gate = SerialWorkGate()
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await gate.acquire()
                    await counter.enter()
                    try? await Task.sleep(for: .milliseconds(5))
                    await counter.leave()
                    await gate.release()
                }
            }
        }
        let maximum = await counter.maximum
        let finished = await counter.finished
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(finished, 8)
    }

    @MainActor
    func testRunTakesTurnsOnTheMainActorAndReturnsTheResult() async {
        let gate = SerialWorkGate()
        let counter = Counter()
        let results = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for index in 0..<6 {
                group.addTask {
                    await gate.run { @MainActor in
                        MainActor.assertIsolated()
                        await counter.enter()
                        try? await Task.sleep(for: .milliseconds(3))
                        await counter.leave()
                        return index
                    }
                }
            }
            var collected: [Int] = []
            for await result in group { collected.append(result) }
            return collected
        }
        XCTAssertEqual(results.sorted(), Array(0..<6))
        let maximum = await counter.maximum
        XCTAssertEqual(maximum, 1)
    }
}

private actor Counter {
    private var running = 0
    private(set) var maximum = 0
    private(set) var finished = 0
    func enter() { running += 1; maximum = max(maximum, running) }
    func leave() { running -= 1; finished += 1 }
}
