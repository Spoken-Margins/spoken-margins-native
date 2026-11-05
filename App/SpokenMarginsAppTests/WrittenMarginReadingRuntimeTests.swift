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

    /// The default English voice silently skips Japanese and Hindi, which left only "Cole wrote:" that was then marked heard.
    /// The render must use the note's own voice, so its file is longer than the intro's alone.
    func testANoteInAnotherScriptIsReadWholeNotJustTheIntro() async throws {
        executionTimeAllowance = 180
        try await SystemVoiceRuntime.requireAnsweringVoice()
        let notes = [
            ("ja-JP", "これは素晴らしい港です。最後にカモメの声が聞こえます。", 2.0),
            ("hi-IN", "यह एक बहुत सुंदर बंदरगाह है और मुझे यह पसंद है।", 2.0),
            ("zh-CN", "Great point. 你好世界。Listen again.", 1.5), // a mixed note: the one voice says the English too
            ("ja-JP", "ok はい", 0.3),
        ]
        var checked = 0
        var skipped: [String] = []
        for (language, words, margin) in notes {
            guard AVSpeechSynthesisVoice(language: language) != nil else { skipped.append("no \(language) voice installed"); continue }
            let directory = FileManager.default.temporaryDirectory.appending(path: "written-margin-script-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: directory) }
            let reader = WrittenMarginReader(directory: directory)
            let intro = WrittenMarginReading.intro(senderName: "Cole")
            let introOnly = try AVAudioPlayer(contentsOf: try await reader.rendered(WrittenMarginReading(intro: intro, text: "ok", itemId: "intro")))
            let whole = try AVAudioPlayer(contentsOf: try await reader.rendered(WrittenMarginReading(intro: intro, text: words, itemId: "note")))
            XCTAssertGreaterThan(whole.duration, introOnly.duration + margin, "\(language): the note itself was spoken, not only \"\(intro)\"")
            checked += 1
        }
        if checked == 0 { throw XCTSkip("this Mac has no Japanese or Hindi voice installed: \(skipped.joined(separator: "; "))") }
    }
}
