#if os(macOS) && canImport(AVFoundation)
import AVFoundation
import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// #166: on a stream, the clock stayed at a resume point for minutes while the audio played on,
/// because the seek's completion never cleared the pending seek. Real `AVPlayer`, real audio, muted.
@MainActor
final class StreamSeekLifecycleTests: XCTestCase {
    func testClockFollowsThePlayerWhenASeekCompletionNeverArrives() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "stream-seek-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let episodeURL = try Self.writeTone(to: directory.appending(path: "episode.caf"), seconds: 12, hz: 220)

        let client = AVPlayerStreamPlaybackClient()
        try client.setPlaybackVolume(0)
        try client.configureMediaContext(PlaybackMediaContext(
            itemId: "episode", targetType: .transcriptBackedMedia, targetId: "episode-target",
            title: "Test episode", playbackURL: episodeURL.absoluteString, durationMs: 12_000,
            sourceType: .nativeMediaFile
        ))
        defer { try? client.stop() }
        let trace = TraceLines()
        client.playbackStallTraceHandler = { fields in trace.append(fields) }
        client.withholdsSeekCompletionsForTesting = true

        try client.play(targetId: "episode-target", fromMediaTimeMs: 1_000)
        // The player passes the target by 1 s after about a second; one 2 s watchdog tick later the
        // clock must follow it.
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, (client.currentMediaTimeMs() ?? 0) <= 2_500 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }

        XCTAssertGreaterThan(client.currentMediaTimeMs() ?? 0, 2_500, "the clock follows the audio, not the seek target")
        let abandoned = try XCTUnwrap(trace.lines.first { $0["event"] == "seek_abandoned" }, "the abandoned seek is logged")
        XCTAssertEqual(abandoned["toMs"], "1000")
        XCTAssertEqual(abandoned["purpose"], "start")
        XCTAssertNotNil(abandoned["playerMs"])
        XCTAssertNotNil(abandoned["ageMs"])
    }

    private static func writeTone(to url: URL, seconds: Double, hz: Double) throws -> URL {
        let sampleRate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) {
            samples[frame] = Float(0.4 * sin(2 * .pi * hz * Double(frame) / sampleRate))
        }
        try file.write(from: buffer)
        return url
    }
}

private final class TraceLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String: String]] = []
    var lines: [[String: String]] { lock.withLock { stored } }
    func append(_ fields: [String: String]) { lock.withLock { stored.append(fields) } }
}
#endif
