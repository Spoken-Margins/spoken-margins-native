import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// #2099: the in-app Play/Pause tap and the mini player's X left no trace in everyday Diagnostics, so a tap
/// that landed late looked the same as one that never landed.
@MainActor
final class HangTelemetryTests: XCTestCase {
    private func events(_ model: Gate1AppModel, kind: String) -> [DeveloperDiagnosticRecording.Event] {
        model.playbackEventRecording.events.filter { $0.kind == kind }
    }

    func testThePlayPauseButtonLogsTheTapAsAnAppUITransportRequest() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.playPauseTapped()
        let requests = events(model, kind: "transport.request")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.fields["origin"], "app_ui")
        XCTAssertEqual(requests.first?.fields["command"], "togglePlayPause")
        XCTAssertTrue(model.hangTelemetry.lastTapFields()["lastTap"] == "togglePlayPause")
    }

    func testTheCloseTapRecordsWhetherItWasAcceptedOrIgnored() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.dismissMiniPlayer()
        model.dismissMiniPlayer() // before the first one's task runs
        let outcomes = events(model, kind: "miniPlayer.close.outcome").map { $0.fields["outcome"] }
        XCTAssertEqual(outcomes, ["accepted", "already_dismissing"])
        XCTAssertEqual(events(model, kind: "miniPlayer.close").count, 2, "both taps are still logged")
    }

    func testAStatusChangeAfterATapIsLoggedWithItsDelay() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.hangTelemetry.noteTap(command: "togglePlayPause", status: "paused")
        let answer = model.hangTelemetry.statusChanged(to: "playing")
        XCTAssertEqual(answer?["from"], "paused")
        XCTAssertEqual(answer?["to"], "playing")
        XCTAssertNotNil(answer?["tapToStateMs"].flatMap(Int.init))
        XCTAssertNil(model.hangTelemetry.statusChanged(to: "paused"), "one answer per tap")
    }
}
