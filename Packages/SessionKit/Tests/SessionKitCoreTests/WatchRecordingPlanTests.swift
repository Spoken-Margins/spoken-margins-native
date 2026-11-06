import XCTest
@testable import SessionKit

final class WatchRecordingPlanTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func playing(_ item: String = "ep", isPlaying: Bool = true, positionMs: Int = 60_000) -> WatchNowPlaying {
        WatchNowPlaying(itemId: item, title: "Episode", isPlaying: isPlaying, positionMs: positionMs, positionAt: t0)
    }

    func testTheTargetsAreNamedInWords() {
        XCTAssertEqual(WatchRecordingTarget.episode.words, "On this episode")
        XCTAssertEqual(WatchRecordingTarget.session.words, "On the session")
    }

    func testRecordingOnAPlayingEpisodePausesItAndAimsAtItWhereItIs() throws {
        let plan = WatchRecordingPlan.begin(target: .episode, nowPlaying: playing(), phoneNow: t0.addingTimeInterval(10))
        XCTAssertEqual(plan.pauseOnStart, .pause)
        XCTAssertEqual(plan.itemTarget, WatchItemTarget(itemId: "ep", positionMs: 70_000), "60 s plus the 10 s it has played since")
        XCTAssertEqual(plan.resumeOnEnd(nowPlaying: playing()), .play)
    }

    func testRecordingOnTheSessionPausesAPlayingItemToo() {
        let plan = WatchRecordingPlan.begin(target: .session, nowPlaying: playing(), phoneNow: t0)
        XCTAssertEqual(plan.pauseOnStart, .pause)
        XCTAssertNil(plan.itemTarget, "a session Margin names no item, so it files as it always did")
        XCTAssertEqual(plan.resumeOnEnd(nowPlaying: playing()), .play)
    }

    func testAPausedItemIsNeitherPausedNorStartedByTheWatch() {
        let paused = playing(isPlaying: false)
        for target in [WatchRecordingTarget.episode, .session] {
            let plan = WatchRecordingPlan.begin(target: target, nowPlaying: paused, phoneNow: t0.addingTimeInterval(30))
            XCTAssertNil(plan.pauseOnStart, "\(target)")
            XCTAssertNil(plan.resumeOnEnd(nowPlaying: paused), "\(target): never play what the Watch did not pause")
        }
        let aimed = WatchRecordingPlan.begin(target: .episode, nowPlaying: paused, phoneNow: t0.addingTimeInterval(30))
        XCTAssertEqual(aimed.itemTarget?.positionMs, 60_000, "a paused item has not moved on")
    }

    func testPlayIsNotSentToADifferentItemOrAfterTheBoardLostIt() {
        let plan = WatchRecordingPlan.begin(target: .episode, nowPlaying: playing("ep"), phoneNow: t0)
        XCTAssertNil(plan.resumeOnEnd(nowPlaying: playing("another")), "the listener moved on")
        XCTAssertEqual(plan.resumeOnEnd(nowPlaying: nil), .play, "no board yet: the same item is assumed")
        XCTAssertEqual(plan.resumeOnEnd(nowPlaying: playing("ep", isPlaying: false)), .play)
        XCTAssertEqual(plan.resumeOnEnd(nowPlaying: playing("ep", isPlaying: true)), .play, "a playing phone ignores it")
    }

    func testNothingLoadedMeansNothingToPauseOrAimAt() {
        let plan = WatchRecordingPlan.begin(target: .episode, nowPlaying: nil, phoneNow: t0)
        XCTAssertNil(plan.itemTarget)
        XCTAssertNil(plan.pauseOnStart)
        XCTAssertNil(plan.resumeOnEnd(nowPlaying: nil))
    }

    func testDiscardAsksOnlyAfterAShortClipIsOver() {
        let plan = WatchRecordingPlan(target: .session)
        XCTAssertFalse(plan.discardAsks(afterRecording: 0))
        XCTAssertFalse(plan.discardAsks(afterRecording: 29.9))
        XCTAssertTrue(plan.discardAsks(afterRecording: 30))
        XCTAssertTrue(plan.discardAsks(afterRecording: 600))
    }
}

final class WatchSessionModelNowPlayingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func model(item: WatchNowPlaying?, receivedAt: Date? = nil, clock: WatchClockStamp? = nil) -> WatchSessionModel {
        var model = WatchSessionModel()
        model.clock = clock
        model.apply(WatchBoard(phoneTime: t0, nowPlaying: item), receivedAt: receivedAt ?? t0)
        return model
    }

    private func item(playing: Bool = true) -> WatchNowPlaying {
        WatchNowPlaying(itemId: "ep", title: "Episode", isPlaying: playing, positionMs: 60_000, positionAt: t0)
    }

    func testTheItemShowsWhileReachableOrFreshAndNotWhenOldAndOutOfReach() {
        let model = model(item: item())
        XCTAssertNotNil(model.nowPlaying(now: t0.addingTimeInterval(3_600), phoneReachable: true), "reachable: always")
        XCTAssertNotNil(model.nowPlaying(now: t0.addingTimeInterval(59), phoneReachable: false))
        XCTAssertNil(model.nowPlaying(now: t0.addingTimeInterval(61), phoneReachable: false), "old and out of reach")
    }

    func testABoardWithNoItemOrFromBeforeTheFeatureShowsNothing() {
        XCTAssertNil(model(item: nil).nowPlaying(now: t0, phoneReachable: true))
        XCTAssertNil(WatchSessionModel().nowPlaying(now: t0, phoneReachable: true), "no board yet")
    }

    func testThePositionMovesOnWhilePlayingAndUsesThePhonesClock() throws {
        // A Watch 100 s ahead of the phone: its clock reads t0+130 when the phone's reads t0+30.
        let ahead = model(item: item(), clock: WatchClockStamp(offset: 100, measuredAt: t0))
        XCTAssertEqual(ahead.nowPlayingPosition(now: t0.addingTimeInterval(130)), 90_000)
        XCTAssertEqual(ahead.phoneTime(of: t0.addingTimeInterval(130)), t0.addingTimeInterval(30))
        XCTAssertEqual(model(item: item(playing: false)).nowPlayingPosition(now: t0.addingTimeInterval(130)), 60_000)
        XCTAssertNil(model(item: nil).nowPlayingPosition(now: t0))
    }

    func testPressingPlayOrPauseFlipsTheStateAtOnceFromWhereTheItemIs() throws {
        var pressed = model(item: item())
        pressed.noteTransport(.pause, now: t0.addingTimeInterval(20))
        let paused = try XCTUnwrap(pressed.nowPlaying(now: t0.addingTimeInterval(20), phoneReachable: true))
        XCTAssertFalse(paused.isPlaying)
        XCTAssertEqual(paused.positionMs, 80_000)
        XCTAssertEqual(pressed.nowPlayingPosition(now: t0.addingTimeInterval(500)), 80_000, "paused: it stays")
        pressed.noteTransport(.play, now: t0.addingTimeInterval(30))
        XCTAssertTrue(try XCTUnwrap(pressed.nowPlaying(now: t0.addingTimeInterval(30), phoneReachable: true)).isPlaying)
        XCTAssertEqual(pressed.nowPlayingPosition(now: t0.addingTimeInterval(40)), 90_000)
    }

    func testASkipDoesNotGuessAndTheNextBoardReplacesTheFlip() throws {
        var pressed = model(item: item())
        pressed.noteTransport(.skipForward, now: t0.addingTimeInterval(5))
        XCTAssertEqual(pressed.board?.nowPlaying, item())
        pressed.noteTransport(.pause, now: t0.addingTimeInterval(5))
        pressed.apply(WatchBoard(phoneTime: t0, nowPlaying: item()), receivedAt: t0.addingTimeInterval(6))
        XCTAssertEqual(pressed.board?.nowPlaying, item())
        var empty = WatchSessionModel()
        empty.noteTransport(.pause, now: t0)
        XCTAssertNil(empty.board, "nothing to flip with no board")
    }

    func testTheReplyToACommandLeavesTheButtonAndTheNextBoardSaysWhatIsTrue() {
        var model = model(item: item(playing: true), receivedAt: t0)
        model.noteTransport(.pause, now: t0)
        let later = t0.addingTimeInterval(1)
        let madeBeforeThePause = WatchBoard(phoneTime: later, nowPlaying: item(playing: true))

        model.apply(madeBeforeThePause, receivedAt: later, keepingNowPlaying: true)
        XCTAssertEqual(model.board?.nowPlaying?.isPlaying, false, "the reply must not flip the drawn button back")
        XCTAssertEqual(model.board?.phoneTime, later, "the rest of the reply still counts")
        XCTAssertEqual(model.boardReceivedAt, later)

        model.apply(madeBeforeThePause, receivedAt: later)
        XCTAssertEqual(model.board?.nowPlaying?.isPlaying, true, "a board sent after the command wins, so a refused command is corrected")
    }

    func testAReplyWithNoItemBoardStillKeepsTheDrawnItemUntilABoardSaysSo() {
        var model = model(item: item(playing: false), receivedAt: t0)
        model.apply(WatchBoard(phoneTime: t0, nowPlaying: nil), receivedAt: t0, keepingNowPlaying: true)
        XCTAssertNotNil(model.board?.nowPlaying)
        model.apply(WatchBoard(phoneTime: t0, nowPlaying: nil), receivedAt: t0)
        XCTAssertNil(model.board?.nowPlaying, "nothing loaded: back to the single Record")
    }

    func testTheModelStillDecodesFromWhatTheLastBuildSaved() throws {
        let old = #"{"endedHere":{}}"#
        XCTAssertNoThrow(try WatchContractCoding.decoder.decode(WatchSessionModel.self, from: Data(old.utf8)))
        var saved = model(item: item())
        saved.noteTransport(.pause, now: t0)
        let round = try WatchContractCoding.decoder.decode(WatchSessionModel.self, from: try WatchContractCoding.encoder.encode(saved))
        XCTAssertEqual(round, saved)
    }
}

