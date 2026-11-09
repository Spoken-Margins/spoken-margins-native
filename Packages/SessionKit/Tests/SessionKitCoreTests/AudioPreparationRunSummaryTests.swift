import Foundation
import XCTest
@testable import SessionKit

/// #3816: the basic Diagnostics export says what the last "Make available offline" run cost.
final class AudioPreparationRunSummaryTests: XCTestCase {
    private func run(_ renders: [Int]) -> AudioPreparationRunSummary {
        var summary = AudioPreparationRunSummary(startedAt: 0)
        for (index, ms) in renders.enumerated() {
            summary.chunkCommitted(renderMs: ms, thermalAtStart: .nominal, thermalAtEnd: .nominal, at: Double(index + 1))
        }
        return summary
    }

    func testAnEmptyRunSaysSoInsteadOfInventingNumbers() {
        let summary = AudioPreparationRunSummary(startedAt: 100)
        XCTAssertEqual(summary.line, "chunks=0;renderMsMedian=none;renderMsP90=none;heatPauses=0;peakThermal=nominal;wallClockS=0")
    }

    func testTheMedianOfAnOddCountIsTheMiddleRender() {
        XCTAssertEqual(run([9_000, 1_000, 5_000]).renderMsMedian, 5_000)
    }

    func testTheMedianOfAnEvenCountIsTheMeanOfTheMiddleTwo() {
        XCTAssertEqual(run([4_000, 1_000, 3_000, 2_000]).renderMsMedian, 2_500)
        XCTAssertEqual(run([1_001, 1_002]).renderMsMedian, 1_002, "halves round up")
    }

    func testTheP90IsTheNearestRank() {
        // 10 renders: the 9th smallest is the P90. 20 renders: the 18th.
        XCTAssertEqual(run(Array(1...10).map { $0 * 100 }).renderMsP90, 900)
        XCTAssertEqual(run(Array(1...20).map { $0 * 100 }).renderMsP90, 1_800)
        XCTAssertEqual(run([700]).renderMsP90, 700, "one chunk is its own P90")
        XCTAssertEqual(run([100, 900]).renderMsP90, 900)
    }

    func testOneSlowChunkMovesTheP90ButNotTheMedian() {
        let fast = Array(repeating: 1_000, count: 9)
        XCTAssertEqual(run(fast + [60_000]).renderMsMedian, 1_000)
        XCTAssertEqual(run(fast + [60_000]).renderMsP90, 1_000, "9 of 10 at or under 1000")
        XCTAssertEqual(run(Array(repeating: 1_000, count: 8) + [60_000, 60_000]).renderMsP90, 60_000)
    }

    func testAPausedRunCountsHeatPausesAndTheHottestHeat() {
        var summary = AudioPreparationRunSummary(startedAt: 0)
        summary.chunkCommitted(renderMs: 2_000, thermalAtStart: .nominal, thermalAtEnd: .fair, at: 2)
        summary.heatPaused(thermal: .serious, at: 3)
        summary.chunkCommitted(renderMs: 3_000, thermalAtStart: .fair, thermalAtEnd: .fair, at: 70)
        summary.heatPaused(thermal: .serious, at: 71)
        XCTAssertEqual(summary.line, "chunks=2;renderMsMedian=2500;renderMsP90=3000;heatPauses=2;peakThermal=serious;wallClockS=71")
    }

    func testThePeakNeverFallsWhenTheHeatDoes() {
        var summary = AudioPreparationRunSummary(startedAt: 0)
        summary.chunkCommitted(renderMs: 1, thermalAtStart: .critical, thermalAtEnd: .nominal, at: 1)
        summary.chunkCommitted(renderMs: 1, thermalAtStart: .nominal, thermalAtEnd: .nominal, at: 2)
        XCTAssertEqual(summary.peakThermal, .critical)
    }

    func testAnEventOutOfOrderNeverShrinksTheWallClock() {
        var summary = AudioPreparationRunSummary(startedAt: 10)
        summary.chunkCommitted(renderMs: 1, thermalAtStart: .nominal, thermalAtEnd: .nominal, at: 50)
        summary.heatPaused(thermal: .nominal, at: 20)
        XCTAssertEqual(summary.wallClockSeconds, 40)
    }

    func testANegativeRenderTimeCountsAsZero() {
        XCTAssertEqual(run([-5, 7]).chunkRenderMs, [0, 7])
    }

    // MARK: The runs

