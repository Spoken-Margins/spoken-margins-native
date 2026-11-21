import Foundation
import SessionKit
import XCTest
@testable import SessionKitAudio

/// #3940, PR 4: how the transcription job uses the cut. The cut itself is `MarginEndPhraseTrimTests`; this is the
/// toggle, the words that get saved, and the order of "words saved, then audio swapped".
final class MarginEndPhraseSavingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "margin-saving-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func transcript(_ pieces: [String], text: String) -> AlignedInterjectionTranscript {
        AlignedInterjectionTranscript(
            text: text,
            localeIdentifier: "en_US",
            segments: pieces.enumerated().map {
                AlignedTranscriptSegment(id: "seg-\($0.offset + 1)", text: $0.element, startMs: $0.offset * 400, endMs: $0.offset * 400 + 300)
            }
        )
    }

    private func prepared(original: String, cut: String) throws -> MarginEndPhraseTrim.PreparedEndPhraseTrim {
        let target = directory.appending(path: "margin.m4a")
        let temporary = directory.appending(path: ".trim-test.m4a")
        try Data(original.utf8).write(to: target)
        try Data(cut.utf8).write(to: temporary)
        return MarginEndPhraseTrim.PreparedEndPhraseTrim(
            transcript: transcript(["that", "is", "my", "point"], text: "That is my point."),
            durationMs: 1_700, target: target, temporary: temporary
        )
    }

    // MARK: toggle

    func testTheToggleIsOnUntilTheListenerTurnsItOff() throws {
        let suite = "margin-saving-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(MarginEndPhraseSaving.isSwitchedOn(defaults), "absent means on")
        defaults.set(false, forKey: MarginEndPhraseSaving.settingsKey)
        XCTAssertFalse(MarginEndPhraseSaving.isSwitchedOn(defaults))
        defaults.set(true, forKey: MarginEndPhraseSaving.settingsKey)
        XCTAssertTrue(MarginEndPhraseSaving.isSwitchedOn(defaults))
        XCTAssertEqual(MarginEndPhraseSaving.settingsKey, "marginEndPhrase", "the key Settings stores the toggle under")
    }

    func testNoCutIsTriedWithTheToggleOffOrNothingToCut() async throws {
        let said = transcript(["that", "is", "my", "point", "stop", "margin"], text: "That is my point. Stop margin.")
        let file = directory.appending(path: "margin.m4a")
        try Data("audio".utf8).write(to: file)
        let off = await MarginEndPhraseSaving.prepare(audioURL: file, transcript: said, isSwitchedOn: false, endedByPhrase: true)
        XCTAssertNil(off)
        let noFile = await MarginEndPhraseSaving.prepare(audioURL: nil, transcript: said, isSwitchedOn: true, endedByPhrase: true)
        XCTAssertNil(noFile)
        let noWords = await MarginEndPhraseSaving.prepare(audioURL: file, transcript: nil, isSwitchedOn: true, endedByPhrase: true)
        XCTAssertNil(noWords)
        let notEndedByPhrase = await MarginEndPhraseSaving.prepare(audioURL: file, transcript: said, isSwitchedOn: true, endedByPhrase: false)
        XCTAssertNil(notEndedByPhrase, "a Margin the phrase did not end is never cut, whatever its last words are")
        XCTAssertEqual(try Data(contentsOf: file), Data("audio".utf8))
    }

    // MARK: who ended the Margin

    func testOnlyAMarginThePhraseEndedIsMarkedAndItIsAskedAboutOnce() {
        let ledger = MarginEndPhraseEndLedger()
        XCTAssertFalse(ledger.consumeEndedByPhrase(interjectionId: "a"), "nothing marked: not ended by the phrase")
        ledger.markEndedByPhrase(interjectionId: "a")
        XCTAssertFalse(ledger.consumeEndedByPhrase(interjectionId: "b"), "another Margin is not marked")
        XCTAssertTrue(ledger.consumeEndedByPhrase(interjectionId: "a"))
        XCTAssertFalse(ledger.consumeEndedByPhrase(interjectionId: "a"), "a retry or a relaunch keeps everything")
    }

    // MARK: words and the swap

    func testTheWordsToSaveAreTheCutOnesOrTheHeardOnes() throws {
        let heard = transcript(["that", "is", "my", "point", "stop", "margin"], text: "That is my point. Stop margin.")
        let cut = try prepared(original: "full", cut: "short")
        XCTAssertEqual(MarginEndPhraseSaving.wordsToSave(heard: heard, prepared: cut)?.text, "That is my point.")
        XCTAssertEqual(MarginEndPhraseSaving.wordsToSave(heard: heard, prepared: nil)?.text, heard.text)
        XCTAssertNil(MarginEndPhraseSaving.wordsToSave(heard: nil, prepared: nil))
    }

    #if os(macOS) // Foundation's replaceItemAt on Linux fails on a plain replace; the app is Apple-only.
    func testTheCutAudioReplacesTheOriginalOnlyOnceTheWordsAreSaved() throws {
        let cut = try prepared(original: "full", cut: "short")
        MarginEndPhraseSaving.finish(cut, wordsSaved: true)
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "margin.m4a"), encoding: .utf8), "short")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: ".trim-test.m4a").path))
    }
    #endif

    func testFailedWordsKeepTheOriginalAudioAndLeaveNoCopy() throws {
        let cut = try prepared(original: "full", cut: "short")
        MarginEndPhraseSaving.finish(cut, wordsSaved: false)
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "margin.m4a"), encoding: .utf8), "full")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: ".trim-test.m4a").path))
    }

    func testNothingPreparedIsANoOp() {
        MarginEndPhraseSaving.finish(nil, wordsSaved: true)
        MarginEndPhraseSaving.finish(nil, wordsSaved: false)
    }

    func testADeletedMarginGetsNoStrayFile() throws {
        let cut = try prepared(original: "full", cut: "short")
        try FileManager.default.removeItem(at: directory.appending(path: "margin.m4a"))
        MarginEndPhraseSaving.finish(cut, wordsSaved: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "margin.m4a").path), "no file back at a deleted Margin's path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: ".trim-test.m4a").path))
    }

    #if os(macOS) && canImport(AVFoundation)
    // MARK: the whole step, on a real file

    func testAMarginEndedOnThePhraseIsSavedWithoutIt() async throws {
        let file = try MarginEndPhraseSavingTone.write(seconds: 4, to: directory.appending(path: "margin.m4a"))
        // "margin" ends at 2,300 ms in a 4 s file: well over the confirming second of audio after it.
        let said = transcript(["that", "is", "my", "point", "stop", "margin"], text: "That is my point. Stop margin.")
        let cut = await MarginEndPhraseSaving.prepare(audioURL: file, transcript: said, isSwitchedOn: true, endedByPhrase: true)
        let prepared = try XCTUnwrap(cut)
        XCTAssertEqual(MarginEndPhraseSaving.wordsToSave(heard: said, prepared: prepared)?.text, "That is my point.")
        MarginEndPhraseSaving.finish(prepared, wordsSaved: true)
        guard case .milliseconds(let ms) = RecordedFileDuration.measure(file) else { return XCTFail("duration") }
        // "point" ends at 1,500 ms and "stop" starts at 1,600: the cut is at the end of the last word kept.
        XCTAssertEqual(Double(ms), 1_500, accuracy: 150, "the phrase is cut from the audio")
    }

    func testAMarginEndedByTheScreenOnWordsThatEndLikeThePhraseKeepsAllOfIt() async throws {
        let file = try MarginEndPhraseSavingTone.write(seconds: 4, to: directory.appending(path: "margin.m4a"))
        let before = try Data(contentsOf: file)
        let said = transcript(["so", "i", "wrote", "it", "in", "the", "end", "margin"], text: "So I wrote it in the end margin.")
        let screen = await MarginEndPhraseSaving.prepare(audioURL: file, transcript: said, isSwitchedOn: true, endedByPhrase: false)
        XCTAssertNil(screen, "ended by the screen: nothing is cut")
        XCTAssertEqual(MarginEndPhraseSaving.wordsToSave(heard: said, prepared: screen)?.text, "So I wrote it in the end margin.")
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testAFileThatStopsRightAfterThePhraseWordsIsNotCut() async throws {
        // 8 words end at 3,100 ms; a 3.4 s file has 300 ms after them, less than the confirming second a phrase ending needs.
        let file = try MarginEndPhraseSavingTone.write(seconds: 3.4, to: directory.appending(path: "margin.m4a"))
        let said = transcript(["so", "i", "wrote", "it", "in", "the", "end", "margin"], text: "So I wrote it in the end margin.")
        let early = await MarginEndPhraseSaving.prepare(audioURL: file, transcript: said, isSwitchedOn: true, endedByPhrase: true)
        XCTAssertNil(early)
    }

    func testAPhraseInTheMiddleOrANonMatchingEndKeepsAll() async throws {
        let file = try MarginEndPhraseSavingTone.write(seconds: 4, to: directory.appending(path: "margin.m4a"))
        let notLast = transcript(["stop", "margin", "notes", "here"], text: "Stop margin notes here.")
        let kept = await MarginEndPhraseSaving.prepare(audioURL: file, transcript: notLast, isSwitchedOn: true, endedByPhrase: true)
        XCTAssertNil(kept)
        let said = transcript(["that", "is", "my", "point", "stop", "margin"], text: "That is my point. Stop margin.")
        let off = await MarginEndPhraseSaving.prepare(audioURL: file, transcript: said, isSwitchedOn: false, endedByPhrase: true)
        XCTAssertNil(off, "with the toggle off the phrase stays")
    }
    #endif
}

#if os(macOS) && canImport(AVFoundation)
import AVFoundation

private enum MarginEndPhraseSavingTone {
    static func write(seconds: Double, to url: URL) throws -> URL {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(frames) { samples[frame] = Float(0.3 * sin(2 * .pi * 440 * Double(frame) / 44_100)) }
        try file.write(from: buffer)
        return url
    }
}
#endif
