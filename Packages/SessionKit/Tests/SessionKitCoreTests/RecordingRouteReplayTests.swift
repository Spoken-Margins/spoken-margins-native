import Foundation
import XCTest
@testable import SessionKit

/// #3937: route timing a host test could not put the code in. Each fixture is a recorded run of what a headset did while
/// a Margin recorded, with when, in the JSON format `RecordingRouteTrace` reads. They are written by hand from the
/// timings in the bug reports (#1708: a `play` 50 ms and 440 ms in; #2182: a `play` 2,182 ms in on a hands-free input),
/// never from a listener's recording. The replay runs them through the same clock and rules the app uses, and each trace
/// is also run against the rule as it stood before its fix, which must save the wrong Margin.
final class RecordingRouteReplayTests: XCTestCase {
    // MARK: Fixtures

    /// #1708: the headset switches from music to the hands-free profile as the microphone opens, and sends a `play`
    /// 50 ms and 440 ms after the recorder started (and a third as the profile settles). The listener's own click comes
    /// 13.2 s in.
    private let phantomPlaysAsTheMicrophoneOpens = """
    {"name": "phantom plays as the microphone opens", "issue": "#1708", "events": [
      {"atMs": 0, "event": "recording_started"},
      {"atMs": 20, "event": "route_changed", "handsFreeInput": false},
      {"atMs": 50, "event": "command", "command": "play", "origin": "now_playing_remote"},
      {"atMs": 440, "event": "command", "command": "play", "origin": "now_playing_remote"},
      {"atMs": 1200, "event": "command", "command": "togglePlayPause", "origin": "now_playing_remote"},
      {"atMs": 13200, "event": "command", "command": "togglePlayPause", "origin": "now_playing_remote"}
    ]}
    """

    /// #2182: a Live Activity recording on a Bluetooth hands-free input. The headset's `play` arrives 2,182 ms in, after
    /// the 1.5 s start window. The listener's pause 9.4 s in is real.
    private let latePlayOnAHandsFreeInput = """
    {"name": "late play on a hands-free input", "issue": "#2182", "events": [
      {"atMs": 0, "event": "recording_started", "handsFreeInput": true},
      {"atMs": 300, "event": "route_changed"},
      {"atMs": 2182, "event": "command", "command": "play", "origin": "now_playing_remote"},
      {"atMs": 9400, "event": "command", "command": "pause", "origin": "now_playing_remote"}
    ]}
    """

    /// A wired headset or the Lock Screen: a `play` there is the listener's, however soon after the start window.
    private let wiredHeadsetPlayEndsTheMargin = """
    {"name": "wired headset play", "events": [
      {"atMs": 0, "event": "recording_started", "handsFreeInput": false},
      {"atMs": 1500, "event": "command", "command": "play", "origin": "now_playing_remote"},
      {"atMs": 4000, "event": "command", "command": "play", "origin": "now_playing_remote"}
    ]}
    """

    /// A route change late in the recording: the headset announces its new profile with a command, then the listener clicks.
    private let routeChangeLateInTheRecording = """
    {"name": "route change late in the recording", "issue": "#1708", "events": [
      {"atMs": 0, "event": "recording_started"},
      {"atMs": 8000, "event": "route_changed"},
      {"atMs": 8400, "event": "command", "command": "pause", "origin": "now_playing_remote"},
      {"atMs": 9000, "event": "command", "command": "pause", "origin": "now_playing_remote"},
      {"atMs": 9400, "event": "command", "command": "pause", "origin": "now_playing_remote"}
    ]}
    """

    /// #3650: the headset's mute press. Two notifications come in the start window (the first repeats the state the microphone was
    /// in), one just after a route change, one repeats the current state later, then a real press.
    private let headsetMutePress = """
    {"name": "headset mute press", "issue": "#3650", "events": [
      {"atMs": 0, "event": "recording_started", "muted": false},
      {"atMs": 40, "event": "mute_changed", "muted": false},
      {"atMs": 800, "event": "mute_changed", "muted": true},
      {"atMs": 3000, "event": "route_changed"},
      {"atMs": 3400, "event": "mute_changed", "muted": false},
      {"atMs": 5000, "event": "mute_changed", "muted": false},
      {"atMs": 7000, "event": "mute_changed", "muted": true},
      {"atMs": 9000, "event": "command", "command": "pause", "origin": "now_playing_remote"}
    ]}
    """

    private func trace(_ json: String) throws -> RecordingRouteTrace { try RecordingRouteTrace.decode(Data(json.utf8)) }

