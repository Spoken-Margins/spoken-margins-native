import Foundation
@testable import SessionKit
@testable import SessionKitAudio
import XCTest

/// #3391: a friend's written Margin is read in the listener's chosen on-device voice after the Terms, in the iPhone
/// voice before them, and a slow, failed, missing or skipped on-device render never leaves silence.
final class WrittenMarginOnDeviceVoiceTests: XCTestCase {
    typealias Choice = WrittenMarginVoiceChoice

    // MARK: The choice

    func testBeforeTheTermsItIsTheIPhoneVoiceWhateverElseIsTrue() {
        let ready = Choice.Candidate(key: "phonon", isInstalled: true, allowedNow: true)
        XCTAssertEqual(Choice.choose(termsAccepted: false, candidate: ready), .iPhone(.termsNotAccepted))
        XCTAssertEqual(Choice.choose(termsAccepted: false, candidate: nil), .iPhone(.termsNotAccepted))
    }

    func testAfterTheTermsAReadyChosenVoiceReads() {
        XCTAssertEqual(Choice.choose(termsAccepted: true, candidate: .init(key: "phonon", isInstalled: true, allowedNow: true)), .onDevice(key: "phonon"))
    }

    func testNoSelectionVoiceMissingAndNotAllowedAllFallBackToTheIPhoneVoice() {
        XCTAssertEqual(Choice.choose(termsAccepted: true, candidate: nil), .iPhone(.noSelection))
        XCTAssertEqual(Choice.choose(termsAccepted: true, candidate: .init(key: "k", isInstalled: false, allowedNow: true)), .iPhone(.voiceMissing))
        XCTAssertEqual(Choice.choose(termsAccepted: true, candidate: .init(key: "k", isInstalled: true, allowedNow: false)), .iPhone(.notAllowedNow))
    }

    func testOnlyEnglishLatinNotesGoToTheOnDeviceVoice() {
        XCTAssertTrue(Choice.onDeviceCanRead("Lovely harbour."))
        XCTAssertTrue(Choice.onDeviceCanRead("Ha! Yes."), "a short note's language can't be told: it is read")
        XCTAssertFalse(Choice.onDeviceCanRead("これは日本語のメモです。"))
        XCTAssertFalse(Choice.onDeviceCanRead("Привет, это заметка"))
        XCTAssertFalse(Choice.onDeviceCanRead("Hola, me encantó este episodio, muchas gracias por compartirlo conmigo ayer."))
        XCTAssertTrue(Choice.onDeviceCanRead("I loved this episode, thank you so much for sharing it with me yesterday."))
    }

    #if canImport(AVFoundation)
    // MARK: The render, with real files

    private var directory: URL!
    private var voiceOutput: URL! // where an on-device voice writes its own files, as Supertonic does (not the reader's folder)
    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "WrittenMarginOnDeviceVoiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        directory = root.appending(path: "readings", directoryHint: .isDirectory)
        voiceOutput = root.appending(path: "voice-output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: voiceOutput, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var onDevice = 0, iPhone = 0
        var onDeviceCount: Int { lock.withLock { onDevice } }
        var iPhoneCount: Int { lock.withLock { iPhone } }
        func hitOnDevice() { lock.withLock { onDevice += 1 } }
        func hitIPhone() { lock.withLock { iPhone += 1 } }
    }

