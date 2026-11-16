import Foundation
import XCTest
@testable import SessionKit

/// #4388: followed feeds are fetched several at once, never above a cap.
final class BoundedConcurrencyTests: XCTestCase {
    private actor Flight {
        private(set) var current = 0
        private(set) var peak = 0
        private(set) var started = 0
        func enter() { current += 1; started += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    /// Fails without the fix: the old loop awaited each feed before starting the next, so the peak was 1.
    func testMoreThanOneCallIsInFlightAndNeverAboveTheCap() async {
        let flight = Flight()
        let results = await BoundedConcurrency.map(Array(0..<12), limit: 4) { value -> Int in
            await flight.enter()
            try? await Task.sleep(nanoseconds: 20_000_000)
            await flight.leave()
            return value * 2
        }
        let peak = await flight.peak
        XCTAssertGreaterThan(peak, 1, "feeds must overlap")
        XCTAssertLessThanOrEqual(peak, 4, "never above the cap")
        XCTAssertEqual(results, (0..<12).map { $0 * 2 }, "results come back in the order of the inputs")
    }

    func testALimitBelowOneRunsOneAtATimeAndEmptyInputReturnsNothing() async {
        let flight = Flight()
        let results = await BoundedConcurrency.map([1, 2, 3], limit: 0) { value -> Int in
            await flight.enter()
            try? await Task.sleep(nanoseconds: 5_000_000)
            await flight.leave()
            return value
        }
        let peak = await flight.peak
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(results, [1, 2, 3])
        let none = await BoundedConcurrency.map([Int](), limit: 4) { $0 }
        XCTAssertEqual(none.count, 0)
    }

    func testACancelledCallerStartsNothingNew() async {
        let flight = Flight()
        let task = Task {
            await BoundedConcurrency.map(Array(0..<20), limit: 2) { value -> Int in
                await flight.enter()
                try? await Task.sleep(nanoseconds: 30_000_000)
                await flight.leave()
                return value
            }
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        let results = await task.value
        let started = await flight.started
        XCTAssertLessThan(started, 20, "calls not yet started when the task was cancelled never start")
        XCTAssertEqual(results.compactMap { $0 }.count, started, "a started call keeps its result")
    }
}
