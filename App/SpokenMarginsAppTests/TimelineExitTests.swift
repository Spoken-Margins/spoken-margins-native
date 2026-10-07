import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #670: the Timeline's Back button must always leave the Timeline. It did nothing once the session
/// was closed from the mini player on that screen, so the listener was stuck until they went
/// Share, then Home.
@MainActor
final class TimelineExitTests: XCTestCase {
    func testBackFromTheTimelineOfAPlayingSessionReturnsToNowPlaying() async {
        await withTermsAccepted {
            let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
            model.resetAndSeed()
            model.startItem(id: "item-pill")
            XCTAssertTrue(model.hasActiveSession)
            model.openTimeline()
            XCTAssertEqual(model.screen, .timeline)
            XCTAssertEqual(model.timelineExitTitle, "Now Playing")

            model.leaveTimeline()

            XCTAssertEqual(model.screen, .playback)
        }
    }

    func testBackFromTheTimelineStillLeavesAfterTheSessionIsClosedFromTheMiniPlayer() async {
        await withTermsAccepted {
            let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
            model.resetAndSeed()
            model.startItem(id: "item-pill")
            XCTAssertTrue(model.hasActiveSession)
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

    /// A fresh install has not accepted the Terms, and the Terms sheet then holds back the first playback
    /// of text read by James or Lily (#781), so no session starts. This suite is about navigation: accept
    /// them before the model is created (it reads the acceptance then), and put the old answer back after.
    private func withTermsAccepted(_ body: () async -> Void) async {
        let defaults = UserDefaults.standard
        let version = defaults.object(forKey: SpokenMarginsTerms.acceptanceVersionKey)
        let date = defaults.object(forKey: SpokenMarginsTerms.acceptanceDateKey)
        defer {
            if let version {
                defaults.set(version, forKey: SpokenMarginsTerms.acceptanceVersionKey)
            } else {
                defaults.removeObject(forKey: SpokenMarginsTerms.acceptanceVersionKey)
            }
            if let date {
                defaults.set(date, forKey: SpokenMarginsTerms.acceptanceDateKey)
            } else {
                defaults.removeObject(forKey: SpokenMarginsTerms.acceptanceDateKey)
            }
        }
        SpokenMarginsTerms.recordAcceptance()
        await body()
    }
}