    /// The rule before #1708's fix: every command that can end a Margin does.
    private var beforeTheFixFor1708: RecordingRouteReplay.Rules {
        var rules = RecordingRouteReplay.Rules.production
        rules.transport = { _, _, _, _ in .endMargin }
        return rules
    }

    /// The rule between #1708 and #2182: timing only, no notion of a hands-free input.
    private var beforeTheFixFor2182: RecordingRouteReplay.Rules {
        var rules = RecordingRouteReplay.Rules.production
        rules.transport = { command, recordingMs, sinceRouteChangeMs, _ in
            RecordingTransportGuard.verdict(command: command, recordingMs: recordingMs, sinceRouteChangeMs: sinceRouteChangeMs, onHandsFreeProfile: false)
        }
        return rules
    }

    // MARK: Replays

    func testThePhantomPlaysAsTheMicrophoneOpensAreIgnoredAndTheClickEnds() throws {
        let result = try RecordingRouteReplay.replay(trace(phantomPlaysAsTheMicrophoneOpens))
        XCTAssertEqual(result.endedAtMs, 13_200)
        XCTAssertEqual(result.ignoredReasons, ["recording_just_started", "recording_just_started", "recording_just_started"])
        XCTAssertEqual(result.steps.map(\.atMs), [0, 20, 50, 440, 1_200, 13_200])
    }

    func testAPhantomPlayLateOnAHandsFreeInputNeverEndsTheMargin() throws {
        let result = try RecordingRouteReplay.replay(trace(latePlayOnAHandsFreeInput))
        XCTAssertEqual(result.ignoredReasons, ["bare_play_on_hands_free"])
        XCTAssertEqual(result.endedAtMs, 9_400, "the listener's pause ends it")
    }

    func testAPlayOnAWiredHeadsetEndsTheMarginOnceTheStartWindowIsOver() throws {
        let result = try RecordingRouteReplay.replay(trace(wiredHeadsetPlayEndsTheMargin))
        XCTAssertEqual(result.endedAtMs, 1_500, "the window is exactly 1.5 s, and the Margin ends at its edge")
        XCTAssertEqual(result.steps.count, 2, "nothing after the end reaches the saved Margin")
    }

    func testACommandJustAfterALateRouteChangeIsIgnoredAndTheNextOneEnds() throws {
        let result = try RecordingRouteReplay.replay(trace(routeChangeLateInTheRecording))
        XCTAssertEqual(result.ignoredReasons, ["route_just_changed"])
        XCTAssertEqual(result.endedAtMs, 9_000, "1,000 ms after the route change is the edge, and it counts")
    }

    func testTheHeadsetMutePressEndsTheMarginOnlyOnARealChange() throws {
        let result = try RecordingRouteReplay.replay(trace(headsetMutePress))
        XCTAssertEqual(result.ignoredReasons, ["recording_just_started", "recording_just_started", "route_just_changed", "no_change"])
        XCTAssertEqual(result.endedAtMs, 7_000)
    }

    // MARK: Each trace fails against the rule before its fix

    func testTheReplaysFailAgainstTheRulesBeforeTheirFixes() throws {
        // #1708: before the fix, the first phantom `play` ended and saved an empty Margin at 50 ms.
        let phantom = try trace(phantomPlaysAsTheMicrophoneOpens)
        let oldEnd = try RecordingRouteReplay.replay(phantom, rules: beforeTheFixFor1708).endedAtMs
        XCTAssertEqual(oldEnd, 50)
        XCTAssertNotEqual(oldEnd, try RecordingRouteReplay.replay(phantom).endedAtMs)

        // #2182: timing alone let the 2,182 ms `play` end the Margin.
        let late = try trace(latePlayOnAHandsFreeInput)
        let timingOnlyEnd = try RecordingRouteReplay.replay(late, rules: beforeTheFixFor2182).endedAtMs
        XCTAssertEqual(timingOnlyEnd, 2_182)
        XCTAssertNotEqual(timingOnlyEnd, try RecordingRouteReplay.replay(late).endedAtMs)
        XCTAssertEqual(try RecordingRouteReplay.replay(phantom, rules: beforeTheFixFor2182).endedAtMs, 13_200,
                       "the #1708 trace is still handled by the timing rule: the later fix did not undo it")
    }

    /// The fixture's route-change event must reach the rules: a replay that dropped it would pass the #1708 trace
    /// through the start window alone.
    func testARouteChangeInTheTraceReachesTheRule() throws {
        let withTheRouteChange = try trace(routeChangeLateInTheRecording)
        let without = RecordingRouteTrace(name: "same, route change dropped", events: withTheRouteChange.events.filter { $0.event != .routeChanged })
        XCTAssertEqual(try RecordingRouteReplay.replay(without).endedAtMs, 8_400)
        XCTAssertEqual(try RecordingRouteReplay.replay(withTheRouteChange).endedAtMs, 9_000)
    }

