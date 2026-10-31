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

    /// The player's tap decodes about half a second ahead of its clock, so when playback pauses for a Margin the
    /// rolling minute already holds audio past the anchor, and one more decoded buffer can arrive before the
    /// rejoin's seek. Leaving that read-ahead out of the window, then keeping the late buffer as "after", left a
    /// gap right after the Margin that the rejoin's replay never filled (#1133, found by the real-player test).
    func testAudioDecodedAheadOfTheClockAtTheMarginLeavesNoGap() throws {
        var recorder = HeardAudioWindowRecorder(sampleRate: rate)
        _ = play(&recorder, fromMs: 0, durationMs: 7_500) // the clock paused at 7 000; the tap reached 7 500
        recorder.begin(request(anchorMs: 7_000))
        _ = play(&recorder, fromMs: 7_500, durationMs: 500) // one more read-ahead buffer before the seek lands
        _ = play(&recorder, fromMs: 4_000, durationMs: 8_000) // the rejoin replays from 3 s before the Margin
        let window = try XCTUnwrap(recorder.finishAll(reason: "stopped").first)
        XCTAssertEqual(window.segments.map(\.startMediaTimeMs), [0], "one run, no hole after the Margin")
        XCTAssertEqual(window.durationMs(of: try XCTUnwrap(window.segments.first)), 12_000)
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
    // Codex audit on 4b107c5, P2: a fresh chunk had to end more than 10 ms past the audio already held, so
    // back-to-back 10 ms buffers were kept only every other time and a minute took two to collect.
    func testBackToBackShortBuffersAreAllCollected() throws {
        var recorder = HeardAudioWindowRecorder(sampleRate: rate)
        func play10(fromMs: Int, durationMs: Int) -> [HeardAudioWindow] {
            stride(from: fromMs, to: fromMs + durationMs, by: 10).flatMap {
                recorder.append(samples: [Float](repeating: 0.1, count: 10), startMediaTimeMs: $0)
            }
        }
        XCTAssertTrue(play10(fromMs: 0, durationMs: 10_000).isEmpty)
        recorder.begin(request(anchorMs: 10_000))
        let window = try XCTUnwrap(play10(fromMs: 10_000, durationMs: 60_000).first,
                                   "a minute of 10 ms buffers fills the minute after resuming")
        let run = try XCTUnwrap(window.segments.first)
        XCTAssertEqual(window.segments.count, 1)
        XCTAssertEqual(run.startMediaTimeMs, 0)
        XCTAssertEqual(window.durationMs(of: run), 70_000)
    }

    // Codex audit on 4b107c5, P2: a rejoin that lands inside a chunk kept that chunk whole, so the replayed
    // audio after it was spliced in twice and the run's timestamps drifted.
    func testARewindInsideAChunkKeepsOnlyTheAudioBeforeIt() throws {
        var recorder = HeardAudioWindowRecorder(sampleRate: rate)
        _ = play(&recorder, fromMs: 40_000, durationMs: 60_000)   // last chunk 99_500–100_000
        _ = play(&recorder, fromMs: 99_750, durationMs: 1_500)    // rejoin mid-chunk, up to 101_250
        recorder.begin(request(anchorMs: 101_250))
        let window = try XCTUnwrap(recorder.finishAll(reason: "stopped").first)
        let run = try XCTUnwrap(window.segments.last)
        XCTAssertEqual(window.segments.count, 1)
        XCTAssertEqual(run.startMediaTimeMs + window.durationMs(of: run), 101_250,
                       "episode time and held audio agree: nothing is held twice")
    }

    func testAfterResumingAChunkThatOverlapsHeldAudioAddsOnlyItsNewPart() throws {
        var recorder = HeardAudioWindowRecorder(sampleRate: rate)
        _ = play(&recorder, fromMs: 40_000, durationMs: 60_000)   // held up to 100_000
        recorder.begin(request(anchorMs: 100_000))
        _ = play(&recorder, fromMs: 97_250, durationMs: 5_000)    // the rejoin replays from mid-chunk
        let window = try XCTUnwrap(recorder.finishAll(reason: "stopped").first)
        let run = try XCTUnwrap(window.segments.last)
        XCTAssertEqual(window.segments.count, 1)
        XCTAssertEqual(run.startMediaTimeMs, 40_000)
        XCTAssertEqual(run.startMediaTimeMs + window.durationMs(of: run), 102_250)
    }

    /// #2966: the "Just heard" card on a podcast transcribes the last seconds before the tap, from the rolling minute.
    func testRecentRunIsTheLastSecondsBeforeTheTapFromTheNewestUnbrokenRun() throws {
        var recorder = HeardAudioWindowRecorder(sampleRate: rate)
        _ = play(&recorder, fromMs: 100_000, durationMs: 30_000) // 100 s to 130 s
        // The tap decoded half a second past the clock; the card stops at the tap.
        _ = play(&recorder, fromMs: 130_000, durationMs: 500)
        let run = try XCTUnwrap(recorder.recentRun(endingAtMs: 130_000, lastMs: 12_000))
        XCTAssertEqual(run.startMediaTimeMs, 118_000)
        XCTAssertEqual(run.samples.count, 12_000)

        // Asked for more than the run holds: what there is, from the run's start.
        var short = HeardAudioWindowRecorder(sampleRate: rate)
        _ = play(&short, fromMs: 50_000, durationMs: 5_000)
        let partial = try XCTUnwrap(short.recentRun(endingAtMs: 55_000, lastMs: 12_000))
        XCTAssertEqual(partial.startMediaTimeMs, 50_000)
        XCTAssertEqual(partial.samples.count, 5_000)

        // A tap that cuts a chunk keeps only its first part.
        let cut = try XCTUnwrap(recorder.recentRun(endingAtMs: 129_750, lastMs: 4_000))
        XCTAssertEqual(cut.startMediaTimeMs, 125_750)
        XCTAssertEqual(cut.samples.count, 4_000)
    }

    func testRecentRunStopsAtAGapAndNeedsTwoSecondsOfAudio() throws {
        var recorder = HeardAudioWindowRecorder(sampleRate: rate)
        _ = play(&recorder, fromMs: 0, durationMs: 20_000)
        // A jump forward without a noted seek: only the run after the gap was heard just before the tap.
        _ = play(&recorder, fromMs: 40_000, durationMs: 3_000)
        let run = try XCTUnwrap(recorder.recentRun(endingAtMs: 43_000, lastMs: 12_000))
        XCTAssertEqual(run.startMediaTimeMs, 40_000)
        XCTAssertEqual(run.samples.count, 3_000)

        XCTAssertNil(recorder.recentRun(endingAtMs: 41_500, lastMs: 12_000), "1.5 s is too little to transcribe")
        XCTAssertNil(recorder.recentRun(endingAtMs: 30_000, lastMs: 12_000), "a tap before the newest run")
        XCTAssertNil(HeardAudioWindowRecorder(sampleRate: rate).recentRun(endingAtMs: 1_000, lastMs: 12_000))

        _ = recorder.noteSeek()
        XCTAssertNil(recorder.recentRun(endingAtMs: 43_000, lastMs: 12_000), "a seek empties the rolling minute")
    }

    func testRecentRunLeavesTheRollingMinuteAndAnyMarginWindowAsTheyWere() throws {
        var recorder = HeardAudioWindowRecorder(sampleRate: rate)
        _ = play(&recorder, fromMs: 0, durationMs: 300_000)
        _ = recorder.recentRun(endingAtMs: 300_000, lastMs: 12_000)
        recorder.begin(request(anchorMs: 300_000))
        let window = try XCTUnwrap(play(&recorder, fromMs: 300_000, durationMs: 60_000).first)
        XCTAssertEqual(window.segments.first?.startMediaTimeMs, 240_000)
        XCTAssertEqual(window.durationMs(of: try XCTUnwrap(window.segments.first)), 120_000)
    }
}