final class WatchMarginNewsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func held(_ id: String = "m1") -> WatchMarginLedger {
        var ledger = WatchMarginLedger()
        ledger.record(WatchMarginTransfer(id: id, wallStart: t0, durationMs: 1_000), fileName: "\(id).m4a", now: t0)
        return ledger
    }

    func testAHeldMarginIsNewsHoweverLongItWaits() {
        XCTAssertTrue(held().isNews("m1", now: t0.addingTimeInterval(3_600)), "waiting is never hidden below the fold")
    }

    func testFiledWordsAreNewsForThirtySecondsThenGiveTheLineBack() {
        var ledger = held()
        let answer = WatchMarginAnswer(
            receipt: WatchMarginReceipt(captureId: "m1", sha256: "", status: .stored), outcome: .filed, filedIn: "this episode"
        )
        _ = ledger.apply(answer, now: t0)
        XCTAssertTrue(ledger.isNews("m1", now: t0))
        XCTAssertTrue(ledger.isNews("m1", now: t0.addingTimeInterval(WatchContract.filedIsNewsFor)))
        XCTAssertFalse(ledger.isNews("m1", now: t0.addingTimeInterval(WatchContract.filedIsNewsFor + 1)))
        XCTAssertEqual(ledger.display("m1", now: t0.addingTimeInterval(600))?.words, "Filed in this episode", "the words are still there")
    }

    func testAMarginTheWatchNeverHeldIsNotNews() {
        XCTAssertFalse(WatchMarginLedger().isNews("nobody", now: t0))
    }
}
