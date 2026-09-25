import XCTest
@testable import DesktopCore

final class ChatterboxResourcePolicyTests: XCTestCase {
    func testSixteenGigabyteMacStopsBeforeLargeSwapGrowth() {
        let memory: UInt64 = 16_000_000_000
        XCTAssertEqual(ChatterboxResourcePolicy.residentLimit(for: .nano, physicalMemory: memory), 2_500_000_000)
        XCTAssertEqual(ChatterboxResourcePolicy.residentLimit(for: .turbo, physicalMemory: memory), 5_000_000_000)
        XCTAssertNil(ChatterboxResourcePolicy.stopReason(model: .turbo, physicalMemory: memory,
            residentBytes: 4_000_000_000, swapGrowthBytes: 500_000_000, elapsed: 30))
        XCTAssertNotNil(ChatterboxResourcePolicy.stopReason(model: .turbo, physicalMemory: memory,
            residentBytes: 5_100_000_000, swapGrowthBytes: 0, elapsed: 30))
        XCTAssertNotNil(ChatterboxResourcePolicy.stopReason(model: .nano, physicalMemory: memory,
            residentBytes: 2_000_000_000, swapGrowthBytes: 513_000_000, elapsed: 30))
        XCTAssertNotNil(ChatterboxResourcePolicy.stopReason(model: .nano, physicalMemory: memory,
            residentBytes: 2_000_000_000, swapGrowthBytes: 0, elapsed: 91))
    }

    func testResourceCutoffSuggestsNanoOnlyWhenMonitorIsAvailable() {
        XCTAssertTrue(ChatterboxResourcePolicy.shouldSuggestNano(
            model: .turbo, stopReason: "memory exceeded 5000 MB"))
        XCTAssertTrue(ChatterboxResourcePolicy.shouldSuggestNano(
            model: .turbo, stopReason: "system swap grew by more than 512 MB"))
        XCTAssertFalse(ChatterboxResourcePolicy.shouldSuggestNano(
            model: .nano, stopReason: "memory exceeded 2500 MB"))
        XCTAssertFalse(ChatterboxResourcePolicy.shouldSuggestNano(
            model: .turbo, stopReason: "memory and swap could not be monitored", monitoringAvailable: false))
        XCTAssertFalse(ChatterboxResourcePolicy.shouldSuggestNano(
            model: .turbo, stopReason: "Python package is incompatible"))
    }
}
