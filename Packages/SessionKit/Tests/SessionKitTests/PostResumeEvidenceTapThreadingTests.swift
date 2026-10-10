#if os(macOS) && canImport(AVFoundation) && canImport(MediaToolbox) && canImport(ShazamKit)
import AVFoundation
import Foundation
import ShazamKit
import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// #457: the tap's `process` callback runs on the real-time audio thread. Slow signature work used to run inside
/// it, so a Margin's ~12 s of fingerprinting could stutter the podcast. The callback now only copies the buffer;
/// the signature appends, the ring and the heard-audio recorder run on a worker queue.
final class PostResumeEvidenceTapThreadingTests: XCTestCase {
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PostResumePodcastEvidenceCaptureResult] = []
        func append(_ value: PostResumePodcastEvidenceCaptureResult) { lock.withLock { values.append(value) } }
        var all: [PostResumePodcastEvidenceCaptureResult] { lock.withLock { values } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        /// Adds one and returns the count before it.
        @discardableResult
        func increment() -> Int { lock.withLock { defer { value += 1 }; return value } }
        var count: Int { lock.withLock { value } }
    }

    private func request(_ id: String, targetDurationMs: Int = 4_000) -> PostResumeAudioSampleRequest {
        PostResumeAudioSampleRequest(
            interjectionId: id,
            sessionId: "session",
            itemId: "episode",
            anchorMediaTimeMs: 300_000,
            targetDurationMs: targetDurationMs
        )
    }

    func testTheTapCallbackStaysFastWhileSignatureAppendsAreSlow() throws {
        let results = Results()
        let appends = Counter()
        let tap = PostResumePodcastEvidenceTapContext(
            resultHandler: { results.append($0) },
            becameIdle: {},
            appendToSignature: { generator, buffer in
                Thread.sleep(forTimeInterval: 0.05)
                appends.increment()
                try generator.append(buffer, at: nil)
            }
        )
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        tap.prepare(processingFormat: format.streamDescription)
        XCTAssertTrue(tap.arm(request("ij-first")))
        XCTAssertTrue(tap.arm(request("ij-second")))

        // Two open captures, 50 ms per append: the old callback took about 100 ms per buffer.
        var generator = SystemRandomNumberGenerator()
        var buffers: [AVAudioPCMBuffer] = []
        for _ in 0..<6 { buffers.append(try Self.oneSecondOfNoise(format: format, using: &generator)) }
        let clock = ContinuousClock()
        var elapsedMs: [Double] = []
        for (index, buffer) in buffers.enumerated() {
            let elapsed = clock.measure {
                tap.process(
                    bufferList: buffer.mutableAudioBufferList,
                    frameCount: CMItemCount(buffer.frameLength),
                    timeRange: CMTimeRange(
                        start: CMTime(value: CMTimeValue(296 + index), timescale: 1),
                        duration: CMTime(value: 1, timescale: 1)
                    )
                )
            }
            elapsedMs.append(Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1e15)
        }
        let sorted = elapsedMs.sorted()
        XCTAssertLessThan(sorted[sorted.count / 2], 5, "the median callback must return in under 5 ms: \(elapsedMs)")
        XCTAssertLessThan(elapsedMs.reduce(0, +), 150, "all six callbacks together: \(elapsedMs)")

        // The slow work still happens, off the callback, and gives the same evidence.
        XCTAssertTrue(spin(until: 10) { results.all.count == 2 })
        for result in results.all {
            guard case .captured(let capture) = result else {
                return XCTFail("expected captured post-resume evidence, got \(result)")
            }
            XCTAssertEqual(capture.windowRole, .postResume)
            XCTAssertEqual(capture.anchorOffsetMs, 4_000, "the window starts at 296 s, 4 s before the 300 s anchor")
            XCTAssertEqual(capture.durationMs, 4_000, accuracy: 100)
        }
        XCTAssertEqual(Set(results.all.compactMap { result -> String? in
            if case .captured(let capture) = result { return capture.request.interjectionId }
            return nil
        }), ["ij-first", "ij-second"])
        XCTAssertEqual(appends.count, 8, "four one-second buffers per capture")
    }

    func testATapBehindTheWorkerDropsBuffersInsteadOfGrowingWithoutBound() throws {
        let results = Results()
        let appends = Counter()
        let gate = DispatchSemaphore(value: 0)
        let tap = PostResumePodcastEvidenceTapContext(
            resultHandler: { results.append($0) },
            becameIdle: {},
            appendToSignature: { generator, buffer in
                // The first append stalls, as a worker stuck behind slow signature work would.
                if appends.increment() == 0 { _ = gate.wait(timeout: .now() + 10) }
                try generator.append(buffer, at: nil)
            }
        )
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        tap.prepare(processingFormat: format.streamDescription)
        XCTAssertTrue(tap.arm(request("ij-first")))

        var generator = SystemRandomNumberGenerator()
        var buffers: [AVAudioPCMBuffer] = []
        for _ in 0..<25 { buffers.append(try Self.oneSecondOfNoise(format: format, using: &generator)) }
        for (index, buffer) in buffers.enumerated() {
            tap.process(
                bufferList: buffer.mutableAudioBufferList,
                frameCount: CMItemCount(buffer.frameLength),
                timeRange: CMTimeRange(
                    start: CMTime(value: CMTimeValue(296 + index), timescale: 1),
                    duration: CMTime(value: 1, timescale: 1)
                )
            )
        }
        let capFrames = Int(format.sampleRate * PostResumePodcastEvidenceTapContext.maxPendingSeconds)
        XCTAssertLessThanOrEqual(tap.pendingTapFrames, capFrames,
                                 "25 s of audio arrived behind a stalled worker; the tap keeps at most 20 s")
        XCTAssertGreaterThan(tap.pendingTapFrames, capFrames / 2)

        gate.signal()
        XCTAssertTrue(spin(until: 10) { tap.pendingTapFrames == 0 }, "the worker catches up once it is unstuck")
        XCTAssertTrue(spin(until: 5) { !results.all.isEmpty })
        guard case .captured(let capture) = results.all.first else {
            return XCTFail("expected captured post-resume evidence, got \(results.all)")
        }
        XCTAssertEqual(capture.anchorOffsetMs, 4_000, "the buffers it kept, in order, from 296 s")
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
