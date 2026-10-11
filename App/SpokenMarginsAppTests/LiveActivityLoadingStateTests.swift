import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #943: the Live Activity drew a waveform and "PLAY" while the engine was still starting.
final class LiveActivityLoadingStateTests: XCTestCase {
    private func state(_ status: String, isRecording: Bool = false) -> Gate2LiveActivityAttributes.ContentState {
        Gate2LiveActivityAttributes.ContentState(
            title: "Episode", chapterTitle: "Opening", status: status, phase: "itemPlayback",
            progressPercent: 10, isRecording: isRecording
        )
    }

    func testOnlyStartingIsLoadingAndOnlyPlayingIsRunning() {
        XCTAssertTrue(state("starting").isLoadingAudio)
        XCTAssertFalse(state("starting").isAudioRunning)
        XCTAssertTrue(state("playing").isAudioRunning)
        XCTAssertFalse(state("playing").isLoadingAudio)
        for status in ["paused", "idle", "failed"] {
            XCTAssertFalse(state(status).isLoadingAudio, status)
            XCTAssertFalse(state(status).isAudioRunning, status)
        }
    }

    func testAStartingMarginRecordingIsNotLoadingAudio() {
        XCTAssertFalse(state("starting", isRecording: true).isLoadingAudio)
    }

    func testTheStatusStringsAreThePlaybackStatusRawValues() {
        XCTAssertEqual(PlaybackStatus.starting.rawValue, "starting")
        XCTAssertEqual(PlaybackStatus.playing.rawValue, "playing")
    }
}
