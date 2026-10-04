import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// #156: source context for streamed Margins comes from the audio the listener heard, not a second download.
final class HeardAudioWindowRecorderTests: XCTestCase {
    private let rate = 1_000.0 // 1 sample per ms keeps the arithmetic readable

    private func request(anchorMs: Int, id: String = "ij-001") -> PostResumeAudioSampleRequest {
        PostResumeAudioSampleRequest(
            interjectionId: id, sessionId: "session", itemId: "episode",
            anchorMediaTimeMs: anchorMs, targetDurationMs: 11_000
        )
    }

    /// Feeds `durationMs` of heard audio in 500 ms chunks starting at `fromMs`.
    private func play(_ recorder: inout HeardAudioWindowRecorder, fromMs: Int, durationMs: Int) -> [HeardAudioWindow] {
        var finished: [HeardAudioWindow] = []
        var ms = fromMs
        while ms < fromMs + durationMs {
            finished += recorder.append(samples: [Float](repeating: 0.1, count: 500), startMediaTimeMs: ms)
            ms += 500
        }
        return finished
    }

    func testKeepsAMinuteBeforeTheMarginAndAMinuteAfterResumingAsOneRun() throws {
        var recorder = HeardAudioWindowRecorder(sampleRate: rate)
        XCTAssertTrue(play(&recorder, fromMs: 0, durationMs: 300_000).isEmpty)
        recorder.begin(request(anchorMs: 300_000))
        XCTAssertTrue(play(&recorder, fromMs: 300_000, durationMs: 59_500).isEmpty, "not a full minute yet")
        let window = try XCTUnwrap(play(&recorder, fromMs: 359_500, durationMs: 500).first)
        XCTAssertEqual(window.endReason, "complete")
        XCTAssertEqual(window.segments.count, 1, "the pause during recording leaves no gap in episode time")
        let run = try XCTUnwrap(window.segments.first)
        XCTAssertEqual(run.startMediaTimeMs, 240_000)
        XCTAssertEqual(window.durationMs(of: run), 120_000)
        XCTAssertTrue(window.coversBeforeAnchor)
        XCTAssertTrue(window.coversAfterAnchor)
        XCTAssertFalse(recorder.isCollecting)
    }

    func testAMarginSoonAfterStartingKeepsWhatThereIs() throws {
        var recorder = HeardAudioWindowRecorder(sampleRate: rate)
        _ = play(&recorder, fromMs: 0, durationMs: 8_000)
        recorder.begin(request(anchorMs: 8_000))
        let window = try XCTUnwrap(play(&recorder, fromMs: 8_000, durationMs: 60_000).first)
        XCTAssertEqual(window.segments.first?.startMediaTimeMs, 0)
        XCTAssertEqual(window.durationMs(of: try XCTUnwrap(window.segments.first)), 68_000)
    }

    func testSkippingAfterResumingEndsTheWindowButKeepsWhatWasHeard() throws {
        var recorder = HeardAudioWindowRecorder(sampleRate: rate)
        _ = play(&recorder, fromMs: 100_000, durationMs: 60_000)
        recorder.begin(request(anchorMs: 160_000))
        _ = play(&recorder, fromMs: 160_000, durationMs: 12_000)
        let window = try XCTUnwrap(recorder.noteSeek().first)
        XCTAssertEqual(window.endReason, "seeked")
        XCTAssertTrue(window.coversBeforeAnchor)
        XCTAssertTrue(window.coversAfterAnchor, "at least the 12 s after the Margin is kept")
        XCTAssertEqual(window.durationMs(of: try XCTUnwrap(window.segments.first)), 72_000)
        XCTAssertTrue(recorder.noteSeek().isEmpty)
    }

    func testAJumpInEpisodeTimeStartsANewSegment() throws {
        var recorder = HeardAudioWindowRecorder(sampleRate: rate)
        _ = play(&recorder, fromMs: 50_000, durationMs: 30_000)
        recorder.begin(request(anchorMs: 80_000))
        _ = play(&recorder, fromMs: 95_000, durationMs: 10_000) // resumed 15 s later than it paused
        let window = try XCTUnwrap(recorder.finishAll(reason: "stopped").first)
        XCTAssertEqual(window.segments.map(\.startMediaTimeMs), [50_000, 95_000])
    }

