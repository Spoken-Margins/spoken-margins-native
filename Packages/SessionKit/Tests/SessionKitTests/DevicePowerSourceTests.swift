import Foundation
import XCTest
@testable import SessionKitAudio

/// `DevicePowerSource` moved out of the app (#4691) so the mapping from a reported battery state to "on external
/// power" runs on the host. The render-ahead policy decides on this value (#2703): a charging phone renders further
/// ahead, and a phone that can't tell (the simulator) must not be treated as charging.
final class DevicePowerSourceTests: XCTestCase {
    func testAFreshSourceCannotTellWhetherThePhoneIsOnPower() {
        XCTAssertNil(DevicePowerSource().isOnExternalPower)
    }

    func testEachReportedStateMapsToItsExternalPowerAnswer() {
        let source = DevicePowerSource()
        let table: [(DevicePowerSource.BatteryState, Bool?)] = [
            (.charging, true),
            (.full, true),
            (.unplugged, false),
            (.unknown, nil)
        ]
        for (state, expected) in table {
            source.record(state)
            XCTAssertEqual(source.isOnExternalPower, expected, "\(state)")
        }
    }

    func testTheLastRecordedStateWinsInBothDirections() {
        let source = DevicePowerSource()
        source.record(.charging)
        source.record(.unplugged)
        XCTAssertEqual(source.isOnExternalPower, false)
        source.record(.full)
        XCTAssertEqual(source.isOnExternalPower, true)
        source.record(.unknown)
        XCTAssertNil(source.isOnExternalPower, "a state that went unknown is not left reading as charging")
    }

    func testTwoSourcesKeepSeparateState() {
        let a = DevicePowerSource()
        let b = DevicePowerSource()
        a.record(.charging)
        XCTAssertNil(b.isOnExternalPower)
    }

    @MainActor
    func testStartMonitoringOffAnIPhoneLeavesTheStateUnknownAndCanRepeat() {
        let source = DevicePowerSource()
        source.startMonitoring()
        source.startMonitoring()
        #if !(canImport(UIKit) && os(iOS))
        XCTAssertNil(source.isOnExternalPower, "no UIDevice on the host, so nothing is read")
        #endif
    }

    func testTheSourceReadsFromAnyThreadWhileAnotherRecords() async {
        let source = DevicePowerSource()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    source.record(index.isMultiple(of: 2) ? .charging : .unplugged)
                    _ = source.isOnExternalPower
                }
            }
        }
        XCTAssertNotNil(source.isOnExternalPower)
    }

    func testTheProtocolLetsATestStandInForThePhone() {
        struct Fixed: ExternalPowerSource { let isOnExternalPower: Bool? }
        let sources: [any ExternalPowerSource] = [Fixed(isOnExternalPower: true), DevicePowerSource.app]
        XCTAssertEqual(sources[0].isOnExternalPower, true)
        _ = sources[1].isOnExternalPower
    }
}
