import AVFoundation
import SessionKit
import SessionKitAudio
import SessionKitSupertonic
import XCTest

/// `SupertonicOutputGuard` on the host (#318). #1695: the guard's Diagnostics line says how long the iOS voice's stand-in
/// write took, written or failed, and whether it was the first of the launch. The clock is the test's own, advanced by
/// the fake write, so the elapsed time is exact and nothing waits on Apple's speech service.
final class SupertonicOutputGuardTests: XCTestCase {
    private let babbleText = "Table 3 reports 91.1% 8.9% 0.0 and 7,494 tool decisions across 2,548 summaries."
    private let proseText = "The committee reads the report aloud before the vote begins today."

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 1_000
        func read() -> TimeInterval { lock.withLock { seconds } }
        func advance(_ by: TimeInterval) { lock.withLock { seconds += by } }
    }

    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        var values: [String] { lock.withLock { entries } }
        func add(_ report: String) { lock.withLock { entries.append(report) } }
    }

    /// Returns audio of a set length for any text; deletes only files it made, like the real renderer. Twenty seconds
    /// for the babble text is the babble signature the guard replaces.
    private actor FixedLengthRenderer: SupertonicRendering {
        let template: URL
        let seconds: TimeInterval
        nonisolated let engine: String
        private var generated: Set<URL> = []
        init(template: URL, seconds: TimeInterval, engine: String = SupertonicNarrationResult.supertonicEngine) {
            self.template = template; self.seconds = seconds; self.engine = engine
        }
        func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
            let url = FileManager.default.temporaryDirectory.appending(path: "timing-\(UUID().uuidString).wav")
            try FileManager.default.copyItem(at: template, to: url)
            generated.insert(url)
            return SupertonicNarrationResult(audioURL: url, duration: seconds, sampleRate: 44_100, renderDuration: 0.01, sessionLoadCount: 1, engine: engine)
        }
        func discardGeneratedAudio(at url: URL) async {
            if generated.remove(url) != nil { try? FileManager.default.removeItem(at: url) }
        }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "guard-timing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func template() throws -> URL {
        let url = root.appending(path: "t.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)); buffer.frameLength = 44_100
        try file.write(from: buffer)
        return url
    }

    private func makeGuard(
        seconds: TimeInterval, clock: Clock, log: StandInWriteLog, reports: Reports,
        standIn: @escaping SupertonicOutputGuard.StandInRender
    ) throws -> SupertonicOutputGuard {
        SupertonicOutputGuard(
            wrapping: FixedLengthRenderer(template: try template(), seconds: seconds), systemVoiceIdentifier: nil,
            onReplacement: { reports.add($0) }, standIn: standIn, writeLog: log, now: { clock.read() }
        )
    }

    private func render(_ guardRenderer: SupertonicOutputGuard, text: String) async throws {
        let result = try await guardRenderer.render(text: text, voice: .m2, language: "en", speed: 1, synthesisSteps: 8)
        await guardRenderer.discardGeneratedAudio(at: result.audioURL)
    }

    func testAWrittenStandInReportsHowLongTheWriteTook() async throws {
        let clock = Clock()
        let reports = Reports()
        let guardRenderer = try makeGuard(seconds: 20, clock: clock, log: StandInWriteLog(), reports: reports) { _, _, reference, output in
            clock.advance(2.5)
            try FileManager.default.copyItem(at: reference, to: output)
            return 1
        }

        try await render(guardRenderer, text: babbleText)

        let report = try XCTUnwrap(reports.values.first)
        XCTAssertTrue(report.contains("last system_voice:"), report)
        XCTAssertTrue(report.contains("iOS voice first write this launch took 2.50 s"), report)
    }

    func testATimedOutWriteReportsHowLongItWaitedAndKeepsSupertonic() async throws {
        let clock = Clock()
        let reports = Reports()
        let guardRenderer = try makeGuard(seconds: 20, clock: clock, log: StandInWriteLog(), reports: reports) { _, _, _, _ in
            clock.advance(30)
            throw SystemVoiceChunkRenderer.Failure.timedOut
        }

        let result = try await guardRenderer.render(text: babbleText, voice: .m2, language: "en", speed: 1, synthesisSteps: 8)
        await guardRenderer.discardGeneratedAudio(at: result.audioURL)

        XCTAssertNotEqual(result.engine, SupertonicNarrationResult.systemVoiceEngine, "the Supertonic chunk stays")
        let report = try XCTUnwrap(reports.values.first)
        XCTAssertTrue(report.contains("kept_supertonic:"), report)
        XCTAssertTrue(report.contains("system_voice_failed"), report)
        XCTAssertTrue(report.contains("iOS voice first write this launch took 30.00 s"), report)
    }

    func testOnlyTheFirstWriteOfALaunchIsCalledFirst() async throws {
        let clock = Clock()
        let reports = Reports()
        let guardRenderer = try makeGuard(seconds: 20, clock: clock, log: StandInWriteLog(), reports: reports) { _, _, reference, output in
            clock.advance(0.25)
            try FileManager.default.copyItem(at: reference, to: output)
            return 1
        }

        try await render(guardRenderer, text: babbleText)
        try await render(guardRenderer, text: babbleText)

        let values = reports.values
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values[0].contains("first write this launch took 0.25 s"), values[0])
        XCTAssertTrue(values[1].contains("write 2 this launch took 0.25 s"), values[1])
        XCTAssertFalse(values[1].contains("first"), values[1])
    }

    func testAChunkThatPassesTheCheckStartsNoWriteAndReportsNothing() async throws {
        let clock = Clock()
        let reports = Reports()
        let log = StandInWriteLog()
        let guardRenderer = try makeGuard(seconds: 5, clock: clock, log: log, reports: reports) { _, _, _, _ in
            XCTFail("a good chunk was re-read by the iOS voice")
            return 1
        }

        try await render(guardRenderer, text: proseText)

        XCTAssertTrue(reports.values.isEmpty)
        XCTAssertEqual(log.writeStarted(), 1, "no write was counted")
    }

    func testTheReportCarriesNoArticleText() async throws {
        let clock = Clock()
        let reports = Reports()
        let guardRenderer = try makeGuard(seconds: 20, clock: clock, log: StandInWriteLog(), reports: reports) { _, _, reference, output in
            try FileManager.default.copyItem(at: reference, to: output)
            return 1
        }

        try await render(guardRenderer, text: babbleText)

        let report = try XCTUnwrap(reports.values.first)
        XCTAssertFalse(report.contains("Table"), report)
        XCTAssertFalse(report.contains("summaries"), report)
    }

    /// The guard's tests that used to run in the app (#318): a stand-in that copies the Supertonic chunk, already in
    /// its format, so nothing waits on Apple's speech service (#1688).
    private let copyStandIn: SupertonicOutputGuard.StandInRender = { _, _, reference, output in
        try FileManager.default.copyItem(at: reference, to: output)
        let file = try AVAudioFile(forReading: output)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // #311: the guard's iOS-voice file is deleted when the player discards it.
    func testGuardDeletesItsStandInFileOnDiscard() async throws {
        let guardRenderer = SupertonicOutputGuard(
            wrapping: FixedLengthRenderer(template: try template(), seconds: 20), systemVoiceIdentifier: nil, standIn: copyStandIn
        )
        let result = try await guardRenderer.render(text: babbleText, voice: .m2, language: "en", speed: 1, synthesisSteps: 8)
        XCTAssertTrue(result.audioURL.lastPathComponent.hasPrefix("system-voice-"), "the guard stood in")
        XCTAssertEqual(result.engine, SupertonicNarrationResult.systemVoiceEngine)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.audioURL.path))
        await guardRenderer.discardGeneratedAudio(at: result.audioURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.audioURL.path), "the stand-in file is deleted")
    }

    // #288: a render that timed out was still checked when it finished, and a flagged chunk was
    // written by a second speech synthesizer while the iOS voice read the article live. The live
    // voice then went silent. A render nobody waits for is dropped instead of re-read.
    /// The stand-in fails at once rather than asking the real iOS voice, so a regression fails here without waiting
    /// on Apple's speech service.
    func testACancelledRenderIsNotReadByTheIOSVoice() async throws {
        let reports = Reports()
        let guardRenderer = SupertonicOutputGuard(
            wrapping: FixedLengthRenderer(template: try template(), seconds: 20), systemVoiceIdentifier: nil,
            onReplacement: { reports.add($0) },
            standIn: { _, _, _, _ in
                XCTFail("a cancelled render was handed to the iOS voice")
                throw CancellationError()
            }
        )
        let text = babbleText
        let render = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await guardRenderer.render(text: text, voice: .m2, language: "en", speed: 1, synthesisSteps: 8)
        }
        do {
            let result = try await render.value
            XCTFail("a cancelled render was read by the iOS voice: \(result.audioURL.lastPathComponent)")
            await guardRenderer.discardGeneratedAudio(at: result.audioURL)
        } catch is CancellationError {
        }
        XCTAssertTrue(reports.values.isEmpty, "no stand-in was made: \(reports.values)")
    }

    // #363 audit: background preparation made a guard per chunk and never discarded its render, so
    // every flagged chunk left an iOS-voice file behind. The render is discarded once kept, or on
    // failure.
    /// The guard gets its own write log and a fixed clock (#2386), so nothing here reads the device's uptime or
    /// shares a count with other tests; a failure means a render was kept or leaked.
    func testABackgroundRenderIsDiscardedOnceKeptOrOnFailure() async throws {
        let guardRenderer = SupertonicOutputGuard(
            wrapping: FixedLengthRenderer(template: try template(), seconds: 20), systemVoiceIdentifier: nil, standIn: copyStandIn,
            writeLog: StandInWriteLog(), now: { 0 }
        )
        var standIn: URL?
        let kept = try await guardRenderer.render(text: babbleText, voice: .m2, language: "en", speed: 1, synthesisSteps: 8) { rendered in
            standIn = rendered.audioURL
            let copy = root.appending(path: "kept.wav")
            try FileManager.default.copyItem(at: rendered.audioURL, to: copy)
            return copy
        }
        XCTAssertTrue(try XCTUnwrap(standIn).lastPathComponent.hasPrefix("system-voice-"), "the guard stood in")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(standIn).path), "the stand-in is deleted once kept")

        do {
            _ = try await guardRenderer.render(text: babbleText, voice: .m2, language: "en", speed: 1, synthesisSteps: 8) { rendered -> URL in
                standIn = rendered.audioURL
                throw CancellationError()
            }
            XCTFail("the failure is rethrown")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(standIn).path), "and on failure")
    }

    /// Supertonic's babble check (#240) is tuned to Supertonic's pacing; a slower voice must not be swapped for the iOS
    /// voice by it, and the guard must keep reporting the inner renderer's engine. The app's version of this test read
    /// "Hi.", too short for the check to judge, so it passed with the engine rule removed; the babble text, which the
    /// check flags for Supertonic, only passes because of that rule (#318).
    func testTheSupertonicOutputGuardPassesAnotherEnginesAudioThroughUnchecked() async throws {
        let reports = Reports()
        let guarded = SupertonicOutputGuard(
            wrapping: FixedLengthRenderer(template: try template(), seconds: 20, engine: "phonon"),
            systemVoiceIdentifier: nil,
            onReplacement: { reports.add($0) },
            standIn: { _, _, _, _ in XCTFail("the iOS voice was asked"); return 0 },
            writeLog: StandInWriteLog(),
            now: { 0 }
        )
        XCTAssertEqual(guarded.engine, "phonon")
        let result = try await guarded.render(text: babbleText, voice: .m2, language: "en", speed: 1, synthesisSteps: 8)
        await guarded.discardGeneratedAudio(at: result.audioURL)
        XCTAssertEqual(result.engine, "phonon")
        XCTAssertTrue(reports.values.isEmpty)
    }
}
