import AVFoundation
import SessionKitPersistence
import SessionKitSupertonic
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #281: many Library text items showed a spinner at once, and none finished.
@MainActor
final class LibraryAudioPreparationTests: XCTestCase {
    private func textItem(_ id: String) -> Item {
        Item(id: id, title: id, mediaType: "text", text: "A few words to read aloud.", externalReference: nil, status: "ready")
    }

    private func modelWithOnDeviceVoice() -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.ttsVoiceSelection = .lily
        model.acceptCurrentTermsAndEnableOnDeviceVoice()
        return model
    }

    func testOnlyTheItemBeingPreparedShowsProgressAndTheRestWait() {
        let model = modelWithOnDeviceVoice()
        let items = (1...5).map { textItem("queued-\($0)") }
        func states() -> [NativeTextStartupAudioState] {
            items.map { model.libraryStartupAudioPresentation(item: $0, manifest: nil, job: nil).state }
        }
        XCTAssertEqual(states(), Array(repeating: .waiting, count: 5), "queued items wait; none shows a spinner")
        model.libraryAudioPreparingItemId = "queued-3"
        XCTAssertEqual(states(), [.waiting, .waiting, .preparing, .waiting, .waiting], "exactly one shows progress")
    }

    /// Codex audit on #380: a restored session that is paused isn't being prepared, so its item
    /// waits like the rest. It shows progress again once playback is active.
    func testAPausedSessionsItemWaitsWhileAnotherItemIsPrepared() {
        let model = modelWithOnDeviceVoice()
        let items = (1...3).map { textItem("queued-\($0)") }
        func states() -> [NativeTextStartupAudioState] {
            items.map { model.libraryStartupAudioPresentation(item: $0, manifest: nil, job: nil).state }
        }
        model.libraryAudioPreparingItemId = "queued-2"
        var paused = model.snapshot
        paused.sessionId = "session-queued-1"
        paused.itemId = "queued-1"
        paused.status = .paused
        model.snapshot = paused
        model.libraryAudioPreparingItemId = "queued-2"
        XCTAssertEqual(states(), [.waiting, .preparing, .waiting], "the paused item isn't being prepared")
        model.snapshot.status = .playing
        model.libraryAudioPreparingItemId = "queued-2"
        XCTAssertEqual(states(), [.preparing, .preparing, .waiting], "the playing item prepares as it plays")
    }

    /// APA-12 (#1042): the tests above set the preparing item by hand, so they proved the label, not the turn-taking.
    /// Here the real foreground and background passes run at once over one queued article, with a renderer that holds
    /// its first render open. The second pass must wait for the first to finish rather than render alongside it.
    func testTheForegroundAndBackgroundPassesNeverRenderAtTheSameTime() async throws {
        let defaults = UserDefaults.standard
        let keys = ["supertonicTTSMigrationV1", "supertonicVoicePendingTermsV1", "ttsMode", "ttsVoiceSelection",
                    SpokenMarginsTerms.acceptanceVersionKey, SpokenMarginsTerms.acceptanceDateKey]
        let prior = keys.reduce(into: [String: Any]()) { $0[$1] = defaults.object(forKey: $1) }
        defer { for key in keys { if let value = prior[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        SpokenMarginsTerms.recordAcceptance()

        let root = FileManager.default.temporaryDirectory.appending(path: "render-turns-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(),
                                  databaseURLOverride: root.appending(path: "store.sqlite"))
        let store = try model.libraryStoreForTesting()
        addTeardownBlock { [weak model, weak store] in
            if model == nil, store == nil { try? FileManager.default.removeItem(at: root) }
        }
        model.ttsVoiceSelection = .james
        model.automaticAudioPreparationPolicy = .whileCharging // the background pass runs only under this policy
        let voice = try XCTUnwrap(model.ttsVoiceSelection.supertonicVoice)

        let itemId = "turns-item-\(UUID().uuidString)"
        let text = (1...36).map { "Sentence \($0) of the article carries enough ordinary words to fill part of a chunk." }.joined(separator: " ")
        try store.saveItem(Item(id: itemId, title: "Queued article", mediaType: "text", text: text, externalReference: nil, status: "ready"))
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let preparedRoot = support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
        let assets = try SupertonicTestAssets.installPlaceholderDownload(in: self) // the renderer is a stand-in (#1820)
        let signature = try SupertonicRenderIdentity.make(assets: assets, voice: voice)
        let plan = PreparedChunkPlan.articlePlan(text)
        XCTAssertGreaterThanOrEqual(plan.count, 2, "precondition: one pass per chunk, so both passes have a chunk to render")
        let manifest = try await PreparedAudioCoordinator(repository: store, rootDirectory: preparedRoot)
            .begin(itemId: itemId, sourceText: text, signature: signature, plan: plan, schedulesJob: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: preparedRoot.appending(path: itemId, directoryHint: .isDirectory)) }
        // Explicit, so the foreground pass may take it too: both passes want the same work.
        try store.saveAudioPreparationJob(AudioPreparationJob(id: "job-\(manifest.id)", itemId: itemId, manifestId: manifest.id, policy: .explicit))

        let template = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = HeldRenderer(templateURL: template)
        model.preparationSeams = PreparationPassSeams(
            deviceConditions: { SpeechEngineConditions(thermal: .nominal) },
            renderer: { renderer },
            memoryBackoffActive: { false }
        )

        let background = Task { await model.performBackgroundAudioPreparationPass() }
        let foreground = Task { await model.performBackgroundAudioPreparationPass(foregroundDemandOnly: true) }
        defer { background.cancel(); foreground.cancel() }
        try await waitFor(renderer, toStart: 1, within: .seconds(30))
        let firstStarted = await renderer.started
        XCTAssertEqual(firstStarted, 1, "one pass reached its render")
        XCTAssertEqual(model.libraryAudioPreparingItemId, itemId, "the item being rendered is the one that shows progress")
        // Without the turn-taking the other pass reaches its own render within this window.
        try await waitFor(renderer, toStart: 2, within: .seconds(3))
        let startedWhileHeld = await renderer.started
        XCTAssertEqual(startedWhileHeld, 1, "the other pass waits while a render is under way")

        await renderer.release()
        _ = await background.value
        _ = await foreground.value
        let started = await renderer.started
        let mostAtOnce = await renderer.mostAtOnce
        XCTAssertGreaterThanOrEqual(started, 2, "the waiting pass rendered once the first had finished")
        XCTAssertEqual(mostAtOnce, 1, "never two renders at once")
        let committed = try XCTUnwrap(try store.loadPreparedAudioManifest(id: manifest.id)).chunks.map(\.index)
        XCTAssertEqual(Array(committed.sorted().prefix(2)), [0, 1], "each pass committed its own chunk, one after the other")
    }

    private func waitFor(_ renderer: HeldRenderer, toStart count: Int, within limit: Duration) async throws {
        let deadline = ContinuousClock.now + limit
        while await renderer.started < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeSilentWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "turns-template-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testAWaitingItemStillStartsAtOnce() {
        let model = modelWithOnDeviceVoice()
        let itemID = "item-pill"
        guard let index = model.libraryItems.firstIndex(where: { $0.id == itemID }) else {
            return XCTFail("Missing seeded text item")
        }
        model.libraryItems[index].startupAudioState = .waiting
        model.startItem(id: itemID)
        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.diagnostics["startupAudioPlayback:\(itemID)"], "started_without_waiting_for_opening_buffer")
    }
}

/// Copies a short WAV per chunk, reports a duration the output check accepts, and holds every render open until
/// `release()`, counting how many run at once.
private actor HeldRenderer: SupertonicRendering {
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
        let url = FileManager.default.temporaryDirectory.appending(path: "turns-render-\(UUID().uuidString).wav")
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
