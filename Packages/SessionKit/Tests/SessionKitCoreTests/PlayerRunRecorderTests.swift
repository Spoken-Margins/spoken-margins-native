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

    /// #4079: a Margin recorded from the Watch with no live session goes to the item the phone has loaded, also when it
    /// is paused, at the place it is paused. Fails without the parked run: this was `.newQuick`.
    func testAMarginTakenWhileAnItemIsPausedFilesAtItsPlace() {
        var recorder = PlayerRunRecorder()
        recorder.observe(playing(0), at: at(0))
        recorder.observe(playing(5_000), at: at(5))
        recorder.observe(pausedOn("ep", ms: 5_100), at: at(5.2))
        recorder.observe(pausedOn("ep", ms: 5_100), at: at(20))
        let runs = recorder.runs(at: at(60))
        for (name, marked, expected) in [
            ("during the play run", 3.0, 3_000), ("at the pause", 5.1, 5_100),
            ("long after, still paused", 45.0, 5_100)
        ] as [(String, TimeInterval, Int)] {
            let decision = LiveSessionFiling.decide(
                .init(marginId: name, markedAt: at(marked)), sessions: [], deletions: .init(), playerRuns: runs, now: at(60)
            )
            XCTAssertEqual(decision, .playerItem(itemId: "ep", positionMs: expected), name)
        }
    }

    func testAPausedItemStopsHoldingWhenPlayingResumesOrAnotherItemLoads() {
        var recorder = PlayerRunRecorder()
        recorder.observe(pausedOn("one", ms: 9_000), at: at(0))
        recorder.observe(playing(9_000, item: "one"), at: at(30)) // resumed
        recorder.observe(pausedOn("two", ms: 0), at: at(100)) // another item, paused
        let runs = recorder.runs(at: at(200))
        func place(_ seconds: TimeInterval) -> LiveSessionFiling.Decision {
            LiveSessionFiling.decide(
                .init(marginId: "m\(seconds)", markedAt: at(seconds)), sessions: [], deletions: .init(), playerRuns: runs, now: at(200)
            )
        }
        XCTAssertEqual(place(10), .playerItem(itemId: "one", positionMs: 9_000))
        XCTAssertEqual(place(150), .playerItem(itemId: "two", positionMs: 0))
    }

    func testASeekWhilePausedKeepsTheOldPlaceOnlyUpToTheLastSighting() {
        var recorder = PlayerRunRecorder()
        recorder.observe(pausedOn("ep", ms: 1_000), at: at(0))
        recorder.observe(pausedOn("ep", ms: 1_000), at: at(10))
        recorder.observe(pausedOn("ep", ms: 90_000), at: at(50))
        let runs = recorder.runs(at: at(60))
        func position(_ seconds: TimeInterval) -> Int? {
            runs.last { $0.startedAt <= at(seconds) && at(seconds) <= $0.endedAt }?.positionMs(at: at(seconds))
        }
        XCTAssertEqual(position(5), 1_000)
        XCTAssertNil(position(30), "between the last sighting and the seek nothing is vouched for")
        XCTAssertEqual(position(55), 90_000)
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
