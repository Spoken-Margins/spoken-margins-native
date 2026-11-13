import Foundation
import XCTest
@testable import SessionKit

/// #2542: the runs our own player records are the only time a Watch or Lock Screen Margin may be put on the playing
/// item, so a run must end wherever steady playback ends.
final class PlayerRunRecorderTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }

    private func playing(_ ms: Int, item: String = "ep", rate: Double = 1) -> PlayerRunRecorder.Observation {
        .init(itemId: item, mediaTimeMs: ms, rate: rate, isPlaying: true)
    }

    private func pausedOn(_ item: String, ms: Int) -> PlayerRunRecorder.Observation {
        .init(itemId: item, mediaTimeMs: ms, rate: 1, isPlaying: false, isPaused: true)
    }

    private let paused = PlayerRunRecorder.Observation(itemId: "ep", mediaTimeMs: 0, rate: 1, isPlaying: false)

    func testASteadyRunPlacesAMarginAtTheTimeItWasTaken() {
        var recorder = PlayerRunRecorder()
        recorder.observe(playing(60_000), at: at(0))
        recorder.observe(playing(60_500), at: at(0.5))
        recorder.observe(playing(70_000), at: at(10))
        let runs = recorder.runs(at: at(12))
        XCTAssertEqual(runs.count, 1, "steady ticks stay one run")
        let decision = LiveSessionFiling.decide(
            .init(marginId: "m", markedAt: at(4)), sessions: [], deletions: .init(), playerRuns: runs, now: at(12)
        )
        XCTAssertEqual(decision, .playerItem(itemId: "ep", positionMs: 64_000))
    }

    func testAPauseEndsTheRunAndALaterMarginIsNotPlacedOnIt() {
        // Not told the item is paused (starting, recording, finished): the rest of the rule files it.
        var recorder = PlayerRunRecorder()
        recorder.observe(playing(0), at: at(0))
        recorder.observe(playing(5_000), at: at(5))
        recorder.observe(paused, at: at(5.2))
        let runs = recorder.runs(at: at(60))
        XCTAssertEqual(runs.map(\.endedAt), [at(5.2)])
        let late = LiveSessionFiling.decide(
            .init(marginId: "m", markedAt: at(30)), sessions: [], deletions: .init(), playerRuns: runs, now: at(60)
        )
        XCTAssertEqual(late, .newQuick, "a Margin taken while the player is not playing or paused is filed by the rest of the rule")
    }

    private func decide(_ runs: [LiveSessionFiling.PlayerRun], at seconds: TimeInterval, now: TimeInterval) -> LiveSessionFiling.Decision {
        LiveSessionFiling.decide(
            .init(marginId: "m\(seconds)", markedAt: at(seconds)), sessions: [], deletions: .init(), playerRuns: runs, now: at(now)
        )
    }

    /// #4079: a Margin recorded from the Watch with no live session goes to the item the phone was playing, also once the
    /// Watch has paused it, at the place it is paused. Fails without the parked stretch: this was `.newQuick`.
    func testAMarginTakenWhileAnItemIsPausedFilesAtItsPlace() {
        var recorder = PlayerRunRecorder()
        recorder.observe(playing(0), at: at(0))
        recorder.observe(playing(5_000), at: at(5))
        recorder.observe(pausedOn("ep", ms: 5_100), at: at(5.2))
        recorder.observe(pausedOn("ep", ms: 5_100), at: at(20))
        let runs = recorder.runs(at: at(60))
        XCTAssertEqual(decide(runs, at: 3, now: 60), .playerItem(itemId: "ep", positionMs: 3_000))
        XCTAssertEqual(decide(runs, at: 5.1, now: 60), .playerItem(itemId: "ep", positionMs: 5_100))
        XCTAssertEqual(decide(runs, at: 45, now: 60), .playerItem(itemId: "ep", positionMs: 5_100), "inside the hold")
    }

    func testAPausedItemOlderThanTheHoldDoesNotPark() {
        var recorder = PlayerRunRecorder()
        recorder.observe(playing(5_000), at: at(0))
        recorder.observe(pausedOn("ep", ms: 5_000), at: at(0.2))
        let late = PlayerRunRecorder.parkedHold + 120
        let runs = recorder.runs(at: at(late))
        XCTAssertEqual(decide(runs, at: late - 10, now: late), .newQuick, "a pause left for hours holds nothing")
        XCTAssertEqual(decide(runs, at: PlayerRunRecorder.parkedHold - 10, now: late), .playerItem(itemId: "ep", positionMs: 5_000))
    }

    func testAPausedItemRestoredAtLaunchWithNoPlayRunDoesNotPark() {
        var recorder = PlayerRunRecorder()
        recorder.observe(pausedOn("ep", ms: 70_000), at: at(0))
        recorder.observe(pausedOn("ep", ms: 70_000), at: at(30))
        XCTAssertTrue(recorder.runs(at: at(60)).isEmpty)
        XCTAssertEqual(decide(recorder.runs(at: at(60)), at: 40, now: 60), .newQuick)
    }

    func testAFinishedItemDoesNotPark() {
        var snapshot = SessionSnapshot()
        snapshot.itemId = "ep"
        snapshot.currentMediaTimeMs = 9_000
        snapshot.status = .paused
        snapshot.phase = .finished
        XCTAssertFalse(PlayerRunRecorder.observation(of: snapshot).isPaused)
        var recorder = PlayerRunRecorder()
        recorder.observe(playing(8_000), at: at(0))
        recorder.observe(PlayerRunRecorder.observation(of: snapshot), at: at(1))
        XCTAssertEqual(decide(recorder.runs(at: at(30)), at: 20, now: 30), .newQuick)
        snapshot.phase = .itemPlayback
        XCTAssertTrue(PlayerRunRecorder.observation(of: snapshot).isPaused, "a real pause still parks")
    }

    func testAPausedItemStopsHoldingWhenPlayingResumes() {
        var recorder = PlayerRunRecorder()
        recorder.observe(playing(8_000, item: "one"), at: at(0))
        recorder.observe(pausedOn("one", ms: 9_000), at: at(1))
        recorder.observe(playing(9_000, item: "one"), at: at(30)) // resumed
        recorder.observe(playing(15_000, item: "one"), at: at(36))
        let runs = recorder.runs(at: at(40))
        XCTAssertEqual(decide(runs, at: 10, now: 40), .playerItem(itemId: "one", positionMs: 9_000))
        XCTAssertEqual(decide(runs, at: 33, now: 40), .playerItem(itemId: "one", positionMs: 12_000))
    }

    func testASeekOrAnotherItemWhilePausedEndsTheHoldAndDoesNotParkAgain() {
        var seek = PlayerRunRecorder()
        seek.observe(playing(8_000), at: at(0))
        seek.observe(pausedOn("ep", ms: 9_000), at: at(1))
        seek.observe(pausedOn("ep", ms: 9_000), at: at(10))
        seek.observe(pausedOn("ep", ms: 90_000), at: at(50)) // the listener moved the place
        seek.observe(pausedOn("ep", ms: 90_000), at: at(60))
        XCTAssertEqual(decide(seek.runs(at: at(70)), at: 5, now: 70), .playerItem(itemId: "ep", positionMs: 9_000))
        XCTAssertEqual(decide(seek.runs(at: at(70)), at: 30, now: 70), .newQuick, "nothing vouches for 10 to 50 s")
        XCTAssertEqual(decide(seek.runs(at: at(70)), at: 65, now: 70), .newQuick, "the new place was not played to")

        var other = PlayerRunRecorder()
        other.observe(playing(8_000), at: at(0))
        other.observe(pausedOn("ep", ms: 9_000), at: at(1))
        other.observe(pausedOn("two", ms: 0), at: at(100)) // another item loaded, paused
        XCTAssertEqual(decide(other.runs(at: at(200)), at: 150, now: 200), .newQuick)
    }

    func testASeekStartsANewRunAndKeepsTheOldOneUpToTheLastSteadyTick() throws {
        var recorder = PlayerRunRecorder()
        recorder.observe(playing(10_000), at: at(0))
        recorder.observe(playing(15_000), at: at(5))
        recorder.observe(playing(300_000), at: at(6)) // the listener skipped far ahead
        recorder.observe(playing(304_000), at: at(10))
        let runs = recorder.runs(at: at(11))
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].endedAt, at(5), "vouched for only up to the last steady tick")
        XCTAssertEqual(runs[1].startPositionMs, 300_000)
        XCTAssertEqual(runs[1].positionMs(at: at(10)), 304_000)
        // A Margin between the last steady tick and the jump is in no run.
        XCTAssertNil(runs.last { $0.startedAt <= at(5.5) && at(5.5) <= $0.endedAt })
    }

    func testAnotherItemEndsTheRun() {
        var recorder = PlayerRunRecorder()
        recorder.observe(playing(1_000, item: "one"), at: at(0))
        recorder.observe(playing(2_000, item: "one"), at: at(1))
        recorder.observe(playing(0, item: "two"), at: at(2))
        let runs = recorder.runs(at: at(3))
        XCTAssertEqual(runs.map(\.itemId), ["one", "two"])
        XCTAssertEqual(runs[0].endedAt, at(1))
    }

    func testAChangeOfSpeedIsContinuousAndKeepsTheNewRate() {
        var recorder = PlayerRunRecorder()
        recorder.observe(playing(0), at: at(0))
        recorder.observe(playing(10_000), at: at(10))
        recorder.observe(playing(10_000, rate: 1.5), at: at(10))
        recorder.observe(playing(25_000, rate: 1.5), at: at(20))
        let runs = recorder.runs(at: at(20))
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].endedAt, at(10))
        XCTAssertEqual(runs[1].rate, 1.5)
        XCTAssertEqual(runs[1].positionMs(at: at(14)), 16_000)
    }

    func testTableOfObservationsThatAreNotPlayback() {
        let rows: [(String, PlayerRunRecorder.Observation)] = [
            ("not playing", .init(itemId: "ep", mediaTimeMs: 5_000, rate: 1, isPlaying: false)),
            ("no item", .init(itemId: nil, mediaTimeMs: 5_000, rate: 1, isPlaying: true)),
            ("no media time", .init(itemId: "ep", mediaTimeMs: nil, rate: 1, isPlaying: true)),
            ("negative time", .init(itemId: "ep", mediaTimeMs: -1, rate: 1, isPlaying: true)),
            ("zero rate", .init(itemId: "ep", mediaTimeMs: 5_000, rate: 0, isPlaying: true))
        ]
        for (name, observation) in rows {
            var recorder = PlayerRunRecorder()
            recorder.observe(observation, at: at(0))
            XCTAssertTrue(recorder.runs(at: at(10)).isEmpty, name)
        }
    }

    func testAJustStartedRunThatEndsAtOnceLeavesNoRun() {
        var recorder = PlayerRunRecorder()
        recorder.observe(playing(0), at: at(0))
        recorder.observe(paused, at: at(0))
        XCTAssertTrue(recorder.runs(at: at(1)).isEmpty)
    }

    func testOldRunsAreDroppedAndTheCountIsBounded() {
        var recorder = PlayerRunRecorder()
        recorder.observe(playing(0), at: at(0))
        recorder.observe(paused, at: at(10))
        recorder.observe(paused, at: at(10 + PlayerRunRecorder.keepFor + 1))
        XCTAssertTrue(recorder.runs(at: at(10 + PlayerRunRecorder.keepFor + 1)).isEmpty)

        var busy = PlayerRunRecorder()
        for index in 0..<(PlayerRunRecorder.capacity + 20) {
            busy.observe(playing(0), at: at(Double(index) * 10))
            busy.observe(paused, at: at(Double(index) * 10 + 1))
        }
        XCTAssertEqual(busy.runs(at: at(10_000)).count, PlayerRunRecorder.capacity)
    }
}
