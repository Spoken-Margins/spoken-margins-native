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

    /// #835: the app test that stalls at a Skim destination reads the player's raw state through this, to tell
    /// AVPlayer's own clock freezing from a pending seek pinning the adapter clock.
    func testPlaybackStateTraceFieldsReportTheRawPlayerBesideAPendingSeek() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "stream-state-fields-\(UUID().uuidString)", directoryHint: .isDirectory)
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
        let playing = client.playbackStateTraceFields()
        XCTAssertEqual(playing["pendingSeek"], "none")
        XCTAssertEqual(playing["timeControl"], "playing")
        XCTAssertEqual(playing["intendsToPlay"], "1")
        XCTAssertEqual(playing["itemStatus"], "ready")
        let playingMs = try XCTUnwrap(playing["playerMs"].flatMap(Int.init), "the raw player clock is reported")
        XCTAssertGreaterThanOrEqual(playingMs, 200)
        XCTAssertNotNil(playing["uptimeMs"].flatMap(Int.init), "samples carry a monotonic time so gaps show")

        try client.pause()
        client.withholdsSeekCompletionsForTesting = true
        _ = try client.requestMediaSeek(toMediaTimeMs: 5_000)
        let seeking = client.playbackStateTraceFields()
        XCTAssertEqual(client.currentMediaTimeMs(), 5_000, "precondition: a pending seek pins the adapter clock")
        XCTAssertEqual(seeking["pendingSeek"], "navigation:retry0")
        XCTAssertEqual(seeking["pendingSeekToMs"], "5000")
        XCTAssertEqual(seeking["intendsToPlay"], "0")
        XCTAssertEqual(seeking["timeControl"], "paused")
        XCTAssertNotNil(seeking["playerMs"].flatMap(Int.init), "the raw clock is reported even while a seek pins the adapter clock")
    }

    /// #588 on the real player (#1133, ANC-06): an episode that played to its end stays ended until the listener
    /// scrubs back. The seek must clear the client's own end-of-item flag, or the engine moves the episode
    /// straight back to its end. EpisodeEndSeekTests runs the engine against a fake that copies this rule;
    /// this runs the rule itself, in `AVPlayerStreamPlaybackClient`.
    func testScrubbingBackFromTheEndClearsTheEndedFlag() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "stream-seek-end-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let episodeURL = try Self.writeTone(to: directory.appending(path: "episode.caf"), seconds: 3, hz: 220)
        let client = AVPlayerStreamPlaybackClient()
        try client.setPlaybackVolume(0)
        try client.configureMediaContext(PlaybackMediaContext(
            itemId: "episode", targetType: .transcriptBackedMedia, targetId: "episode-target",
            title: "Test episode", playbackURL: episodeURL.absoluteString, durationMs: 3_000,
            sourceType: .nativeMediaFile
        ))
        defer { try? client.stop() }

        try client.play(targetId: "episode-target", fromMediaTimeMs: 1_500)
        XCTAssertTrue(spin(until: 8) { client.isPlaybackComplete(targetId: "episode-target") }, "the episode plays to its end")

        let request = try client.requestMediaSeek(toMediaTimeMs: 1_000)
        XCTAssertTrue(spin(until: 5) { client.mediaSeekResolution(for: request) != .pending }, "the seek lands")
        XCTAssertFalse(client.isPlaybackComplete(targetId: "episode-target"), "scrubbed back, so no longer at the end")
        let position = try XCTUnwrap(client.currentMediaTimeMs())
        XCTAssertLessThan(abs(position - 1_000), 500, "the player is at the new place, not the end: \(position) ms")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(client.isPlaybackComplete(targetId: "episode-target"), "and stays there, paused")
    }

    /// #835: Skim's return seeks the paused source to the scene, then resumes it at once, reusing that seek.
    /// The player reports playing while its clock still reads the destination, because the audio output takes
    /// time to start (about 0.4–0.7 s on this Mac, and longer on a loaded simulator). That is the normal start, not a
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
        var playingAtDestinationSince: Date?
        var heldWhilePlaying: TimeInterval?
        var lowest = Int.max
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, (client.currentMediaTimeMs() ?? 0) <= 5_100 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            let clock = client.currentMediaTimeMs() ?? 0
            lowest = min(lowest, clock)
            if clock == 5_000, client.playbackTransportState(targetId: "episode-target") == .playing {
                playingAtDestinationSince = playingAtDestinationSince ?? Date()
            } else if clock > 5_000, heldWhilePlaying == nil, let since = playingAtDestinationSince {
                heldWhilePlaying = Date().timeIntervalSince(since)
            }
        }

        XCTAssertGreaterThan(client.currentMediaTimeMs() ?? 0, 5_100, "the source plays on from Skim's destination")
        XCTAssertGreaterThan(lowest, 4_700, "the clock never shows the place Skim left")
        XCTAssertEqual(trace.lines.last?["seek"], "reused", "the resume rides Skim's seek instead of issuing another")
        // Not a requirement, a record of what the app test has to wait through (#835).
        print("note: player reported playing with the clock held at 5000 ms for "
            + (heldWhilePlaying.map { "\(Int($0 * 1_000)) ms" } ?? "no measurable time"))
    }

    private func spin(until seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
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
