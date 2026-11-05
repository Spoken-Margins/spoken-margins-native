import AVFoundation
import SessionKit
import SessionKitAudio
import XCTest

/// #3365: the iPhone's voice, rendered by the shipped `WrittenMarginReader` into a real file, opened by a real
/// `AVAudioPlayer`, leveled the way a recording is, and played for a couple of seconds. On a runtime whose speech
/// service doesn't answer it skips, as the other system-voice tests do (#768). What it sounds like is the owner's phone.
final class WrittenMarginReadingRuntimeTests: XCTestCase {
    func testARenderedReadingOpensLevelsAndPlays() async throws {
        executionTimeAllowance = 180 // the first write in a fresh simulator can take minutes (#1230)
        try await SystemVoiceRuntime.requireAnsweringVoice()
        let directory = FileManager.default.temporaryDirectory.appending(path: "written-margin-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = WrittenMarginReader(directory: directory)
        let reading = WrittenMarginReading(intro: WrittenMarginReading.intro(senderName: "Cole"), text: "Lovely harbour. Hear the gulls near the end.")

        let file = try await reader.rendered(reading)
        XCTAssertTrue(reader.isReady(reading))
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [file.lastPathComponent], "only the finished file is kept")

        let player = try AVAudioPlayer(contentsOf: file)
        XCTAssertGreaterThan(player.duration, 1, "a sentence is more than a second of speech")

        let cache = LeveledMarginCache(directory: directory.appending(path: "leveled", directoryHint: .isDirectory))
        _ = await cache.level(file)
        let leveled = try XCTUnwrap(cache.readyCopy(for: file), "the reading levels like a recording")
        let leveledPlayer = try AVAudioPlayer(contentsOf: leveled)
        XCTAssertGreaterThan(leveledPlayer.duration, 1)

        XCTAssertTrue(leveledPlayer.play())
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThan(leveledPlayer.currentTime, 1, "the reading advanced while it played")
        leveledPlayer.stop()
    }
}
