import AVFoundation
import SessionKit
import SessionKitSupertonic
import XCTest
@testable import SpokenMarginsApp

/// #2700: the speech player built over a downloaded voice (Phonon, Kokoro). Its own chunks must count as its own
/// audio, not stand-ins; Kitten must take a hot phone's passages and keep the item (#1680, I14) exactly as it does for
/// Supertonic; and the voice may render only when it is registered, installed, allowed on this chip and the phone allows.
@MainActor
final class DownloadedVoiceEngineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "downloaded-voice-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: The player

    /// Before #2700 the player called a chunk its own only when its engine said "supertonic", so every chunk of
    /// another voice was a stand-in and its article was never assembled (#363's stand-in rule).
    func testADownloadedVoicesOwnAudioIsAssembledNotTreatedAsAStandIn() async throws {
        let renderer = StampedVoiceRenderer(engine: "kokoro", templateURL: try makeTestWAV(duration: 2))
        let assemblies = Counter()
        let ready = expectation(description: "generation ready")
        ready.assertForOverFulfill = false
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            preparedAudioDirectory: root.appending(path: "assembled", directoryHint: .isDirectory),
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient(),
            onGenerationStateChange: { state, _ in if state == .ready { ready.fulfill() } },
            onPreparedAudio: { _, _ in assemblies.add() }
        )
        _ = try client.prepareSpeechText("A short sentence that the downloaded voice reads in about two seconds.")
        try client.play(targetId: "item", from: 0)
        await fulfillment(of: [ready], timeout: 60)
        let renders = await renderer.renderCount
        XCTAssertGreaterThan(renders, 0)
        XCTAssertEqual(assemblies.value, 1, "the downloaded voice's own audio is assembled like Supertonic's")
        try client.stop()
    }

    /// #2762 audit: the render-headroom memory filed every chunk whose engine wasn't Supertonic's as a stand-in, so a
    /// downloaded voice's own headroom was never found for it (its resume mark always fell back to half the window),
    /// and Kitten, after a heat hand-over, read the downloaded voice's headroom as its own.
    func testADownloadedVoicesRenderHeadroomIsKeptAsItsOwnNotAStandIns() async throws {
        let renderer = StampedVoiceRenderer(engine: "phonon", templateURL: try makeTestWAV(duration: 2))
        let ready = expectation(description: "generation ready")
        ready.assertForOverFulfill = false
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient(),
            onGenerationStateChange: { state, _ in if state == .ready { ready.fulfill() } }
        )
        _ = try client.prepareSpeechText("A short sentence that the downloaded voice reads in about two seconds.")
        try client.play(targetId: "headroom-item", from: 0)
        await fulfillment(of: [ready], timeout: 60)
        let renders = await renderer.renderCount
        XCTAssertGreaterThan(renders, 0)
        XCTAssertNotNil(client.debugRenderHeadroom(isStandIn: false), "the chosen voice's headroom is kept as its own")
        XCTAssertNil(client.debugRenderHeadroom(isStandIn: true), "and never as a stand-in's")
        try client.stop()
    }

    /// #2744 review: audio saved earlier by a downloaded voice and replayed (the prepared-chunk path) was stamped as
    /// Supertonic's, so against the voice's own engine it counted as a stand-in and blocked assembly. Nothing renders
    /// here: every chunk is a replay.
    func testReplayedSavedAudioOfADownloadedVoiceIsNotTreatedAsAStandIn() async throws {
        let template = try makeTestWAV(duration: 2)
        let renderer = StampedVoiceRenderer(engine: "kokoro", templateURL: template)
        let assemblies = Counter()
        let ready = expectation(description: "generation ready")
        ready.assertForOverFulfill = false
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            preparedAudioDirectory: root.appending(path: "replayed", directoryHint: .isDirectory),
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient(),
            onGenerationStateChange: { state, _ in if state == .ready { ready.fulfill() } },
            preparedChunkLookup: { _, _, _ in .init(audioURL: template, duration: 2) },
            onPreparedAudio: { _, _ in assemblies.add() }
        )
        _ = try client.prepareSpeechText("A short sentence that the downloaded voice saved earlier and now replays.")
        try client.play(targetId: "replayed-item", from: 0)
        await fulfillment(of: [ready], timeout: 60)
        let renders = await renderer.renderCount
        XCTAssertEqual(renders, 0, "every chunk came from saved audio")
        XCTAssertEqual(assemblies.value, 1, "saved audio of the voice's own engine is assembled, not held back as a stand-in")
        try client.stop()
    }

    /// Supertonic's babble check (#240) is tuned to Supertonic's pacing; a slower voice must not be swapped for the iOS
    /// voice by it, and the guard must keep reporting the inner renderer's engine.
    func testTheSupertonicOutputGuardPassesAnotherEnginesAudioThroughUnchecked() async throws {
        let template = try makeTestWAV(duration: 20)
        let replacements = Counter()
        let guarded = SupertonicOutputGuard(
            wrapping: StampedVoiceRenderer(engine: "phonon", templateURL: template),
            systemVoiceIdentifier: nil,
            onReplacement: { _ in replacements.add() },
            standIn: { _, _, _, _ in XCTFail("the iOS voice was asked"); return 0 },
            writeLog: StandInWriteLog(),
            now: { 0 }
        )
        XCTAssertEqual(guarded.engine, "phonon")
        let result = try await guarded.render(text: "Hi.", voice: .m2, language: "en", speed: 1, synthesisSteps: 8)
        XCTAssertEqual(result.engine, "phonon")
        XCTAssertEqual(replacements.value, 0)
    }

    /// #1680, I14: a hot phone hands the item to Kitten; when the phone cools mid-item the downloaded voice does not
    /// come back mid-play; the next item gets the chosen voice again.
    func testOnAHotPhoneKittenReadsTheItemAndTheDownloadedVoiceNeverBouncesBackMidItem() async throws {
        let kittenRoot = try XCTUnwrap(Bundle.main.resourceURL?.appending(path: "Kitten", directoryHint: .isDirectory))
        let output = root.appending(path: "kitten", directoryHint: .isDirectory)
        let kitten = try KittenNarrationRenderer(assets: KittenAssetLocation(rootURL: kittenRoot), outputDirectory: output, governor: OnDeviceVoiceGovernor())
        let chosen = StampedVoiceRenderer(engine: "kokoro", templateURL: try makeTestWAV(duration: 0.2))
        let allowed = Flag()
        let progress = ProgressLog()
        let started = expectation(description: "audio started")
        started.assertForOverFulfill = false
        let client = SupertonicSpeechPlaybackClient(
            renderer: chosen, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {},
            audioPlayerStarter: { player, rate in
                player.volume = 0
                player.playImmediately(atRate: rate)
                started.fulfill()
            },
            observesPlayerLifecycle: false,
            onDeviceRenderingAllowed: { allowed.value },
            pressureRenderer: kitten,
            fallbackClient: RecordingFallbackAudioClient(),
            onGenerationProgress: { value in
                progress.record(value)
                // The phone cools as soon as Kitten has rendered the first chunk.
                if value.completedChunks >= 1 { allowed.value = true }
            },
            onRestore: { _ in progress.recordRestore() }
        )
        // Two paragraphs, not four: the item only needs a chunk before the phone cools and a chunk after it (#2819).
        let text = (0..<2).map { _ in
            "The committee met on Tuesday to discuss the proposal, which had been circulating among members for several weeks and had attracted a surprising amount of criticism from both sides. Most of the objections concerned cost."
        }.joined(separator: " ")
        _ = try client.prepareSpeechText(text)
        try client.play(targetId: "hot-item")

        await fulfillment(of: [started], timeout: 60)
        // #2819: on the hosted Mac this item stalled part-way (at 3, 4 and 6 of 7 chunks) on the first run of 3 of 3 flagged runs, took
        // the plan's whole 120 s allowance, and passed on the retry in 11 to 19 s. Give up when no chunk has arrived for
        // `stallSeconds`, or at `ceilingSeconds`, which is inside that allowance, and say where it stopped.
        let stallSeconds = 45.0, ceilingSeconds = 100.0
        let begun = ContinuousClock.now
        var lastCompleted = -1, lastAdvance = begun
        while progress.total == 0 || progress.completed < progress.total {
            let now = ContinuousClock.now
            if progress.completed != lastCompleted { lastCompleted = progress.completed; lastAdvance = now }
            if now - begun > .seconds(ceilingSeconds) || now - lastAdvance > .seconds(stallSeconds) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let waited = ContinuousClock.now - begun
        XCTAssertEqual(progress.completed, progress.total, "Kitten stopped at \(progress.completed) of \(progress.total) chunks after \(waited)")
        XCTAssertTrue(allowed.value, "the phone cooled during the generation")
        let rendersDuringItem = await chosen.renderCount
        XCTAssertEqual(rendersDuringItem, 0, "the downloaded voice never takes a chunk back mid-item")

        try client.stop()
        _ = try client.prepareSpeechText("The next item. The phone is cool now, so the chosen voice reads it.")
        try client.play(targetId: "next-item")
        XCTAssertEqual(progress.restores, 1, "the next item releases Kitten")
        let releaseDeadline = ContinuousClock.now + .seconds(30)
        var rendersAfter = await chosen.renderCount
        while rendersAfter == 0, ContinuousClock.now < releaseDeadline {
            try await Task.sleep(for: .milliseconds(100))
            rendersAfter = await chosen.renderCount
        }
        XCTAssertGreaterThan(rendersAfter, 0, "the downloaded voice reads the next item")
        try client.stop()
        await kitten.unload()
    }

    // MARK: The engine factory

    private func descriptor(registered: Bool = true, engine: String = "kokoro") -> DownloadedVoiceDescriptor {
        DownloadedVoiceDescriptor(
            voiceId: ReadingVoiceChoice.kokoroVoiceId, choice: .kokoro, runtime: VoiceModelCatalogVerifier.coreMLRuntime,
            engine: engine, speaker: "af_heart",
            identity: { entry, speaker in KokoroRenderSignature.make(voice: speaker, entry: entry) },
            registration: registered ? registration : nil
        )
    }

    private var registration: DownloadedVoiceRegistration {
        DownloadedVoiceRegistration(makeRenderer: { _, _ in StampedVoiceRenderer(engine: "kokoro", templateURL: URL(fileURLWithPath: "/dev/null")) }, preparer: nil)
    }

    private let entry = VoiceModelEntry(
        id: ReadingVoiceChoice.kokoroVoiceId, displayName: "Kokoro", publisher: "hexgrad", version: "1.0",
        runtime: VoiceModelRuntime(name: "coreml", version: "1"), minimumIOSVersion: "26.0",
        minimumMemoryMegabytes: 4_096, minimumChip: "A14",
        files: [VoiceModelFile(path: "model.bin", byteCount: 1, sha256: String(repeating: "a", count: 64),
                               sources: ["https://voices.example/model.bin"], licenseId: "m"),
                VoiceModelFile(path: "voices/af_heart.bin", byteCount: 1, sha256: String(repeating: "c", count: 64),
                               sources: ["https://voices.example/af_heart.bin"], licenseId: "m")],
        licenses: [VoiceModelLicense(id: "m", name: "Apache 2.0", textURL: "https://voices.example/l",
                                     textSHA256: String(repeating: "b", count: 64), requiresAcceptance: false)]
    )

    private func install() throws {
        try FileManager.default.createDirectory(
            at: VoiceCatalogCoordinator.voicesRoot(supportDirectory: root).appending(path: "kokoro-82m/1.0", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    private func engine(chip: Int?, governor: Bool, memory: Int = 8_192) -> OnDeviceVoiceEngine {
        let entry = entry
        return OnDeviceVoiceEngines.downloaded(
            descriptor(), registration: registration, supportDirectory: root,
            entry: { entry }, deviceChipGeneration: { chip }, physicalMemoryMegabytes: { memory }, governorAllows: { governor }
        )
    }

    func testTheDownloadedVoiceRendersOnlyWhenInstalledOnAnAllowedChipAndThePhoneAllows() throws {
        XCTAssertFalse(engine(chip: 14, governor: true).renderingAllowed(), "not installed: Kitten reads")
        try install()
        XCTAssertTrue(engine(chip: 14, governor: true).renderingAllowed())
        XCTAssertFalse(engine(chip: 13, governor: true).renderingAllowed(), "below the A14 floor: Kitten reads")
        XCTAssertFalse(engine(chip: nil, governor: true).renderingAllowed(), "an unknown chip never gets a floored voice")
        XCTAssertFalse(engine(chip: 14, governor: false).renderingAllowed(), "a hot phone: Kitten reads")
        XCTAssertFalse(engine(chip: 14, governor: true, memory: 2_000).renderingAllowed(), "a 2 GB phone is below the 4 GB need: Kitten reads")
    }

    func testTheSavedAudioIdentityCarriesTheRenderersEngineNotSupertonics() throws {
        let made = engine(chip: 14, governor: true)
        let signature = try made.signature.make()
        XCTAssertEqual(signature.engine, made.renderer.engine, "otherwise its chunks are filed as stand-ins")
        XCTAssertEqual(signature, KokoroRenderSignature.make(voice: "af_heart", entry: entry))
        XCTAssertNotEqual(signature.engine, SupertonicNarrationResult.supertonicEngine)
    }

    /// An identity that names another engine than the descriptor's would never match its renderer's chunks: refused.
    func testAnIdentityNamingAnotherEngineIsRefused() {
        XCTAssertThrowsError(try descriptor(engine: "phonon").signature(entry: entry)) { error in
            XCTAssertEqual(error as? OnDeviceVoiceEngines.Failure,
                           .engineMismatch(voiceId: ReadingVoiceChoice.kokoroVoiceId, identity: "kokoro", renderer: "phonon"))
        }
    }

    /// #2762 audit: Phonon's saved audio was filed under the speaker "en" while its renderer read Alfie, so a change
    /// of default voice would have reused Alfie's chunks beside the new voice's in one item. Every registered voice's
    /// renderer now reads the descriptor's speaker, its identity names that speaker's own file, and another speaker
    /// gives another identity. Checked against the catalog the app ships, so a drift in any copy shows here.
    func testEveryRegisteredVoiceIsFiledUnderTheSpeakerItsRendererReads() throws {
        let registered = DownloadedVoiceRegistry.all.filter(\.isAvailable)
        XCTAssertEqual(Set(registered.map(\.voiceId)), [ReadingVoiceChoice.phononVoiceId, ReadingVoiceChoice.kokoroVoiceId])
        for descriptor in registered {
            let entry = try XCTUnwrap(BundledVoiceCatalog.entry(voiceId: descriptor.voiceId), descriptor.voiceId)
            let renderer = try XCTUnwrap(descriptor.registration).makeRenderer(descriptor.speaker, { nil })
            XCTAssertEqual(renderer.engine, descriptor.engine, descriptor.voiceId)
            let rendererSpeaker = (renderer as? PhononDownloadedVoiceRenderer)?.voiceName ?? (renderer as? KokoroDownloadedVoiceRenderer)?.voice
            XCTAssertEqual(rendererSpeaker, descriptor.speaker, "the renderer reads the speaker the identity names: \(descriptor.voiceId)")

            let signature = try descriptor.signature(entry: entry)
            XCTAssertEqual(signature.engine, descriptor.engine, descriptor.voiceId)
            let speakerFile = try XCTUnwrap(entry.files.first { $0.path.hasPrefix("voices/\(descriptor.speaker).") }, descriptor.voiceId)
            XCTAssertEqual(signature.voiceStyleHash, speakerFile.sha256, "the identity names the speaker's own file: \(descriptor.voiceId)")

            let other = try XCTUnwrap(entry.files.lazy.map(\.path).filter { $0.hasPrefix("voices/") }
                .compactMap { $0.dropFirst("voices/".count).split(separator: ".").first.map(String.init) }
                .first { $0 != descriptor.speaker }, descriptor.voiceId)
            let otherSignature = try XCTUnwrap(descriptor.identity(entry, other), "\(descriptor.voiceId) \(other)")
            XCTAssertNotEqual(otherSignature.digest, signature.digest, "another speaker is another identity: \(descriptor.voiceId)")
        }
    }

    /// #2762 audit: Kokoro's cutting version (`KokoroBucketPlanner.version`) was not part of the identity the player
    /// used, so a change to the cutting would have reused audio cut the old way.
    func testKokorosSavedAudioIdentityCarriesItsCuttingVersion() throws {
        let entry = try XCTUnwrap(BundledVoiceCatalog.entry(voiceId: ReadingVoiceChoice.kokoroVoiceId))
        let signature = try KokoroVoiceEngine.descriptor.signature(entry: entry)
        XCTAssertTrue(signature.chunkingVersion.contains(KokoroBucketPlanner.version), signature.chunkingVersion)
    }

    func testAVoiceWithNoRegisteredRendererIsNeitherDownloadableNorPickable() {
        XCTAssertFalse(descriptor(registered: false).isAvailable)
        for descriptor in DownloadedVoiceRegistry.all where !descriptor.isAvailable {
            XCTAssertFalse(VoiceDownloadsModel.playableVoiceIds.contains(descriptor.voiceId), descriptor.voiceId)
            XCTAssertNil(DownloadedVoiceRegistry.descriptor(for: descriptor.choice), descriptor.voiceId)
            XCTAssertFalse(AppTTSVoiceSelection.pickerChoices(current: .kitten, rows: []).contains(AppTTSVoiceSelection(choice: descriptor.choice)))
        }
    }

    // MARK: Helpers

    private func makeTestWAV(duration: TimeInterval) throws -> URL {
        let url = root.appending(path: "template-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frameCount = AVAudioFrameCount(44_100 * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(frameCount) {
            samples[frame] = sin(Float(frame) * 2 * .pi * 440 / 44_100) * 0.1
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

/// A downloaded voice's renderer: copies a template file and stamps each result with its own engine.
private actor StampedVoiceRenderer: SupertonicRendering {
    nonisolated let engine: String
    let templateURL: URL
    private(set) var renderCount = 0
    private var generated: Set<URL> = []

    init(engine: String, templateURL: URL) {
        self.engine = engine
        self.templateURL = templateURL
    }

    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        renderCount += 1
        let url = FileManager.default.temporaryDirectory.appending(path: "stamped-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: templateURL, to: url)
        generated.insert(url)
        let audio = try AVAudioFile(forReading: url)
        return SupertonicNarrationResult(
            audioURL: url,
            duration: Double(audio.length) / audio.processingFormat.sampleRate,
            sampleRate: Int(audio.processingFormat.sampleRate.rounded()),
            renderDuration: 0.01,
            sessionLoadCount: 1,
            engine: engine
        )
    }

    func discardGeneratedAudio(at url: URL) async {
        if generated.remove(url) != nil { try? FileManager.default.removeItem(at: url) }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var last = RenderedSpeechGenerationProgress(completedChunks: 0, totalChunks: 0)
    private var restoreCount = 0
    func record(_ value: RenderedSpeechGenerationProgress) { lock.withLock { last = value } }
    func recordRestore() { lock.withLock { restoreCount += 1 } }
    var completed: Int { lock.withLock { last.completedChunks } }
    var total: Int { lock.withLock { last.totalChunks } }
    var restores: Int { lock.withLock { restoreCount } }
}
