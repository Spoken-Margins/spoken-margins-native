import AVFoundation
import XCTest
@testable import SpokenMarginsApp

/// #3650: the real notification path. iOS reports a Bluetooth headset press during a recording as an input mute
/// state change; a real one outside the start-up and route-change windows ends the Margin, and every event is logged.
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

    private func rig(recordingMs: Int? = nil, sinceRouteChangeMs: Int? = nil) -> Rig {
        let center = NotificationCenter()
        let clock = Clock()
        var ended = 0
        var logged: [(kind: String, fields: [String: String])] = []
        let monitor = HeadphoneEndGestureMonitor(
            log: { kind, fields in logged.append((kind, fields)) },
            recordingMs: { recordingMs ?? clock.ms },
            sinceRouteChangeMs: { sinceRouteChangeMs },
            endMargin: { ended += 1 },
            captureLevel: { ["peakNowDb": "-30", "capturedMs": "4000"] },
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

    func testASinglePressEndsTheMarginOnceAndIsLogged() async throws {
        let rig = rig()
        rig.monitor.begin()
        try await press(rig, muted: true)
        let mute = rig.lines().filter { $0.kind == "headphone.mute_state" }
        XCTAssertEqual(mute.count, 1)
        XCTAssertEqual(mute.first?.fields["muted"], "true")
        XCTAssertEqual(mute.first?.fields["verdict"], "end_margin")
        XCTAssertNotNil(mute.first?.fields["route"])
        XCTAssertEqual(mute.first?.fields["peakNowDb"], "-30", "the level now is on the line, so a silent file shows")
        XCTAssertEqual(rig.ends(), 1)
    }

    func testARepeatedStateIsLoggedAndIgnored() async throws {
        let rig = rig()
        rig.monitor.begin()
        try await press(rig, muted: false)
        XCTAssertEqual(rig.ends(), 0)
        XCTAssertEqual(rig.lines().last { $0.kind == "headphone.mute_state" }?.fields["verdict"], "ignored:no_change")
    }

    func testAPressInTheFirstMomentOfARecordingIsLoggedAndIgnored() async throws {
        let rig = rig(recordingMs: 300)
        rig.monitor.begin()
        try await press(rig, muted: true)
        XCTAssertEqual(rig.ends(), 0)
        XCTAssertEqual(rig.lines().last { $0.kind == "headphone.mute_state" }?.fields["verdict"], "ignored:recording_just_started")
    }

    func testAPressJustAfterARouteChangeIsLoggedAndIgnored() async throws {
        let rig = rig(sinceRouteChangeMs: 200)
        rig.monitor.begin()
        try await press(rig, muted: true)
        XCTAssertEqual(rig.ends(), 0)
        XCTAssertEqual(rig.lines().last { $0.kind == "headphone.mute_state" }?.fields["verdict"], "ignored:route_just_changed")
    }

    func testNothingIsLoggedOrEndedOnceTheRecordingHasStopped() async throws {
        let rig = rig()
        rig.monitor.begin()
        rig.monitor.stop()
        let before = rig.lines().count
        try await press(rig, muted: true)
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
