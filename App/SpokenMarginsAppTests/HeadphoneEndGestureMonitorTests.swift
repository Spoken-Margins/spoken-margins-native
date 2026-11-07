import AVFoundation
import XCTest
@testable import SpokenMarginsApp

/// #3650: the real notification path. iOS reports a Bluetooth headset press during a recording as input mute
/// state changes; two real ones within 0.6 s end the Margin, one never does, and every event is logged.
@MainActor
final class HeadphoneEndGestureMonitorTests: XCTestCase {
    private final class Clock { var ms = 5_000 }

    private struct Rig {
        let monitor: HeadphoneEndGestureMonitor
        let center: NotificationCenter
        let clock: Clock
        let ends: () -> Int
        let lines: () -> [(kind: String, fields: [String: String])]
    }

    private func rig(endsOnMutePair: Bool = true, sinceRouteChangeMs: Int? = nil) -> Rig {
        let center = NotificationCenter()
        let clock = Clock()
        var ended = 0
        var logged: [(kind: String, fields: [String: String])] = []
        let monitor = HeadphoneEndGestureMonitor(
            log: { kind, fields in logged.append((kind, fields)) },
            recordingMs: { clock.ms },
            sinceRouteChangeMs: { sinceRouteChangeMs },
            endsMarginOnMutePair: { endsOnMutePair },
            endMargin: { ended += 1 },
            notificationCenter: center,
            nowMs: { clock.ms }
        )
        return Rig(monitor: monitor, center: center, clock: clock, ends: { ended }, lines: { logged })
    }

    private func press(_ rig: Rig, muted: Bool) async throws {
        rig.center.post(
            name: AVAudioApplication.inputMuteStateChangeNotification, object: nil,
            userInfo: [AVAudioApplication.muteStateKey: NSNumber(value: muted)]
        )
        try await Task.sleep(nanoseconds: 60_000_000) // the observer runs on the main queue
    }

    func testASinglePressIsLoggedAndNeverEndsTheMargin() async throws {
        let rig = rig()
        rig.monitor.begin()
        try await press(rig, muted: true)
        let mute = rig.lines().filter { $0.kind == "headphone.mute_state" }
        XCTAssertEqual(mute.count, 1)
        XCTAssertEqual(mute.first?.fields["muted"], "true")
        XCTAssertEqual(mute.first?.fields["verdict"], "first_of_pair")
        XCTAssertNotNil(mute.first?.fields["route"])
        XCTAssertEqual(rig.ends(), 0)
    }

    func testTwoPressesWithinTheWindowEndTheMarginOnce() async throws {
        let rig = rig()
        rig.monitor.begin()
        try await press(rig, muted: true)
        rig.clock.ms += 300
        try await press(rig, muted: false)
        XCTAssertEqual(rig.ends(), 1)
        let verdicts = rig.lines().filter { $0.kind == "headphone.mute_state" }.map { $0.fields["verdict"] }
        XCTAssertEqual(verdicts, ["first_of_pair", "end_margin"])
    }

    func testTwoSlowPressesDoNotEndTheMargin() async throws {
        let rig = rig()
        rig.monitor.begin()
        try await press(rig, muted: true)
        rig.clock.ms += 2_000
        try await press(rig, muted: false)
        XCTAssertEqual(rig.ends(), 0)
    }

    func testTheSettingOffLogsThePairButDoesNotEndTheMargin() async throws {
        let rig = rig(endsOnMutePair: false)
        rig.monitor.begin()
        try await press(rig, muted: true)
        rig.clock.ms += 300
        try await press(rig, muted: false)
        XCTAssertEqual(rig.ends(), 0)
        XCTAssertEqual(rig.lines().last { $0.kind == "headphone.mute_state" }?.fields["verdict"], "end_margin")
    }

    func testAPairJustAfterARouteChangeIsPhantomAndIgnored() async throws {
        let rig = rig(sinceRouteChangeMs: 200)
        rig.monitor.begin()
        try await press(rig, muted: true)
        rig.clock.ms += 300
        try await press(rig, muted: false)
        XCTAssertEqual(rig.ends(), 0)
    }

    func testNothingIsLoggedOrEndedOnceTheRecordingHasStopped() async throws {
        let rig = rig()
        rig.monitor.begin()
        rig.monitor.stop()
        let before = rig.lines().count
        try await press(rig, muted: true)
        rig.clock.ms += 300
        try await press(rig, muted: false)
        rig.monitor.noteRemoteCommand("nextTrack")
        XCTAssertEqual(rig.ends(), 0)
        XCTAssertEqual(rig.lines().count, before)
    }

    func testRemoteCommandsAndRouteChangesAreLoggedWithTheirNameAndGap() async throws {
        let rig = rig()
        rig.monitor.begin()
        rig.monitor.noteRemoteCommand("nextTrack")
        rig.clock.ms += 250
        rig.monitor.noteRemoteCommand("togglePlayPause")
        rig.center.post(
            name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: NSNumber(value: AVAudioSession.RouteChangeReason.categoryChange.rawValue)]
        )
        try await Task.sleep(nanoseconds: 60_000_000)
        let commands = rig.lines().filter { $0.kind == "headphone.remote_command" }
        XCTAssertEqual(commands.map { $0.fields["command"] }, ["nextTrack", "togglePlayPause"])
        XCTAssertEqual(commands.last?.fields["sincePreviousEventMs"], "250")
        XCTAssertEqual(rig.lines().last { $0.kind == "headphone.route_change" }?.fields["reason"], "categoryChange")
        XCTAssertEqual(rig.ends(), 0, "a remote command is logged here; ending is decided by the transport guard")
    }
}
