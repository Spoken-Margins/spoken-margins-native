import XCTest
@testable import SessionKit

final class LibraryAudioPreparationQueueTests: XCTestCase {
    private func job(_ item: String, requestedAt seconds: TimeInterval, openingBuffer: Bool = true) -> AudioPreparationJob {
        var job = AudioPreparationJob(id: "job-\(item)", itemId: item, manifestId: "m-\(item)", policy: .demandWindow)
        job.requestedAt = Date(timeIntervalSince1970: seconds)
        job.maximumChunkCount = openingBuffer ? 2 : nil
        return job
    }

    func testThePlayingItemJumpsAheadAndOnlyOneItemIsPreparing() {
        // #281: five Library items queued their opening audio and all showed a spinner.
        let jobs = (1...5).map { job("item-\($0)", requestedAt: Double($0)) }
        let queued = LibraryAudioPreparationQueue.places(jobs: jobs, activeItemId: nil, preparingItemId: nil)
        XCTAssertEqual(queued["item-5"], 1, "newest first while nothing is playing")
        XCTAssertEqual(Set(queued.values), [1, 2, 3, 4, 5])

        let playing = LibraryAudioPreparationQueue.places(jobs: jobs, activeItemId: "item-2", preparingItemId: "item-2")
        XCTAssertEqual(playing["item-2"], 0, "the playing item is prepared first")
        XCTAssertEqual(playing.values.filter { $0 == 0 }.count, 1, "exactly one item is preparing")
        XCTAssertEqual(playing["item-5"], 1)
        XCTAssertEqual(playing.count, 5)
    }

    func testTheOrderStaysPutWhileAnItemPrepares() {
        // One item runs to its target: progress on it doesn't move another ahead.
        var first = job("a", requestedAt: 2)
        let second = job("b", requestedAt: 1)
        first.nextChunkIndex = 1
        XCTAssertTrue(LibraryAudioPreparationQueue.precedes(first, second, activeItemId: nil))
        first.nextChunkIndex = 0
        XCTAssertTrue(LibraryAudioPreparationQueue.precedes(first, second, activeItemId: nil))
    }

    func testTwoPassesNeverRenderAtOnce() async {
        // The foreground and background passes used to interleave their awaits.
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
}

private actor Counter {
    private var running = 0
    private(set) var maximum = 0
    private(set) var finished = 0
    func enter() { running += 1; maximum = max(maximum, running) }
    func leave() { running -= 1; finished += 1 }
}
