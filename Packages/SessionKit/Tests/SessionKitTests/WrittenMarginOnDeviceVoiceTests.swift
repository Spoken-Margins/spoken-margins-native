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
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "WrittenMarginOnDeviceVoiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var onDevice = 0, iPhone = 0
        var onDeviceCount: Int { lock.withLock { onDevice } }
        var iPhoneCount: Int { lock.withLock { iPhone } }
        func hitOnDevice() { lock.withLock { onDevice += 1 } }
        func hitIPhone() { lock.withLock { iPhone += 1 } }
    }

    private static func write(_ words: String, in scratch: URL) throws -> URL {
        let file = scratch.appending(path: "speech-\(UUID().uuidString).caf")
        try Data(words.utf8).write(to: file)
        return file
    }

    private func reader(_ calls: Calls, budget: TimeInterval = 1, onDevice: @escaping @Sendable (String, URL, RenderCancellation) throws -> URL) -> WrittenMarginReader {
        WrittenMarginReader(
            directory: directory,
            onDevice: WrittenMarginOnDeviceStage(key: "phonon", budget: budget, render: { text, scratch, cancel in
                calls.hitOnDevice()
                return try onDevice(text, scratch, cancel)
            }),
            renderAudio: { text, scratch in calls.hitIPhone(); return try Self.write("iphone: \(text)", in: scratch) }
        )
    }

    private let reading = WrittenMarginReading(intro: "Cole wrote:", text: "Lovely harbour, worth the climb.", itemId: "item-1")

    func testAReadyOnDeviceVoiceReadsAndTheIPhoneVoiceIsNotUsed() async throws {
        let calls = Calls()
        let reader = reader(calls) { text, scratch, _ in try Self.write("on-device: \(text)", in: scratch) }
        let file = try await reader.rendered(reading)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "on-device: Cole wrote: Lovely harbour, worth the climb.", "introduced as the sender's words")
        XCTAssertEqual(calls.iPhoneCount, 0)
    }

    func testTheOnDeviceVoiceAndTheIPhoneVoiceKeepSeparateFiles() {
        let plain = WrittenMarginReader(directory: directory, renderAudio: { _, _ in throw CancellationError() })
        let onDevice = reader(Calls()) { _, _, _ in throw CancellationError() }
        XCTAssertNotEqual(plain.fileURL(for: reading), onDevice.fileURL(for: reading))
    }

    func testASlowOnDeviceRenderGivesWayToTheIPhoneVoiceWithinTheBudget() async throws {
        let calls = Calls()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let reader = reader(calls, budget: 0.3) { _, scratch, _ in
            release.wait() // a cold model still loading
            return try Self.write("late", in: scratch)
        }
        let began = Date()
        let file = try await reader.rendered(reading)
        XCTAssertLessThan(Date().timeIntervalSince(began), 3)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "iphone: Cole wrote: Lovely harbour, worth the climb.", "never silence")
        XCTAssertEqual(calls.iPhoneCount, 1)
    }

    func testALateRenderNeverHoldsTheVoiceBesideAnotherAttempt() async throws {
        let calls = Calls()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let reader = reader(calls, budget: 0.2) { _, scratch, _ in release.wait(); return try Self.write("late", in: scratch) }
        _ = try await reader.rendered(reading)
        let second = WrittenMarginReading(intro: "Cole wrote:", text: "Another note about the harbour.", itemId: "item-1")
        let file = try await reader.rendered(second)
        XCTAssertEqual(calls.onDeviceCount, 1, "the second reading did not start another on-device render while the first was still running")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasPrefix("iphone:"))
    }

    func testAFailedOnDeviceRenderFallsBackToTheIPhoneVoice() async throws {
        struct Broken: Error {}
        let calls = Calls()
        let reader = reader(calls) { _, _, _ in throw Broken() }
        let file = try await reader.rendered(reading)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasPrefix("iphone:"))
        XCTAssertEqual(calls.onDeviceCount, 1)
    }

    func testAVoiceThatMadeNoFileFallsBack() async throws {
        let calls = Calls()
        let reader = reader(calls) { _, scratch, _ in scratch.appending(path: "never-written.caf") }
        let file = try await reader.rendered(reading)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasPrefix("iphone:"))
    }

    func testANoteTheOnDeviceVoiceCannotReadGoesStraightToTheIPhoneVoice() async throws {
        let calls = Calls()
        let reader = reader(calls) { _, scratch, _ in try Self.write("on-device", in: scratch) }
        let japanese = WrittenMarginReading(intro: "Cole wrote:", text: "これは日本語のメモです。", itemId: "item-1")
        _ = try await reader.rendered(japanese)
        XCTAssertEqual(calls.onDeviceCount, 0)
        XCTAssertEqual(calls.iPhoneCount, 1)
    }

    func testSkippingMidRenderStopsTheVoiceKeepsNoFileAndDoesNotFallBack() async throws {
        let calls = Calls()
        let started = DispatchSemaphore(value: 0)
        let stopped = Calls()
        let reader = reader(calls, budget: 30) { _, _, cancel in
            started.signal()
            while !cancel.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
            stopped.hitOnDevice() // the voice saw the stop
            throw CancellationError()
        }
        let reading = self.reading
        let render = Task { try await reader.rendered(reading) }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        reader.cancelOnDevice(reading)
        do { _ = try await render.value; XCTFail("a skipped render makes no reading") } catch is CancellationError {}
        XCTAssertEqual(calls.iPhoneCount, 0, "a skip is not a failure: no iPhone render starts")
        XCTAssertFalse(FileManager.default.fileExists(atPath: reader.fileURL(for: reading).path))
        XCTAssertFalse(reader.isReady(reading))
        let deadline = Date().addingTimeInterval(5)
        while stopped.onDeviceCount == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(stopped.onDeviceCount, 1)
    }
    #endif
}
