import AVFoundation
import SessionKitPersistence
import SessionKitSupertonic
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #995: `LibraryAudioPreparationLoopTests` prove the loop; these prove the model reaches it from the right places.
/// A real model over a temporary SQLite store, with a renderer that holds the first render open so a run stays alive.
@MainActor
final class LibraryAudioPreparationLoopWiringTests: XCTestCase {
    private struct Fixture {
        let model: Gate1AppModel
        let store: SQLiteSessionStore
        let manifestId: String
        let renderer: LoopHeldRenderer
    }

    private func makeFixture() async throws -> Fixture {
        let defaults = UserDefaults.standard
        let keys = ["supertonicTTSMigrationV1", "supertonicVoicePendingTermsV1", "ttsMode", "ttsVoiceSelection",
                    SpokenMarginsTerms.acceptanceVersionKey, SpokenMarginsTerms.acceptanceDateKey]
        let prior = keys.reduce(into: [String: Any]()) { $0[$1] = defaults.object(forKey: $1) }
        addTeardownBlock { for key in keys { if let value = prior[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        SpokenMarginsTerms.recordAcceptance()

        let root = FileManager.default.temporaryDirectory.appending(path: "loop-wiring-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(),
                                  databaseURLOverride: root.appending(path: "store.sqlite"))
        let store = try model.libraryStoreForTesting()
        addTeardownBlock { [weak model, weak store] in
            if model == nil, store == nil { try? FileManager.default.removeItem(at: root) }
        }
        model.ttsVoiceSelection = .james
        model.automaticAudioPreparationPolicy = .whileCharging
        let voice = try XCTUnwrap(model.ttsVoiceSelection.supertonicVoice)

        let itemId = "loop-item-\(UUID().uuidString)"
        let text = (1...36).map { "Sentence \($0) of the article carries enough ordinary words to fill part of a chunk." }.joined(separator: " ")
        try store.saveItem(Item(id: itemId, title: "Queued article", mediaType: "text", text: text, externalReference: nil, status: "ready"))
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let preparedRoot = support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
        let assets = try SupertonicTestAssets.installPlaceholderDownload(in: self) // the renderer is a stand-in (#1820)
        let signature = try SupertonicRenderIdentity.make(assets: assets, voice: voice)
        let plan = PreparedChunkPlan.articlePlan(text)
        XCTAssertGreaterThanOrEqual(plan.count, 2, "precondition: one pass per chunk, so a second run has a chunk to render")
        let manifest = try await PreparedAudioCoordinator(repository: store, rootDirectory: preparedRoot)
            .begin(itemId: itemId, sourceText: text, signature: signature, plan: plan, schedulesJob: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: preparedRoot.appending(path: itemId, directoryHint: .isDirectory)) }
        try store.saveAudioPreparationJob(AudioPreparationJob(id: "job-\(manifest.id)", itemId: itemId, manifestId: manifest.id, policy: .explicit))

        let template = try makeSilentWAV()
        addTeardownBlock { try? FileManager.default.removeItem(at: template) }
        let renderer = LoopHeldRenderer(templateURL: template)
        model.preparationSeams = PreparationPassSeams(
            deviceConditions: { SpeechEngineConditions(thermal: .nominal) },
            renderer: { renderer },
            memoryBackoffActive: { false }
        )
        return Fixture(model: model, store: store, manifestId: manifest.id, renderer: renderer)
    }

    /// The model reaches the loop's two stop operations from the right places: a plain stop and clearing the queue
    /// invalidate the run, while a snapshot change that forbids preparation only cancels it.
    func testTheModelStopsTheLoopFromEachCallSite() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        defer { Task { await fixture.renderer.release() } }

        model.startForegroundAudioPreparationIfNeeded()
        XCTAssertTrue(model.isForegroundAudioPreparationRunning)
        try await waitFor(fixture.renderer, toStart: 1, within: .seconds(30))

        model.stopForegroundAudioPreparation()
        XCTAssertFalse(model.isForegroundAudioPreparationRunning, "stopping from the continued-processing task invalidates the run")

        model.startForegroundAudioPreparationIfNeeded()
        XCTAssertTrue(model.isForegroundAudioPreparationRunning)
        let generation = model.libraryAudioLoop.generation
        var memoryBackoff = false
        model.preparationSeams = PreparationPassSeams(
            deviceConditions: { SpeechEngineConditions(thermal: .nominal) },
            renderer: { fixture.renderer },
            memoryBackoffActive: { memoryBackoff }
        )
        memoryBackoff = true
        var playing = model.snapshot
        playing.sessionId = "session-loop-wiring"
        playing.itemId = "playing-elsewhere"
        playing.status = .playing
        model.snapshot = playing // playback starts while preparation is forbidden: cancel only
        XCTAssertTrue(model.isForegroundAudioPreparationRunning, "a cancel-only stop leaves the run for its own finalizer")
        XCTAssertEqual(model.libraryAudioLoop.generation, generation, "and does not invalidate it")
        memoryBackoff = false

        model.clearAudioPreparationQueue()
        XCTAssertFalse(model.isForegroundAudioPreparationRunning, "clearing the queue invalidates the run")
        XCTAssertGreaterThan(model.libraryAudioLoop.generation, generation)

        await fixture.renderer.release()
        try await Task.sleep(for: .milliseconds(400)) // let the cancelled passes finish before the store goes away
    }

    /// 10-12 characterization on #995: a foreground run queued behind a held pass is invalidated, a replacement is
    /// queued, and the holder is released. The replacement must render and no two renders ever overlap (that the
    /// invalidated run renders nothing is the next test).
    func testTheReplacementOfAnInvalidatedRunRendersAfterTheHeldPassLetsGo() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let renderer = fixture.renderer
        let holder = Task { await model.performBackgroundAudioPreparationPass() }
        defer { holder.cancel() }
        try await waitFor(renderer, toStart: 1, within: .seconds(30))

        model.startForegroundAudioPreparationIfNeeded() // A queues behind the holder at the render gate
        try await Task.sleep(for: .milliseconds(300))
        model.stopForegroundAudioPreparation() // A is invalidated while it waits
        model.startForegroundAudioPreparationIfNeeded() // B
        try await Task.sleep(for: .milliseconds(300))
        let startedWhileHeld = await renderer.started
        XCTAssertEqual(startedWhileHeld, 1, "only the holder renders while it holds the gate")

        await renderer.release()
        _ = await holder.value
        try await waitFor(renderer, toStart: 2, within: .seconds(30))
        let mostAtOnce = await renderer.mostAtOnce
        XCTAssertEqual(mostAtOnce, 1, "never two renders at once")
        let started = await renderer.started
        XCTAssertGreaterThanOrEqual(started, 2, "the replacement run rendered after the holder let go")
        func committedIndexes() throws -> [Int] {
            try XCTUnwrap(try fixture.store.loadPreparedAudioManifest(id: fixture.manifestId)).chunks.map(\.index).sorted()
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while try committedIndexes().count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(Array(try committedIndexes().prefix(2)), [0, 1], "the holder's chunk and the replacement's, one after the other")

        model.stopForegroundAudioPreparation()
        try await Task.sleep(for: .milliseconds(400))
    }

    /// No replacement this time: the invalidated run is the only thing waiting behind the held pass. If it were not
    /// cancelled it would take the next chunk the moment the holder let go, so nothing but the holder's chunk may render.
    /// #2690 audit: a not-ready startup job for one voice held back the next voice's job for the same item, because
    /// the cooldown was keyed by item alone. It is keyed by item and voice; clearing an item clears every voice.
    func testTheStartupAudioCooldownForOneVoiceDoesNotHoldBackAnother() {
        var cooldown = RetryCooldown(base: 30, ceiling: 600)
        let first = Gate1AppModel.startupAudioCooldownKey("item", .f1)
        cooldown.recordFailure(first)
        XCTAssertFalse(cooldown.canAttempt(first))
        XCTAssertTrue(cooldown.canAttempt(Gate1AppModel.startupAudioCooldownKey("item", .m1)), "another voice")
        XCTAssertTrue(cooldown.canAttempt(Gate1AppModel.startupAudioCooldownKey("other", .f1)), "another item")
        cooldown.clear(Gate1AppModel.startupAudioCooldownKeys(["item"]))
        XCTAssertTrue(cooldown.canAttempt(first), "clearing the item clears every voice")
    }

    func testAnInvalidatedRunQueuedBehindAHeldPassRendersNothing() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        let renderer = fixture.renderer
        let holder = Task { await model.performBackgroundAudioPreparationPass() }
        defer { holder.cancel() }
        try await waitFor(renderer, toStart: 1, within: .seconds(30))

        model.startForegroundAudioPreparationIfNeeded() // A queues behind the holder at the render gate
        try await Task.sleep(for: .milliseconds(300))
        model.stopForegroundAudioPreparation()

        await renderer.release()
        _ = await holder.value
        try await Task.sleep(for: .seconds(1)) // long enough for A to take the gate and, wrongly, render
        let started = await renderer.started
        XCTAssertEqual(started, 1, "the holder's render is the only one; the invalidated run never renders")
        let committed = try XCTUnwrap(try fixture.store.loadPreparedAudioManifest(id: fixture.manifestId)).chunks.map(\.index)
        XCTAssertEqual(committed.sorted(), [0], "one chunk committed, by the holder")
    }

