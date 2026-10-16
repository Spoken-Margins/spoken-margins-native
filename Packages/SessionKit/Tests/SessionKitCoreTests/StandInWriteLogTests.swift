import XCTest
@testable import SessionKit

/// #1695: the Diagnostics line for an iOS-voice stand-in write says how long it took and whether it was the first
/// of the launch, and nothing else about it.
final class StandInWriteLogTests: XCTestCase {
    func testTheFirstWriteOfALaunchIsNumberedOneAndNamedAsSuch() {
        let log = StandInWriteLog()

        XCTAssertEqual(log.writeStarted(), 1)
        XCTAssertEqual(StandInWriteLog.describe(writeNumber: 1, elapsed: 29.4), "iOS voice first write this launch took 29.40 s")
    }

    func testLaterWritesCountOnAndAreNotCalledFirst() {
        let log = StandInWriteLog()
        _ = log.writeStarted()

        XCTAssertEqual(log.writeStarted(), 2)
        XCTAssertEqual(StandInWriteLog.describe(writeNumber: 2, elapsed: 0.456), "iOS voice write 2 this launch took 0.46 s")
    }

    func testEachLogCountsItsOwnLaunch() {
        let first = StandInWriteLog()
        let second = StandInWriteLog()
        _ = first.writeStarted()
        _ = first.writeStarted()

        XCTAssertEqual(second.writeStarted(), 1)
    }

    func testWritesStartedFromManyThreadsAreEachNumberedOnce() async {
        let log = StandInWriteLog()
        let numbers = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<50 { group.addTask { log.writeStarted() } }
            var all: [Int] = []
            for await number in group { all.append(number) }
            return all
        }

        XCTAssertEqual(Set(numbers), Set(1...50))
    }

    func testNeighbouringElapsedValues() {
        // A write that finished at once, a clock that stepped back, and a very long one.
        XCTAssertEqual(StandInWriteLog.describe(writeNumber: 1, elapsed: 0), "iOS voice first write this launch took 0.00 s")
        XCTAssertEqual(StandInWriteLog.describe(writeNumber: 1, elapsed: -3), "iOS voice first write this launch took 0.00 s")
        XCTAssertEqual(StandInWriteLog.describe(writeNumber: 1, elapsed: 303), "iOS voice first write this launch took 303.00 s")
        XCTAssertEqual(StandInWriteLog.describe(writeNumber: 1, elapsed: 0.004), "iOS voice first write this launch took 0.00 s")
    }

    func testTheLineCarriesNoTextOrIdentifier() {
        let line = StandInWriteLog.describe(writeNumber: 3, elapsed: 1.5)

        XCTAssertEqual(line.filter(\.isNumber), "3150", "only the write number and the seconds")
    }
}
