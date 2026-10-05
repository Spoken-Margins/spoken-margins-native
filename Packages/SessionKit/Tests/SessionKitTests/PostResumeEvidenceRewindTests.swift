#if os(macOS) && canImport(AVFoundation) && canImport(MediaToolbox) && canImport(ShazamKit)
import AVFoundation
import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// #776: a saved Margin rejoins 3 s early without a noted seek. When a second Margin's rejoin rewinds playback
/// while the first Margin's post-resume window is still collecting, that window used to keep appending the
/// replayed audio under its original start time, so its signature held a splice and its anchor offset was
/// wrong (Codex audit on 34a1cae). The window now starts again at the rewound audio, as it does after a seek.
final class PostResumeEvidenceRewindTests: XCTestCase {
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PostResumePodcastEvidenceCaptureResult] = []
        func append(_ value: PostResumePodcastEvidenceCaptureResult) { lock.withLock { values.append(value) } }
        var all: [PostResumePodcastEvidenceCaptureResult] { lock.withLock { values } }
    }

    func testARewindWithoutASeekRestartsAnUnfinishedPostResumeWindow() throws {
        let results = Results()
        let tap = PostResumePodcastEvidenceTapContext(
            resultHandler: { results.append($0) },
            becameIdle: {}
        )
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        tap.prepare(processingFormat: format.streamDescription)
        XCTAssertTrue(tap.arm(PostResumeAudioSampleRequest(
            interjectionId: "ij-first",
            sessionId: "session",
            itemId: "episode",
            anchorMediaTimeMs: 300_000,
            targetDurationMs: 4_000
        )))

        // The first Margin's window collects 297–299 s, then a second Margin rejoins at 296 s and the
        // player decodes from there again.
        var generator = SystemRandomNumberGenerator()
        for second in [297, 298, 296, 297, 298, 299] {
            let buffer = try Self.oneSecondOfNoise(format: format, using: &generator)
            tap.process(
                bufferList: buffer.mutableAudioBufferList,
                frameCount: CMItemCount(buffer.frameLength),
                timeRange: CMTimeRange(
                    start: CMTime(value: CMTimeValue(second), timescale: 1),
                    duration: CMTime(value: 1, timescale: 1)
                )
            )
        }

        XCTAssertTrue(spin(until: 5) { !results.all.isEmpty })
        guard case .captured(let capture) = results.all.first else {
            return XCTFail("expected a captured post-resume signature, got \(results.all)")
        }
        XCTAssertEqual(capture.windowRole, .postResume)
        XCTAssertEqual(capture.anchorOffsetMs, 4_000,
                       "the window starts at the rewound audio (296 s), 4 s before the 300 s anchor")
        XCTAssertEqual(capture.durationMs, 4_000, accuracy: 100)
    }

    // Codex audit on 4b107c5, P2: a rewind that lands inside the last buffer (its start is still earlier) went
    // unnoticed, so the window kept the audio before the rewind and appended the replay after it.
    func testARewindInsideTheLastBufferRestartsTheWindow() throws {
        let results = Results()
        let tap = PostResumePodcastEvidenceTapContext(
            resultHandler: { results.append($0) },
            becameIdle: {}
        )
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        tap.prepare(processingFormat: format.streamDescription)
        XCTAssertTrue(tap.arm(PostResumeAudioSampleRequest(
            interjectionId: "ij-first",
            sessionId: "session",
            itemId: "episode",
            anchorMediaTimeMs: 300_000,
            targetDurationMs: 4_000
        )))

        // Collects 297–299 s, then playback rejoins at 298.5 s, inside the 298 s buffer.
        var generator = SystemRandomNumberGenerator()
        for tenths in [2_970, 2_980, 2_985, 2_995, 3_005, 3_015] {
            let buffer = try Self.oneSecondOfNoise(format: format, using: &generator)
            tap.process(
                bufferList: buffer.mutableAudioBufferList,
                frameCount: CMItemCount(buffer.frameLength),
                timeRange: CMTimeRange(
                    start: CMTime(value: CMTimeValue(tenths), timescale: 10),
                    duration: CMTime(value: 1, timescale: 1)
                )
            )
        }

        XCTAssertTrue(spin(until: 5) { !results.all.isEmpty })
        guard case .captured(let capture) = results.all.first else {
            return XCTFail("expected a captured post-resume signature, got \(results.all)")
        }
        XCTAssertEqual(capture.anchorOffsetMs, 1_500,
                       "the window starts at the rewound audio (298.5 s), 1.5 s before the 300 s anchor")
        XCTAssertEqual(capture.durationMs, 4_000, accuracy: 100)
    }

    private static func oneSecondOfNoise(
        format: AVAudioFormat,
        using generator: inout SystemRandomNumberGenerator
    ) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                channels[channel][frame] = Float.random(in: -0.3...0.3, using: &generator)
            }
        }
        return buffer
    }

    private func spin(until seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}
#endif
