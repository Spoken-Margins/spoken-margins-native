#if os(macOS) && canImport(AVFoundation) && canImport(MediaToolbox) && canImport(ShazamKit)
import AVFoundation
import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// #2626: after any seek the tap cut a new post-seek landmark each time the last one finished, for the rest of the
/// session. Build 35's spine, signature files and disk writes grew until iOS killed the backgrounded app.
final class SeekLandmarkRepeatTests: XCTestCase {
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PostResumePodcastEvidenceCaptureResult] = []
        func append(_ value: PostResumePodcastEvidenceCaptureResult) { lock.withLock { values.append(value) } }
        var landmarks: [CapturedEpisodeFingerprintLandmark] {
            lock.withLock { values.compactMap { if case .landmark(let landmark) = $0 { landmark } else { nil } } }
        }
    }

    func testOneSeekMakesOnePostSeekLandmarkHoweverLongPlaybackContinues() throws {
        let results = Results()
        let context = PostResumePodcastEvidenceTapContext(
            resultHandler: { results.append($0) },
            becameIdle: {},
            continuousCollection: true,
            itemId: "episode"
        )
        let sampleRate = 8_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        context.prepare(processingFormat: format.streamDescription)

        context.noteSeek()
        // The tap waits for the seek to settle, in wall-clock time, before it cuts anything.
        let settled = Date().addingTimeInterval(SparseFingerprintSchedule.seekDebounceMs.timeInterval + 0.3)
        while Date() < settled { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

        // 10–50 s of the episode: before the first periodic grid point is due, so only the seek can cut a landmark.
        // Playback keeps delivering buffers while a signature is generated, so feed them in two stretches.
        func feed(_ seconds: Range<Int>) throws {
            for second in seconds {
                let frames = AVAudioFrameCount(sampleRate)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
                buffer.frameLength = frames
                let samples = try XCTUnwrap(buffer.floatChannelData?[0])
                for frame in 0..<Int(frames) {
                    samples[frame] = Float(0.2 * sin(2 * .pi * (200 + Double(second * 7)) * Double(frame) / sampleRate))
                }
                context.process(
                    bufferList: buffer.mutableAudioBufferList,
                    frameCount: CMItemCount(frames),
                    timeRange: CMTimeRange(
                        start: CMTime(value: CMTimeValue(second * 1_000), timescale: 1_000),
                        duration: CMTime(value: 1_000, timescale: 1_000)
                    )
                )
            }
        }
        try feed(10..<30)

        XCTAssertTrue(spin(until: 20) { !results.landmarks.isEmpty }, "the settled seek should cut its landmark")
        // Buffers that arrive after the landmark was cut are what used to cut the next one.
        _ = spin(until: 1) { false }
        try feed(30..<50)
        _ = spin(until: 4) { false }
        let landmarks = results.landmarks
        XCTAssertEqual(landmarks.count, 1, "starts: \(landmarks.map(\.sourceMediaStartMs))")
        XCTAssertEqual(landmarks.first?.trigger, .stablePostSeek)
        XCTAssertEqual(landmarks.first?.continuityEpoch, 1)
    }

    private func spin(until seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}

private extension Int {
    var timeInterval: TimeInterval { TimeInterval(self) / 1_000 }
}
#endif
