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

    func testNativeSeekJumpRecordsLandingWithoutAWatchdogTick() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "stream-seek-jump-\(UUID().uuidString)", directoryHint: .isDirectory)
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
        try client.play(targetId: "episode-target", fromMediaTimeMs: 0)
        let readyDeadline = Date().addingTimeInterval(5)
        while Date() < readyDeadline, (client.currentMediaTimeMs() ?? 0) < 200 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThanOrEqual(client.currentMediaTimeMs() ?? 0, 200)
        try client.pause() // Stop the watchdog before creating the pending seek.
        client.withholdsSeekCompletionsForTesting = true
        _ = try client.requestMediaSeek(toMediaTimeMs: 5_000)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !client.pendingSeekHasLandingEvidenceForTesting {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(client.pendingSeekHasLandingEvidenceForTesting,
                      "a real AVPlayer seek jump must record landing even with its completion withheld and watchdog stopped")
    }

    /// #835: Skim's return seeks the paused source to the scene, then resumes it at once, reusing that seek.
    /// The player reports playing while its clock still reads the destination, because the audio output takes
    /// time to start (0.6–0.75 s on this Mac, and longer on a loaded simulator). That is the normal start, not a
    /// hang: the clock never falls back to where Skim began, and it moves on from the destination.
    func testResumeRightAfterANavigationSeekPlaysOnFromTheDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "stream-seek-resume-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let episodeURL = try Self.writeTone(to: directory.appending(path: "episode.caf"), seconds: 10, hz: 220)
        let client = AVPlayerStreamPlaybackClient()
        try client.setPlaybackVolume(0)
        try client.configureMediaContext(PlaybackMediaContext(
            itemId: "episode", targetType: .transcriptBackedMedia, targetId: "episode-target",
            title: "Test episode", playbackURL: episodeURL.absoluteString, durationMs: 10_000,
            sourceType: .nativeMediaFile
        ))
        defer { try? client.stop() }
        let trace = TraceLines()
        client.playbackStartTraceHandler = { fields in trace.append(fields) }
        try client.play(targetId: "episode-target", fromMediaTimeMs: 0)
        let readyDeadline = Date().addingTimeInterval(10)
        while Date() < readyDeadline, (client.currentMediaTimeMs() ?? 0) < 300 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let origin = try XCTUnwrap(client.currentMediaTimeMs())
        XCTAssertGreaterThanOrEqual(origin, 300, "precondition: the source played before Skim")
        try client.pause()

        // completeSkimBridge: seekMedia, then resumePlayback straight away.
        _ = try client.requestMediaSeek(toMediaTimeMs: 5_000)
        try client.play(targetId: "episode-target", fromMediaTimeMs: 5_000)
        var heldAtDestinationWhilePlaying = false
        var lowest = Int.max
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, (client.currentMediaTimeMs() ?? 0) <= 5_100 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            let clock = client.currentMediaTimeMs() ?? 0
            lowest = min(lowest, clock)
            if clock == 5_000, client.playbackTransportState(targetId: "episode-target") == .playing {
                heldAtDestinationWhilePlaying = true
            }
        }

        XCTAssertGreaterThan(client.currentMediaTimeMs() ?? 0, 5_100, "the source plays on from Skim's destination")
        XCTAssertGreaterThanOrEqual(lowest, 5_000, "the clock never shows the place Skim left")
        XCTAssertEqual(trace.lines.last?["seek"], "reused", "the resume rides Skim's seek instead of issuing another")
        // Not a requirement, a record of what the app test has to wait through: on this Mac the player
        // reports playing before its clock leaves the destination.
        if !heldAtDestinationWhilePlaying {
            print("note: the clock left 5000 ms before the player reported playing on this run")
        }
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
