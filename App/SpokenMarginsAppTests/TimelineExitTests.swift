import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #670: the Timeline's Back button must always leave the Timeline. It did nothing once the session
/// was closed from the mini player on that screen, so the listener was stuck until they went
/// Share, then Home.
@MainActor
final class TimelineExitTests: XCTestCase {
    func testBackFromTheTimelineOfAPlayingSessionReturnsToNowPlaying() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.openTimeline()
        XCTAssertEqual(model.screen, .timeline)
        XCTAssertEqual(model.timelineExitTitle, "Now Playing")

        model.leaveTimeline()

        XCTAssertEqual(model.screen, .playback)
    }

    func testBackFromTheTimelineStillLeavesAfterTheSessionIsClosedFromTheMiniPlayer() async {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        model.openTimeline()
        XCTAssertEqual(model.screen, .timeline)
        XCTAssertTrue(model.shouldShowMiniPlayer, "The Timeline shows the mini player, with its close button.")

        model.dismissMiniPlayer()
        for _ in 0..<50 where model.hasActiveSession {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.hasActiveSession)
        XCTAssertEqual(model.screen, .timeline, "Closing the mini player keeps the page the listener is on (#583).")
        XCTAssertEqual(model.timelineExitTitle, "Home", "Back must not promise Now Playing when nothing is playing.")

        model.leaveTimeline()

        XCTAssertEqual(model.screen, .home)
    }
}
