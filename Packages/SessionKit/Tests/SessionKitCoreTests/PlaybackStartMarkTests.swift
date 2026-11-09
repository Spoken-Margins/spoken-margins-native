import XCTest
@testable import SessionKit

/// #3638: a tap's open that was still reading must be dropped when playback was started meanwhile, however it was
/// started, and kept when nothing was started.
final class PlaybackStartMarkTests: XCTestCase {
    private func snapshot(session: String? = "s1", status: PlaybackStatus = .paused, skim: SkimBridgeState? = nil) -> SessionSnapshot {
        var snapshot = SessionSnapshot()
        snapshot.sessionId = session
        snapshot.itemId = session == nil ? nil : "item"
        snapshot.status = status
        snapshot.skimBridgeState = skim
        return snapshot
    }

    private func mark(_ snapshot: SessionSnapshot, moment: String? = nil, shared: String? = nil, own: String? = nil) -> PlaybackStartMark {
        PlaybackStartMark(snapshot: snapshot, momentId: moment, sharedMarginId: shared, ownMarginId: own)
    }

    private func skimBridge(asset: String = "summary-1", at ms: Int = 90_000) -> SkimBridgeState {
        SkimBridgeState(direction: .forward, itemId: "item", originMediaTimeMs: 0, summarySceneId: "scene-1",
                        destinationSceneId: "scene-2", destinationMediaTimeMs: ms, summaryAssetId: asset,
                        wasSourcePlaying: true, status: .playing)
    }

    func testNothingStartedIsNotAStart() {
        let tap = mark(snapshot(status: .paused))
        XCTAssertFalse(tap.startedSince(tap))
        XCTAssertFalse(mark(snapshot(status: .paused)).startedSince(tap))
        let playing = mark(snapshot(status: .playing))
        XCTAssertFalse(playing.startedSince(playing), "playing at the tap and still playing is not a start")
        XCTAssertFalse(mark(snapshot(status: .playing)).startedSince(mark(snapshot(status: .starting))), "starting to playing is the same start")
    }

    func testStartingAnotherSessionIsAStart() {
        XCTAssertTrue(mark(snapshot(session: "s2")).startedSince(mark(snapshot(session: "s1"))))
        XCTAssertTrue(mark(snapshot(session: "s2")).startedSince(mark(snapshot(session: nil))), "a first session after none")
    }

    func testPlayOrResumeIsAStart() {
        XCTAssertTrue(mark(snapshot(status: .playing)).startedSince(mark(snapshot(status: .paused))))
        XCTAssertTrue(mark(snapshot(status: .starting)).startedSince(mark(snapshot(status: .idle))))
    }

    func testAMarginMomentASkimBridgeAndEachMarginVoiceAreStarts() {
        let base = snapshot(status: .playing)
        let tap = mark(base)
        XCTAssertTrue(mark(base, moment: "shared::layer::m1").startedSince(tap), "a shared Margin's moment")
        XCTAssertTrue(mark(snapshot(status: .playing, skim: skimBridge())).startedSince(tap), "a Skim bridge")
        XCTAssertTrue(mark(base, shared: "m1").startedSince(tap), "a shared Margin's voice")
        XCTAssertTrue(mark(base, own: "m2").startedSince(tap), "one of their own Margin voices")
    }

    func testAnotherMomentOrBridgeReplacingTheOneAtTheTapIsAStart() {
        let tap = mark(snapshot(status: .playing, skim: skimBridge()), moment: "a", shared: "x", own: "y")
        XCTAssertTrue(mark(snapshot(status: .playing, skim: skimBridge()), moment: "b", shared: "x", own: "y").startedSince(tap))
        XCTAssertTrue(mark(snapshot(status: .playing, skim: skimBridge(asset: "summary-2")), moment: "a", shared: "x", own: "y").startedSince(tap))
        XCTAssertTrue(mark(snapshot(status: .playing, skim: skimBridge(at: 200_000)), moment: "a", shared: "x", own: "y").startedSince(tap))
        XCTAssertTrue(mark(snapshot(status: .playing, skim: skimBridge()), moment: "a", shared: "z", own: "y").startedSince(tap))
        XCTAssertTrue(mark(snapshot(status: .playing, skim: skimBridge()), moment: "a", shared: "x", own: "w").startedSince(tap))
    }

    /// An ending is not a start: the listener who pauses, or whose item finishes, still gets the item they tapped.
    func testEndingsAreNotStarts() {
        let tap = mark(snapshot(status: .playing, skim: skimBridge()), moment: "a", shared: "x", own: "y")
        XCTAssertFalse(mark(snapshot(status: .paused)).startedSince(tap), "a pause")
        XCTAssertFalse(mark(snapshot(session: nil, status: .idle)).startedSince(tap), "the session ended")
    }

    func testPositionTicksAreNotStarts() {
        var tick = snapshot(status: .playing)
        let tap = mark(tick)
        tick.currentMediaTimeMs = 42_000
        XCTAssertFalse(mark(tick).startedSince(tap))
    }
}
