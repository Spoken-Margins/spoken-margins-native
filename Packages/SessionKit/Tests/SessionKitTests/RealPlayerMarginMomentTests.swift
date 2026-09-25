#if os(macOS) && canImport(AVFoundation)
import AVFoundation
import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// "Play this moment" against real audio (#159): a real episode file through the real `AVPlayer` podcast
/// client, and a real Margin recording decoded by `AVAudioPlayer`. Both muted.
@MainActor
final class RealPlayerMarginMomentTests: XCTestCase {
    func testMarginPlaysWhenPlaybackReachesItAndTheEpisodeResumesAfterwards() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "margin-moment-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let episodeURL = try Self.writeTone(to: directory.appending(path: "episode.caf"), seconds: 8, hz: 220)
        let marginURL = try Self.writeTone(to: directory.appending(path: "ij-001.caf"), seconds: 0.8, hz: 440)

        let client = AVPlayerStreamPlaybackClient()
        try client.setPlaybackVolume(0)
        try client.configureMediaContext(PlaybackMediaContext(
            itemId: "episode", targetType: .transcriptBackedMedia, targetId: "episode-target",
            title: "Test episode", playbackURL: episodeURL.absoluteString, durationMs: 8_000,
            sourceType: .nativeMediaFile
        ))
        defer { try? client.stop() }

        var sourcePlaying = false
        var pausedAtMs: Int?
        var events: [String] = []
        let source = MarginMomentConductor.Source(
            pause: {
                pausedAtMs = client.currentMediaTimeMs()
                try? client.pause()
                sourcePlaying = false
                events.append("source.pause")
            },
            resume: {
                try? client.play(targetId: "episode-target", fromMediaTimeMs: pausedAtMs ?? 0)
                sourcePlaying = true
                events.append("source.resume")
            },
            seek: { mediaTimeMs in
                try? client.play(targetId: "episode-target", fromMediaTimeMs: mediaTimeMs)
                sourcePlaying = true
            }
        )
        let anchor = MarginMomentAnchor(marginId: "ij-001", mediaTimeMs: 2_500)
        let conductor = MarginMomentConductor(
            sequence: MarginMomentSequence(itemId: "episode", target: anchor, otherMargins: [], leadInMs: 1_500),
            source: source,
            voiceURL: { $0 == "ij-001" ? marginURL : nil }
        )
        conductor.voiceVolume = 0
        var unavailable: [String] = []
        conductor.onVoiceUnavailable = { id, reason in unavailable.append("\(id):\(reason)") }

        conductor.start()
        XCTAssertEqual(conductor.sequence.startMediaTimeMs, 1_000)

        var sawVoice = false
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if conductor.isPlayingVoice {
                sawVoice = true
                XCTAssertFalse(sourcePlaying, "the episode is paused while the Margin plays")
            }
            if sourcePlaying { conductor.observe(mediaTimeMs: client.currentMediaTimeMs()) }
            if conductor.sequence.phase == .listening, (client.currentMediaTimeMs() ?? 0) >= 3_500 { break }
        }

        XCTAssertEqual(unavailable, [])
        XCTAssertTrue(sawVoice, "the Margin's recording never played")
        XCTAssertEqual(events, ["source.pause", "source.resume"])
        XCTAssertEqual(conductor.sequence.phase, .listening)
        let paused = try XCTUnwrap(pausedAtMs)
        XCTAssertGreaterThanOrEqual(paused, 2_500, "paused at the Margin, not before it")
        XCTAssertLessThan(paused, 3_500)
        XCTAssertGreaterThanOrEqual(client.currentMediaTimeMs() ?? 0, 3_500, "the episode continued after the Margin")
    }

    func testAMissingRecordingIsReportedAndTheEpisodeKeepsPlaying() throws {
        var resumed = 0
        let conductor = MarginMomentConductor(
            sequence: MarginMomentSequence(
                itemId: "episode", target: MarginMomentAnchor(marginId: "ij-009", mediaTimeMs: 5_000), otherMargins: []
            ),
            source: .init(pause: {}, resume: { resumed += 1 }, seek: { _ in }),
            voiceURL: { _ in URL(fileURLWithPath: "/nonexistent/ij-009.m4a") }
        )
        var unavailable: [String] = []
        conductor.onVoiceUnavailable = { id, reason in unavailable.append("\(id):\(reason)") }
        conductor.start()
        conductor.observe(mediaTimeMs: 4_800)
        conductor.observe(mediaTimeMs: 5_200)
        XCTAssertEqual(unavailable, ["ij-009:recording_missing"])
        XCTAssertEqual(resumed, 1)
        XCTAssertEqual(conductor.sequence.phase, .listening)
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
#endif
