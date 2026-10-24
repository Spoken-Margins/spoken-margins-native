import Foundation
import XCTest
@testable import SessionKit

final class ProgressWriteGateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testABurstOfTicksWritesOncePerInterval() {
        var gate = ProgressWriteGate(interval: 5)
        var writes = 0
        // Two ticks a second for a minute.
        for tick in 0..<120 where gate.shouldWrite(key: "a", at: start.addingTimeInterval(Double(tick) * 0.5)) { writes += 1 }
        XCTAssertEqual(writes, 12)
    }

    func testTheFirstTickWritesAtOnce() {
        var gate = ProgressWriteGate()
        XCTAssertTrue(gate.shouldWrite(key: "a", at: start))
        XCTAssertFalse(gate.shouldWrite(key: "a", at: start.addingTimeInterval(0.5)))
    }

    func testItemsAreGatedSeparately() {
        var gate = ProgressWriteGate()
        XCTAssertTrue(gate.shouldWrite(key: "a", at: start))
        XCTAssertTrue(gate.shouldWrite(key: "b", at: start.addingTimeInterval(0.5)))
    }

    func testAWriteForAnotherReasonHoldsTheNextTickBack() {
        var gate = ProgressWriteGate()
        gate.didWrite(key: "a", at: start)
        XCTAssertFalse(gate.shouldWrite(key: "a", at: start.addingTimeInterval(1)))
        XCTAssertTrue(gate.shouldWrite(key: "a", at: start.addingTimeInterval(5)))
    }

    func testForgettingAKeyLetsTheNextTickWrite() {
        var gate = ProgressWriteGate()
        XCTAssertTrue(gate.shouldWrite(key: "a", at: start))
        gate.forget(key: "a")
        XCTAssertTrue(gate.shouldWrite(key: "a", at: start.addingTimeInterval(0.5)))
    }

    func testAClockStepBackwardsWritesRatherThanWaiting() {
        var gate = ProgressWriteGate()
        XCTAssertTrue(gate.shouldWrite(key: "a", at: start))
        XCTAssertTrue(gate.shouldWrite(key: "a", at: start.addingTimeInterval(-60)))
    }
}
