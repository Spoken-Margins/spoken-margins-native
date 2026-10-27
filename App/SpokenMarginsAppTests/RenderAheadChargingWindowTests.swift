import Foundation
import SessionKit
import XCTest
@testable import SpokenMarginsApp

/// #2703 audit: `RenderAheadPolicy` raises the window to `chargingWindow` on external power, but the app's conditions
/// left `isOnExternalPower` nil ("for logging only"), so charging never raised it on the phone. The policy's own
/// tests build their conditions by hand and couldn't see that. These read the client's default window as the app
/// builds it, with only the reported battery state changed; nothing here reads the real `UIDevice`.
final class RenderAheadChargingWindowTests: XCTestCase {
    private var savedState: DevicePowerSource.BatteryState = .unknown

    override func setUpWithError() throws {
        let info = ProcessInfo.processInfo
        try XCTSkipIf(info.thermalState == .serious || info.thermalState == .critical || info.isLowPowerModeEnabled,
                      "the charging window applies only to a cool phone without Low Power Mode")
        savedState = Self.state(for: DevicePowerSource.app.isOnExternalPower)
        OnDeviceVoiceGovernor.app.setAppBackgrounded(true)
    }

    override func tearDown() {
        OnDeviceVoiceGovernor.app.setAppBackgrounded(false)
        DevicePowerSource.app.record(savedState)
    }

    func testTheDefaultWindowIsTheChargingWindowWhileThePhoneCharges() {
        DevicePowerSource.app.record(.charging)
        XCTAssertEqual(SupertonicSpeechPlaybackClient.defaultRenderAheadWindow(), RenderAheadPolicy.chargingWindow)
        DevicePowerSource.app.record(.full)
        XCTAssertEqual(SupertonicSpeechPlaybackClient.defaultRenderAheadWindow(), RenderAheadPolicy.chargingWindow,
                       "full on power counts as external power")
    }

    func testTheDefaultWindowIsTheNormalWindowOffPower() {
        let normal = max(RenderAheadPolicy.minimumWindow, RenderAheadPolicy.window)
        DevicePowerSource.app.record(.unplugged)
        XCTAssertEqual(SupertonicSpeechPlaybackClient.defaultRenderAheadWindow(), normal)
        DevicePowerSource.app.record(.unknown)
        XCTAssertEqual(SupertonicSpeechPlaybackClient.defaultRenderAheadWindow(), normal,
                       "a phone that can't tell (the simulator) is not treated as charging")
    }

    private static func state(for power: Bool?) -> DevicePowerSource.BatteryState {
        switch power {
        case true?: .charging
        case false?: .unplugged
        case nil: .unknown
        }
    }
}
