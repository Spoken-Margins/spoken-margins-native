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

    /// #3412 audit: a render that came back right at its limit, with the time limit firing before the result was handed
    /// over, was counted stuck for good (nothing lowers the count for a render that has already returned). After
    /// `mostStuckRenders` of those every reading failed at once until the app restarted. The hook holds that gap open.
    func testARenderThatCameBackBeforeTheTimeLimitFiredIsNeverCountedStuck() async throws {
        let renders = Renders()
        let reader = WrittenMarginReader(directory: directory, timeLimit: { _ in 0.3 }, mostStuckRenders: 1, renderAudio: { try renders.render($0, scratch: $1) })
        reader.beforeFinish = { reading in
            if reading.text.contains("slow hand-off") { Thread.sleep(forTimeInterval: 0.8) } // the limit (0.3 s) fires in here
        }
        let slow = WrittenMarginReading(intro: "Cole wrote:", text: "A slow hand-off.")
        let file = try await reader.rendered(slow) // it came back in time, so it is answered with its file, not `timedOut`
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(reader.isReady(slow))
        // With one stuck render allowed, a wrongly counted one would fail this at once with `tooManyStuck`.
        let next = try await reader.rendered(WrittenMarginReading(intro: "Cole wrote:", text: "The next one."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: next.path))
    }

    /// #3423: tests share one reader, so each one must see that it left no render behind. `activity` says what is
    /// queued, running, waited on or stuck, `settle` waits for the readings someone waits on without starting any, and
    /// `whenSettled` runs a file's removal only after the render that was about to look at it.
    func testActivityShowsARenderUntilItIsDoneAndSettleWaitsForItWithoutStartingOne() async throws {
        let release = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let reader = WrittenMarginReader(directory: directory, renderAudio: { text, scratch in
            started.signal()
            release.wait()
            let file = scratch.appending(path: "speech.caf")
            try Data(text.utf8).write(to: file)
            return file
        })
        XCTAssertTrue(reader.activity.isIdle, "a new reader has nothing to do")
        let idle = await reader.settle(upTo: 5)
        XCTAssertTrue(idle.isIdle, "settling with nothing waited on starts no render")

        let reading = WrittenMarginReading(intro: "Cole wrote:", text: "Busy words.")
        let second = WrittenMarginReading(intro: "Cole wrote:", text: "Queued words.")
        _ = reader.start(["a": reading, "b": second])
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success, "the first render is running")
        XCTAssertFalse(reader.activity.isIdle)
        XCTAssertEqual(reader.activity.waiting, 2)
        XCTAssertEqual(reader.activity.running, 1)
        XCTAssertEqual(reader.activity.queued, 1)

        let removed = Flag()
        reader.whenSettled(reading) { removed.set() }
        XCTAssertFalse(removed.value, "the render of these words is still running")
        release.signal()
        release.signal() // the first render and the queued one
        let done = await reader.settle(upTo: 5)
        XCTAssertTrue(done.isIdle, "\(done)")
        XCTAssertTrue(removed.value, "ran when the render finished, before settle returned")
        let ran = Flag()
        reader.whenSettled(reading) { ran.set() }
        XCTAssertTrue(ran.value, "with no render of these words, it runs at once")
    }

    /// #3619's T3: a tap's wait asked the reader from a task of its own, so for a moment after the tap nobody was waiting
    /// on the reading, and a clean-up that removed the file then made the render start real speech. The callback forms
    /// ask before they return: the reading is waited on from the caller's next line, and `whenSettled` waits for it.
    func testTheCallbackAsksAreWaitedOnBeforeTheyReturn() async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let reader = WrittenMarginReader(directory: directory, renderAudio: { text, scratch in
            release.wait()
            let file = scratch.appending(path: "speech.caf")
            try Data(text.utf8).write(to: file)
            return file
        })
        let tapped = WrittenMarginReading(intro: "Cole wrote:", text: "Tapped words.")
        let answered = Flag()
        reader.render(tapped) { if case .success = $0 { answered.set() } }
        XCTAssertEqual(reader.activity.waiting, 1, "the tap's reading is waited on before render returns")
        let removed = Flag()
        reader.whenSettled(tapped) { removed.set() }
        XCTAssertFalse(removed.value, "a removal asked for now waits for the render")

        let held = WrittenMarginReading(intro: "Cole wrote:", text: "Held words.")
        let settled = Flag()
        reader.whenRendered([held], upTo: 30) { settled.set() }
        XCTAssertEqual(reader.activity.waiting, 2, "the hold's reading is waited on before whenRendered returns")

        release.signal()
        release.signal()
        let done = await reader.settle(upTo: 5)
        XCTAssertTrue(done.isIdle, "\(done)")
        XCTAssertTrue(answered.value, "render's answer came")
        XCTAssertTrue(removed.value, "the removal ran after the render")
        XCTAssertTrue(settled.value, "whenRendered ran once its reading was on disk")
        let none = Flag()
        reader.whenRendered([], upTo: 30) { none.set() }
        XCTAssertTrue(none.value, "with no readings it runs at once")
    }

    func testSettleEndsAtTheLimitAndShowsARenderThatIsStillBlocked() async throws {
        let stuck = DispatchSemaphore(value: 0)
        defer { stuck.signal() }
        let reader = WrittenMarginReader(directory: directory, timeLimit: { _ in 30 }, renderAudio: { _, _ in stuck.wait(); throw WrittenMarginReader.RenderError.nothingToSay })
        _ = reader.start(["a": WrittenMarginReading(intro: "Cole wrote:", text: "Never.")])
        let left = await reader.settle(upTo: 0.3)
        XCTAssertFalse(left.isIdle, "a blocked render is not idle: \(left)")
        XCTAssertEqual(left.running, 1)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        var value: Bool { lock.withLock { stored } }
        func set() { lock.withLock { stored = true } }
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


    /// The gate is capability: one installed voice must cover every script in the note, or there is no reading (#3365).
    func testOneInstalledVoiceMustCoverEveryScriptInTheNoteOrThereIsNone() {
        let all = ["en": "v.en", "es": "v.es", "ja": "v.ja", "zh-Hans": "v.zh", "hi": "v.hi", "ar": "v.ar", "ko": "v.ko"]
        func voice(_ text: String, has: [String: String] = all, available: Bool = true) -> String? {
            WrittenMarginVoice.voice(forNote: WrittenMarginSpeech.speakable(text), voiceFor: { has[$0] }, defaultVoice: { "v.default" }, isAvailable: { _ in available })
        }
        XCTAssertEqual(voice("Lovely harbour, hear the gulls near the end of it."), "v.en")
        XCTAssertEqual(voice("Me encanta este puerto, escucha las gaviotas al final del episodio."), "v.es")
        XCTAssertEqual(voice("ok はい"), "v.ja", "mixed script: the Japanese voice, which says the English too")
        XCTAssertEqual(voice("Great point. 你好世界。Listen again."), "v.zh")
        XCTAssertEqual(voice("Great episode, loved the harbour नमस्ते at the end of it"), "v.hi", "one Hindi word: a voice exists, so it is read")
        XCTAssertEqual(voice("هذا ميناء جميل جدا"), "v.ar", "a short Arabic note")
        XCTAssertEqual(voice("هَذَا مِينَاءٌ جَمِيلٌ، وَأَنَا أُحِبُّهُ كَثِيرًا"), "v.ar", "Arabic with its marks still passes")
        XCTAssertNil(voice("یہ ایک خوبصورت بندرگاہ ہے اور مجھے پسند ہے"), "Urdu: the Arabic voice skips ٹ ہ ک ی, so no voice covers it")
        XCTAssertNil(voice("این یک بندر زیبا است و من آن را دوست دارم"), "Persian: ک ی پ گ are not read by the Arabic voice")
        XCTAssertEqual(voice("ha!"), "v.default", "short English")
        XCTAssertEqual(voice("yes"), "v.default")
        XCTAssertEqual(voice("hmm ok so"), "v.default", "a short Latin note in an unsure language: the default voice")
        XCTAssertEqual(voice(""), "v.default")
        XCTAssertEqual(voice("?!..."), "v.default", "punctuation only has no script to cover")
        XCTAssertEqual(voice(String(repeating: "Harbour lights. ", count: 4_000)), "v.en", "a very long note")
        XCTAssertNil(voice("ok はい", has: ["en": "v.en"]), "no Japanese voice")
        XCTAssertNil(voice("यह एक बहुत सुंदर बंदरगाह है", has: ["en": "v.en"]), "no Hindi voice")
        XCTAssertNil(voice("これは नमस्ते です"), "Japanese and Hindi together: no one voice covers both")
        XCTAssertNil(voice("გამარჯობა მეგობარო"), "a script that isn't in the table is not covered")
        XCTAssertNil(voice("Hello வணக்கம்"), "likewise, with Latin beside it")
        XCTAssertNil(voice("ok はい", available: false), "listed but not installed now: no reading")
        XCTAssertNil(voice("Lovely harbour, hear the gulls near the end of it.", available: false), "also for a Latin note")
        XCTAssertEqual(voice("Das ist ein sehr schöner Hafen mit vielen Möwen.", has: ["en": "v.en"]), "v.default", "no German voice: read in the default one")
    }

    func testANoteNoVoiceCanReadIsNeverRenderedAndLeavesNoFile() async throws {
        let renders = Renders()
        let none = WrittenMarginReader(directory: directory, voiceForNote: { _ in nil }, renderAudio: { try renders.render($0, scratch: $1) })
        let note = WrittenMarginReading(intro: "Cole wrote:", text: "ok はい", itemId: "item-a")
        do { _ = try await none.rendered(note); XCTFail("no voice") } catch { XCTAssertEqual(error as? WrittenMarginReader.RenderError, .noVoice) }
        XCTAssertTrue(renders.spoken.isEmpty, "nothing was synthesized")
        XCTAssertFalse(none.isReady(note))
        XCTAssertFalse(filesInDirectory().contains { $0.hasSuffix(".caf") })
    }

    /// A sanity check, not proof: a file no longer than the intro alone means the voice said nothing of the note.
    func testAFileNoLongerThanTheIntroAloneIsAFailureAndKeepsNoFile() async throws {
        let renders = Renders()
        @Sendable func seconds(_ url: URL) -> Double? { String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self).contains("harbour") ? 3 : 1 }
        let reader = WrittenMarginReader(directory: directory, voiceForNote: { _ in "v" }, audioSeconds: { seconds($0) },
                                         renderAudio: { try renders.render($0, scratch: $1) })
        let spoken = WrittenMarginReading(intro: "Cole wrote:", text: "Lovely harbour.", itemId: "item-a")
        let silent = WrittenMarginReading(intro: "Cole wrote:", text: "これは", itemId: "item-a")
        _ = try await reader.rendered(spoken)
        do { _ = try await reader.rendered(silent); XCTFail("intro only") } catch { XCTAssertEqual(error as? WrittenMarginReader.RenderError, .nothingToSay) }
        XCTAssertFalse(reader.isReady(silent))
        XCTAssertEqual(filesInDirectory().filter { $0.hasSuffix(".caf") }.count, 1, "only the whole reading is kept")
    }

    /// Render a reading, make its leveled copy through the real leveler, delete the item, then look under the Caches root.
    func testDeletingAnItemLeavesNothingOfItsReadingsOrTheirLeveledCopiesAndTouchesNothingElse() async throws {
        let caches = directory.appending(path: "Caches", directoryHint: .isDirectory)
        let readings = caches.appending(path: "WrittenMargins", directoryHint: .isDirectory)
        let leveled = LeveledMarginCache(directory: caches.appending(path: "LeveledMargins", directoryHint: .isDirectory))
        let seed = Seeds()
        let reader = WrittenMarginReader(directory: readings, voiceForNote: { _ in "v" }, audioSeconds: { $0.deletingLastPathComponent().lastPathComponent == "intro" ? 1 : 5 }, renderAudio: { text, scratch in
            let file = scratch.appending(path: "speech.caf") // a real, different recording for each text
            try MarginLoudnessLevelerTests.write([MarginLoudnessLevelerTests.speechLike(seed: seed.next(), lufs: -30)], to: file, aac: false)
            return file
        })
        let a1 = WrittenMarginReading(intro: "Cole wrote:", text: "First note.", itemId: "item-a")
        let a2 = WrittenMarginReading(intro: "Cole wrote:", text: "Second note.", itemId: "item-a")
        let b1 = WrittenMarginReading(intro: "Cole wrote:", text: "First note.", itemId: "item-b")
        var readingFiles: [URL] = []
        for reading in [a1, a2, b1] { readingFiles.append(try await reader.rendered(reading)) }
        for file in readingFiles { guard case .leveled = await leveled.level(file) else { return XCTFail("the leveler should make a copy of \(file.lastPathComponent)") } }
        let recording = directory.appending(path: "recording.wav") // a recording and its own leveled copy: not this path's to touch
        try MarginLoudnessLevelerTests.write([MarginLoudnessLevelerTests.speechLike(seed: 999, lufs: -40)], to: recording, aac: false)
        guard case .leveled = await leveled.level(recording) else { return XCTFail("recording copy") }
        func leveledCount() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: caches.appending(path: "LeveledMargins").path)) ?? []).filter { $0.hasSuffix(".caf") }.count }
        XCTAssertEqual(leveledCount(), 4)

        reader.removeReadings(forItem: "item-a", leveled: leveled)
        try await waitUntil("item-a's readings and their copies are gone") {
            leveledCount() == 2 && !FileManager.default.fileExists(atPath: readingFiles[0].path) && !FileManager.default.fileExists(atPath: readingFiles[1].path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readingFiles[2].path), "item-b's reading stays")
        XCTAssertNotNil(leveled.readyCopy(for: readingFiles[2]), "and its leveled copy")
        XCTAssertNotNil(leveled.readyCopy(for: recording), "the recording's leveled copy is not touched")
        let left = (FileManager.default.enumerator(atPath: caches.path)?.allObjects as? [String]) ?? []
        XCTAssertFalse(left.contains { $0.contains(WrittenMarginReader.itemKey("item-a")) }, "nothing named for item-a is left: \(left)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.path), "no recording was touched")
    }

    private final class Seeds: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 10
        func next() -> UInt64 { lock.withLock { value += 1; return value } }
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
        reader.removeReadings(forItem: "item-a", leveled: nil)
        try await waitUntil("the item's files are gone") { !FileManager.default.fileExists(atPath: fileA.path) && !FileManager.default.fileExists(atPath: fileA2.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileB.path), "another item's reading stays, identical words or not")
        XCTAssertFalse(reader.isReady(mine), "the ready set forgets it at once")
        XCTAssertTrue(reader.isReady(theirs))
        XCTAssertEqual(filesInDirectory(), [fileB.lastPathComponent])
        let again = try await reader.rendered(mine)
        XCTAssertEqual(again, fileA, "if the item comes back, the reading simply renders again")
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
        reader.removeReadings(forItem: "item-a", leveled: nil)
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
        reader(Renders()).removeReadings(forItem: "item-a", leveled: nil)
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
