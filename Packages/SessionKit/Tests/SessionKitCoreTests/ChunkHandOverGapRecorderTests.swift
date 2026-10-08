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
}
