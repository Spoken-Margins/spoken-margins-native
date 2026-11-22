import Foundation
import XCTest
@testable import SessionKit

/// #4453: when the Now tab's scene follows the playing sentence.
final class PlaybackSceneFollowTests: XCTestCase {
    private func at(_ sentence: Int, scene start: Int = 0, title: String? = "One") -> PlaybackSceneFollow.Playhead {
        .init(chapterStart: start, chapterTitle: title, sentence: sentence)
    }

    private func following(at sentence: Int = 3) -> PlaybackSceneFollow {
        var follow = PlaybackSceneFollow()
        follow.playheadMoved(to: at(sentence), byListenerControl: false)
        return follow
    }

    func testItFollowsFromTheStart() {
        let follow = following()
        XCTAssertTrue(follow.isFollowing)
        XCTAssertFalse(follow.offersBackToPlaying)
        XCTAssertEqual(follow.shownChapterStart, 0)
        XCTAssertNil(follow.nowInTitle)
    }

    func testAScrollStopsFollowingAndOffersTheWayBack() {
        var follow = following()
        follow.listenerScrolled()
        XCTAssertFalse(follow.isFollowing)
        XCTAssertTrue(follow.offersBackToPlaying)
        XCTAssertFalse(follow.scrollsOnItsOwn(assistiveTechnologyRunning: false))
    }

    func testTheSameAndTheNextSentenceDoNotStartFollowingAgain() {
        var follow = following()
        follow.listenerScrolled()
        follow.playheadMoved(to: at(3), byListenerControl: false)
        follow.playheadMoved(to: at(4), byListenerControl: false)
        XCTAssertFalse(follow.isFollowing, "playback going on is not a reason to take the page back")
    }

    func testAJumpStartsFollowingAgain() {
        for jump in [at(9), at(1), at(7, scene: 500, title: "Two")] {
            var follow = following()
            follow.listenerScrolled()
            follow.playheadMoved(to: jump, byListenerControl: false)
            XCTAssertTrue(follow.isFollowing, "\(jump)")
            XCTAssertEqual(follow.shownChapterStart, jump.chapterStart)
        }
    }

    /// By the design a move that is not the same sentence, the next one or a later scene's first is a jump, whether or not
    /// the listener's control made it, so the app calls `playheadMoved` once per sentence change and never samples slower.
    /// A tick that skips a sentence, or goes back, takes the page back (found by the review of #4453's first piece).
    func testAnUnflaggedMoveThatSkipsASentenceOrGoesBackIsStillAJump() {
        for jump in [at(5), at(2), at(1, scene: 500, title: "Two")] {
            var follow = following()
            follow.listenerScrolled()
            follow.playheadMoved(to: jump, byListenerControl: false)
            XCTAssertTrue(follow.isFollowing, "\(jump)")
        }
    }

    func testBackToPlayingBeforeAnyPlayheadChangesNothingToShow() {
        var follow = PlaybackSceneFollow()
        follow.backToPlayingTapped()
        XCTAssertTrue(follow.isFollowing)
        XCTAssertNil(follow.shownChapterStart)
    }

    func testAListenersControlStartsFollowingEvenToTheNextSentence() {
        var follow = following()
        follow.listenerScrolled()
        follow.playheadMoved(to: at(4), byListenerControl: true)
        XCTAssertTrue(follow.isFollowing)
    }

    func testSkimToTheNextSceneIsAJumpButPlaybackReachingItIsNot() {
        var skimmed = following()
        skimmed.listenerScrolled()
        skimmed.playheadMoved(to: at(0, scene: 500, title: "Two"), byListenerControl: true)
        XCTAssertTrue(skimmed.isFollowing)
        XCTAssertEqual(skimmed.shownChapterStart, 500)

        var reached = following()
        reached.listenerScrolled()
        reached.playheadMoved(to: at(0, scene: 500, title: "Two"), byListenerControl: false)
        XCTAssertFalse(reached.isFollowing)
        XCTAssertEqual(reached.shownChapterStart, 0, "the scene they are reading stays")
        XCTAssertEqual(reached.nowInTitle, "Two")
    }

    func testFollowingTakesTheNextSceneAlongWithoutAJump() {
        var follow = following()
        follow.playheadMoved(to: at(0, scene: 500, title: "Two"), byListenerControl: false)
        XCTAssertTrue(follow.isFollowing)
        XCTAssertEqual(follow.shownChapterStart, 500)
        XCTAssertNil(follow.nowInTitle)
    }

    func testBackToPlayingShowsThePlayingSceneAndFollows() {
        var follow = following()
        follow.listenerScrolled()
        follow.playheadMoved(to: at(0, scene: 500, title: "Two"), byListenerControl: false)
        follow.backToPlayingTapped()
        XCTAssertTrue(follow.isFollowing)
        XCTAssertEqual(follow.shownChapterStart, 500)
        XCTAssertNil(follow.nowInTitle)
    }

    func testAScrollAtRestFollowsOnlyWithTheLitSentenceOnScreenInTheShownScene() {
        var follow = following()
        follow.listenerScrolled()
        follow.scrollCameToRest(litSentenceIsVisible: false)
        XCTAssertFalse(follow.isFollowing)
        follow.scrollCameToRest(litSentenceIsVisible: true)
        XCTAssertTrue(follow.isFollowing)

        var older = following()
        older.listenerScrolled()
        older.playheadMoved(to: at(0, scene: 500, title: "Two"), byListenerControl: false)
        older.scrollCameToRest(litSentenceIsVisible: true)
        XCTAssertFalse(older.isFollowing, "the lit sentence is in a scene that isn't the one on screen")
    }

    func testVoiceOverMeansTheListNeverScrollsByItself() {
        let follow = following()
        XCTAssertTrue(follow.scrollsOnItsOwn(assistiveTechnologyRunning: false))
        XCTAssertFalse(follow.scrollsOnItsOwn(assistiveTechnologyRunning: true))
    }

    func testTwoQuickJumpsSettleOnTheLastPlace() {
        var follow = following()
        follow.listenerScrolled()
        follow.playheadMoved(to: at(8), byListenerControl: true)
        follow.playheadMoved(to: at(20, scene: 500, title: "Two"), byListenerControl: true)
        XCTAssertTrue(follow.isFollowing)
        XCTAssertEqual(follow.playhead, at(20, scene: 500, title: "Two"))
        XCTAssertEqual(follow.shownChapterStart, 500)
    }
}
