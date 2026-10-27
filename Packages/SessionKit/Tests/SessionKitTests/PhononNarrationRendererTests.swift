import AVFoundation
import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitSupertonic

/// #2704: Phonon through the narration-renderer seam, with a stand-in for Gradium's Neural Engine runtime (which
/// ships only in the app). What is checked here is ours: the WAV it writes, the engine name its audio carries,
/// loading once, the chosen voice, one render at a time, and the output checks.
final class PhononNarrationRendererTests: XCTestCase {
    private var bundle: URL!
    private var output: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "phonon-renderer-\(UUID().uuidString)", directoryHint: .isDirectory)
        bundle = base.appending(path: "bundle", directoryHint: .isDirectory)
        output = base.appending(path: "out", directoryHint: .isDirectory)
        for name in PhononModelLocation.requiredFiles {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: bundle.appending(path: name))
        }
        for package in PhononModelLocation.modelPackages {
            try FileManager.default.createDirectory(at: bundle.appending(path: package), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: bundle.appending(path: "voices"), withIntermediateDirectories: true)
        for voice in PhononVoice.voiceNames { try Data("v".utf8).write(to: bundle.appending(path: "voices/\(voice).safetensors")) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent())
    }

    private func renderer(voice: String = PhononVoice.defaultVoiceName, engine: FakePhonon) throws -> PhononNarrationRenderer {
        let loads = engine
        return try PhononNarrationRenderer(
            location: PhononModelLocation(rootURL: bundle), voiceName: voice, outputDirectory: output,
            governor: OnDeviceVoiceGovernor(), load: { _ in loads.loaded(); return loads })
    }

    func testRendersAParagraphToAWavFileUnderPhononsEngineName() async throws {
        let engine = FakePhonon()
        let phonon = try renderer(engine: engine)
        let result = try await phonon.render(text: "  The first paragraph.  ")
        XCTAssertEqual(result.engine, PhononVoice.engine, "the engine its saved audio is filed under")
        XCTAssertEqual(result.sampleRate, 24_000)
        XCTAssertEqual(engine.spoken, ["The first paragraph."])
        let file = try AVAudioFile(forReading: result.audioURL)
        XCTAssertEqual(file.fileFormat.sampleRate, 24_000)
        XCTAssertEqual(Double(file.length) / 24_000, result.duration, accuracy: 0.001)
        XCTAssertGreaterThan(result.trimmedSilence, 0.1, "the leading and trailing silence is cut as for Kitten")
    }

    func testLoadsOnceAndSwitchesToTheChosenVoiceBeforeTheFirstWord() async throws {
        let engine = FakePhonon()
        let phonon = try renderer(voice: "Pippa", engine: engine)
        _ = try await phonon.render(text: "One.")
        _ = try await phonon.render(text: "Two.")
        XCTAssertEqual(engine.loads, 1)
        XCTAssertEqual(engine.voicesSet, ["Pippa"])
        XCTAssertEqual(engine.voiceAtEachSpeak, ["Pippa", "Pippa"])
        let diagnostics = await phonon.diagnostics()
        XCTAssertEqual(diagnostics.sessionLoadCount, 1)
        XCTAssertEqual(diagnostics.generatedFileCount, 2)
    }

    func testTheDefaultVoiceNeedsNoSwitch() async throws {
        let engine = FakePhonon()
        _ = try await renderer(engine: engine).render(text: "Hello.")
        XCTAssertEqual(engine.voicesSet, [])
    }

    func testRendersRunOneAtATimeInOrder() async throws {
        let engine = FakePhonon(delay: .milliseconds(30))
        let phonon = try renderer(engine: engine)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask { _ = try await phonon.render(text: "Paragraph \(index).") }
                try await Task.sleep(for: .milliseconds(2))
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(engine.mostAtOnce, 1, "one paragraph at a time, like Kitten's serial queue")
        XCTAssertEqual(engine.spoken, (0..<4).map { "Paragraph \($0)." })
    }

    func testSilentOrBrokenOutputIsAnErrorNotAFile() async throws {
        for (samples, expected) in [([Float](repeating: 0, count: 2_400), PhononModelError.unsafeAudio("silent_output")),
                                    ([Float.nan, 0.5], .unsafeAudio("non_finite_samples")),
                                    ([], .emptyAudio)] {
            let phonon = try renderer(engine: FakePhonon(samples: samples))
            do {
                _ = try await phonon.render(text: "Hello.")
                XCTFail("\(expected) should have thrown")
            } catch {
                XCTAssertEqual(error as? PhononModelError, expected)
            }
            let count = await phonon.diagnostics().generatedFileCount
            XCTAssertEqual(count, 0)
        }
    }

    func testEmptyTextAndUnknownVoicesAreRefused() async throws {
        let phonon = try renderer(engine: FakePhonon())
        do {
            _ = try await phonon.render(text: " \n ")
            XCTFail("empty text")
        } catch {
            XCTAssertEqual(error as? PhononModelError, .emptyText)
        }
        XCTAssertThrowsError(try renderer(voice: "Grub the Ogre", engine: FakePhonon())) {
            XCTAssertEqual($0 as? PhononModelError, .unknownVoice("Grub the Ogre"))
        }
    }

    func testDiscardsOnlyItsOwnFilesAndUnloadRemovesTheRest() async throws {
        let engine = FakePhonon()
        let phonon = try renderer(engine: engine)
        let first = try await phonon.render(text: "One.")
        let second = try await phonon.render(text: "Two.")
        let other = output.appending(path: "kitten-other.wav")
        try Data("not ours".utf8).write(to: other)
        await phonon.discardGeneratedAudio(at: other)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        await phonon.discardGeneratedAudio(at: first.audioURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.audioURL.path))
        await phonon.unload()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.audioURL.path))
        _ = try await phonon.render(text: "Three.")
        XCTAssertEqual(engine.loads, 2, "after unload the model loads again")
    }
}

/// Speaks a tone with silence either side, so the trim and the WAV length can be checked.
private final class FakePhonon: PhononSynthesizing, @unchecked Sendable {
    private let lock = NSLock()
    private let delay: Duration
    private let samples: [Float]?
    private var current = PhononVoice.defaultVoiceName
    private var active = 0
    private(set) var mostAtOnce = 0
    private(set) var loads = 0
    private(set) var spoken: [String] = []
    private(set) var voicesSet: [String] = []
    private(set) var voiceAtEachSpeak: [String] = []

    init(delay: Duration = .zero, samples: [Float]? = nil) {
        self.delay = delay
        self.samples = samples
    }

    func loaded() { lock.withLock { loads += 1 } }

    var voice: String { lock.withLock { current } }

    func setVoice(_ name: String) async throws {
        lock.withLock {
            current = name
            voicesSet.append(name)
        }
    }

    func synthesize(_ text: String) async throws -> [Float] {
        lock.withLock {
            active += 1
            mostAtOnce = max(mostAtOnce, active)
            spoken.append(text)
            voiceAtEachSpeak.append(current)
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        lock.withLock { active -= 1 }
        if let samples { return samples }
        let silence = [Float](repeating: 0, count: 7_200)
        let tone = (0..<12_000).map { Float(sin(Double($0) * 2 * .pi * 220 / 24_000) * 0.3) }
        return silence + tone + silence
    }
}
