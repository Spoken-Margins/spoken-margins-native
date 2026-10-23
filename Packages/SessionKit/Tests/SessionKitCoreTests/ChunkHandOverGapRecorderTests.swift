import Foundation
import XCTest
@testable import SessionKit

/// #586: diagnostics keep the longest gap between one narration chunk ending and the next playing.
final class ChunkHandOverGapRecorderTests: XCTestCase {
    private let generation = UUID()

    func testTheFirstChunkOfAPlayHasNoGap() {
        var recorder = ChunkHandOverGapRecorder()
        XCTAssertNil(recorder.chunkStarted(at: 10, generation: generation))
        XCTAssertNil(recorder.longest)
    }

    func testAGapRunsFromTheEndOfOneChunkToTheStartOfTheNext() throws {
        var recorder = ChunkHandOverGapRecorder()
        recorder.chunkFinished(at: 10, generation: generation, boundary: .sentence, nextChunkWasReady: true)
        let gap = try XCTUnwrap(recorder.chunkStarted(at: 10.42, generation: generation))
        XCTAssertEqual(gap.seconds, 0.42, accuracy: 0.0001)
        XCTAssertEqual(gap.boundary, .sentence)
        XCTAssertTrue(gap.nextChunkWasReady)
        XCTAssertEqual(recorder.longest, gap)
    }

    // #1786: a background seam handed to the bundled voice moves the item to a new generation; the silence until
    // the bundled voice's chunk starts is still the seam's gap. Another seam's pending gap isn't moved.
    func testAGapMovedToANewGenerationIsStillMeasured() throws {
        var recorder = ChunkHandOverGapRecorder()
        let bundled = UUID()
        recorder.chunkFinished(at: 10, generation: generation, boundary: .sentence, nextChunkWasReady: false)
        recorder.pendingMoved(from: UUID(), to: bundled)
        recorder.pendingMoved(from: generation, to: bundled)
        let gap = try XCTUnwrap(recorder.chunkStarted(at: 12.5, generation: bundled))
        XCTAssertEqual(gap.seconds, 2.5, accuracy: 0.0001)
        XCTAssertFalse(gap.nextChunkWasReady)
    }

    func testOnlyAGapLongerThanTheLongestIsReported() throws {
        var recorder = ChunkHandOverGapRecorder()
        recorder.chunkFinished(at: 0, generation: generation, boundary: .sentence, nextChunkWasReady: true)
        XCTAssertNotNil(recorder.chunkStarted(at: 0.5, generation: generation))
        recorder.chunkFinished(at: 20, generation: generation, boundary: .comma, nextChunkWasReady: true)
        XCTAssertNil(recorder.chunkStarted(at: 20.2, generation: generation), "shorter than 0.5 s")
        recorder.chunkFinished(at: 40, generation: generation, boundary: .comma, nextChunkWasReady: false)
        let longer = try XCTUnwrap(recorder.chunkStarted(at: 41.8, generation: generation))
        XCTAssertEqual(longer.seconds, 1.8, accuracy: 0.0001)
        XCTAssertFalse(longer.nextChunkWasReady)
        XCTAssertEqual(recorder.longest, longer)
    }

    func testAPauseDiscardsTheGapInProgress() {
        var recorder = ChunkHandOverGapRecorder()
        recorder.chunkFinished(at: 10, generation: generation, boundary: .sentence, nextChunkWasReady: true)
        recorder.discardPending()
        XCTAssertNil(recorder.chunkStarted(at: 300, generation: generation), "five minutes paused is not a hand-over")
        XCTAssertNil(recorder.longest)
    }

    func testAStopOrSeekStartsANewGeneration() {
        var recorder = ChunkHandOverGapRecorder()
        recorder.chunkFinished(at: 10, generation: generation, boundary: .sentence, nextChunkWasReady: false)
        XCTAssertNil(recorder.chunkStarted(at: 90, generation: UUID()))
        XCTAssertNil(recorder.longest)
    }

    func testAGapIsCountedOnce() {
        var recorder = ChunkHandOverGapRecorder()
        recorder.chunkFinished(at: 1, generation: generation, boundary: .hard, nextChunkWasReady: true)
        XCTAssertNotNil(recorder.chunkStarted(at: 1.3, generation: generation))
        XCTAssertNil(recorder.chunkStarted(at: 9, generation: generation))
    }

    func testTheSummaryNamesTheBoundaryAndWhetherTheRendererWasWaitedOn() {
        XCTAssertEqual(
            ChunkHandOverGapRecorder.Gap(seconds: 0.4162, boundary: .sentence, nextChunkWasReady: true).summary,
            "0.42s after sentence, next chunk ready"
        )
        XCTAssertEqual(
            ChunkHandOverGapRecorder.Gap(seconds: 2, boundary: .comma, nextChunkWasReady: false).summary,
            "2.00s after comma, waited for next chunk"
        )
    }

    /// The audit on PR 1061: a voice change builds a new playback client with an empty recorder,
    /// and its first seam must not replace the stall the listener already had.
    func testALaterClientsShorterGapDoesNotReplaceTheLongestOfTheRun() throws {
        var shown = LongestChunkHandOverGap()
        var firstClient = ChunkHandOverGapRecorder()
        firstClient.chunkFinished(at: 0, generation: generation, boundary: .comma, nextChunkWasReady: false)
        let stall = try XCTUnwrap(firstClient.chunkStarted(at: 2.4, generation: generation))
        XCTAssertTrue(shown.keep(stall))

        var clientAfterAVoiceChange = ChunkHandOverGapRecorder()
        clientAfterAVoiceChange.chunkFinished(at: 100, generation: generation, boundary: .sentence, nextChunkWasReady: true)
        let seam = try XCTUnwrap(clientAfterAVoiceChange.chunkStarted(at: 100.3, generation: generation))
        XCTAssertFalse(shown.keep(seam), "the new client's recorder reports its first gap, the run's longest stays")
        XCTAssertEqual(shown.gap, stall)
    }

    func testALongerGapFromALaterClientReplacesIt() {
        var shown = LongestChunkHandOverGap()
        XCTAssertTrue(shown.keep(.init(seconds: 0.4, boundary: .sentence, nextChunkWasReady: true)))
        let longer = ChunkHandOverGapRecorder.Gap(seconds: 0.9, boundary: .comma, nextChunkWasReady: false)
        XCTAssertTrue(shown.keep(longer))
        XCTAssertEqual(shown.gap, longer)
    }

    func testAnEqualGapKeepsTheFirstAndNothingIsKeptBeforeTheFirst() {
        var shown = LongestChunkHandOverGap()
        XCTAssertNil(shown.gap)
        let first = ChunkHandOverGapRecorder.Gap(seconds: 0.5, boundary: .sentence, nextChunkWasReady: true)
        XCTAssertTrue(shown.keep(first))
        XCTAssertFalse(shown.keep(.init(seconds: 0.5, boundary: .comma, nextChunkWasReady: false)))
        XCTAssertEqual(shown.gap, first)
        XCTAssertFalse(shown.keep(.init(seconds: 0, boundary: .hard, nextChunkWasReady: true)))
    }
}
