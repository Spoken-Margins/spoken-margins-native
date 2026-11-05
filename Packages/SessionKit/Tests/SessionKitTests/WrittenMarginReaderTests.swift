import Foundation
@testable import SessionKit
@testable import SessionKitAudio
import XCTest

/// #3365: a written Margin's words become an audio file the conductor plays like a recording. The file's name comes
/// from the words and the voice alone, a file that exists is whole, and the same words render once.
final class WrittenMarginReaderTests: XCTestCase {
    #if canImport(AVFoundation)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "WrittenMarginReaderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A renderer that writes a small real file and counts its calls.
    private final class Renders: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var spoken: [String] = []
        func render(_ text: String, scratch: URL) throws -> URL {
            lock.withLock { spoken.append(text) }
            let file = scratch.appending(path: "speech.caf")
            try Data("audio for \(text)".utf8).write(to: file)
            return file
        }
    }

    private func reader(_ renders: Renders, voice: String? = nil) -> WrittenMarginReader {
        WrittenMarginReader(directory: directory, voiceIdentifier: voice, renderAudio: { try renders.render($0, scratch: $1) })
    }

    func testNamingAFileTouchesNoDiskAndDependsOnlyOnTheWordsAndTheVoice() {
        let colesNote = WrittenMarginReading(intro: "Cole wrote:", text: "Lovely harbour.")
        let url = reader(Renders()).fileURL(for: colesNote)
        XCTAssertEqual(url, reader(Renders()).fileURL(for: colesNote), "stable across readers")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "nothing was created")
        XCTAssertEqual(url.pathExtension, "caf")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)

        XCTAssertNotEqual(url, reader(Renders()).fileURL(for: WrittenMarginReading(intro: "Ana wrote:", text: "Lovely harbour.")), "the intro is part of the words")
        XCTAssertNotEqual(url, reader(Renders()).fileURL(for: WrittenMarginReading(intro: "Cole wrote:", text: "Lovely harbours.")))
        XCTAssertNotEqual(url, reader(Renders(), voice: "com.apple.voice.compact.en-GB.Daniel").fileURL(for: colesNote), "another voice, another file")
        XCTAssertEqual(url, reader(Renders()).fileURL(for: WrittenMarginReading(intro: "Cole wrote:", text: "  Lovely harbour.\n")), "padding is not part of the words")
    }

    func testTheReadingSaysWhoWroteItAndThenTheirWords() {
        XCTAssertEqual(WrittenMarginReading(intro: WrittenMarginReading.intro(senderName: "Cole"), text: "Hi").spokenText, "Cole wrote: Hi")
        for anonymous in [nil, "", "   ", "Your friend", "your friend", " YOUR FRIEND "] as [String?] {
            XCTAssertEqual(WrittenMarginReading.intro(senderName: anonymous), "Your friend wrote:", "\(String(describing: anonymous))")
        }
        XCTAssertEqual(WrittenMarginReading.intro(senderName: "  Ana María  "), "Ana María wrote:")
    }

    func testStartingNamesTheFileNowAndRendersItWholeLater() async throws {
        let renders = Renders()
        let reader = reader(renders)
        let reading = WrittenMarginReading(intro: "Cole wrote:", text: "Lovely harbour.")
        let urls = reader.start(["shared::a::1": reading])
        XCTAssertEqual(urls["shared::a::1"], reader.fileURL(for: reading))

        let file = try await reader.rendered(reading)
        XCTAssertEqual(file, urls["shared::a::1"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "audio for Cole wrote: Lovely harbour.")
        XCTAssertEqual(renders.spoken, ["Cole wrote: Lovely harbour."])
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(left, [file.lastPathComponent], "the scratch folder is gone: only the finished file is kept")
    }

    func testTheSameWordsRenderOnceAndAFileAlreadyThereIsNotRenderedAgain() async throws {
        let renders = Renders()
        let reader = reader(renders)
        let reading = WrittenMarginReading(intro: "Cole wrote:", text: "Once.")
        async let first = reader.rendered(reading)
        async let second = reader.rendered(reading)
        _ = try await (first, second)
        _ = try await reader.rendered(reading)
        XCTAssertEqual(renders.spoken.count, 1)
    }

    func testAFailedRenderLeavesNoFileAndTheNextAskTriesAgain() async throws {
        struct Broken: Error {}
        let attempts = Renders()
        let failing = WrittenMarginReader(directory: directory, renderAudio: { text, scratch in
            if attempts.spoken.isEmpty { _ = try attempts.render(text, scratch: scratch); throw Broken() }
            return try attempts.render(text, scratch: scratch)
        })
        let reading = WrittenMarginReading(intro: "Cole wrote:", text: "Try twice.")
        do { _ = try await failing.rendered(reading); XCTFail("the first render fails") } catch is Broken {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: failing.fileURL(for: reading).path), "a failed render leaves no file for the conductor to open")
        let file = try await failing.rendered(reading)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// A write that never returns (#1230) must not hold back every other reading until the app is killed.
    func testARenderThatNeverReturnsTimesOutAndTheNextReadingStillRenders() async throws {
        let stuck = DispatchSemaphore(value: 0)
        defer { stuck.signal() } // lets the abandoned thread end when the test does
        let renders = Renders()
        let reader = WrittenMarginReader(directory: directory, timeLimit: { _ in 0.3 }, renderAudio: { text, scratch in
            if text.contains("stuck") { stuck.wait() }
            return try renders.render(text, scratch: scratch)
        })
        let hung = WrittenMarginReading(intro: "Cole wrote:", text: "This one is stuck.")
        let fine = WrittenMarginReading(intro: "Cole wrote:", text: "This one is fine.")
        _ = reader.start(["a": hung, "b": fine]) // the stuck one is first in line for the lane, or second: either way both must be answered
        let began = Date()
        do { _ = try await reader.rendered(hung); XCTFail("a render that never returns must time out") } catch let error as WrittenMarginReader.RenderError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        XCTAssertFalse(reader.isReady(hung))
        let file = try await reader.rendered(fine)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(reader.isReady(fine))
        // The same words asked for again start a fresh render rather than waiting on the abandoned one.
        let retry = WrittenMarginReading(intro: "Cole wrote:", text: "Fresh start.")
        _ = try await reader.rendered(retry)
        XCTAssertTrue(reader.isReady(retry))
    }

    func testReadyIsAnsweredFromMemoryAndOnlyOnceTheFileIsThere() async throws {
        let renders = Renders()
        let reader = reader(renders)
        let reading = WrittenMarginReading(intro: "Cole wrote:", text: "Ready soon.")
        XCTAssertFalse(reader.isReady(reading))
        _ = try await reader.rendered(reading)
        XCTAssertTrue(reader.isReady(reading))
        let another = self.reader(Renders()) // a new reader finds a file an earlier run left, once it has looked
        XCTAssertFalse(another.isReady(reading), "no disk check happens when asking")
        _ = another.start(["k": reading])
        await another.waitUntilSettled([reading], upTo: 5)
        XCTAssertTrue(another.isReady(reading))
    }

    func testWaitingForReadingsEndsAtTheLimitEvenWhenARenderIsStuck() async {
        let stuck = DispatchSemaphore(value: 0)
        defer { stuck.signal() }
        let reader = WrittenMarginReader(directory: directory, timeLimit: { _ in 30 }, renderAudio: { _, _ in stuck.wait(); throw WrittenMarginReader.RenderError.nothingToSay })
        let began = Date()
        await reader.waitUntilSettled([WrittenMarginReading(intro: "Cole wrote:", text: "Never.")], upTo: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
    }

    /// Blocked writes each hold a thread (#1230): after a few, new readings fail at once instead of starting another.
    func testAfterTwoRendersAreStuckTheNextFailsAtOnceUntilOneComesBack() async throws {
        let release = DispatchSemaphore(value: 0)
        let calls = Renders()
        let reader = WrittenMarginReader(directory: directory, timeLimit: { _ in 0.2 }, mostStuckRenders: 2, renderAudio: { text, scratch in
            if text.contains("stuck") { _ = try calls.render(text, scratch: scratch); release.wait() }
            return try calls.render(text, scratch: scratch)
        })
        defer { release.signal(); release.signal(); release.signal() }
        for word in ["stuck one", "stuck two"] {
            do { _ = try await reader.rendered(WrittenMarginReading(intro: "Cole wrote:", text: word)); XCTFail("times out") } catch let e as WrittenMarginReader.RenderError { XCTAssertEqual(e, .timedOut) }
        }
        let began = Date()
        do { _ = try await reader.rendered(WrittenMarginReading(intro: "Cole wrote:", text: "stuck three")); XCTFail("fails at once") } catch let e as WrittenMarginReader.RenderError {
            XCTAssertEqual(e, .tooManyStuck)
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.15, "no wait, and no third thread")
        XCTAssertEqual(calls.spoken.filter { $0.contains("stuck three") }.count, 0)
        release.signal() // one abandoned write comes back
        try await Task.sleep(for: .milliseconds(300))
        let file = try await reader.rendered(WrittenMarginReading(intro: "Cole wrote:", text: "A fine one."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "renders start again once a stuck one returns")
    }

    /// Caches can be cleared while the app lives: a reading whose file is gone stops counting as ready, so the next ask renders it.
    func testAReadingWhoseFileWasClearedStopsBeingReadyAndRendersAgain() async throws {
        let renders = Renders()
        let reader = WrittenMarginReader(directory: directory, recheckAfter: 0, renderAudio: { try renders.render($0, scratch: $1) })
        let reading = WrittenMarginReading(intro: "Cole wrote:", text: "Cleared away.")
        let file = try await reader.rendered(reading)
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(reader.isReady(reading), "the first look still answers from memory")
        try await Task.sleep(for: .milliseconds(300)) // the check ran off the calling thread
        XCTAssertFalse(reader.isReady(reading))
        _ = try await reader.rendered(reading)
        XCTAssertEqual(renders.spoken.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        reader.forget(reading)
        XCTAssertFalse(reader.isReady(reading), "forgetting drops it at once")
    }

    /// One answer picks the voice, and the render uses it: a note is never read in a voice that cannot say it (#3365).
    func testTheVoiceIsChosenFromTheNotesLanguageOrThereIsNone() {
        let installed = ["en": "voice.en", "es": "voice.es", "ja": "voice.ja"]
        func voice(_ text: String, has: [String: String] = installed) -> String? {
            WrittenMarginReader.voice(forNote: text, voiceFor: { has[$0] }, defaultVoice: { "voice.default" })
        }
        XCTAssertEqual(voice("Lovely harbour, hear the gulls near the end of it."), "voice.en")
        XCTAssertEqual(voice("Me encanta este puerto, escucha las gaviotas al final del episodio."), "voice.es")
        XCTAssertEqual(voice("これは素晴らしい港です。最後にカモメの声が聞こえます。"), "voice.ja")
        XCTAssertEqual(voice("Great episode, loved the part about the harbour नमस्ते at the end"), "voice.en", "mostly English with one Hindi word")
        XCTAssertEqual(voice("ha!"), "voice.default", "too short to tell the language of")
        XCTAssertEqual(voice("yes"), "voice.default")
        XCTAssertEqual(voice("🎧 ok"), "voice.default")
        XCTAssertNil(voice("これは素晴らしい港です。最後にカモメの声が聞こえます。", has: ["en": "voice.en"]), "Japanese with no Japanese voice has no reading")
        XCTAssertNil(voice("यह एक बहुत सुंदर बंदरगाह है और मुझे यह पसंद है", has: ["en": "voice.en"]), "Hindi with no Hindi voice has no reading")
        XCTAssertNil(voice("هذا ميناء جميل جدا وأنا أحبه كثيرا", has: ["en": "voice.en"]), "Arabic likewise")
        XCTAssertEqual(voice("Das ist ein sehr schöner Hafen mit vielen Möwen.", has: ["en": "voice.en"]), "voice.default", "Latin script, no German voice: read in the default voice")
    }

    func testTheSpokenWordsKeepEverythingButLinksAndEmoji() {
        XCTAssertEqual(WrittenMarginSpeech.speakable("Great point.Totally agree"), "Great point.Totally agree")
        XCTAssertEqual(WrittenMarginSpeech.speakable("नमस्ते दुनिया"), "नमस्ते दुनिया")
        XCTAssertEqual(WrittenMarginSpeech.speakable("สวัสดีครับ"), "สวัสดีครับ")
        XCTAssertEqual(WrittenMarginSpeech.speakable("see https://example.com/a?b=1 now"), "see now")
        XCTAssertEqual(WrittenMarginSpeech.speakable("🎧 great  episode 🔥\n\nreally"), "great episode really")
        XCTAssertEqual(WrittenMarginSpeech.speakable("Café 東京, 3 days"), "Café 東京, 3 days")
    }

    // MARK: A friend's words do not outlive the item

    private func filesInDirectory() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), what)
    }

    func testDeletingAnItemForGoodRemovesItsReadingsAndOnlyThose() async throws {
        let reader = reader(Renders())
        let mine = WrittenMarginReading(intro: "Cole wrote:", text: "Lovely harbour.", itemId: "item-a")
        let mineToo = WrittenMarginReading(intro: "Cole wrote:", text: "Another note.", itemId: "item-a")
        let theirs = WrittenMarginReading(intro: "Cole wrote:", text: "Lovely harbour.", itemId: "item-b")
        let fileA = try await reader.rendered(mine)
        let fileA2 = try await reader.rendered(mineToo)
        let fileB = try await reader.rendered(theirs)
        XCTAssertNotEqual(fileA, fileB, "identical words on two items are two files: deleting one can never take the other's")
        reader.removeReadings(forItem: "item-a")
        try await waitUntil("the item's files are gone") { !FileManager.default.fileExists(atPath: fileA.path) && !FileManager.default.fileExists(atPath: fileA2.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileB.path), "another item's reading stays, identical words or not")
        XCTAssertFalse(reader.isReady(mine), "the ready set forgets it at once")
        XCTAssertTrue(reader.isReady(theirs))
        XCTAssertEqual(filesInDirectory(), [fileB.lastPathComponent])
        let again = try await reader.rendered(mine)
        XCTAssertEqual(again, fileA, "if the item comes back, the reading simply renders again")
    }

    /// Trash is not a permanent delete: the app calls `removeReadings` only for the latter, so Undo finds the file.
    func testTrashingLeavesTheReadingSoUndoStillHasIt() async throws {
        let renders = Renders()
        let reader = reader(renders)
        let note = WrittenMarginReading(intro: "Cole wrote:", text: "Lovely harbour.", itemId: "item-a")
        let file = try await reader.rendered(note)
        // Trash and Undo call nothing on the reader. What the host cannot show: that the player then plays the file.
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(reader.isReady(note))
        let after = try await reader.rendered(note)
        XCTAssertEqual(after, file)
        XCTAssertEqual(renders.spoken.count, 1, "nothing was rendered again")
    }

    func testARenderThatFinishesAfterTheDeleteLeavesNoFile() async throws {
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let reader = WrittenMarginReader(directory: directory, renderAudio: { text, scratch in
            started.signal()
            release.wait()
            let file = scratch.appending(path: "speech.caf")
            try Data(text.utf8).write(to: file)
            return file
        })
        let note = WrittenMarginReading(intro: "Cole wrote:", text: "Lovely harbour.", itemId: "item-a")
        let result = Task { try? await reader.rendered(note) }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        reader.removeReadings(forItem: "item-a")
        release.signal()
        let url = await result.value
        XCTAssertNil(url, "the render gave up its file")
        XCTAssertFalse(reader.isReady(note))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(filesInDirectory().contains { $0.hasSuffix(".caf") }, "no reading was left behind")
    }

    func testDeletingSweepsOldScratchFoldersAndLeavesRecentOnes() async throws {
        let fileManager = FileManager.default
        let old = directory.appending(path: "scratch-old", directoryHint: .isDirectory)
        let recent = directory.appending(path: "scratch-recent", directoryHint: .isDirectory)
        for folder in [old, recent] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("a friend's words".utf8).write(to: folder.appending(path: "speech.caf"))
        }
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: old.path)
        reader(Renders()).removeReadings(forItem: "item-a")
        try await waitUntil("the old scratch folder is swept") { !fileManager.fileExists(atPath: old.path) }
        XCTAssertTrue(fileManager.fileExists(atPath: recent.path), "a render that may still be running keeps its folder")
    }

    func testTheFileNameIsASha256OfTheWordsAndTheItem() {
        let note = WrittenMarginReading(intro: "Cole wrote:", text: "Lovely harbour.", itemId: "item-a")
        let name = reader(Renders()).fileURL(for: note).deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-")
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].count, 16)
        XCTAssertEqual(parts[1].count, 64, "a full SHA-256, in hex")
        XCTAssertTrue(name.allSatisfy { $0.isHexDigit || $0 == "-" })
        let other = WrittenMarginReading(intro: "Cole wrote:", text: "Lovely harbour.", itemId: "item-b")
        XCTAssertNotEqual(name, reader(Renders()).fileURL(for: other).deletingPathExtension().lastPathComponent)
    }

    func testALongerNoteGetsALongerTimeLimit() {
        XCTAssertEqual(WrittenMarginReader.defaultTimeLimit(forCharacters: 100), 20)
        XCTAssertEqual(WrittenMarginReader.defaultTimeLimit(forCharacters: 50_000), 120)
        XCTAssertTrue(WrittenMarginReading(intro: "Cole wrote:", text: String(repeating: "a", count: 600)).isShortEnoughToRenderAhead)
        XCTAssertFalse(WrittenMarginReading(intro: "Cole wrote:", text: String(repeating: "a", count: 601)).isShortEnoughToRenderAhead)
    }

    /// The renderer is not on the main thread, which `AVSpeechSynthesizer.write` must never be (#2100).
    @MainActor
    func testRenderingNeverRunsOnTheMainThread() async throws {
        let ranOnMain = OnMain()
        let reader = WrittenMarginReader(directory: directory, renderAudio: { text, scratch in
            ranOnMain.set(Thread.isMainThread)
            let file = scratch.appending(path: "x.caf")
            try Data(text.utf8).write(to: file)
            return file
        })
        _ = try await reader.rendered(WrittenMarginReading(intro: "Cole wrote:", text: "Off the main thread."))
        XCTAssertEqual(ranOnMain.value, false)
    }

    private final class OnMain: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?
        var value: Bool? { lock.withLock { stored } }
        func set(_ value: Bool) { lock.withLock { stored = value } }
    }
    #endif
}