    func testTwoMarginsCollectIndependently() {
        var recorder = HeardAudioWindowRecorder(sampleRate: rate)
        _ = play(&recorder, fromMs: 0, durationMs: 70_000)
        recorder.begin(request(anchorMs: 70_000, id: "ij-001"))
        _ = play(&recorder, fromMs: 70_000, durationMs: 20_000)
        recorder.begin(request(anchorMs: 90_000, id: "ij-002"))
        let first = play(&recorder, fromMs: 90_000, durationMs: 40_000)
        XCTAssertEqual(first.map(\.request.interjectionId), ["ij-001"])
        let second = play(&recorder, fromMs: 130_000, durationMs: 20_000)
        XCTAssertEqual(second.map(\.request.interjectionId), ["ij-002"])
    }

    /// #776: a Margin rejoins 3 s before its anchor. Those 3 s replay the end of the minute before, and used to
    /// become a second, overlapping segment, so the source context repeated the words at the anchor.
    func testTheRejoinStepBackIsNotCollectedTwice() throws {
        var recorder = HeardAudioWindowRecorder(sampleRate: rate)
        _ = play(&recorder, fromMs: 0, durationMs: 300_000)
        recorder.begin(request(anchorMs: 300_000))
        XCTAssertTrue(play(&recorder, fromMs: 297_000, durationMs: 62_500).isEmpty, "the replay doesn't count")
        let window = try XCTUnwrap(play(&recorder, fromMs: 359_500, durationMs: 500).first)
        XCTAssertEqual(window.segments.count, 1)
        let run = try XCTUnwrap(window.segments.first)
        XCTAssertEqual(run.startMediaTimeMs, 240_000)
        XCTAssertEqual(window.durationMs(of: run), 120_000, "each moment is held once")
    }

    /// The rolling minute drops its first copy of the replayed seconds, so the next Margin's minute before is
    /// one run without a repeat.
    func testTheRollingMinuteKeepsOneCopyAfterAStepBack() throws {
        var recorder = HeardAudioWindowRecorder(sampleRate: rate)
        _ = play(&recorder, fromMs: 0, durationMs: 100_000)
        recorder.begin(request(anchorMs: 100_000, id: "ij-001"))
        _ = play(&recorder, fromMs: 97_000, durationMs: 20_000)
        recorder.begin(request(anchorMs: 117_000, id: "ij-002"))
        let windows = recorder.finishAll(reason: "stopped")
        let second = try XCTUnwrap(windows.first { $0.request.interjectionId == "ij-002" })
        XCTAssertEqual(second.segments.count, 1)
        let run = try XCTUnwrap(second.segments.first)
        XCTAssertEqual(run.startMediaTimeMs, 57_000)
        XCTAssertEqual(second.durationMs(of: run), 60_000)
        let first = try XCTUnwrap(windows.first { $0.request.interjectionId == "ij-001" })
        XCTAssertEqual(first.segments.map(\.startMediaTimeMs), [40_000])
        XCTAssertEqual(first.durationMs(of: try XCTUnwrap(first.segments.first)), 77_000)
    }

    func testTimelinesAreShiftedIntoEpisodeTime() {
        let part = MediaTimeline(segments: [
            MediaTimelineSegment(id: "s1", startMs: 1_000, endMs: 4_000, text: "Nice job, Joe."),
        ], chapters: [])
        let timeline = HeardAudioWindow.episodeTimeline([(startMediaTimeMs: 240_000, timeline: part)])
        XCTAssertEqual(timeline.segments.map(\.startMs), [241_000])
        XCTAssertEqual(timeline.segments.map(\.endMs), [244_000])
    }

    func testDownsamplingMixesChannelsAndDecimates() {
        let left: [Float] = [1, 1, 0, 0, 1, 1]
        let right: [Float] = [0, 0, 0, 0, 1, 1]
        let mono = left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                HeardAudioDownsampler.mono(
                    channels: [l.baseAddress!, r.baseAddress!], interleavedStride: 1, frameCount: 6, factor: 2
                )
            }
        }
        XCTAssertEqual(mono, [0.5, 0, 1])
        XCTAssertEqual(HeardAudioDownsampler.factor(for: 44_100), 2)
        XCTAssertEqual(HeardAudioDownsampler.factor(for: 48_000), 3)
    }
}