    func testTheFirstChunkStartsTheClockWhenItsRenderBegan() {
        var tracker = AudioPreparationRunTracker()
        let line = tracker.chunkCommitted(renderMs: 4_000, thermalAtStart: .nominal, thermalAtEnd: .nominal, at: 1_000)
        XCTAssertEqual(line, "chunks=1;renderMsMedian=4000;renderMsP90=4000;heatPauses=0;peakThermal=nominal;wallClockS=4")
    }

    func testChunksAndPausesCloseTogetherAreOneRunWhoeverRendersThem() {
        var tracker = AudioPreparationRunTracker()
        tracker.chunkCommitted(renderMs: 1_000, thermalAtStart: .nominal, thermalAtEnd: .nominal, at: 1_001)
        tracker.heatPaused(thermal: .serious, at: 1_002)
        let line = tracker.chunkCommitted(renderMs: 3_000, thermalAtStart: .nominal, thermalAtEnd: .nominal, at: 1_100)
        XCTAssertEqual(line, "chunks=2;renderMsMedian=2000;renderMsP90=3000;heatPauses=1;peakThermal=serious;wallClockS=100")
    }

    func testAHeatWaitAsLongAsTheLongestAllowedDoesNotSplitTheRun() {
        var tracker = AudioPreparationRunTracker()
        tracker.heatPaused(thermal: .serious, at: 1_000)
        let resumed = 1_000 + Double(OfflinePreparationRun.maximumHeatWaitSeconds)
        let line = tracker.chunkCommitted(renderMs: 2_000, thermalAtStart: .fair, thermalAtEnd: .fair, at: resumed)
        XCTAssertTrue(line.hasPrefix("chunks=1;"), line)
        XCTAssertTrue(line.contains("heatPauses=1;peakThermal=serious;"), "the pause before the wait is still in the run: \(line)")
    }

    func testTheRunAfterAQuietSpellReplacesTheLastOneAndDoesNotAddToIt() {
        var tracker = AudioPreparationRunTracker()
        tracker.chunkCommitted(renderMs: 9_000, thermalAtStart: .critical, thermalAtEnd: .critical, at: 100)
        tracker.heatPaused(thermal: .critical, at: 101)
        XCTAssertEqual(tracker.current?.chunks, 1, "the last run's summary stays until another replaces it")
        let later = 101 + AudioPreparationRunTracker.idleGap + 1
        let line = tracker.chunkCommitted(renderMs: 1_000, thermalAtStart: .nominal, thermalAtEnd: .nominal, at: later)
        XCTAssertEqual(line, "chunks=1;renderMsMedian=1000;renderMsP90=1000;heatPauses=0;peakThermal=nominal;wallClockS=1")
    }

    func testARunThenAnEmptyQueueThenAChunkWithinTheGapStartsAFreshLine() {
        // Article A finishes at 10:05, the listener starts article B at 10:20: 15 minutes, inside the idle gap.
        var tracker = AudioPreparationRunTracker()
        tracker.chunkCommitted(renderMs: 4_000, thermalAtStart: .fair, thermalAtEnd: .fair, at: 600)
        tracker.heatPaused(thermal: .serious, at: 601)
        tracker.queueDrained()
        XCTAssertEqual(tracker.current?.chunks, 1, "the finished run's line stays until the next run replaces it")
        let line = tracker.chunkCommitted(renderMs: 1_000, thermalAtStart: .nominal, thermalAtEnd: .nominal, at: 600 + 15 * 60)
        XCTAssertEqual(line, "chunks=1;renderMsMedian=1000;renderMsP90=1000;heatPauses=0;peakThermal=nominal;wallClockS=1")
    }

    func testAChunkAfterAnEmptyQueueIsNotTheRunsChunkEvenAfterAHeatPause() {
        var tracker = AudioPreparationRunTracker()
        tracker.heatPaused(thermal: .critical, at: 10)
        tracker.queueDrained()
        let line = tracker.heatPaused(thermal: .nominal, at: 20)
        XCTAssertTrue(line.contains("heatPauses=1;peakThermal=nominal;"), line)
    }

    func testAnEmptyQueueBeforeAnyEventChangesNothing() {
        var tracker = AudioPreparationRunTracker()
        tracker.queueDrained()
        XCTAssertNil(tracker.current)
        let line = tracker.heatPaused(thermal: .serious, at: 5)
        XCTAssertTrue(line.contains("heatPauses=1;"), line)
    }

