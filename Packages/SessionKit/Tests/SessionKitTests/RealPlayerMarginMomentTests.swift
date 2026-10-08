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

    // MARK: Another listener's Margin gets the chime first (#932)

    /// The Timeline's tap path used to start a shared Margin's voice with no chime at all. The chime plays
    /// first, and the voice starts only after it has finished, so the two never overlap.
    func testASharedMarginsChimePlaysBeforeItsVoiceAndNeverOverlapsIt() throws {
        let fixture = try ChimeFixture(chimed: true)
        defer { fixture.cleanUp() }

        fixture.reachTheMargin()
        XCTAssertEqual(fixture.events, ["source.pause", "chime:shared"], "the chime is the first sound; the voice waits for it")
        XCTAssertTrue(fixture.conductor.isPlayingVoice, "the Margin already has the floor during its chime")

        try fixture.pump(until: { fixture.events.contains("voice:shared") }, "the voice starts after the chime")
        XCTAssertEqual(fixture.events, ["source.pause", "chime:shared", "voice:shared"])
        let chimeSeconds = try AVAudioPlayer(data: SharedMarginCue.doubleChimeWAVData()).duration
        let gap = try XCTUnwrap(fixture.voiceStartedAt).timeIntervalSince(try XCTUnwrap(fixture.chimeStartedAt))
        XCTAssertGreaterThanOrEqual(gap, chimeSeconds, "the voice starts only once the chime is over")

        try fixture.pump(until: { fixture.resumed == 1 }, "the episode resumes when the voice ends")
        XCTAssertEqual(fixture.events.filter { $0.hasPrefix("chime") }.count, 1, "exactly one chime")
        XCTAssertEqual(fixture.conductor.sequence.phase, .listening)
    }

    /// Your own Margins, and a muted layer's, get no chime: the voice starts the moment the Margin is reached.
    func testAMarginThatIsNotChimedStartsItsVoiceStraightAway() throws {
        let fixture = try ChimeFixture(chimed: false)
        defer { fixture.cleanUp() }

        fixture.reachTheMargin()
        XCTAssertEqual(fixture.events, ["source.pause", "voice:shared"])
        try fixture.pump(until: { fixture.resumed == 1 }, "the episode resumes when the voice ends")
        XCTAssertEqual(fixture.events, ["source.pause", "voice:shared", "source.resume"])
    }

    /// Skip during the chime stops it, never starts the voice, and the episode carries on.
    func testSkippingDuringTheChimeNeverStartsTheVoice() throws {
        let fixture = try ChimeFixture(chimed: true)
        defer { fixture.cleanUp() }

        fixture.reachTheMargin()
        fixture.conductor.skipVoice()
        XCTAssertEqual(fixture.resumed, 1)
        XCTAssertFalse(fixture.conductor.isPlayingVoice)
        fixture.pump(forSeconds: 1)
        XCTAssertEqual(fixture.events, ["source.pause", "chime:shared", "source.resume"], "the voice never started")
        XCTAssertEqual(fixture.conductor.sequence.phase, .listening)
    }

    /// Leaving the moment (another item, a recording) during the chime also keeps the voice from starting.
    func testCancellingDuringTheChimeNeverStartsTheVoice() throws {
        let fixture = try ChimeFixture(chimed: true)
        defer { fixture.cleanUp() }

        fixture.reachTheMargin()
        fixture.conductor.cancel()
        fixture.pump(forSeconds: 1)
        XCTAssertEqual(fixture.events, ["source.pause", "chime:shared"])
        XCTAssertFalse(fixture.conductor.isPlayingVoice)
    }

    /// Pause during the chime holds the voice; resume starts it, once, and marks it started.
    func testPausingDuringTheChimeHoldsTheVoiceUntilResumed() throws {
        let fixture = try ChimeFixture(chimed: true)
        defer { fixture.cleanUp() }

        fixture.reachTheMargin()
        fixture.conductor.setVoicePaused(true)
        fixture.pump(forSeconds: 1)
        XCTAssertEqual(fixture.events, ["source.pause", "chime:shared"], "paused, so the voice stays silent")
        XCTAssertTrue(fixture.conductor.isVoicePaused)

        fixture.conductor.setVoicePaused(false)
        XCTAssertEqual(fixture.events, ["source.pause", "chime:shared", "voice:shared"])
        XCTAssertFalse(fixture.conductor.isVoicePaused)
        try fixture.pump(until: { fixture.resumed == 1 }, "the episode resumes when the voice ends")
        XCTAssertEqual(fixture.events.filter { $0 == "voice:shared" }.count, 1, "the voice started once")
    }

    /// A conductor for one shared Margin at 5 s with real chime and voice players, both silent.
    @MainActor
    private final class ChimeFixture {
        private final class Log {
            var events: [String] = []
            var resumed = 0
            var chimeStartedAt: Date?
            var voiceStartedAt: Date?
        }

        let conductor: MarginMomentConductor
        private let directory: URL
        private let log = Log()

        var events: [String] { log.events }
        var resumed: Int { log.resumed }
        var chimeStartedAt: Date? { log.chimeStartedAt }
        var voiceStartedAt: Date? { log.voiceStartedAt }

        init(chimed: Bool) throws {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "margin-chime-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let voiceURL = try RealPlayerMarginMomentTests.writeTone(
                to: directory.appending(path: "shared.caf"), seconds: 0.8, hz: 440
            )
            let log = self.log
            self.directory = directory
            conductor = MarginMomentConductor(
                sequence: MarginMomentSequence(
                    itemId: "episode", target: MarginMomentAnchor(marginId: "shared", mediaTimeMs: 5_000), otherMargins: []
                ),
                source: .init(
                    pause: { log.events.append("source.pause") },
                    resume: { log.resumed += 1; log.events.append("source.resume") },
                    seek: { _ in }
                ),
                voiceURL: { _ in voiceURL }
            )
            conductor.voiceVolume = 0
            conductor.chimeVolume = 0
            if chimed { conductor.chimedMarginIds = ["shared"] }
            conductor.onChimeStarted = { log.chimeStartedAt = Date(); log.events.append("chime:\($0)") }
            conductor.onVoiceStarted = { log.voiceStartedAt = Date(); log.events.append("voice:\($0)") }
        }

        func reachTheMargin() {
            conductor.start()
            conductor.observe(mediaTimeMs: 4_800)
            conductor.observe(mediaTimeMs: 5_200)
        }

        func pump(forSeconds seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        func pump(until condition: () -> Bool, _ what: String, timeout: TimeInterval = 5) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                guard Date() < deadline else { return XCTFail("timed out waiting until \(what)") }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }

        func cleanUp() {
            conductor.cancel()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    fileprivate static func writeTone(to url: URL, seconds: Double, hz: Double) throws -> URL {
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
