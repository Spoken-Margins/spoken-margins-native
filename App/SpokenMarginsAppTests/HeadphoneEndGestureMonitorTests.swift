import AVFoundation
import XCTest
@testable import SpokenMarginsApp

/// #3650: the real notification path. iOS reports a Bluetooth headset press during a recording as an input mute
/// state change; a real one outside the start-up and route-change windows ends the Margin, and every event is logged.
@MainActor
final class HeadphoneEndGestureMonitorTests: XCTestCase {
    private final class Clock { var ms = 5_000 }

    /// The app's input mute state as iOS holds it: a press sets it, and the monitor's unmute clears it.
    private final class FakeInput {
        var muted = false
        var unmuteCalls = 0
        var refuseUnmute = false
    }

    private struct Rig {
        let monitor: HeadphoneEndGestureMonitor
        let center: NotificationCenter
        let clock: Clock
        let input: FakeInput
        let ends: () -> Int
        let lines: () -> [(kind: String, fields: [String: String])]
    }

    private func rig(recordingMs: Int? = nil, sinceRouteChangeMs: Int? = nil, mutedAtStart: Bool = false) -> Rig {
        let center = NotificationCenter()
        let clock = Clock()
        let input = FakeInput()
        input.muted = mutedAtStart
        var ended = 0
        var logged: [(kind: String, fields: [String: String])] = []
        let monitor = HeadphoneEndGestureMonitor(
            log: { kind, fields in logged.append((kind, fields)) },
            recordingMs: { recordingMs ?? clock.ms },
            sinceRouteChangeMs: { sinceRouteChangeMs },
            endMargin: { ended += 1 },
            captureLevel: { ["peakNowDb": "-30", "capturedMs": "4000"] },
            notificationCenter: center,
            nowMs: { clock.ms },
            isInputMuted: { input.muted },
            setInputMuted: { muted in
                if muted == false { input.unmuteCalls += 1 }
                if input.refuseUnmute { return false }
                input.muted = muted
                return true
            }
        )
        return Rig(monitor: monitor, center: center, clock: clock, input: input, ends: { ended }, lines: { logged })
    }

    private func press(_ rig: Rig, muted: Bool) async throws {
        rig.input.muted = muted // iOS mutes the input, then posts the notification
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

    /// The audit finding on #3657: the press that ended a Margin left the input muted, so the next Margin recorded
    /// silence. Fails without the unmute in the monitor.
    func testThePressThatEndsAMarginLeavesTheInputUnmutedForTheNextOne() async throws {
        let rig = rig()
        rig.monitor.begin()
        try await press(rig, muted: true)
        XCTAssertEqual(rig.ends(), 1)
        XCTAssertFalse(rig.input.muted, "the press that ended the Margin must not leave the next one muted")
        let unmute = rig.lines().first { $0.kind == "headphone.unmute" }
        XCTAssertEqual(unmute?.fields["reason"], "margin_ended")
        XCTAssertEqual(unmute?.fields["unmuted"], "true")

        // The next Margin: starts unmuted, and a press on it ends it too.
        rig.monitor.stop()
        rig.clock.ms += 10_000
        rig.monitor.begin()
        XCTAssertEqual(rig.lines().last { $0.kind == "headphone.recording_begin" }?.fields["mutedAtStart"], "false")
        try await press(rig, muted: true)
        XCTAssertEqual(rig.ends(), 2)
        XCTAssertFalse(rig.input.muted)
    }

    func testTheUnmuteItselfDoesNotEndTheMarginAgain() async throws {
        let rig = rig()
        rig.monitor.begin()
        try await press(rig, muted: true)
        try await press(rig, muted: false) // the notification our own unmute posts
        XCTAssertEqual(rig.ends(), 1)
        XCTAssertEqual(rig.lines().last { $0.kind == "headphone.mute_state" }?.fields["verdict"], "ignored:already_ending")
    }

    func testAMarginStartedWhileTheInputIsStillMutedUnmutesItFirst() async throws {
        let rig = rig(mutedAtStart: true)
        rig.monitor.begin()
        XCTAssertFalse(rig.input.muted)
        let begin = rig.lines().last { $0.kind == "headphone.recording_begin" }
        XCTAssertEqual(begin?.fields["mutedAtStart"], "true")
        XCTAssertEqual(begin?.fields["unmutedAtStart"], "true")
        try await press(rig, muted: true)
        XCTAssertEqual(rig.ends(), 1, "a press on a Margin that began muted still ends it")
    }

    func testAnInputThatStaysMutedIsLoggedAsNotUnmuted() async throws {
        let rig = rig()
        rig.input.refuseUnmute = true
        rig.monitor.begin()
        try await press(rig, muted: true)
        XCTAssertEqual(rig.ends(), 1)
        XCTAssertEqual(rig.lines().first { $0.kind == "headphone.unmute" }?.fields["unmuted"], "false")
    }

    func testAMuteThatWasIgnoredIsStillClearedWhenTheRecordingStops() async throws {
        let rig = rig(recordingMs: 300)
        rig.monitor.begin()
        try await press(rig, muted: true) // inside the start-up window: logged, not acted on
        XCTAssertEqual(rig.ends(), 0)
        XCTAssertTrue(rig.input.muted)
        rig.monitor.stop()
        XCTAssertFalse(rig.input.muted)
        XCTAssertEqual(rig.lines().first { $0.kind == "headphone.unmute" }?.fields["reason"], "recording_stopped")
    }

    func testAnUnmutedInputIsNeverTouched() async throws {
        let rig = rig()
        rig.monitor.begin()
        rig.monitor.stop()
        XCTAssertEqual(rig.input.unmuteCalls, 0)
        XCTAssertNil(rig.lines().first { $0.kind == "headphone.unmute" })
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
