import AVFoundation
import XCTest
@testable import SpokenMarginsApp

/// #3649: a listener taps a spoken note's sentence and then stops before it has begun. The audio session is handed
/// back to other apps only after the player has stopped; handing it back under a running player fails, and the
/// session would stay active as `.playback` with other apps' audio unable to resume.
final class SpokenNoteSentenceAudioTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sentence-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Two seconds of silence as a real 16-bit mono WAV file, so the real `AVAudioPlayer` opens and plays it.
    private func writeSilence() throws -> URL {
        let sampleRate = 8_000
        let samples = sampleRate * 2
        let dataBytes = samples * 2
        var wav = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); append32(UInt32(36 + dataBytes))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2)); append16(2); append16(16)
        wav.append(contentsOf: Array("data".utf8)); append32(UInt32(dataBytes))
        wav.append(Data(count: dataBytes))
        let url = folder.appendingPathComponent("silence.wav")
        try wav.write(to: url)
        return url
    }

    /// Records, at the moment the session is handed back, whether the player was still running.
    private final class HandBackLog: @unchecked Sendable {
        private let lock = NSLock()
        private var playingAtHandBack: [Bool] = []
        var player: AVAudioPlayer?
        func record() { lock.withLock { playingAtHandBack.append(player?.isPlaying ?? false) } }
        var entries: [Bool] { lock.withLock { playingAtHandBack } }
    }

    func testEndStopsThePlayerBeforeHandingTheSessionBack() async throws {
        let url = try writeSilence()
        let log = HandBackLog()
        let audio = SpokenNoteSentenceAudio(deactivate: { log.record() })
        let started = try await audio.start(url: url, startMs: 0)
        log.player = started.player
        XCTAssertTrue(started.player.isPlaying, "the player is running before the stop")

        await audio.end()

        XCTAssertEqual(log.entries, [false], "the session is handed back once, and only after the player stopped")
        XCTAssertFalse(started.player.isPlaying, "the player is stopped")
    }

    /// A stop whose task reached the actor after the next sentence had started (the model raises its generation at the stop,
    /// and the sentence tapped next is started for that same generation).
    func testALateEndDoesNotStopASentenceStartedAfterIt() async throws {
        let url = try writeSilence()
        let log = HandBackLog()
        let audio = SpokenNoteSentenceAudio(deactivate: { log.record() })
        let started = try await audio.start(url: url, startMs: 0, generation: 2)

        await audio.end(generation: 2)  // the stop that preceded the tap which started generation 2

        XCTAssertTrue(started.player.isPlaying, "the newer sentence keeps playing")
        XCTAssertEqual(log.entries, [], "the session stays with the sentence that is playing")
        await audio.end()
        XCTAssertFalse(started.player.isPlaying)
    }

    func testEndForALaterGenerationStopsAnOlderSentence() async throws {
        let url = try writeSilence()
        let log = HandBackLog()
        let audio = SpokenNoteSentenceAudio(deactivate: { log.record() })
        let started = try await audio.start(url: url, startMs: 0, generation: 1)
        log.player = started.player

        await audio.end(generation: 2)

        XCTAssertFalse(started.player.isPlaying)
        XCTAssertEqual(log.entries, [false])
    }

    func testEndWithNothingStartedStillHandsTheSessionBack() async {
        let log = HandBackLog()
        let audio = SpokenNoteSentenceAudio(deactivate: { log.record() })
        await audio.end()
        XCTAssertEqual(log.entries, [false])
    }
}