    private func waitFor(_ renderer: LoopHeldRenderer, toStart count: Int, within limit: Duration,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + limit
        while await renderer.started < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let started = await renderer.started
        XCTAssertGreaterThanOrEqual(started, count, "the renderer did not reach render \(count) in time", file: file, line: line)
    }

    private func makeSilentWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "loop-template-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

/// Copies a short WAV per chunk, reports a duration the output check accepts, and holds every render open until
/// `release()`, counting how many run at once.
private actor LoopHeldRenderer: SupertonicRendering {
    let templateURL: URL
    private(set) var started = 0
    private(set) var mostAtOnce = 0
    private var running = 0
    private var holds = true
    private var held: [CheckedContinuation<Void, Never>] = []
    private var generated: Set<URL> = []

    init(templateURL: URL) { self.templateURL = templateURL }

    func release() {
        holds = false
        held.forEach { $0.resume() }
        held.removeAll()
    }

    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        started += 1
        running += 1
        mostAtOnce = max(mostAtOnce, running)
        defer { running -= 1 }
        if holds { await withCheckedContinuation { held.append($0) } }
        let url = FileManager.default.temporaryDirectory.appending(path: "loop-render-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: templateURL, to: url)
        generated.insert(url)
        return SupertonicNarrationResult(audioURL: url, duration: Double(text.count) / 15, sampleRate: 44_100,
                                         renderDuration: 0.01, sessionLoadCount: 1,
                                         engine: SupertonicNarrationResult.supertonicEngine)
    }

    func discardGeneratedAudio(at url: URL) async {
        if generated.remove(url) != nil { try? FileManager.default.removeItem(at: url) }
    }
}