    func testTheQueueStillHoldingJobsKeepsTheRunOpen() {
        // The caller reports a drain only when the queue is empty; a chunk then another chunk is one run.
        var tracker = AudioPreparationRunTracker()
        tracker.chunkCommitted(renderMs: 1_000, thermalAtStart: .nominal, thermalAtEnd: .nominal, at: 100)
        let line = tracker.chunkCommitted(renderMs: 1_000, thermalAtStart: .nominal, thermalAtEnd: .nominal, at: 110)
        XCTAssertTrue(line.hasPrefix("chunks=2;"), line)
    }

    func testAnEventExactlyAtTheGapStillJoinsTheRun() {
        var tracker = AudioPreparationRunTracker()
        tracker.chunkCommitted(renderMs: 1_000, thermalAtStart: .nominal, thermalAtEnd: .nominal, at: 100)
        let line = tracker.chunkCommitted(renderMs: 1_000, thermalAtStart: .nominal, thermalAtEnd: .nominal, at: 100 + AudioPreparationRunTracker.idleGap)
        XCTAssertTrue(line.hasPrefix("chunks=2;"), line)
    }

    func testARunThatOnlyPausedForHeatLeavesASummary() {
        var tracker = AudioPreparationRunTracker()
        let line = tracker.heatPaused(thermal: .serious, at: 10)
        XCTAssertEqual(line, "chunks=0;renderMsMedian=none;renderMsP90=none;heatPauses=1;peakThermal=serious;wallClockS=0")
    }

    // MARK: Which jobs count as work left

    private func job(_ id: String, _ policy: PreparationJobPolicy, cancelled: Bool = false) -> AudioPreparationJob {
        AudioPreparationJob(id: id, itemId: "item-\(id)", manifestId: "manifest-\(id)", policy: policy, isCancelled: cancelled)
    }

    func testAnEmptyTableIsDrained() {
        XCTAssertTrue(AudioPreparationRunTracker.isDrained(remainingJobs: [], automaticPolicy: .off))
        XCTAssertTrue(AudioPreparationRunTracker.isDrained(remainingJobs: [], automaticPolicy: .whileCharging))
    }

    func testAJobTheListenerStoppedIsNotWorkLeft() {
        // Stop keeps the job with isCancelled; a table holding only that is drained.
        for policy in [AutomaticAudioPreparationPolicy.off, .whileCharging] {
            XCTAssertTrue(AudioPreparationRunTracker.isDrained(remainingJobs: [job("x", .explicit, cancelled: true)], automaticPolicy: policy))
        }
    }

    func testAnExplicitJobStillQueuedIsWorkLeftWhateverTheAutomaticPolicy() {
        for policy in [AutomaticAudioPreparationPolicy.off, .whileCharging] {
            XCTAssertFalse(AudioPreparationRunTracker.isDrained(
                remainingJobs: [job("x", .explicit, cancelled: true), job("y", .explicit)], automaticPolicy: policy))
        }
    }

    func testAnAutomaticJobIsWorkLeftOnlyWhileAutomaticPreparationIsOn() {
        for policy in [PreparationJobPolicy.whileCharging, .demandWindow] {
            XCTAssertTrue(AudioPreparationRunTracker.isDrained(remainingJobs: [job("a", policy)], automaticPolicy: .off), "nothing will pick it up")
            XCTAssertFalse(AudioPreparationRunTracker.isDrained(remainingJobs: [job("a", policy)], automaticPolicy: .whileCharging))
        }
    }

    // MARK: The export

    func testTheLineIsInTheBasicExportAndHoldsNothingPrivate() throws {
        var summary = AudioPreparationRunSummary(startedAt: 0)
        summary.chunkCommitted(renderMs: 5_200, thermalAtStart: .nominal, thermalAtEnd: .fair, at: 6)
        let fixed = DiagnosticsExport.Fixed(
            developerBuild: "0.1 (37)", developerRecording: nil, playbackEvents: nil, exportedAt: Date(timeIntervalSince1970: 0),
            playbackStatus: "idle", sessionPhase: "idle", targetType: nil, pendingAIJobs: 0)
        let entries = DiagnosticsExport.entries(live: [AudioPreparationRunSummary.diagnosticsKey: summary.line], stored: [:], fixed: fixed)
        XCTAssertEqual(entries["audioPreparationLastRun"], "chunks=1;renderMsMedian=5200;renderMsP90=5200;heatPauses=0;peakThermal=fair;wallClockS=6")
        XCTAssertNil(entries["developerRecording"], "the summary is there with detailed recording off")
        XCTAssertFalse(DiagnosticsExport.keyMayContainUserContent(AudioPreparationRunSummary.diagnosticsKey))
        XCTAssertFalse(summary.line.contains("item"), "the line holds no item ids")
    }
}
