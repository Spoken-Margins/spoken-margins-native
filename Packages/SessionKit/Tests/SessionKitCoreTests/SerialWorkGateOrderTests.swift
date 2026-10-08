import XCTest
@testable import SessionKit

/// `SerialWorkGate` promises "first come first served": an explicit Prepare Now that has waited for the running
/// render must not be passed over by background parts that arrived after it. The tests in
/// `LibraryAudioPreparationQueueTests` check that the work never overlaps, which a last-in-first-out queue also does.
final class SerialWorkGateOrderTests: XCTestCase {
    func testWaitersTakeTheirTurnInTheOrderTheyArrived() async throws {
        let gate = SerialWorkGate()
        let log = TurnLog()
        await gate.acquire()
        var waiters: [Task<Void, Never>] = []
        for index in 0..<6 {
            waiters.append(Task {
                await log.arrived(index)
                await gate.acquire()
                await log.tookTurn(index)
                await gate.release()
            })
            // The next one arrives only once this one is queued behind the holder, so "arrived" is a known order.
            while await !log.hasArrived(index) { await Task.yield() }
            try await Task.sleep(for: .milliseconds(30))
        }
        let beforeRelease = await log.turns
        XCTAssertEqual(beforeRelease, [], "nobody runs while the holder has the turn")

        await gate.release()
        for waiter in waiters { await waiter.value }

        let turns = await log.turns
        XCTAssertEqual(turns, [0, 1, 2, 3, 4, 5], "the earliest waiter goes first")
    }
}

private actor TurnLog {
    private var arrivals: Set<Int> = []
    private(set) var turns: [Int] = []
    func arrived(_ index: Int) { arrivals.insert(index) }
    func hasArrived(_ index: Int) -> Bool { arrivals.contains(index) }
    func tookTurn(_ index: Int) { turns.append(index) }
}
