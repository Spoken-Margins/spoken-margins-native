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