    private static func write(_ words: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "speech-\(UUID().uuidString).caf")
        try Data(words.utf8).write(to: file)
        return file
    }

    private func reader(_ calls: Calls, retryOnDeviceAfter: TimeInterval = 120, iPhone: (@Sendable (String, URL) throws -> URL)? = nil) -> WrittenMarginReader {
        WrittenMarginReader(
            directory: directory,
            retryOnDeviceAfter: retryOnDeviceAfter,
            renderAudio: { text, scratch in
                calls.hitIPhone()
                if let iPhone { return try iPhone(text, scratch) }
                return try Self.write("iphone: \(text)", in: scratch)
            }
        )
    }

    /// An on-device voice whose render writes to `voiceOutput`, like the real one.
    private func stage(_ calls: Calls, key: String = "phonon", budget: TimeInterval = 1, mostCharacters: Int = 300,
                       reads: @escaping @Sendable (String) -> Bool = WrittenMarginVoiceChoice.onDeviceCanRead,
                       allowed: @escaping @Sendable () -> Bool = { true },
                       render: @escaping @Sendable (String, RenderCancellation) throws -> URL) -> WrittenMarginOnDeviceStage {
        WrittenMarginOnDeviceStage(key: key, budget: budget, mostCharacters: mostCharacters, reads: reads, isAllowed: allowed, render: { text, _, cancel in
            calls.hitOnDevice()
            return try render(text, cancel)
        })
    }

    private func speaking(_ voiceOutput: URL) -> @Sendable (String, RenderCancellation) throws -> URL {
        { text, _ in try Self.write("on-device: \(text)", in: voiceOutput) }
    }

    private func allFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".caf") }
    }
    private func leftInVoiceOutput() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: voiceOutput.path)) ?? [] }

    private func text(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }

    private let reading = WrittenMarginReading(intro: "Cole wrote:", text: "Lovely harbour, worth the climb.", itemId: "item-1")

    func testAReadyOnDeviceVoiceReadsAndTheIPhoneVoiceIsNotUsed() async throws {
        let calls = Calls()
        let reader = reader(calls)
        let voice = stage(calls, render: speaking(voiceOutput))
        let file = try await reader.rendered(reading, onDevice: voice)
        XCTAssertEqual(try text(file), "on-device: Cole wrote: Lovely harbour, worth the climb.", "introduced as the sender's words")
        XCTAssertEqual(calls.iPhoneCount, 0)
        XCTAssertEqual(file, reader.fileURL(for: reading, onDevice: voice))
        XCTAssertEqual(reader.playbackState(for: reading, onDevice: voice).file, file)
        XCTAssertTrue(reader.playbackState(for: reading, onDevice: voice).isReady)
        XCTAssertEqual(leftInVoiceOutput(), [], "the voice's own file moved into place; none is left where it wrote it")
    }

    func testTheOnDeviceVoiceAndTheIPhoneVoiceKeepSeparateFiles() {
        let reader = reader(Calls())
        let voice = stage(Calls()) { _, _ in throw CancellationError() }
        XCTAssertNotEqual(reader.fileURL(for: reading), reader.fileURL(for: reading, onDevice: voice))
        let other = stage(Calls(), key: "lily") { _, _ in throw CancellationError() }
        XCTAssertNotEqual(reader.fileURL(for: reading, onDevice: voice), reader.fileURL(for: reading, onDevice: other))
    }

    // Bug 2: the iPhone voice's fallback was saved under the on-device name and served as the on-device voice forever.
    func testAFallbackIsSavedAtTheIPhonePathNeverTheOnDeviceOne() async throws {
        let calls = Calls()
        let reader = reader(calls, retryOnDeviceAfter: 0.3)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let cold = stage(calls, budget: 0.2) { _, cancel in
            release.wait() // a cold model still loading
            throw CancellationError()
        }
        let began = Date()
        let file = try await reader.rendered(reading, onDevice: cold)
        XCTAssertLessThan(Date().timeIntervalSince(began), 3)
        XCTAssertEqual(try text(file), "iphone: Cole wrote: Lovely harbour, worth the climb.", "never silence")
        XCTAssertEqual(file, reader.fileURL(for: reading), "the file's path says the iPhone voice made it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: reader.fileURL(for: reading, onDevice: cold).path), "nothing is saved under the on-device name")
        XCTAssertEqual(reader.playbackState(for: reading, onDevice: cold).file, file, "a moment later it is played as it is")
        release.signal()
        // Once the voice is warm and the retry time has passed, the same Margin is read by the on-device voice.
        try await Task.sleep(for: .milliseconds(400))
        let warm = stage(calls, render: speaking(voiceOutput))
        let state = reader.playbackState(for: reading, onDevice: warm)
        XCTAssertFalse(state.isReady, "the iPhone reading is no longer taken for the on-device voice's")
        let again = try await reader.rendered(reading, onDevice: warm)
        XCTAssertEqual(try text(again), "on-device: Cole wrote: Lovely harbour, worth the climb.")
        XCTAssertNotEqual(again, file)
    }

    func testALateRenderNeverHoldsTheVoiceBesideAnotherAttemptWhateverTheVoice() async throws {
        let out = voiceOutput!
        let calls = Calls()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let reader = reader(calls)
        let slow = stage(calls, key: "phonon", budget: 0.2) { _, _ in release.wait(); return try Self.write("late", in: out) }
        _ = try await reader.rendered(reading, onDevice: slow)
        let second = WrittenMarginReading(intro: "Cole wrote:", text: "Another note about the harbour.", itemId: "item-1")
        let otherVoice = stage(calls, key: "lily", render: speaking(voiceOutput)) // the listener changed voice meanwhile
        let file = try await reader.rendered(second, onDevice: otherVoice)
        XCTAssertEqual(calls.onDeviceCount, 1, "no second on-device render started while the first still held its model")
        XCTAssertTrue(try text(file).hasPrefix("iphone:"))
        release.signal()
        let deadline = Date().addingTimeInterval(5)
        while !leftInVoiceOutput().isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(leftInVoiceOutput(), [], "a render that came back after it was given up on is deleted, not kept")
    }

    func testAFailedOnDeviceRenderFallsBackToTheIPhoneVoice() async throws {
        struct Broken: Error {}
        let calls = Calls()
        let reader = reader(calls)
        let file = try await reader.rendered(reading, onDevice: stage(calls) { _, _ in throw Broken() })
        XCTAssertTrue(try text(file).hasPrefix("iphone:"))
        XCTAssertEqual(calls.onDeviceCount, 1)
    }

    func testAVoiceThatMadeNoFileFallsBack() async throws {
        let out = voiceOutput!
        let calls = Calls()
        let reader = reader(calls)
        let voice = stage(calls) { _, _ in out.appending(path: "never-written.caf") }
        let file = try await reader.rendered(reading, onDevice: voice)
        XCTAssertTrue(try text(file).hasPrefix("iphone:"))
    }

    func testANoteTheOnDeviceVoiceCannotReadGoesStraightToTheIPhoneVoice() async throws {
        let calls = Calls()
        let reader = reader(calls)
        let japanese = WrittenMarginReading(intro: "Cole wrote:", text: "これは日本語のメモです。", itemId: "item-1")
        let voice = stage(calls, render: speaking(voiceOutput))
        let file = try await reader.rendered(japanese, onDevice: voice)
        XCTAssertEqual(calls.onDeviceCount, 0)
        XCTAssertEqual(calls.iPhoneCount, 1)
        XCTAssertEqual(file, reader.fileURL(for: japanese))
        XCTAssertTrue(reader.playbackState(for: japanese, onDevice: voice).isReady, "its playback state is the iPhone reading, not an on-device one that never comes")
    }

    // Bug 3: a hot, low-memory or missing voice must not be asked to render; every voice obeys the same block.
    func testAVoiceTheGovernorOrTheDiskBlocksIsNeverAskedToRender() async throws {
        let calls = Calls()
        let reader = reader(calls)
        let blocked = stage(calls, allowed: { false }, render: speaking(voiceOutput))
        let file = try await reader.rendered(reading, onDevice: blocked)
        XCTAssertEqual(calls.onDeviceCount, 0, "the render was never started")
        XCTAssertEqual(calls.iPhoneCount, 1)
        XCTAssertTrue(try text(file).hasPrefix("iphone:"))
    }

    // Bug 4: opening a screen prepares readings, and that must never run the on-device model.
    func testPreparingReadingsWhenAScreenOpensUsesTheIPhoneVoiceOnly() async {
        let calls = Calls()
        let reader = reader(calls)
        let voice = stage(calls, render: speaking(voiceOutput))
        let urls = reader.start(["a": reading])
        XCTAssertEqual(urls["a"], reader.fileURL(for: reading))
        await reader.waitUntilSettled([reading], upTo: 5)
        XCTAssertEqual(calls.onDeviceCount, 0)
        XCTAssertEqual(calls.iPhoneCount, 1)
        // Then the listener plays it: the on-device voice is tried for that one Margin, since it was not made by that voice.
        let state = reader.playbackState(for: reading, onDevice: voice)
        XCTAssertFalse(state.isReady, "an iPhone reading made ahead is not the on-device voice's")
    }

    // Bug 5: a skip must not poison the readers still waiting, and a retap must get a real reading.
    func testASkipLeavesARenderSomeoneElseStillWaitsFor() async throws {
        let out = voiceOutput!
        let calls = Calls()
        let reader = reader(calls)
        let started = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)
        let voice = stage(calls, budget: 30) { text, cancel in
            started.signal()
            while go.wait(timeout: .now() + 0.01) == .timedOut { if cancel.isCancelled { throw CancellationError() } }
            return try Self.write("on-device: \(text)", in: out)
        }
        let reading = self.reading
        let first = Task { try await reader.rendered(reading, onDevice: voice) }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        let second = Task { try await reader.rendered(reading, onDevice: voice) } // the retap joins the same render
        try await Task.sleep(for: .milliseconds(100))
        first.cancel() // Next Margin
        do { _ = try await first.value; XCTFail("the skipped wait ends") } catch is CancellationError {}
        go.signal()
        let file = try await second.value
        XCTAssertEqual(try text(file), "on-device: Cole wrote: Lovely harbour, worth the climb.", "the other waiter got its reading")
        XCTAssertEqual(calls.onDeviceCount, 1)
    }

    func testASkipWithNoOneElseWaitingStopsTheVoiceKeepsNoFileAndARetapGetsARealReading() async throws {
        let calls = Calls()
        let reader = reader(calls)
        let started = DispatchSemaphore(value: 0)
        let stopped = Calls()
        let voice = stage(calls, budget: 30) { _, cancel in
            started.signal()
            while !cancel.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
            stopped.hitOnDevice() // the voice saw the stop
            throw CancellationError()
        }
        let reading = self.reading
        let render = Task { try await reader.rendered(reading, onDevice: voice) }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        render.cancel()
        do { _ = try await render.value; XCTFail("a skipped wait ends") } catch is CancellationError {}
        XCTAssertEqual(calls.iPhoneCount, 0, "a skip is not a failure: no iPhone render starts for it")
        XCTAssertTrue(allFiles().isEmpty)
        XCTAssertFalse(reader.isReady(reading))
        let deadline = Date().addingTimeInterval(5)
        while stopped.onDeviceCount == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(stopped.onDeviceCount, 1)
        // The retap: a fresh ask is not joined to the dying render, and reads (here in the iPhone voice, which is what an
        // on-device voice that is still unwinding gives way to).
        let again = try await reader.rendered(reading, onDevice: stage(calls, render: speaking(voiceOutput)))
        XCTAssertFalse(try text(again).isEmpty)
    }

    // Bug 1: an item deleted for good while it renders leaves none of its words on disk, whichever voice was reading.
    func testAPermanentDeleteDuringAnOnDeviceRenderLeavesNoFile() async throws {
        let out = voiceOutput!
        let calls = Calls()
        let reader = reader(calls)
        let started = DispatchSemaphore(value: 0)
        let go = DispatchSemaphore(value: 0)
        let voice = stage(calls, budget: 30) { text, _ in
            started.signal()
            go.wait()
            return try Self.write("on-device: \(text)", in: out)
        }
        let reading = self.reading
        let render = Task { try await reader.rendered(reading, onDevice: voice) }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        reader.removeReadings(forItem: reading.itemId, leveled: nil)
        go.signal()
        do { _ = try await render.value; XCTFail("a deleted item's reading is not made") } catch {}
        _ = await reader.settle(upTo: 5)
        XCTAssertTrue(allFiles().isEmpty, "no reading of the deleted item is on disk: \(allFiles())")
        XCTAssertEqual(leftInVoiceOutput(), [], "and the voice's own file is gone too")
    }

    func testAPermanentDeleteDuringTheIPhoneFallbackLeavesNoFileEither() async throws {
        let calls = Calls()
        let phoneStarted = DispatchSemaphore(value: 0)
        let phoneGo = DispatchSemaphore(value: 0)
        let reader = reader(calls) { text, scratch in
            phoneStarted.signal()
            phoneGo.wait()
            return try Self.write("iphone: \(text)", in: scratch)
        }
        let voice = stage(calls, budget: 0.1) { _, _ in throw CancellationError() } // gives up at once: the iPhone voice reads
        let reading = self.reading
        let render = Task { try await reader.rendered(reading, onDevice: voice) }
        XCTAssertEqual(phoneStarted.wait(timeout: .now() + 5), .success)
        reader.removeReadings(forItem: reading.itemId, leveled: nil)
        phoneGo.signal()
        do { _ = try await render.value; XCTFail("a deleted item's reading is not made") } catch {}
        _ = await reader.settle(upTo: 5)
        XCTAssertTrue(allFiles().isEmpty, "no reading of the deleted item is on disk: \(allFiles())")
    }

    // MARK: The seam between what a caller is handed and what is written (round two)

    private func waitUntilExists(_ file: URL, upTo seconds: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return FileManager.default.fileExists(atPath: file.path)
    }

    // A: the player is only ever given a file that exists or that a render is writing at exactly that path.
    func testACallerThatCannotWaitIsNeverHandedAPathNoRenderWrites() async throws {
        let calls = Calls()
        let reader = reader(calls)
        let voice = stage(calls, render: speaking(voiceOutput))
        let audio = SharedMarginAudio.readingRendering(reading, file: reader.playbackState(for: reading, onDevice: voice).file)
        let handed = try XCTUnwrap(audio.startingRender(on: reader, onDevice: voice))
        XCTAssertNotEqual(handed, reader.fileURL(for: reading, onDevice: voice), "the on-device path is not named while nothing writes it")
        let appeared = await waitUntilExists(handed)
        XCTAssertTrue(appeared, "the file it was handed appears")
        XCTAssertEqual(calls.onDeviceCount, 0, "a caller that cannot wait starts no on-device render")
        XCTAssertTrue(try text(handed).hasPrefix("iphone:"))
    }

    func testTheFileAWaitReturnsIsTheFileTheNextAskNames_WhateverVoiceMadeIt() async throws {
        let calls = Calls()
        let reader = reader(calls)
        let cold = stage(calls, budget: 0.1) { _, _ in throw CancellationError() }
        let fell = try await reader.rendered(reading, onDevice: cold) // the fallback
        let afterFall = SharedMarginAudio.readingRendering(reading, file: fell)
        XCTAssertEqual(afterFall.startingRender(on: reader, onDevice: cold), fell)
        XCTAssertTrue(reader.playbackState(for: reading, onDevice: cold).isReady)
        let warm = stage(calls, key: "lily", render: speaking(voiceOutput))
        let other = WrittenMarginReading(intro: "Cole wrote:", text: "A second note.", itemId: "item-1")
        let made = try await reader.rendered(other, onDevice: warm) // on-device success
        let state = reader.playbackState(for: other, onDevice: warm)
        XCTAssertEqual(state.file, made)
        XCTAssertTrue(state.isReady)
        XCTAssertEqual(SharedMarginAudio.readingRendering(other, file: state.file).startingRender(on: reader, onDevice: warm), made)
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path))
    }

    // B: the first hearing of a note is the chosen voice's. An iPhone reading made ahead is not taken for it, and nothing
    // is rendered ahead in a voice nobody will hear.
    func testAnIPhoneReadingMadeAheadIsNotTheFirstHearingOfAnOnDeviceListener() async throws {
        let calls = Calls()
        let reader = reader(calls)
        let voice = stage(calls, render: speaking(voiceOutput))
        reader.prepareAhead(["a": reading], onDevice: nil) // before the Terms, or no voice chosen
        _ = await reader.settle(upTo: 5)
        XCTAssertEqual(calls.iPhoneCount, 1)
        XCTAssertTrue(reader.wantsOnDevice(reading, stage: voice), "the first hearing waits for the chosen voice")
        let file = try await reader.rendered(reading, onDevice: voice)
        XCTAssertTrue(try text(file).hasPrefix("on-device:"))
        XCTAssertFalse(reader.wantsOnDevice(reading, stage: voice))
    }

    func testOpeningAScreenRendersAheadOnlyWhatTheIPhoneVoiceWillRead() async throws {
        let calls = Calls()
        let reader = reader(calls)
        let voice = stage(calls, mostCharacters: 60, render: speaking(voiceOutput))
        let japanese = WrittenMarginReading(intro: "Cole wrote:", text: "これは日本語のメモです。", itemId: "item-1")
        let long = WrittenMarginReading(intro: "Cole wrote:", text: String(repeating: "A long note about the harbour. ", count: 4), itemId: "item-1")
        reader.prepareAhead(["short": reading, "ja": japanese, "long": long], onDevice: voice)
        let deadline = Date().addingTimeInterval(5)
        while calls.iPhoneCount < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        _ = await reader.settle(upTo: 5)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(calls.iPhoneCount, 2, "the unreadable-by-voice and the too-long notes only")
        XCTAssertEqual(calls.onDeviceCount, 0, "opening a screen never runs the on-device voice")
        XCTAssertFalse(reader.isReady(reading), "the short English note is left for the chosen voice")
        XCTAssertTrue(reader.isReady(japanese))
        XCTAssertTrue(reader.isReady(long))
    }

    // Item 4: the voice takes on only what its short budget can do; a longer note is the iPhone voice's from the start.
    func testANoteLongerThanTheVoiceTakesOnIsReadByTheIPhoneVoiceWithNoOnDeviceRender() async throws {
        let calls = Calls()
        let reader = reader(calls)
        let voice = stage(calls, mostCharacters: 20, render: speaking(voiceOutput))
        XCTAssertFalse(reader.wantsOnDevice(reading, stage: voice))
        let file = try await reader.rendered(reading, onDevice: voice)
        XCTAssertEqual(calls.onDeviceCount, 0)
        XCTAssertEqual(file, reader.fileURL(for: reading))
        XCTAssertTrue(reader.playbackState(for: reading, onDevice: voice).isReady)
    }

    // C: no on-device render without a listener waiting on it.
    func testLeavingAReviewStopsTheOnDeviceRendersNobodyWaitsFor() async throws {
        let calls = Calls()
        let reader = reader(calls)
        let stopped = Calls()
        let started = DispatchSemaphore(value: 0)
        let voice = stage(calls, budget: 30) { _, cancel in
            started.signal()
            while !cancel.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
            stopped.hitOnDevice()
            throw CancellationError()
        }
        let notes = (1...5).map { WrittenMarginReading(intro: "Cole wrote:", text: "Note number \($0) about the harbour.", itemId: "item-1") }
        let hold = Task { await reader.waitUntilSettled(notes, upTo: 30, onDevice: voice) }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        hold.cancel() // the listener backed out of the screen
        await hold.value
        let deadline = Date().addingTimeInterval(5)
        while stopped.onDeviceCount == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(stopped.onDeviceCount, 1, "the render that was running saw the stop")
        _ = await reader.settle(upTo: 5)
        XCTAssertEqual(calls.onDeviceCount, 1, "the four queued behind it never started")
        XCTAssertEqual(calls.iPhoneCount, 0)
        XCTAssertTrue(allFiles().isEmpty)
    }

    func testAHoldThatRunsOutLeavesTheRendersItStartedAndAskedFor() async throws {
        let calls = Calls()
        let reader = reader(calls)
        let stopped = Calls()
        let started = DispatchSemaphore(value: 0)
        let voice = stage(calls, budget: 30) { _, cancel in
            started.signal()
            while !cancel.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
            stopped.hitOnDevice()
            throw CancellationError()
        }
        let notes = (1...3).map { WrittenMarginReading(intro: "Cole wrote:", text: "Note number \($0) about the harbour.", itemId: "item-1") }
        await reader.waitUntilSettled(notes, upTo: 0.3, onDevice: voice)
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        let deadline = Date().addingTimeInterval(5)
        while stopped.onDeviceCount == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(stopped.onDeviceCount, 1)
        _ = await reader.settle(upTo: 5)
        XCTAssertEqual(calls.onDeviceCount, 1)
    }

    // Item 5: the language of a note is never worked out by a caller on the main thread.
    func testTheLanguageGateIsNeverAskedOnTheMainThread() async throws {
        let calls = Calls()
        let reader = reader(calls)
        let askedOnMain = Calls()
        let asked = Calls()
        let voice = stage(calls, reads: { _ in
            asked.hitOnDevice()
            if Thread.isMainThread { askedOnMain.hitOnDevice() }
            return true
        }, render: speaking(voiceOutput))
        let reading = self.reading
        await MainActor.run {
            _ = reader.playbackState(for: reading, onDevice: voice)
            _ = reader.wantsOnDevice(reading, stage: voice)
            _ = reader.start(["a": reading], onDevice: voice)
        }
        _ = await reader.settle(upTo: 5)
        XCTAssertEqual(asked.onDeviceCount, 0, "asking what plays looks at no language")
        _ = try await reader.rendered(reading, onDevice: voice)
        XCTAssertGreaterThan(asked.onDeviceCount, 0, "the render thread looked")
        XCTAssertEqual(askedOnMain.onDeviceCount, 0)
    }
    #endif
}