    func testOnlyNowPlayingCommandsThatCanEndAMarginAreJudged() throws {
        let json = """
        {"name": "other commands", "events": [
          {"atMs": 0, "event": "recording_started"},
          {"atMs": 3000, "event": "command", "command": "skipBack", "origin": "now_playing_remote"},
          {"atMs": 3500, "event": "command", "command": "pause", "origin": "widget"},
          {"atMs": 4000, "event": "command", "command": "skipForward", "origin": "now_playing_remote"}
        ]}
        """
        let result = try RecordingRouteReplay.replay(trace(json))
        XCTAssertEqual(result.steps.map(\.outcome), [.noDecision, .noDecision, .noDecision, .endsMargin])
    }

    // MARK: The clock the app and the replay share

    func testTheClockForgetsAnEarlierRecordingsRouteChange() {
        var clock = RecordingRouteClock()
        clock.routeChanged(atMs: 50) // nothing records yet
        XCTAssertNil(clock.msSinceRouteChange(atMs: 100))
        XCTAssertEqual(clock.elapsedMs(atMs: 100), 0)
        clock.begin(atMs: 1_000)
        XCTAssertNil(clock.msSinceRouteChange(atMs: 1_100))
        clock.routeChanged(atMs: 1_400)
        XCTAssertEqual(clock.msSinceRouteChange(atMs: 1_500), 100)
        XCTAssertEqual(clock.elapsedMs(atMs: 1_500), 500)
        clock.begin(atMs: 9_000)
        XCTAssertNil(clock.msSinceRouteChange(atMs: 9_050), "a route change from the last recording must not hold back this one's click")
        clock.end()
        XCTAssertEqual(clock.elapsedMs(atMs: 9_100), 0)
        XCTAssertEqual(clock.elapsedMs(atMs: 100), 0, "a clock that went backwards never gives a negative time")
    }

    // MARK: The format refuses what it cannot replay

    func testTheFormatRefusesATraceItCannotReplay() {
        func refusal(_ json: String) -> RecordingRouteTrace.TraceError? {
            do { _ = try RecordingRouteTrace.decode(Data(json.utf8)); return nil } catch { return error as? RecordingRouteTrace.TraceError }
        }
        let start = #"{"atMs": 0, "event": "recording_started"}"#
        XCTAssertEqual(refusal(#"{"name": "n", "events": []}"#), .noEvents)
        XCTAssertEqual(refusal(#"{"name": "n", "events": [{"atMs": 0, "event": "route_changed"}]}"#), .mustStartWithRecordingStarted)
        XCTAssertEqual(refusal("{\"name\": \"n\", \"events\": [\(start), {\"atMs\": 500, \"event\": \"route_changed\"}, {\"atMs\": 400, \"event\": \"route_changed\"}]}"),
                       .timeWentBackwards(atMs: 400))
        XCTAssertEqual(refusal("{\"name\": \"n\", \"events\": [\(start), {\"atMs\": 10, \"event\": \"command\", \"origin\": \"now_playing\"}]}"),
                       .missingField(event: .command, field: "command", atMs: 10))
        XCTAssertEqual(refusal("{\"name\": \"n\", \"events\": [\(start), {\"atMs\": 10, \"event\": \"command\", \"command\": \"play\"}]}"),
                       .missingField(event: .command, field: "origin", atMs: 10))
        XCTAssertEqual(refusal("{\"name\": \"n\", \"events\": [\(start), {\"atMs\": 10, \"event\": \"mute_changed\"}]}"),
                       .missingField(event: .muteChanged, field: "muted", atMs: 10))
        XCTAssertEqual(refusal("{\"name\": \"n\", \"events\": [\(start), {\"atMs\": 10, \"event\": \"recording_started\"}]}"),
                       .secondRecordingStarted(atMs: 10))
        XCTAssertThrowsError(try RecordingRouteTrace.decode(Data("{\"name\": \"n\", \"events\": [\(start), {\"atMs\": 10, \"event\": \"headset_exploded\"}]}".utf8)),
                             "an event the format doesn't know is not skipped")
        XCTAssertNil(refusal("{\"name\": \"n\", \"events\": [\(start)]}"))
    }

    func testATraceSurvivesBeingWrittenAndReadBack() throws {
        let original = try trace(headsetMutePress)
        let again = try RecordingRouteTrace.decode(JSONEncoder().encode(original))
        XCTAssertEqual(again, original)
    }
}
