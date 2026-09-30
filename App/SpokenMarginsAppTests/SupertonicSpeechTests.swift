import AVFoundation
import CryptoKit
import SessionKit
import SessionKitAudio
import SessionKitPersistence
import SessionKitSupertonic
import XCTest
@testable import SpokenMarginsApp

@MainActor
final class SupertonicSpeechTests: XCTestCase {
    func testMemoryBackoffExtendsOnRepeatedWarningsAndExpires() {
        let backoff = SupertonicMemoryBackoff()
        XCTAssertFalse(backoff.isActive(now: 100))
        backoff.recordWarning(now: 100)
        XCTAssertTrue(backoff.isActive(now: 159))
        backoff.recordWarning(now: 150)
        XCTAssertTrue(backoff.isActive(now: 209))
        XCTAssertFalse(backoff.isActive(now: 210))
    }

    /// C2 M1 (#183): Low Power Mode alone no longer blocks Supertonic; heat and memory
    /// pressure do, and the listener is told which one and when the voice comes back.
    func testResourceFallbackExplainsObservedCauseAndRecovery() {
        XCTAssertEqual(SupertonicResourcePolicy.thermalLevel(.serious), .serious)
        XCTAssertEqual(SupertonicResourcePolicy.thermalLevel(.critical), .critical)
        XCTAssertEqual(SupertonicResourcePolicy.thermalLevel(.fair), .fair)
        XCTAssertNil(SpeechEnginePolicy.onDeviceRenderingBlock(
            SpeechEngineConditions(thermal: .nominal, isLowPowerModeEnabled: true)))
        let memory = SpeechFallbackReason.memoryWarning.listenerExplanation
        XCTAssertTrue(memory.contains("iOS memory warning"))
        XCTAssertFalse(memory.contains("Low Power Mode"))
        let thermal = SpeechFallbackReason.deviceTooWarm.listenerExplanation
        XCTAssertTrue(thermal.contains("too warm"))
        XCTAssertTrue(thermal.contains("comes back"))
    }

    /// C2 M1 (#183, I14): after a heat or memory fallback, the chosen voice comes back at the
    /// next play once the condition clears, without the listener reselecting it.
    func testResourceFallbackReturnsToSupertonicAtTheNextPlayOnceTheConditionClears() async throws {
        let template = try makeTestWAV(duration: 0.2)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let condition = ResourceConditionSwitch(allowed: false)
        let fallback = RecordingFallbackAudioClient()
        let fellBack = expectation(description: "resource fallback")
        let restored = expectation(description: "chosen voice restored")
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in }, observesPlayerLifecycle: false,
            onDeviceRenderingAllowed: { condition.allowed },
            fallbackClient: fallback,
            onFallback: { reason, _, _ in
                XCTAssertEqual(reason, "supertonic_resource_pressure")
                fellBack.fulfill()
            },
            onRestore: { targetId in
                XCTAssertEqual(targetId, "warm-phone")
                restored.fulfill()
            }
        )
        _ = try client.prepareSpeechText("The phone is warm, so the iOS voice reads this until it cools. Then the chosen voice returns.")
        try client.play(targetId: "warm-phone")
        await fulfillment(of: [fellBack], timeout: 2)
        XCTAssertEqual(fallback.playedOffsets, [0])

        try client.pause()
        try client.play(targetId: "warm-phone", from: 10)
        XCTAssertEqual(fallback.playedOffsets, [0, 10], "still warm: the iOS voice continues")
        let rendersWhileWarm = await renderer.renderCount
        XCTAssertEqual(rendersWhileWarm, 0)

        try client.pause()
        condition.allowed = true
        try client.play(targetId: "warm-phone", from: 10)
        await fulfillment(of: [restored], timeout: 2)
        let rendersAfterCooling = await waitForRenderCount(renderer, minimum: 1)
        XCTAssertGreaterThanOrEqual(rendersAfterCooling, 1, "Supertonic renders again")
        XCTAssertEqual(fallback.playedOffsets, [0, 10], "the iOS voice isn't started again")
        try client.stop()
    }

    /// A slow render would likely be slow again, so that fallback waits for Retry.
    func testSlowRenderFallbackWaitsForRetryInsteadOfReturningAtTheNextPlay() async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template, firstRenderDelay: .seconds(1))
        let fallback = RecordingFallbackAudioClient()
        let timedOut = expectation(description: "bounded fallback")
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in }, observesPlayerLifecycle: false,
            fallbackClient: fallback,
            onFallback: { _, _, _ in timedOut.fulfill() },
            onRestore: { _ in XCTFail("a slow render must not switch back by itself") },
            renderWaitLimit: .milliseconds(100)
        )
        _ = try client.prepareSpeechText("A long response that must remain playable when generation does not finish promptly.")
        try client.play(targetId: "slow", from: 17)
        await fulfillment(of: [timedOut], timeout: 2)
        try client.pause()
        try client.play(targetId: "slow", from: 20)
        XCTAssertEqual(fallback.playedOffsets, [17, 20])
        try client.stop()
    }

    func testPreparedAudioPlaysWithoutInferenceWhenResourcesDisallowRendering() async throws {
        let template = try makeTestWAV(duration: 1)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let fallback = RecordingFallbackAudioClient()
        let started = expectation(description: "prepared audio started")
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1,
            fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in started.fulfill() },
            observesPlayerLifecycle: false, onDeviceRenderingAllowed: { false },
            fallbackClient: fallback,
            preparedChunkLookup: { _, _, _ in .init(audioURL: template, duration: 1) }
        )
        _ = try client.prepareSpeechText("Prepared audio stays available in Low Power Mode.")
        try client.play(targetId: "prepared-low-power")
        await fulfillment(of: [started], timeout: 2)
        let count = await renderer.renderCount
        XCTAssertEqual(count, 0)
        XCTAssertTrue(fallback.playedOffsets.isEmpty)
        try client.stop()
    }

    // #235 (Codex rank 1): a chunk that has rendered and been cached waited to play until the
    // renderer deleted its temporary original, and that deletion queues behind other inference.
    func testCachedChunkPlaysWhileItsTemporaryFileDiscardIsQueued() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rank1-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let template = try makeTestWAV(duration: 1)
        defer { try? FileManager.default.removeItem(at: template) }
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let renderer = GatedDiscardSupertonicRenderer(templateURL: template, discardGate: gate.stream)
        let cache = try RenderedSpeechDiskCache(directory: root.appending(path: "cache"), limitBytes: 50_000_000)
        let started = expectation(description: "the rendered, cached chunk starts")
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1,
            fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            diskCache: cache,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in started.fulfill() },
            observesPlayerLifecycle: false,
            fallbackClient: RecordingFallbackAudioClient()
        )
        _ = try client.prepareSpeechText("One sentence of narration is enough for this chunk.")
        try client.play(targetId: "rank1")
        await fulfillment(of: [started], timeout: 3)
        let discards = await renderer.discards
        XCTAssertGreaterThanOrEqual(discards, 1, "the temporary file's discard is still queued")
        try client.stop()
    }

    private func silentTemplate(_ root: URL) throws -> URL {
        let url = root.appending(path: "template.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        try file.write(from: buffer)
        return url
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<150 { if await condition() { return }; try? await Task.sleep(for: .milliseconds(20)) }
    }

    // #235, Codex rank 2: " [1] " is spoken " citation 1 ", every character mapped to the "[" offset. When a
    // chunk boundary splits it, a pause in the second chunk maps back into the first, already played.
    func testPauseInsideASplitCitationResumesTheCurrentChunk() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rank2-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = TextRecordingSupertonicRenderer(template: try silentTemplate(root))
        let starts = ResumeStartCounter()
        let progress = GenerationProgressLog()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in starts.bump() },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient(),
            onGenerationProgress: { progress.append($0.completedChunks) }
        )
        // Sized so the chunk boundary falls between " citation" and "1": the first chunk ends after
        // "citation", and the second starts at "1", which maps back to "[".
        let text = String(repeating: "a", count: RenderedSpeechChunker.spokenCostBudget - 11) + " [1] " + String(repeating: "b", count: 300)
        _ = try client.prepareSpeechText(text)
        try client.play(targetId: "rank2", from: 0)
        await waitUntil { starts.value >= 1 }
        client.debugFinishActiveChunk()
        await waitUntil { starts.value >= 2 }
        XCTAssertEqual(starts.value, 2, "the second chunk plays")
        let progressBefore = progress.completed.count
        let paused = try XCTUnwrap(client.currentCharOffset())
        try client.pause()
        try client.play(targetId: "rank2", from: paused)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(progress.completed.dropFirst(progressBefore).contains(0),
                       "no restart: progress never went back to 0 (\(progress.completed))")
        let renders = await renderer.renders
        XCTAssertEqual(Set(renders).count, renders.count, "no chunk rendered twice")
        XCTAssertEqual(client.playbackStartStatus(targetId: "rank2"), .confirmed)
        try client.stop()
    }

    // #235, Codex rank 3: while the previous chunk's commit is awaited, the next chunk is planned but not
    // yet rendering. A pause and resume while waiting for it restarted rendering from scratch.
    func testResumeWhileWaitingForAChunkNotYetRenderingKeepsTheGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "rank3-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = TextRecordingSupertonicRenderer(template: try silentTemplate(root))
        let starts = ResumeStartCounter()
        let gate = PreparedChunkCommitGate()
        defer { gate.continuation.finish() }
        let progress = GenerationProgressLog()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in starts.bump() },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient(),
            onGenerationProgress: { progress.append($0.completedChunks) },
            onPreparedChunk: { _, _, _, _, _, _ in await gate.commit() }
        )
        let text = (1...12).map { "Sentence \($0) contains enough ordinary words to keep the narration moving through several chunks." }
            .joined(separator: " ")
        _ = try client.prepareSpeechText(text)
        try client.play(targetId: "rank3", from: 0)
        await waitUntil { starts.value >= 1 }
        await waitUntil { await renderer.renders.count >= 2 }
        client.debugFinishActiveChunk()
        await waitUntil { starts.value >= 2 }
        client.debugFinishActiveChunk()
        // Waiting at the boundary for chunk 3, which isn't rendering: chunk 2's commit is held.
        let rendersBefore = await renderer.renders.count
        XCTAssertEqual(rendersBefore, 2)
        let progressBefore = progress.completed.count
        let paused = try XCTUnwrap(client.currentCharOffset())
        try client.pause()
        try client.play(targetId: "rank3", from: paused)
        await waitUntil { starts.value >= 3 }
        XCTAssertEqual(starts.value, 3, "the third chunk plays")
        XCTAssertFalse(progress.completed.dropFirst(progressBefore).contains(0),
                       "no restart: progress never went back to 0 (\(progress.completed))")
        let renders = await renderer.renders
        XCTAssertEqual(Set(renders).count, renders.count, "no chunk rendered twice")
        try client.stop()
    }

    // #258: playing an article's durable prepared chunk and then stopping deleted that chunk,
    // because cleanup handed it to the renderer, which removed any file it was given.
    // Real player, real prepared-audio coordinator and SQLite, real renderer deletion.
    func testStoppingPlaybackKeepsAnArticlesDurablePreparedChunk() async throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "Supertonic", directoryHint: .isDirectory)
        let root = FileManager.default.temporaryDirectory.appending(path: "prepared-survives-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        let coordinator = PreparedAudioCoordinator(repository: store, rootDirectory: root.appending(path: "PreparedAudio", directoryHint: .isDirectory))
        let text = "Prepared audio must survive stopping playback."
        let plan = PreparedChunkPlan(index: 0, startOffset: 0, sourceLength: text.count, text: text)
        let signature = TTSRenderSignature(
            engine: "supertonic", modelRevision: "3", assetManifestHash: "assets", voiceStyleHash: "voice",
            synthesisParametersHash: "parameters", normalizationVersion: "normalization", chunkingVersion: "chunking",
            digest: "digest-258-prepared-survives"
        )
        _ = try await coordinator.begin(itemId: "item-258", sourceText: text, signature: signature, plan: [plan])
        let wav = try makeTestWAV(duration: 1)
        defer { try? FileManager.default.removeItem(at: wav) }
        try await coordinator.commit(itemId: "item-258", signature: signature, plan: plan, sourceText: text, audioURL: wav, durationMs: 1_000)
        let durable = try await XCTUnwrapAsync(await coordinator.committedChunk(itemId: "item-258", signature: signature, plan: plan, sourceText: text))

        let renderer = try SupertonicNarrationRenderer(
            assets: SupertonicAssetLocation(rootURL: resources),
            outputDirectory: root.appending(path: "Playback", directoryHint: .isDirectory)
        )
        let started = expectation(description: "prepared chunk started")
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1,
            fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in started.fulfill() },
            observesPlayerLifecycle: false,
            fallbackClient: RecordingFallbackAudioClient(),
            preparedChunkLookup: { _, _, requested in
                requested.startOffset == 0 ? try? await coordinator.committedChunk(itemId: "item-258", signature: signature, plan: plan, sourceText: text) : nil
            }
        )
        _ = try client.prepareSpeechText(text)
        try client.play(targetId: "item-258")
        await fulfillment(of: [started], timeout: 3)
        try client.stop()
        // Cleanup runs on the renderer's serial queue; let it drain.
        try? await Task.sleep(for: .milliseconds(300))
        _ = await renderer.diagnostics()

        XCTAssertTrue(FileManager.default.fileExists(atPath: durable.audioURL.path), "the durable prepared chunk survives stop")
        let again = try await coordinator.committedChunk(itemId: "item-258", signature: signature, plan: plan, sourceText: text)
        XCTAssertEqual(again?.audioURL, durable.audioURL, "and is still retrievable")
        await renderer.unload()
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    // #303: a play, or a rate change, on narration that's already playing threw away the live
    // audio and rendered from scratch (the owner's restart_rendering with intent playing, #288).
    func testPlayAndRateChangeWhilePlayingKeepTheLiveAudio() async throws {
        let template = try makeTestWAV(duration: 3)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = TextRecordingSupertonicRenderer(template: template)
        let starts = ResumeStartCounter()
        let progress = GenerationProgressLog()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {},
            audioPlayerStarter: { player, rate in starts.bump(); player.volume = 0; player.playImmediately(atRate: rate) },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient(),
            onGenerationProgress: { progress.append($0.completedChunks) }
        )
        let text = (1...10).map { "Sentence \($0) contains enough ordinary words to keep the narration moving through several chunks." }
            .joined(separator: " ")
        _ = try client.prepareSpeechText(text)
        try client.play(targetId: "item", from: 0)
        for _ in 0..<150 where starts.value < 1 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(400))
        let progressBefore = progress.completed.count
        let rendersBefore = await renderer.renders

        try client.play(targetId: "item", from: try XCTUnwrap(client.currentCharOffset()))
        try client.play(targetId: "item", from: try XCTUnwrap(client.currentCharOffset()))
        try client.setPlaybackRate(1.5)
        try client.play(targetId: "item", from: max(0, try XCTUnwrap(client.currentCharOffset()) + 20))
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertFalse(progress.completed.dropFirst(progressBefore).contains(0),
                       "no new generation: progress never went back to 0 (\(progress.completed))")
        let renders = await renderer.renders
        XCTAssertEqual(Set(renders).count, renders.count, "no chunk rendered twice")
        XCTAssertTrue(renders.starts(with: rendersBefore))
        XCTAssertEqual(starts.value, 1, "the live player kept playing; no new player started")
        try client.stop()
    }

    // #346 audit: a seek while playing reached the client as a plain play, and anything within
    // livePositionTolerance (about two seconds) of the live position was treated as "keep going".
    // A seek now says so and moves; a repeated play near the live position still doesn't.
    func testASmallSeekWhilePlayingMovesButARepeatedPlayDoesNot() async throws {
        let template = try makeTestWAV(duration: 3)
        defer { try? FileManager.default.removeItem(at: template) }
        let starts = ResumeStartCounter()
        let client = SupertonicSpeechPlaybackClient(
            renderer: TextRecordingSupertonicRenderer(template: template), voice: .m2, speed: 1,
            fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {},
            audioPlayerStarter: { player, rate in starts.bump(); player.volume = 0; player.playImmediately(atRate: rate) },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient()
        )
        let text = (1...10).map { "Sentence \($0) contains enough ordinary words to keep the narration moving through several chunks." }
            .joined(separator: " ")
        _ = try client.prepareSpeechText(text)
        try client.play(targetId: "item", from: 0)
        for _ in 0..<150 where starts.value < 1 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))

        let live = try XCTUnwrap(client.currentCharOffset())
        try client.play(targetId: "item", from: live + 20)
        XCTAssertLessThan(try XCTUnwrap(client.currentCharOffset()), live + 15, "a repeated play near the live position keeps going")
        let before = try XCTUnwrap(client.currentCharOffset())
        try client.play(targetId: "item", seekingTo: before + 20)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(client.currentCharOffset()), before + 20, "a seek moves, even this close")
        XCTAssertEqual(starts.value, 1, "in the same player")
        try client.stop()
    }

    private func stallClient(
        _ log: StallEventLog, template: URL, plays: Bool,
        playsFromStart: Int? = nil, onStart: (@Sendable (AVPlayer) -> Void)? = nil
    ) -> SupertonicSpeechPlaybackClient {
        SupertonicSpeechPlaybackClient(
            renderer: CountingAudioSupertonicRenderer(templateURL: template), voice: .m2, speed: 1,
            fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {},
            audioPlayerStarter: { player, rate in
                log.started()
                onStart?(player)
                if plays || playsFromStart.map({ log.startCount >= $0 }) == true {
                    player.volume = 0; player.playImmediately(atRate: rate)
                }
            },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient(),
            interruptionHandler: { event in log.stall("interruption.\(event)", [:]) },
            onStall: { kind, fields in log.stall(kind, fields) },
            stallThreshold: .milliseconds(400), stallSampleInterval: .milliseconds(100)
        )
    }

    // #288: the player says it's playing but its clock doesn't move. It must be noticed, logged
    // with the session's and player's state, and re-seated, at most once per 30 s.
    func testAPlayerWhoseClockStopsIsLoggedAndReseated() async throws {
        let template = try makeTestWAV(duration: 3)
        defer { try? FileManager.default.removeItem(at: template) }
        let log = StallEventLog()
        let client = stallClient(log, template: template, plays: false)
        _ = try client.prepareSpeechText("One sentence of narration is enough for this chunk.")
        try client.play(targetId: "stall", from: 0)
        for _ in 0..<150 where log.startCount < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(log.values.first, "supertonic.stall")
        XCTAssertEqual(log.lastFields["recovery"], "reseat_player")
        XCTAssertNotNil(log.lastFields["playerRate"])
        XCTAssertNotNil(log.lastFields["sessionCategory"], "the session's state is recorded")
        XCTAssertGreaterThanOrEqual(log.startCount, 2, "the player was re-seated")
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(log.values.filter { $0 == "supertonic.stall" }.count, 1, "at most one re-seat per 30 s")
        try client.stop()
    }

    // #302 Done when 3 and 5: a re-seat that doesn't bring the clock back used to leave the app
    // showing "playing" (and retry only after 30 s). It now pauses at the listener's place, so the
    // control shows Play, and one tap plays again in a new player whose clock advances.
    func testAStallTheReseatDoesNotFixPausesAndOneTapPlaysAgain() async throws {
        let template = try makeTestWAV(duration: 3)
        defer { try? FileManager.default.removeItem(at: template) }
        let log = StallEventLog()
        let client = stallClient(log, template: template, plays: false, playsFromStart: 3)
        _ = try client.prepareSpeechText("One sentence of narration is enough for this chunk.")
        try client.play(targetId: "tap", from: 0)
        for _ in 0..<150 where !log.values.contains("supertonic.stall_paused") { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(log.values.prefix(2), ["supertonic.stall", "supertonic.stall_paused"], "\(log.values)")
        XCTAssertTrue(log.values.contains("interruption.began"), "the app is told playback paused")
        XCTAssertEqual(client.playbackTransportState(targetId: "tap"), .paused, "the control shows Play, not Pause")
        XCTAssertEqual(log.startCount, 2, "one re-seat, then a pause")
        XCTAssertEqual(client.debugBackgroundAudioReleaseCount, 1, "other apps' audio is no longer lowered")

        try client.play(targetId: "tap", from: 0)
        for _ in 0..<100 where log.startCount < 3 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(log.startCount, 3, "one tap starts a new player")
        let before = client.currentCharOffset() ?? 0
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(client.playbackTransportState(targetId: "tap"), .playing)
        XCTAssertGreaterThan(client.currentCharOffset() ?? 0, before, "and its clock advances")
        XCTAssertEqual(log.values.filter { $0.hasPrefix("supertonic.stall") }.count, 2, "no new stall: \(log.values)")
        try client.stop()
    }

    // #301 audit: the listener switches items between a stall sample and its handling. The stale
    // stall must not re-seat or pause the new item's player.
    func testAStallSampledBeforeAnItemSwitchLeavesTheNewItemAlone() async throws {
        let template = try makeTestWAV(duration: 3)
        defer { try? FileManager.default.removeItem(at: template) }
        let log = StallEventLog()
        let client = stallClient(log, template: template, plays: false, playsFromStart: 2)
        let switcher = ItemSwitch()
        switcher.client = client
        client.debugStallWillBeHandled = { switcher.run() }
        _ = try client.prepareSpeechText("One sentence of narration is enough for this chunk.")
        try client.play(targetId: "first", from: 0)
        for _ in 0..<150 where log.startCount < 2 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(log.startCount, 2, "the new item started once and was never re-seated: \(log.values)")
        XCTAssertFalse(log.values.contains { $0.hasPrefix("supertonic.stall") }, "\(log.values)")
        XCTAssertEqual(client.playbackTransportState(targetId: "second"), .playing)
        try client.stop()
    }

    // #301 audit: a stall right after resuming mid-chunk, before the initial seek lands, reads the
    // player's clock as zero. The re-seat must keep the place asked for, not replay from the start.
    func testAReseatBeforeTheInitialSeekLandsKeepsTheRequestedPlace() async throws {
        let template = try makeTestWAV(duration: 3)
        defer { try? FileManager.default.removeItem(at: template) }
        let log = StallEventLog()
        let client = stallClient(log, template: template, plays: false) { player in
            player.currentItem?.cancelPendingSeeks()
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        _ = try client.prepareSpeechText("One sentence of narration is enough for this chunk.")
        try client.play(targetId: "mid", from: 24)
        for _ in 0..<150 where log.startCount < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThanOrEqual(log.startCount, 2, "re-seated: \(log.values)")
        XCTAssertGreaterThanOrEqual(client.currentRecoveryCharOffset() ?? 0, 24, "the place asked for is kept")
        try client.stop()
    }

    // Re-audit of #301: a pause and resume between the monitor's last sample and its exit left no
    // stall monitor, because the resume saw the exiting one and started nothing.
    func testResumingAsTheStallMonitorExitsKeepsAMonitor() async throws {
        let template = try makeTestWAV(duration: 3)
        defer { try? FileManager.default.removeItem(at: template) }
        let log = StallEventLog()
        let client = stallClient(log, template: template, plays: true)
        let resume = MonitorExitResume()
        resume.client = client
        client.debugStallMonitorWillExit = { resume.run() }
        _ = try client.prepareSpeechText("One sentence of narration is enough for this chunk.")
        try client.play(targetId: "exit", from: 0)
        for _ in 0..<100 where log.startCount < 1 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(300))
        try client.pause()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(client.debugHasStallMonitor, "playback resumed, so a stall monitor is running")
        try client.stop()
    }

    func testAPlayerThatIsPlayingIsNotAStall() async throws {
        let template = try makeTestWAV(duration: 3)
        defer { try? FileManager.default.removeItem(at: template) }
        let log = StallEventLog()
        let client = stallClient(log, template: template, plays: true)
        _ = try client.prepareSpeechText("One sentence of narration is enough for this chunk.")
        try client.play(targetId: "playing", from: 0)
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertTrue(log.values.isEmpty, "\(log.values)")
        XCTAssertEqual(log.startCount, 1)
        try client.stop()
    }

    /// A client whose render times out, so the iOS voice (`fallback`) takes over at offset 17.
    private func systemVoiceStallClient(_ log: StallEventLog, fallback: RecordingFallbackAudioClient) throws -> SupertonicSpeechPlaybackClient {
        let template = try makeTestWAV(duration: 0.5)
        addTeardownBlock { try? FileManager.default.removeItem(at: template) }
        return SupertonicSpeechPlaybackClient(
            renderer: CountingAudioSupertonicRenderer(templateURL: template, firstRenderDelay: .seconds(1)),
            voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in }, observesPlayerLifecycle: false,
            fallbackClient: fallback,
            interruptionHandler: { event in log.stall("interruption.\(event)", [:]) },
            onFallback: { _, _, _ in log.stall("fallback", [:]) },
            onStall: { kind, fields in log.stall(kind, fields) },
            stallThreshold: .milliseconds(400), stallSampleInterval: .milliseconds(100),
            renderWaitLimit: .milliseconds(100)
        )
    }

    // #288: after a render timeout handed the article to the iOS voice, that voice went silent while
    // the app said "playing", and only the listener's pause and play brought it back. The watchdog
    // didn't look at the iOS voice. Now a place that stops moving is noticed and gets that same
    // pause and play; if that doesn't help, playback pauses so the control shows Play.
    func testASilentIOSVoiceIsRestartedAtItsPlaceThenPausedForATap() async throws {
        let log = StallEventLog()
        let fallback = RecordingFallbackAudioClient()
        let client = try systemVoiceStallClient(log, fallback: fallback)
        _ = try client.prepareSpeechText("A long response that must remain playable when generation does not finish promptly.")
        try client.play(targetId: "silent", from: 17)
        for _ in 0..<150 where !log.values.contains("supertonic.stall") { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(log.values.prefix(2), ["fallback", "supertonic.stall"], "\(log.values)")
        XCTAssertEqual(log.lastFields["recovery"], "restart_system_voice")
        XCTAssertEqual(log.lastFields["engine"], "system_voice")
        XCTAssertEqual(fallback.playedOffsets, [17, 17], "the iOS voice speaks again from the same place")
        XCTAssertGreaterThanOrEqual(fallback.pauseCount, 1, "after a pause, as the listener's recovery did")

        for _ in 0..<150 where !log.values.contains("supertonic.stall_paused") { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(log.values.contains("supertonic.stall_paused"), "\(log.values)")
        XCTAssertTrue(log.values.contains("interruption.began"), "the app is told playback paused")
        XCTAssertEqual(client.playbackTransportState(targetId: "silent"), .paused, "the control shows Play, not Pause")

        fallback.advancesPerRead = 3
        try client.play(targetId: "silent", from: 17)
        XCTAssertEqual(fallback.playedOffsets, [17, 17, 17], "one tap speaks from the same place")
        let stalls = log.values.filter { $0.hasPrefix("supertonic.stall") }.count
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(client.playbackTransportState(targetId: "silent"), .playing)
        XCTAssertEqual(log.values.filter { $0.hasPrefix("supertonic.stall") }.count, stalls, "no new stall: \(log.values)")
        try client.stop()
    }

    // #288: an iOS voice whose place moves, or that finished the article, isn't a stall.
    func testASpeakingOrFinishedIOSVoiceIsNotAStall() async throws {
        let log = StallEventLog()
        let fallback = RecordingFallbackAudioClient()
        fallback.advancesPerRead = 2
        let client = try systemVoiceStallClient(log, fallback: fallback)
        _ = try client.prepareSpeechText("A long response that must remain playable when generation does not finish promptly.")
        try client.play(targetId: "speaking", from: 17)
        for _ in 0..<100 where !log.values.contains("fallback") { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(log.values, ["fallback"])

        fallback.advancesPerRead = 0
        fallback.completedTargetId = "speaking"
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(log.values, ["fallback"], "the end of the article isn't a stall")
        XCTAssertEqual(fallback.playedOffsets, [17])
        try client.stop()
    }

    // #258: with a Listening Map overview, the engine speaks "Overview. …" before the article.
    // Lookups carried that whole text and chunks planned across it, so no prepared chunk ever
    // matched and a fully prepared article was rendered again. They now ask for the article's own
    // prepared chunks, with the article plan's identity.
    func testLookupsWithASpokenPrefaceAskForTheArticlesPreparedChunks() async throws {
        let template = try makeTestWAV(duration: 0.1)
        defer { try? FileManager.default.removeItem(at: template) }
        let article = (1...8).map { "Sentence \($0) of the article carries enough ordinary words to fill part of a chunk." }
            .joined(separator: " ")
        let preface = "Overview. The paper studies evaluation agents and how they choose their tools.\n\n"
        let log = PreparedLookupLog()
        let client = SupertonicSpeechPlaybackClient(
            renderer: CountingAudioSupertonicRenderer(templateURL: template), voice: .m2, speed: 1,
            fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient(),
            articleText: { _ in article },
            preparedChunkLookup: { _, source, plan in log.add(source, plan); return nil }
        )
        let prepared = RenderedSpeechChunker.sourceSlices(from: SpeechTextNormalizer.normalize(article)).enumerated().map {
            PreparedChunkPlan(index: $0.offset, startOffset: $0.element.startOffset,
                              sourceLength: $0.element.slice.sourceLength, text: $0.element.slice.text)
        }
        _ = try client.prepareSpeechText(preface + article)
        try client.play(targetId: "item", from: 0)
        for _ in 0..<150 where Set(log.values.map { $0.1.index }).count < prepared.count {
            try await Task.sleep(for: .milliseconds(20))
        }
        let asked = log.values
        XCTAssertTrue(asked.allSatisfy { $0.0 == NarrationChunkPlanner.identity(ofArticle: article) },
                      "lookups carry the article plan's identity (#312)")
        let byIndex = Dictionary(asked.map { ($0.1.index, $0.1) }, uniquingKeysWith: { first, _ in first })
        for chunk in prepared {
            XCTAssertEqual(byIndex[chunk.index], chunk, "chunk \(chunk.index) matches the prepared plan")
        }
        try client.stop()
    }

    // #312: the player, background preparation and assembly must split an article the same way.
    // All three now take the article plan from NarrationChunkPlanner; the player's lookups must ask
    // for exactly the background plan, with or without a spoken Overview preface.
    func testPlayerLookupsMatchTheBackgroundPlanWithAndWithoutAPreface() async throws {
        let article = (1...8).map { "Sentence \($0) of the article carries enough ordinary words to fill part of a chunk." }
            .joined(separator: " ")
        let prepared = backgroundPlan(article)
        for preface in ["", "Overview. The paper studies evaluation agents and how they choose their tools.\n\n"] {
            let asked = try await preparedLookups(spoken: preface + article, article: article, waitFor: prepared.count)
            XCTAssertTrue(asked.allSatisfy { $0.0 == NarrationChunkPlanner.identity(ofArticle: article) },
                          "lookups carry the article plan's identity (preface: \(!preface.isEmpty))")
            let byIndex = Dictionary(asked.map { ($0.1.index, $0.1) }, uniquingKeysWith: { first, _ in first })
            XCTAssertEqual(byIndex.count, prepared.count, "preface: \(!preface.isEmpty)")
            for chunk in prepared {
                XCTAssertEqual(byIndex[chunk.index], chunk, "chunk \(chunk.index) matches (preface: \(!preface.isEmpty))")
            }
        }
    }

    // #312: a bare "<" in the Overview and a ">" in the article. Normalizing the whole spoken text
    // eats across the seam, so the spoken article no longer matches the prepared one. The player
    // used to ask for prepared chunks by position anyway, which could play another stretch's audio.
    func testASeamThatChangesTheSpokenArticleMatchesNoPreparedAudio() async throws {
        let article = "Results > baseline in every run. " + (1...8).map {
            "Sentence \($0) of the article carries enough ordinary words to fill part of a chunk."
        }.joined(separator: " ")
        let preface = "Overview. Cost < quality for these agents.\n\n"
        let normalized = NarrationChunkPlanner.articlePlan(article).normalizedText
        XCTAssertNotEqual(String(SpeechTextNormalizer.normalize(preface + article).suffix(normalized.count)), normalized,
                          "the seam changes the spoken article (precondition)")
        let prepared = backgroundPlan(article)
        let asked = try await preparedLookups(spoken: preface + article, article: article, waitFor: prepared.count)
        let wrong = asked.filter { !prepared.contains($0.1) }
        XCTAssertTrue(wrong.isEmpty, "\(wrong.count) lookups asked for plans background preparation never made")
    }

    /// Background preparation's plan: the same function the app calls.
    private func backgroundPlan(_ article: String) -> [PreparedChunkPlan] {
        PreparedChunkPlan.articlePlan(article)
    }

    private func preparedLookups(spoken: String, article: String, waitFor count: Int) async throws -> [(String, PreparedChunkPlan)] {
        let template = try makeTestWAV(duration: 0.1)
        defer { try? FileManager.default.removeItem(at: template) }
        let log = PreparedLookupLog()
        let client = SupertonicSpeechPlaybackClient(
            renderer: CountingAudioSupertonicRenderer(templateURL: template), voice: .m2, speed: 1,
            fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient(),
            articleText: { _ in article },
            preparedChunkLookup: { _, identity, plan in log.add(identity, plan); return nil }
        )
        _ = try client.prepareSpeechText(spoken)
        try client.play(targetId: "item", from: 0)
        for _ in 0..<150 where Set(log.values.map { $0.1.index }).count < count {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))
        try client.stop()
        return log.values
    }

    private func guardTemplate(_ root: URL) throws -> URL {
        let url = root.appending(path: "t.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)); buffer.frameLength = 44_100
        try file.write(from: buffer)
        return url
    }

    private func crossChunkTemplate(_ root: URL) throws -> URL {
        let url = root.appending(path: "t.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132_300)); buffer.frameLength = 132_300
        try file.write(from: buffer)
        return url
    }

    // #311: the guard's iOS-voice file is deleted when the player discards it.
    func testGuardDeletesItsStandInFileOnDiscard() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "guard-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let guardRenderer = SupertonicOutputGuard(wrapping: BabbleSupertonicRenderer(template: try guardTemplate(root), seconds: 20), systemVoiceIdentifier: nil)
        let result = try await guardRenderer.render(
            text: "Table 3 reports 91.1% 8.9% 0.0 and 7,494 tool decisions across 2,548 summaries.",
            voice: .m2, language: "en", speed: 1, synthesisSteps: 8
        )
        XCTAssertTrue(result.audioURL.lastPathComponent.hasPrefix("system-voice-"), "the guard stood in")
        XCTAssertEqual(result.engine, SupertonicNarrationResult.systemVoiceEngine)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.audioURL.path))
        await guardRenderer.discardGeneratedAudio(at: result.audioURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.audioURL.path), "the stand-in file is deleted")
    }

    // #311: a stand-in isn't cached under the Supertonic key, so the next play re-checks Supertonic.
    func testStandInIsNotCachedAsSupertonic() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "guard-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "Table 3 reports 91.1% 8.9% 0.0 and 7,494 tool decisions across 2,548 summaries."
        let cache = try RenderedSpeechDiskCache(directory: root.appending(path: "cache"), limitBytes: 50_000_000)
        let started = expectation(description: "the stand-in plays")
        let client = SupertonicSpeechPlaybackClient(
            renderer: SupertonicOutputGuard(wrapping: BabbleSupertonicRenderer(template: try guardTemplate(root), seconds: 20), systemVoiceIdentifier: nil),
            voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            diskCache: cache, audioSessionActivator: {}, audioPlayerStarter: { _, _ in started.fulfill() },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient()
        )
        _ = try client.prepareSpeechText(text)
        try client.play(targetId: "item", from: 0)
        await fulfillment(of: [started], timeout: 10)
        XCTAssertNil(cache.cachedAudio(text: SpeechTextNormalizer.normalize(text), voice: .m2, language: "en", speed: 1, synthesisSteps: 8),
                     "the iOS-voice audio isn't cached as Supertonic's")
        try client.stop()
    }

    // #363 audit: background preparation made a guard per chunk and never discarded its render, so
    // every flagged chunk left an iOS-voice file behind. The render is discarded once kept, or on
    // failure.
    func testABackgroundRenderIsDiscardedOnceKeptOrOnFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "guard-keep-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let guardRenderer = SupertonicOutputGuard(wrapping: BabbleSupertonicRenderer(template: try guardTemplate(root), seconds: 20), systemVoiceIdentifier: nil)
        let text = "Table 3 reports 91.1% 8.9% 0.0 and 7,494 tool decisions across 2,548 summaries."
        var standIn: URL?
        let kept = try await guardRenderer.render(text: text, voice: .m2, language: "en", speed: 1, synthesisSteps: 8) { rendered in
            standIn = rendered.audioURL
            let copy = root.appending(path: "kept.wav")
            try FileManager.default.copyItem(at: rendered.audioURL, to: copy)
            return copy
        }
        XCTAssertTrue(try XCTUnwrap(standIn).lastPathComponent.hasPrefix("system-voice-"), "the guard stood in")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(standIn).path), "the stand-in is deleted once kept")

        do {
            _ = try await guardRenderer.render(text: text, voice: .m2, language: "en", speed: 1, synthesisSteps: 8) { rendered -> URL in
                standIn = rendered.audioURL
                throw CancellationError()
            }
            XCTFail("the failure is rethrown")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(standIn).path), "and on failure")
    }

    // #363 audit: before #311 a stand-in could be cached under the Supertonic key. The key's
    // version moved on, so such an entry is never found again.
    func testAnEntryCachedUnderTheOldKeyIsNotFound() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cache-v1-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "An entry cached before the key changed."
        let payload = "supertonic-v1\u{1f}M2\u{1f}en\u{1f}\(Float(1))\u{1f}8\u{1f}\(text)"
        let digest = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root.appending(path: "cache", directoryHint: .isDirectory)
        let cache = try RenderedSpeechDiskCache(directory: directory, limitBytes: 50_000_000)
        try FileManager.default.copyItem(at: try guardTemplate(root), to: directory.appending(path: "\(digest).wav"))
        XCTAssertNil(cache.cachedAudio(text: text, voice: .m2, language: "en", speed: 1, synthesisSteps: 8))
    }

    // #363 audit (#311 outcome: a wrongly flagged chunk can be rendered again): after a full
    // listen, the whole article was assembled with its iOS-voice stand-ins and attached as the
    // item's audio, so the stand-in played forever. It isn't assembled while a stand-in remains;
    // with Supertonic's own audio it still is.
    func testAnArticleWithAStandInIsNotAssembledButOneWithoutIs() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "assemble-standin-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "A short sentence that Supertonic reads in about three seconds."
        for (seconds, expectsAssembly) in [(20.0, false), (4.0, true)] {
            let assembled = expectation(description: "assembled (\(seconds) s)")
            assembled.isInverted = !expectsAssembly
            let ready = expectation(description: "generation reports ready (\(seconds) s)")
            ready.assertForOverFulfill = false
            let client = SupertonicSpeechPlaybackClient(
                renderer: SupertonicOutputGuard(wrapping: BabbleSupertonicRenderer(template: try guardTemplate(root), seconds: seconds),
                                                systemVoiceIdentifier: nil),
                voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
                preparedAudioDirectory: root.appending(path: "assembled-\(Int(seconds))", directoryHint: .isDirectory),
                audioSessionActivator: {}, audioPlayerStarter: { _, _ in },
                observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient(),
                onGenerationStateChange: { state, _ in if state == .ready { ready.fulfill() } },
                onPreparedAudio: { _, _ in assembled.fulfill() }
            )
            _ = try client.prepareSpeechText(text)
            try client.play(targetId: "item", from: 0)
            // #363 audit: with a stand-in, generation must still end, not show "Generating" forever.
            await fulfillment(of: [ready], timeout: 8)
            await fulfillment(of: [assembled], timeout: expectsAssembly ? 8 : 1)
            try client.stop()
        }
    }

    // #363 audit: a stop during a stand-in render that ignores cancellation returned a file that
    // nothing owned; the cancellation check threw and the file leaked.
    func testAStopDuringAnUncachedRenderDeletesItsFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cancel-standin-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = SlowStandInRenderer(template: try guardTemplate(root))
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient()
        )
        _ = try client.prepareSpeechText("A sentence the guard hands to the iOS voice.")
        try client.play(targetId: "item", from: 0)
        for _ in 0..<50 where renderer.made.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try client.stop()
        try await Task.sleep(for: .milliseconds(700))
        let made = renderer.made
        XCTAssertEqual(made.count, 1)
        XCTAssertFalse(made.contains { FileManager.default.fileExists(atPath: $0.path) }, "the stand-in file was deleted")
    }

    private let crossChunkText = (1...12).map { "Sentence \($0) contains enough ordinary words to keep the narration moving through several chunks." }
        .joined(separator: " ")

    private func chunkStarts() -> [Int] {
        RenderedSpeechChunker.sourceSlices(from: SpeechTextNormalizer.normalize(crossChunkText)).map(\.startOffset)
    }

    // Audit of #346 (1): playing a cached chunk removes it from the cache. Seek ahead into C, then
    // back into B; when B ends, C must still play rather than leave silence.
    func testSeekingAheadThenBackStillPlaysTheLaterChunk() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xc1-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = OrderGatedSupertonicRenderer(template: try crossChunkTemplate(root), gates: [:])
        let starts = ResumeStartCounter()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { player, rate in starts.bump(); player.volume = 0; player.playImmediately(atRate: rate) },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient()
        )
        let offsets = chunkStarts()
        XCTAssertGreaterThanOrEqual(offsets.count, 4)
        _ = try client.prepareSpeechText(crossChunkText)
        try client.play(targetId: "item", from: 0)
        for _ in 0..<150 where await renderer.count < offsets.count { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        try client.play(targetId: "item", from: offsets[2] + 5)   // ahead into C
        try await Task.sleep(for: .milliseconds(200))
        try client.play(targetId: "item", from: offsets[1] + 5)   // back into B
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(client.debugActiveAudioState().startOffset, offsets[1], "B plays")
        let before = starts.value
        client.debugFinishActiveChunk()                            // B ends
        for _ in 0..<50 where starts.value == before { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(starts.value, before + 1, "the next chunk started after B")
        XCTAssertEqual(client.debugActiveAudioState().startOffset, offsets[2], "C plays after B")
        try client.stop()
    }

    // Audit of #346 (2): a seek into cached B left an autoplay marker for still-rendering C, so
    // when C finished it played over B.
    func testALaterRenderDoesNotPlayOverTheChunkTheListenerChose() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xc2-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gateC = AsyncStream<Void>.makeStream()
        defer { gateC.continuation.finish() }
        let renderer = OrderGatedSupertonicRenderer(template: try crossChunkTemplate(root), gates: [3: gateC.stream])
        let starts = ResumeStartCounter()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { player, rate in starts.bump(); player.volume = 0; player.playImmediately(atRate: rate) },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient()
        )
        let offsets = chunkStarts()
        _ = try client.prepareSpeechText(crossChunkText)
        try client.play(targetId: "item", from: 0)                 // A plays; B renders; C is held
        for _ in 0..<150 where await renderer.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        try client.play(targetId: "item", from: offsets[2] + 5)    // ahead into C, still rendering
        try await Task.sleep(for: .milliseconds(100))
        try client.play(targetId: "item", from: offsets[1] + 5)    // back into cached B
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(client.debugActiveAudioState().startOffset, offsets[1], "B plays")
        let before = starts.value
        gateC.continuation.finish()                                 // C finishes rendering
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(starts.value, before, "C didn't start over B")
        XCTAssertEqual(client.debugActiveAudioState().startOffset, offsets[1], "B is still playing")
        try client.stop()
    }

    // Re-audit of #346: from a paused A, choosing rendering C and then going back to A left C as
    // the requested position, so the reported position (and the next pause and resume) jumped to C.
    func testGoingBackToAPausedChunkReportsItsOwnPosition() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xc3-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gateC = AsyncStream<Void>.makeStream()
        defer { gateC.continuation.finish() }
        let renderer = OrderGatedSupertonicRenderer(template: try crossChunkTemplate(root), gates: [3: gateC.stream])
        let starts = ResumeStartCounter()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { player, rate in starts.bump(); player.volume = 0; player.playImmediately(atRate: rate) },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient()
        )
        let offsets = chunkStarts()
        _ = try client.prepareSpeechText(crossChunkText)
        try client.play(targetId: "item", from: 0)
        for _ in 0..<150 where await renderer.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        try client.pause()
        let pausedAt = try XCTUnwrap(client.currentCharOffset())
        XCTAssertLessThan(pausedAt, offsets[1], "paused in A")
        try client.play(targetId: "item", from: offsets[2] + 5)   // choose C, still rendering
        try client.play(targetId: "item", from: pausedAt)          // back to A
        let reported = try XCTUnwrap(client.currentCharOffset())
        XCTAssertLessThan(reported, offsets[1], "the position is back in A, not C (\(reported))")
        try client.stop()
    }

    func testSelectableCatalogExposesOnlyJamesLilyAndSystem() {
        XCTAssertEqual(AppTTSVoiceSelection.allCases, [.james, .lily, .system])
        XCTAssertEqual(AppTTSVoiceSelection.james.rawValue, "supertonic:M2")
        XCTAssertEqual(AppTTSVoiceSelection.james.supertonicVoice, .m2)
        XCTAssertEqual(AppTTSVoiceSelection.lily.rawValue, "supertonic:F2")
        XCTAssertEqual(AppTTSVoiceSelection.lily.supertonicVoice, .f2)
        XCTAssertNil(AppTTSVoiceSelection.system.supertonicVoice)
    }

    func testIdleSupertonicMixPolicyForwardsWithoutActivatingAnAudioSession() throws {
        let fallback = RecordingFallbackAudioClient()
        let client = SupertonicSpeechPlaybackClient(
            renderer: FailingSupertonicRenderer(),
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionActivator: {
                throw NSError(domain: "unexpected_idle_audio_session_activation", code: 1)
            },
            fallbackClient: fallback
        )

        try client.setMixesWithOtherAudio(true)
        try client.setLowersBackgroundAudio(true)
        try client.setPlaybackVolume(0.35)

        XCTAssertEqual(fallback.backgroundAudioStates, [true])
        XCTAssertEqual(fallback.mixingStates, [true])
        XCTAssertEqual(fallback.playbackVolumes, [0.35])
    }

    func testChunkerPrefersSentenceThenCommaThenWhitespaceAndCapsLength() {
        let sentence = String(repeating: "opening words ", count: 8) + "finished. More text follows."
        let sentenceSlice = RenderedSpeechChunker.selectChunkPrefix(sentence, maxCharacters: 150)
        XCTAssertEqual(sentenceSlice.boundary, .sentence)
        XCTAssertTrue(sentenceSlice.text.hasSuffix("."))

        let comma = String(repeating: "opening words ", count: 8) + "pause, more text follows"
        let commaSlice = RenderedSpeechChunker.selectChunkPrefix(comma, maxCharacters: 150)
        XCTAssertEqual(commaSlice.boundary, .comma)
        XCTAssertTrue(commaSlice.text.hasSuffix(","))

        let whitespace = String(repeating: "abcdefghij ", count: 30)
        let whitespaceSlice = RenderedSpeechChunker.sourceSlice(from: whitespace, startOffset: 0)
        XCTAssertEqual(whitespaceSlice.boundary, .whitespace)
        XCTAssertLessThanOrEqual(whitespaceSlice.sourceLength, 240)
        XCTAssertFalse(whitespaceSlice.text.hasSuffix(" "))
    }

    func testChunkerMaintainsSourceOffsetsAcrossEmojiAndWhitespace() {
        let prefix = "Intro 😀 sentence. "
        let source = prefix + String(repeating: "Long body words ", count: 30)
        let slice = RenderedSpeechChunker.sourceSlice(from: source, startOffset: prefix.count)
        XCTAssertFalse(slice.text.isEmpty)
        XCTAssertLessThanOrEqual(prefix.count + slice.sourceLength, source.count)
        let start = source.index(source.startIndex, offsetBy: prefix.count)
        let end = source.index(start, offsetBy: slice.sourceLength)
        XCTAssertTrue(String(source[start..<end]).contains(slice.text.prefix(8)))
    }

    func testChunkerPlansLongSourcesInOneMonotonicPass() {
        let source = String(String(repeating: "A long 😀 sentence with stable offsets. ", count: 4_000).dropLast())
        let plan = RenderedSpeechChunker.sourceSlices(from: source)

        XCTAssertFalse(plan.isEmpty)
        XCTAssertEqual(plan.first?.startOffset, 0)
        for pair in zip(plan, plan.dropFirst()) {
            XCTAssertEqual(pair.0.startOffset + pair.0.slice.sourceLength, pair.1.startOffset)
        }
        let consumed = plan.last.map { $0.startOffset + $0.slice.sourceLength }
        XCTAssertEqual(consumed, source.count)
        XCTAssertTrue(plan.allSatisfy { !$0.slice.text.isEmpty && $0.slice.sourceLength <= 240 })
    }

    func testRenderFailureFallsBackAtLastConfirmedSourceOffset() async throws {
        let fallback = RecordingFallbackAudioClient()
        let callback = expectation(description: "fallback callback")
        let client = SupertonicSpeechPlaybackClient(
            renderer: FailingSupertonicRenderer(),
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            fallbackClient: fallback,
            onFallback: { reason, offset, targetId in
                XCTAssertEqual(reason, "supertonic_render_failed:Failure")
                XCTAssertEqual(offset, 17)
                XCTAssertEqual(targetId, "item")
                callback.fulfill()
            }
        )
        let source = "Start here, then continue through the rest of this sentence."
        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "item", from: 17)

        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(fallback.preparedText, source)
        XCTAssertEqual(fallback.playedOffsets, [17])
        XCTAssertEqual(client.currentCharOffset(), 17)
    }

    func testResourcePressureStopsGenerationBeforeSystemFallbackBecomesAudible() async throws {
        let template = try makeTestWAV(duration: 0.2)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let availability = RenderingAvailabilitySequence(allowedChecks: 2)
        let fallback = RecordingFallbackAudioClient()
        let callback = expectation(description: "resource-pressure fallback")
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            maxCharacters: 120,
            startupBufferChunkCount: 2,
            onDeviceRenderingAllowed: { availability.next() },
            fallbackClient: fallback,
            onFallback: { reason, offset, targetId in
                XCTAssertEqual(reason, "supertonic_resource_pressure")
                XCTAssertEqual(offset, 0)
                XCTAssertEqual(targetId, "thermal-pressure")
                callback.fulfill()
            }
        )
        let source = String(repeating: "A sufficiently long sentence creates several generated chunks. ", count: 12)
        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "thermal-pressure")

        await fulfillment(of: [callback], timeout: 2)
        let countAtFallback = await renderer.renderCount
        try? await Task.sleep(for: .milliseconds(300))
        let finalRenderCount = await renderer.renderCount

        XCTAssertEqual(countAtFallback, 1)
        XCTAssertEqual(finalRenderCount, countAtFallback)
        XCTAssertEqual(fallback.playedOffsets, [0])
        XCTAssertEqual(client.playbackTransportState(targetId: "thermal-pressure"), .playing)
        try client.stop()
    }

    func testSlowSpeculativeChunkDoesNotSwitchAudiblePreparedPlaybackToFallback() async throws {
        let template = try makeTestWAV(duration: 3)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template, renderDelays: [2: .milliseconds(600)])
        let fallback = RecordingFallbackAudioClient()
        let started = expectation(description: "prepared playback started")
        started.assertForOverFulfill = false
        let unwantedFallback = expectation(description: "no speculative timeout fallback")
        unwantedFallback.isInverted = true
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            maxCharacters: 120,
            audioSessionActivator: {}, audioPlayerStarter: { player, rate in
                player.playImmediately(atRate: rate)
                started.fulfill()
            }, observesPlayerLifecycle: false,
            fallbackClient: fallback,
            onFallback: { _, _, _ in unwantedFallback.fulfill() }, renderWaitLimit: .milliseconds(100)
        )
        _ = try client.prepareSpeechText(String(repeating: "This source has several chunks of prepared speech. ", count: 15))
        try client.play(targetId: "speculative")
        await fulfillment(of: [started], timeout: 2)
        await fulfillment(of: [unwantedFallback], timeout: 0.8)
        XCTAssertTrue(fallback.playedOffsets.isEmpty)
        XCTAssertEqual(client.playbackTransportState(targetId: "speculative"), .playing)
        try client.stop()
    }

    func testStalledRendererFallsBackWithinBoundAndCanRetryCurrentTarget() async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template, firstRenderDelay: .seconds(1))
        let fallback = RecordingFallbackAudioClient()
        let timedOut = expectation(description: "bounded fallback")
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in }, observesPlayerLifecycle: false,
            fallbackClient: fallback,
            onFallback: { reason, offset, _ in
                XCTAssertEqual(reason, "supertonic_render_timeout")
                XCTAssertEqual(offset, 17)
                timedOut.fulfill()
            }, renderWaitLimit: .milliseconds(100)
        )
        _ = try client.prepareSpeechText("A long response that must remain playable when generation does not finish promptly.")
        try client.play(targetId: "response-timeout", from: 17)
        await fulfillment(of: [timedOut], timeout: 2)
        XCTAssertEqual(fallback.playedOffsets, [17])
        XCTAssertTrue(try client.retryOnDeviceRendering())
        let retried = await waitForRenderCount(renderer, minimum: 2)
        XCTAssertGreaterThanOrEqual(retried, 2)
        try client.stop()
    }

    /// #314 audit on 099b712: the voice line preferred the model's one app-wide fallback reason
    /// over the stop's own reason, so an item could show another item's reason (A stopped by
    /// the listener, B hit a memory warning, back on A the line said memory warning). The stop
    /// reason now decides, so a fallback stop must name why the iOS voice took over.
    func testAFallbackStopNamesWhyTheIOSVoiceTookOverAndThatReasonDecidesTheLine() async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template, firstRenderDelay: .seconds(1))
        let states = GenerationStateCapture()
        let timedOut = expectation(description: "bounded fallback")
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in }, observesPlayerLifecycle: false,
            fallbackClient: RecordingFallbackAudioClient(),
            onGenerationStateChange: { state, stopReason in states.record(state, stopReason: stopReason) },
            onFallback: { _, _, _ in timedOut.fulfill() },
            renderWaitLimit: .milliseconds(100)
        )
        _ = try client.prepareSpeechText("A long response that must remain playable when generation does not finish promptly.")
        try client.play(targetId: "response-timeout", from: 17)
        await fulfillment(of: [timedOut], timeout: 2)
        XCTAssertEqual(
            states.stopReasons.last, SpeechFallbackReason.renderTooSlow.rawValue,
            "The stop that hands over to the iOS voice says why it did"
        )

        func line(_ stopReason: String) -> String {
            RenderedSpeechGenerationState.stopped.listenerDescription(
                progress: RenderedSpeechGenerationProgress(completedChunks: 0, totalChunks: 0),
                isDelayed: false,
                stopReason: stopReason,
                fallbackReason: .memoryWarning  // left over from another item
            )
        }
        XCTAssertEqual(line(SpeechFallbackReason.renderTooSlow.rawValue), SpeechFallbackReason.renderTooSlow.listenerExplanation)
        XCTAssertEqual(
            line(SpeechFallbackReason.listenerStoppedGeneration.rawValue),
            SpeechFallbackReason.listenerStoppedGeneration.listenerExplanation
        )
        try client.stop()
    }

    func testUnavailableConfiguredSystemVoiceDoesNotSilentlyUseGenericVoice() throws {
        let client = SystemSpeechPlaybackClient(
            voiceIdentifier: "com.spokenmargins.missing-voice",
            speechRate: 0.5,
            isVoiceAvailable: { identifier in
                XCTAssertEqual(identifier, "com.spokenmargins.missing-voice")
                return false
            }
        )
        _ = try client.prepareSpeechText("Keep the configured voice identity truthful.")

        XCTAssertThrowsError(try client.play(targetId: "missing-system-voice")) { error in
            XCTAssertTrue(error.localizedDescription.contains("selected_speech_voice_unavailable"))
        }
    }

    func testMalformedRenderedAudioFallsBackWithoutAdvancingOffset() async throws {
        let malformedURL = FileManager.default.temporaryDirectory
            .appending(path: "malformed-\(UUID().uuidString).wav")
        try Data("not a wav".utf8).write(to: malformedURL)
        defer { try? FileManager.default.removeItem(at: malformedURL) }
        let fallback = RecordingFallbackAudioClient()
        let callback = expectation(description: "malformed audio fallback")
        let client = SupertonicSpeechPlaybackClient(
            renderer: FixedAudioSupertonicRenderer(audioURL: malformedURL),
            voice: .f2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            fallbackClient: fallback,
            onFallback: { reason, offset, targetId in
                XCTAssertEqual(reason, "supertonic_playback_failed")
                XCTAssertEqual(offset, 9)
                XCTAssertEqual(targetId, "malformed")
                callback.fulfill()
            }
        )
        _ = try client.prepareSpeechText("Continue this sentence after the confirmed offset.")
        try client.play(targetId: "malformed", from: 9)

        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(fallback.playedOffsets, [9])
    }

    func testSourceOffsetsSurviveWhitespaceAndURLNormalization() async throws {
        let template = try makeTestWAV(duration: 1)
        defer { try? FileManager.default.removeItem(at: template) }
        let client = SupertonicSpeechPlaybackClient(
            renderer: CountingAudioSupertonicRenderer(templateURL: template),
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionActivator: {},
            audioPlayerStarter: { _, _ in },
            observesPlayerLifecycle: false,
            fallbackClient: RecordingFallbackAudioClient()
        )
        let source = "Opening.\n\nhttps://example.com/removed\n\nDestination sentence."
        let destinationRange = try XCTUnwrap(source.range(of: "Destination"))
        let destinationOffset = source.distance(from: source.startIndex, to: destinationRange.lowerBound)

        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "normalized-offset", from: destinationOffset)
        for _ in 0..<50 where !client.debugActiveAudioState().hasURL {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(client.currentRecoveryCharOffset(), destinationOffset)
        XCTAssertEqual(client.currentCharOffset(), destinationOffset)
        try client.stop()
    }

    func testPausedPlaybackCanSeekWithinRenderedChunk() async throws {
        let template = try makeTestWAV(duration: 5)
        defer { try? FileManager.default.removeItem(at: template) }
        let client = SupertonicSpeechPlaybackClient(
            renderer: CountingAudioSupertonicRenderer(templateURL: template),
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionActivator: {},
            audioPlayerStarter: { _, _ in },
            observesPlayerLifecycle: false,
            fallbackClient: RecordingFallbackAudioClient()
        )
        let source = "Opening words lead toward the destination phrase and then continue for a while."
        let destinationRange = try XCTUnwrap(source.range(of: "destination"))
        let destinationOffset = source.distance(from: source.startIndex, to: destinationRange.lowerBound)

        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "paused-seek")
        for _ in 0..<50 where !client.debugActiveAudioState().hasURL {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try client.pause()
        try client.play(targetId: "paused-seek", from: destinationOffset)
        try client.pause()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertLessThanOrEqual(abs((client.currentCharOffset() ?? 0) - destinationOffset), 2)
        try client.stop()
    }

    func testPlaybackRendersEveryChunkWithoutWaitingForPlaybackToAdvance() async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let ready = expectation(description: "full generation ready")
        let progress = GenerationProgressCapture()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            fallbackClient: RecordingFallbackAudioClient(),
            onGenerationStateChange: { state, _ in
                if state == .ready { ready.fulfill() }
            },
            onGenerationProgress: { update in
                progress.record(update)
            }
        )
        let source = (1...8).map { index in
            "Sentence \(index) contains enough ordinary words to form a useful spoken chunk."
        }.joined(separator: " ")
        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "prefetch")

        await fulfillment(of: [ready], timeout: 3)
        let renderCount = await renderer.renderCount
        XCTAssertEqual(renderCount, renderedChunkCount(source))
        XCTAssertGreaterThan(renderCount, 2)
        XCTAssertEqual(progress.values.first?.completedChunks, 0)
        XCTAssertEqual(progress.values.first?.totalChunks, renderCount)
        XCTAssertEqual(progress.values.last?.completedChunks, renderCount)
        XCTAssertEqual(progress.values.last?.percent, 100)
        for _ in 0..<100 where client.playbackStartStatus(targetId: "prefetch") != .confirmed {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(client.playbackStartStatus(targetId: "prefetch"), .confirmed)
        try client.stop()
    }

    func testDefaultPlaybackStartsWithFirstChunkWhileLaterChunkIsStillRendering() async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template, renderDelays: [2: .seconds(1)])
        let starts = PlaybackStartCapture()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            maxCharacters: 120, audioSessionActivator: {}, audioPlayerStarter: { _, _ in starts.record() },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient()
        )
        _ = try client.prepareSpeechText(String(repeating: "A sentence long enough to produce several useful audio chunks. ", count: 12))
        try client.play(targetId: "progressive")
        _ = await waitForRenderCount(renderer, minimum: 2)
        XCTAssertEqual(starts.count, 1, "The first chunk must be playable before chunk two completes")
        try client.stop()
    }

    func testManifestAndChunkCommitFinishBeforeRenderingAdvances() async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let committed = expectation(description: "first commit finished")
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            maxCharacters: 120, audioSessionActivator: {}, audioPlayerStarter: { _, _ in },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient(),
            onPreparationPlan: { _, _, _ in
                try? await Task.sleep(for: .milliseconds(100))
                let count = await renderer.renderCount
                XCTAssertEqual(count, 0, "Rendering must wait for the manifest")
            },
            onPreparedChunk: { _, _, plan, _, _, _ in
                guard plan.index == 0 else { return }
                try? await Task.sleep(for: .milliseconds(100))
                let count = await renderer.renderCount
                XCTAssertEqual(count, 1, "The next chunk must wait for the prior commit")
                committed.fulfill()
            }
        )
        _ = try client.prepareSpeechText(String(repeating: "A sentence long enough to produce several useful audio chunks. ", count: 12))
        try client.play(targetId: "ordered-preparation")
        await fulfillment(of: [committed], timeout: 3)
        let count = await waitForRenderCount(renderer, minimum: 2)
        XCTAssertGreaterThanOrEqual(count, 2)
        try client.stop()
    }

    func testPlaybackStartsOnlyAfterTwoSupertonicChunksAreReady() async throws {
        let template = try makeTestWAV(duration: 0.2)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(
            templateURL: template,
            renderDelays: [2: .milliseconds(300)]
        )
        let starts = PlaybackStartCapture()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            startupBufferChunkCount: 2,
            audioSessionActivator: {},
            audioPlayerStarter: { _, _ in starts.record() },
            observesPlayerLifecycle: false,
            fallbackClient: RecordingFallbackAudioClient()
        )
        let source = String(repeating: "Each sentence is long enough to create another rendered Supertonic chunk. ", count: 8)

        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "two-chunk-start")
        _ = await waitForRenderCount(renderer, minimum: 2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(starts.count, 0)

        for _ in 0..<30 where starts.count == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(starts.count, 1)
        try client.stop()
    }

    func testObservedPlaybackStartRemainsPendingWhilePlayerIsStillPaused() async throws {
        let template = try makeTestWAV(duration: 0.2)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let starts = PlaybackStartCapture()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionActivator: {},
            audioPlayerStarter: { _, _ in starts.record() },
            observesPlayerLifecycle: true,
            fallbackClient: RecordingFallbackAudioClient()
        )
        let source = String(repeating: "Each sentence creates another rendered Supertonic chunk for startup. ", count: 8)

        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "paused-start")
        for _ in 0..<100 where starts.count == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(client.playbackStartStatus(targetId: "paused-start"), .pending)
        try client.stop()
    }

    func testFullGenerationPersistsPodcastStyleAudioWhilePlaybackIsPaused() async throws {
        let template = try makeTestWAV(duration: 0.1)
        defer { try? FileManager.default.removeItem(at: template) }
        let output = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-prepared-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: output) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let fallback = RecordingFallbackAudioClient()
        let capture = PreparedAudioCapture()
        let completed = expectation(description: "prepared Supertonic audio")
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1.5,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            preparedAudioDirectory: output,
            audioSessionActivator: {},
            observesPlayerLifecycle: false,
            fallbackClient: fallback,
            onPreparedAudio: { itemId, prepared in
                capture.record(itemId: itemId, prepared: prepared)
                completed.fulfill()
            }
        )
        let source = (1...9).map {
            "Persistent sentence \($0) has enough text for progressive local audiobook generation."
        }.joined(separator: " ")

        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "persistent-item")
        try client.pause()

        await fulfillment(of: [completed], timeout: 5)
        let prepared = try XCTUnwrap(capture.prepared)
        let renderCount = await renderer.renderCount
        XCTAssertEqual(capture.itemId, "persistent-item")
        XCTAssertEqual(renderCount, renderedChunkCount(source))
        XCTAssertTrue(fallback.playedOffsets.isEmpty)
        XCTAssertEqual(prepared.media.sourceType, .generatedTTSPrerendered)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(URL(string: prepared.media.url ?? "")) .path))
        XCTAssertEqual(prepared.timeline.segments.first?.startChar, 0)
        XCTAssertEqual(prepared.timeline.segments.last?.endChar, source.count)
        XCTAssertGreaterThan(prepared.timeline.durationMs ?? 0, 0)
        try client.stop()
    }

    /// #314: when every chunk renders but joining them into the saved file fails, the stop
    /// carries that error. Before, it arrived as a bare `.stopped` and the player said the
    /// iOS voice had taken over, which it hadn't.
    func testPreparedAudioAssemblyFailureStopsGenerationWithItsReason() async throws {
        let template = try makeTestWAV(duration: 0.1)
        defer { try? FileManager.default.removeItem(at: template) }
        // A regular file where the output directory should be: creating the directory throws.
        let blockedOutput = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-assembly-blocked-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blockedOutput)
        defer { try? FileManager.default.removeItem(at: blockedOutput) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let capture = PreparedAudioCapture()
        let states = GenerationStateCapture()
        let stopped = expectation(description: "generation stopped after the assembly error")
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1.5,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            preparedAudioDirectory: blockedOutput,
            audioSessionActivator: {},
            observesPlayerLifecycle: false,
            fallbackClient: RecordingFallbackAudioClient(),
            onGenerationStateChange: { state, stopReason in
                states.record(state, stopReason: stopReason)
                if state == .stopped { stopped.fulfill() }
            },
            onPreparedAudio: { itemId, prepared in capture.record(itemId: itemId, prepared: prepared) }
        )
        let source = (1...9).map {
            "Assembly sentence \($0) has enough text for progressive local audiobook generation."
        }.joined(separator: " ")

        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "assembly-fails")
        try client.pause()

        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertNil(capture.prepared, "No prepared audio may be reported when assembly failed")
        let reason = try XCTUnwrap(states.stopReasons.last ?? nil, "The stop must carry the assembly error")
        XCTAssertTrue(reason.hasPrefix(SpeechGenerationStopReason.assemblyFailedCode), reason)
        XCTAssertGreaterThan(reason.count, SpeechGenerationStopReason.assemblyFailedCode.count + 2, "The error itself is kept")
        let shown = RenderedSpeechGenerationState.stopped.listenerDescription(
            progress: RenderedSpeechGenerationProgress(completedChunks: 0, totalChunks: 0),
            isDelayed: false,
            stopReason: reason,
            fallbackReason: nil
        )
        XCTAssertTrue(shown.contains("Couldn't save the finished audio"), shown)
        try client.stop()
    }

    func testRenderGapWaitsForSupertonicAndNeverFallsBack() async throws {
        let template = try makeTestWAV(duration: 0.1)
        defer { try? FileManager.default.removeItem(at: template) }
        let thirdRender = AsyncStream<Void>.makeStream()
        defer { thirdRender.continuation.finish() }
        let renderer = CountingAudioSupertonicRenderer(
            templateURL: template,
            renderGates: [3: thirdRender.stream]
        )
        let fallback = RecordingFallbackAudioClient()
        let firstChunkStarted = expectation(description: "first chunk started")
        let secondChunkStarted = expectation(description: "second chunk started")
        let nextChunkStarted = expectation(description: "rendered chunk starts after gap")
        var starts = 0
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1.75,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionActivator: {},
            audioPlayerStarter: { _, _ in
                starts += 1
                if starts == 1 { firstChunkStarted.fulfill() }
                if starts == 2 { secondChunkStarted.fulfill() }
                if starts == 3 { nextChunkStarted.fulfill() }
            },
            observesPlayerLifecycle: false,
            fallbackClient: fallback
        )
        let source = (1...12).map { index in
            "Sentence \(index) contains enough ordinary words to keep the narration moving through several chunks."
        }.joined(separator: " ")

        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "underrun")
        await fulfillment(of: [firstChunkStarted], timeout: 3)
        client.debugFinishActiveChunk()
        await fulfillment(of: [secondChunkStarted], timeout: 3)
        let secondOffset = client.debugActiveAudioState().startOffset
        XCTAssertGreaterThan(secondOffset, 0)
        client.debugFinishActiveChunk()

        XCTAssertEqual(client.playbackTransportState(targetId: "underrun"), .waiting)
        XCTAssertFalse(client.debugActiveAudioState().hasURL, "Third render must still be blocked")
        thirdRender.continuation.finish()
        await fulfillment(of: [nextChunkStarted], timeout: 3)
        XCTAssertGreaterThan(client.debugActiveAudioState().startOffset, secondOffset)
        XCTAssertTrue(fallback.playedOffsets.isEmpty)
        try client.stop()
    }

    // #235: the owner's pause (or Margin) then Play fails with 4b599361 (playback_start_timeout)
    // while Supertonic is behind the listener, and a second Play minutes later starts at once.
    // Real engine and real client, observing the real player as production does (a client that
    // doesn't observe it reports "started" with no player, which hides the failure). The chunk the
    // listener resumes into is still rendering. The engine's 10 s start watchdog must not fail a
    // resume that is only waiting for that chunk.
    func testResumeWaitingOnASlowChunkIsNotFailedByTheStartWatchdog() async throws {
        let template = try makeTestWAV(duration: 3)
        defer { try? FileManager.default.removeItem(at: template) }
        let thirdRender = AsyncStream<Void>.makeStream()
        defer { thirdRender.continuation.finish() }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template, renderGates: [3: thirdRender.stream])
        let decisions = ResumeDecisionCapture()
        let starts = PlaybackStartCounter()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionActivator: {},
            audioPlayerStarter: { player, rate in
                _ = starts.increment()
                player.volume = 0
                player.playImmediately(atRate: rate)
            },
            observesPlayerLifecycle: true,
            fallbackClient: RecordingFallbackAudioClient(),
            onResumeDecision: { decisions.append($0) }
        )
        let text = (1...12).map { index in
            "Sentence \(index) contains enough ordinary words to keep the narration moving through several chunks."
        }.joined(separator: " ")
        let item = Item(id: "item-235", title: "Slow chunk", mediaType: "text", text: text, externalReference: nil, status: "ready")
        var clock = Date(timeIntervalSince1970: 1_000)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone", displayName: "Phone",
                capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts"]]
            ),
            repository: InMemorySessionRepository(items: [item.id: item]),
            audio: client,
            playbackStartTimeout: 10,
            now: { clock }
        )

        _ = try engine.startSession(itemId: item.id)
        try await waitForEngine(engine, status: .playing, "the first chunk plays")
        client.debugFinishActiveChunk()
        for _ in 0..<150 where starts.value < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(starts.value, 2, "the second chunk plays")
        client.debugFinishActiveChunk()
        // Supertonic is now behind: the third chunk is still rendering and there is no player.
        _ = try engine.syncPlaybackProgress()
        _ = try engine.pause()
        let resumed = try engine.resumePlayback()
        let startsBeforeRender = starts.value
        clock = clock.addingTimeInterval(11)
        let afterWatchdog = try engine.syncPlaybackProgress()
        print("#235 resume decision: \(decisions.values.last ?? [:]); status before: \(resumed.status), after 11 s: \(afterWatchdog.status), failure: \(afterWatchdog.lastFailure ?? "none")")
        XCTAssertEqual(decisions.values.last?["path"], "await_render")
        XCTAssertEqual(resumed.status, .starting, "the resume waits for the rendering chunk")

        XCTAssertEqual(afterWatchdog.status, .starting, "still waiting for Supertonic, not failed")
        XCTAssertTrue(client.isAwaitingRenderedAudio(targetId: item.id))

        thirdRender.continuation.finish()
        for _ in 0..<150 where starts.value == startsBeforeRender {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(starts.value, startsBeforeRender + 1, "the chunk plays when it lands")
        try await waitForEngine(engine, status: .playing, "the resume confirms once the chunk plays")
        try client.stop()
    }

    private func waitForEngine(
        _ engine: SessionEngine, status: PlaybackStatus, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for _ in 0..<150 {
            if try engine.syncPlaybackProgress().status == status { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("\(message): engine stayed \(try engine.syncPlaybackProgress().status)", file: file, line: line)
    }

    // #235 backstop: if the chunk never renders, the client's own render deadline ends the wait in
    // the iOS voice, so relaxing the engine's watchdog can't leave a start pending for ever.
    func testResumeWaitingOnARenderThatNeverFinishesEndsInTheIOSVoice() async throws {
        let template = try makeTestWAV(duration: 3)
        defer { try? FileManager.default.removeItem(at: template) }
        let neverRenders = AsyncStream<Void>.makeStream()
        defer { neverRenders.continuation.finish() }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template, renderGates: [3: neverRenders.stream])
        let starts = PlaybackStartCounter()
        let fallback = RecordingFallbackAudioClient()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionActivator: {},
            audioPlayerStarter: { player, rate in
                _ = starts.increment()
                player.volume = 0
                player.playImmediately(atRate: rate)
            },
            observesPlayerLifecycle: true,
            fallbackClient: fallback,
            renderWaitLimit: .seconds(1)
        )
        let text = (1...12).map { index in
            "Sentence \(index) contains enough ordinary words to keep the narration moving through several chunks."
        }.joined(separator: " ")
        let item = Item(id: "item-235-stuck", title: "Stuck chunk", mediaType: "text", text: text, externalReference: nil, status: "ready")
        var clock = Date(timeIntervalSince1970: 1_000)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone", displayName: "Phone",
                capabilities: ["sync": ["canonical_persistence"], "playback": ["realtime_tts"]]
            ),
            repository: InMemorySessionRepository(items: [item.id: item]),
            audio: client,
            playbackStartTimeout: 10,
            now: { clock }
        )

        _ = try engine.startSession(itemId: item.id)
        try await waitForEngine(engine, status: .playing, "the first chunk plays")
        // Let the second chunk finish rendering first, so only the chunk that never renders can
        // reach the render deadline, however loaded the machine is.
        for _ in 0..<250 where client.debugRenderedCacheOffsets().isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(client.debugRenderedCacheOffsets().isEmpty, "the second chunk rendered")
        client.debugFinishActiveChunk()
        for _ in 0..<150 where starts.value < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(starts.value, 2, "the second chunk plays")
        client.debugFinishActiveChunk()
        _ = try engine.pause()
        _ = try engine.resumePlayback()
        for _ in 0..<200 where fallback.playedOffsets.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(fallback.playedOffsets.isEmpty, "the render deadline fell back to the iOS voice")
        XCTAssertFalse(client.isAwaitingRenderedAudio(targetId: item.id))
        clock = clock.addingTimeInterval(11)
        XCTAssertNotEqual(try engine.syncPlaybackProgress().status, .starting, "the start resolved rather than waiting")
        try client.stop()
    }

    func testRenderGapTimeoutContinuesAfterFinishedPassage() async throws {
        let template = try makeTestWAV(duration: 1)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(
            templateURL: template, renderDelays: [2: .seconds(5)]
        )
        let firstStarted = expectation(description: "first passage started")
        let fellBack = expectation(description: "next passage timed out")
        let fallback = RecordingFallbackAudioClient()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1,
            fallbackVoiceIdentifier: nil, fallbackRate: 0.5, maxCharacters: 120,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in firstStarted.fulfill() },
            observesPlayerLifecycle: false, fallbackClient: fallback,
            onFallback: { reason, _, _ in
                XCTAssertEqual(reason, "supertonic_render_timeout")
                fellBack.fulfill()
            }, renderWaitLimit: .milliseconds(300)
        )
        let source = String(repeating: "A distinct passage contains enough ordinary words to make a full narration chunk. ", count: 5)
        let firstLength = RenderedSpeechChunker.sourceSlice(from: source, startOffset: 0, maxCharacters: 120).sourceLength
        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "passage-gap")
        await fulfillment(of: [firstStarted], timeout: 2)
        client.debugFinishActiveChunk()
        XCTAssertEqual(client.playbackTransportState(targetId: "passage-gap"), .waiting)
        XCTAssertEqual(client.currentCharOffset(), firstLength)
        XCTAssertEqual(client.currentRecoveryCharOffset(), firstLength)
        await fulfillment(of: [fellBack], timeout: 2)
        XCTAssertEqual(fallback.playedOffsets, [firstLength])
        try client.stop()
    }

    func testSentenceBoundaryDelayRemainsWaitingInsteadOfReportingUserPause() async throws {
        let template = try makeTestWAV(duration: 0.1)
        defer { try? FileManager.default.removeItem(at: template) }
        let generationReady = expectation(description: "all sentence chunks rendered")
        let client = SupertonicSpeechPlaybackClient(
            renderer: CountingAudioSupertonicRenderer(templateURL: template),
            voice: .m2,
            speed: 1.75,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            maxCharacters: 120,
            startupBufferChunkCount: 2,
            audioSessionActivator: {},
            audioPlayerStarter: { _, _ in },
            observesPlayerLifecycle: false,
            fallbackClient: RecordingFallbackAudioClient(),
            onGenerationStateChange: { state, _ in
                if state == .ready { generationReady.fulfill() }
            }
        )
        let source = [
            "The first rendered sentence contains enough ordinary words to create a distinct audio chunk.",
            "The second rendered sentence also contains enough ordinary words to exercise the transition delay."
        ].joined(separator: " ")

        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "sentence-delay")
        await fulfillment(of: [generationReady], timeout: 3)
        for _ in 0..<50 where !client.debugActiveAudioState().hasURL {
            try? await Task.sleep(for: .milliseconds(20))
        }

        client.debugFinishActiveChunk()

        XCTAssertEqual(client.playbackStartStatus(targetId: "sentence-delay"), .pending)
        XCTAssertEqual(client.playbackTransportState(targetId: "sentence-delay"), .waiting)
        try client.stop()
    }

    func testForwardSeekDoesNotWrapRenderingBackToSkippedPrefix() async throws {
        let template = try makeTestWAV(duration: 0.1)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(
            templateURL: template,
            renderDelays: [3: .milliseconds(500)]
        )
        let states = GenerationStateCapture()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1.75,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionActivator: {},
            audioPlayerStarter: { _, _ in },
            observesPlayerLifecycle: false,
            fallbackClient: RecordingFallbackAudioClient(),
            onGenerationStateChange: { state, stopReason in states.record(state, stopReason: stopReason) }
        )
        let source = (1...14).map { index in
            "Sentence \(index) contains enough ordinary words to form a useful rendered section."
        }.joined(separator: " ")

        _ = try client.prepareSpeechText(source)
        let requestedOffset = max(0, source.count - 300)
        let plan = RenderedSpeechChunker.sourceSlices(from: source)
        let playbackIndex = plan.lastIndex {
            $0.startOffset <= requestedOffset
                && requestedOffset < $0.startOffset + max(1, $0.slice.sourceLength)
        } ?? max(0, plan.count - 1)
        let expectedForwardCount = plan.count - playbackIndex

        try client.play(targetId: "forward-seek", from: requestedOffset)
        for _ in 0..<100 where states.values.last != .ready {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let renderCount = await renderer.renderCount

        XCTAssertEqual(states.values.last, .ready)
        XCTAssertEqual(renderCount, expectedForwardCount)
        XCTAssertLessThan(renderCount, plan.count)
        try client.stop()
    }

    func testGenerationTokenCancelsStaleRenderAfterReplay() async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template, firstRenderDelay: .milliseconds(120))
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            fallbackClient: RecordingFallbackAudioClient()
        )
        let source = String(repeating: "This replay text has stable source offsets. ", count: 10)
        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "generation", from: 0)
        try client.play(targetId: "generation", from: 12)

        for _ in 0..<100 where !client.debugActiveAudioState().hasURL {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let renderCount = await renderer.renderCount
        let discardCount = await renderer.discardCount
        XCTAssertGreaterThanOrEqual(renderCount, 2)
        XCTAssertEqual(discardCount, 0, "A cancelled obsolete render should not produce audio to discard")
        XCTAssertTrue(client.debugActiveAudioState().hasURL)
        try client.stop()
    }

    // A move to another chunk while the first chunk is still rendering: that render is obsolete,
    // so it's cancelled and the new position rendered. #407: this used a single chunk, where the
    // "obsolete" render was the very chunk the move landed in. Since #346 a move there waits for
    // that render instead (testAMoveWithinTheChunkStillRenderingWaitsForItAndStartsThere), so this
    // needs a second chunk to test what it names.
    func testSeekingCancelsObsoleteRenderBeforeStartingReplacementGeneration() async throws {
        try await assertMoveDuringFirstRenderReplacesIt { client, targetId, source in
            try client.play(targetId: targetId, from: source.count / 2)
        }
    }

    // #407: the app sends a listener's seek through play(targetId:seekingTo:); it cancels the
    // obsolete render the same way.
    func testExplicitSeekToAnotherChunkCancelsTheFirstRender() async throws {
        try await assertMoveDuringFirstRenderReplacesIt { client, targetId, source in
            try client.play(targetId: targetId, seekingTo: source.count / 2)
        }
    }

    private func assertMoveDuringFirstRenderReplacesIt(
        _ move: (SupertonicSpeechPlaybackClient, String, String) throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let started = expectation(description: "obsolete render started")
        let cancelled = expectation(description: "obsolete render cancelled")
        let ready = expectation(description: "replacement render committed")
        let renderer = CancellationAwareSupertonicRenderer(
            templateURL: template, onStart: { started.fulfill() }, onCancel: { cancelled.fulfill() }
        )
        let fallback = RecordingFallbackAudioClient()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            // One sentence per chunk, so the move lands in a later chunk than the one rendering.
            maxCharacters: 120,
            audioSessionActivator: {},
            audioPlayerStarter: { _, _ in },
            observesPlayerLifecycle: false,
            fallbackClient: fallback,
            onGenerationStateChange: { state, _ in if state == .ready { ready.fulfill() } }
        )
        let source = String(
            repeating: "A stable sentence supports repeated navigation without obsolete inference. ",
            count: 6
        )
        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "seek-cancellation", from: 0)
        await fulfillment(of: [started], timeout: 2)

        try move(client, "seek-cancellation", source)
        await fulfillment(of: [cancelled, ready], timeout: 3)

        let cancelledCount = await renderer.cancelledCount
        XCTAssertEqual(cancelledCount, 1, file: file, line: line)
        XCTAssertTrue(fallback.playedOffsets.isEmpty, file: file, line: line)
        let active = client.debugActiveAudioState()
        XCTAssertTrue(active.hasURL, file: file, line: line)
        XCTAssertGreaterThan(active.startOffset, 0, "the new position's chunk plays, not the first", file: file, line: line)
        try client.stop()
    }

    // #407, #346: a play or seek inside the chunk that is still rendering for the first start
    // waits for that render and starts at the chosen place. The render is the one the move
    // needs, so cancelling it would only render the same chunk again, later.
    func testAMoveWithinTheChunkStillRenderingWaitsForItAndStartsThere() async throws {
        let template = try makeTestWAV(duration: 2)
        defer { try? FileManager.default.removeItem(at: template) }
        let (renderGate, releaseRender) = AsyncStream<Void>.makeStream()
        defer { releaseRender.finish() }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template, firstRenderGate: renderGate)
        let playbackStarted = expectation(description: "playback started")
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            maxCharacters: 1_000,
            audioSessionActivator: {},
            audioPlayerStarter: { _, _ in playbackStarted.fulfill() },
            observesPlayerLifecycle: false,
            fallbackClient: RecordingFallbackAudioClient()
        )
        let source = String(
            repeating: "A stable sentence supports repeated navigation without obsolete inference. ",
            count: 6
        )
        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "move-within", from: 0)
        for _ in 0..<100 where await renderer.renderCount < 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let target = source.count / 2
        try client.play(targetId: "move-within", seekingTo: target)
        releaseRender.finish()
        await fulfillment(of: [playbackStarted], timeout: 3)

        let renderCount = await renderer.renderCount
        XCTAssertEqual(renderCount, 1, "the chunk rendering was used, not rendered again")
        XCTAssertEqual(client.debugActiveAudioState().startOffset, 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(client.currentCharOffset()), target - 1, "reports the chosen place, not the top")
        try client.stop()
    }

    func testBackgroundingDuringInitialRenderPreservesSelectedSupertonicVoice() async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let (renderGate, releaseRender) = AsyncStream<Void>.makeStream()
        defer { releaseRender.finish() }
        let renderer = CountingAudioSupertonicRenderer(
            templateURL: template,
            firstRenderGate: renderGate
        )
        let fallback = RecordingFallbackAudioClient()
        let playbackStarted = expectation(description: "selected voice playback started")
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionActivator: {},
            audioPlayerStarter: { _, _ in playbackStarted.fulfill() },
            observesPlayerLifecycle: false,
            fallbackClient: fallback
        )
        let source = "Playback should become audible before the app is suspended during initial rendering."
        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "background-start", from: 11)
        XCTAssertEqual(client.playbackStartStatus(targetId: "background-start"), .pending)

        XCTAssertFalse(client.ensurePlaybackStartsBeforeBackgrounding())

        releaseRender.finish()
        await fulfillment(of: [playbackStarted], timeout: 5)
        XCTAssertTrue(fallback.playedOffsets.isEmpty)
        XCTAssertEqual(client.playbackStartStatus(targetId: "background-start"), .confirmed)
        XCTAssertNotEqual(client.playbackTransportState(targetId: "background-start"), .stopped)
        try client.stop()
    }

    func testUserCanStopOnDeviceRenderingAndContinueWithSystemVoice() async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(
            templateURL: template,
            firstRenderDelay: .milliseconds(300)
        )
        let fallback = RecordingFallbackAudioClient()
        let stopped = expectation(description: "generation stopped")
        stopped.expectedFulfillmentCount = 2
        let states = GenerationStateCapture()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionActivator: {},
            observesPlayerLifecycle: false,
            fallbackClient: fallback,
            onGenerationStateChange: { state, stopReason in
                states.record(state, stopReason: stopReason)
                if state == .stopped { stopped.fulfill() }
            }
        )
        let source = String(repeating: "On-device generation should stop without ending native text playback. ", count: 8)
        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "stop-generation", from: 19)
        let initialRenderCount = await waitForRenderCount(renderer, minimum: 1)
        XCTAssertEqual(initialRenderCount, 1)

        XCTAssertTrue(try client.stopOnDeviceRenderingAndUseSystemSpeech())

        XCTAssertEqual(fallback.preparedText, source)
        XCTAssertEqual(fallback.playedOffsets, [19])
        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "stop-generation", from: 120)
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(fallback.playedOffsets, [19, 120], "Resume and navigation must keep generation stopped")
        XCTAssertEqual(
            states.stopReasons,
            ["listener_stopped_generation", "listener_stopped_generation"],
            "Every stop, including the one reported again on resume, keeps the listener's reason (#314)"
        )
        try? await Task.sleep(for: .milliseconds(350))
        let countAfterStop = await renderer.renderCount
        try? await Task.sleep(for: .milliseconds(350))
        let finalRenderCount = await renderer.renderCount
        XCTAssertEqual(finalRenderCount, countAfterStop, "Stopping must not schedule another chunk")
        XCTAssertTrue(try client.retryOnDeviceRendering())
        let retryCount = await waitForRenderCount(renderer, minimum: countAfterStop + 1)
        XCTAssertGreaterThan(retryCount, countAfterStop)
        XCTAssertEqual(fallback.playedOffsets, [19, 120], "Retry must return to Supertonic now")

        try client.stop()
    }

    /// #314 audit: a stop's reason belongs to its item. When the listener plays item B and then
    /// comes back to item A, whose generation they stopped, A must report its own reason, not
    /// lose it to B's rendering (or borrow B's reason if B had stopped too).
    func testStoppedItemKeepsItsOwnReasonAfterAnotherItemRenders() async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let fallback = RecordingFallbackAudioClient()
        let states = GenerationStateCapture()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionActivator: {},
            observesPlayerLifecycle: false,
            fallbackClient: fallback,
            onGenerationStateChange: { state, stopReason in states.record(state, stopReason: stopReason) }
        )
        let itemA = String(repeating: "Item A stops generating and carries on in the system voice. ", count: 8)
        let itemB = String(repeating: "Item B renders on this device while item A stays stopped. ", count: 8)

        _ = try client.prepareSpeechText(itemA)
        try client.play(targetId: "item-a", from: 0)
        _ = await waitForRenderCount(renderer, minimum: 1)
        XCTAssertTrue(try client.stopOnDeviceRenderingAndUseSystemSpeech())
        let statesBeforeB = states.values.count

        _ = try client.prepareSpeechText(itemB)
        try client.play(targetId: "item-b", from: 0)
        for _ in 0..<100 {
            if states.values.dropFirst(statesBeforeB).contains(.rendering) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(states.values.dropFirst(statesBeforeB).contains(.rendering), "Item B renders on the device")

        _ = try client.prepareSpeechText(itemA)
        try client.play(targetId: "item-a", from: 0)
        XCTAssertEqual(states.values.last, .stopped, "Item A's generation stays stopped")
        XCTAssertEqual(states.stopReasons.last, "listener_stopped_generation", "Item A keeps the reason it stopped for")

        try client.stop()
    }

    func testStopGenerationPreservesPausedTransportAndForwardsFallbackRate() async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(
            templateURL: template,
            firstRenderDelay: .milliseconds(300)
        )
        let fallback = RecordingFallbackAudioClient()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionActivator: {},
            observesPlayerLifecycle: false,
            fallbackClient: fallback
        )
        let source = String(repeating: "Paused playback must remain remotely recoverable after generation stops. ", count: 8)
        _ = try client.prepareSpeechText(source)
        try client.play(targetId: "stop-generation-paused", from: 23)
        try client.pause()

        XCTAssertTrue(try client.stopOnDeviceRenderingAndUseSystemSpeech())
        XCTAssertEqual(client.playbackTransportState(targetId: "stop-generation-paused"), .paused)
        XCTAssertEqual(fallback.playedOffsets, [23])
        XCTAssertEqual(fallback.pauseCount, 1)

        try client.setPlaybackRate(1.75)
        XCTAssertEqual(fallback.playbackRates, [1.75])
        XCTAssertEqual(client.currentPlaybackPosition()?.playbackRate ?? 0, 1.75, accuracy: 0.001)

        try client.play(targetId: "stop-generation-paused", from: 23)
        XCTAssertEqual(fallback.playedOffsets, [23, 23])
        XCTAssertEqual(client.playbackTransportState(targetId: "stop-generation-paused"), .playing)
        try client.stop()
    }

    func testRateChangeUsesTransportWithoutChangingSynthesisOrRestartingRender() async throws {
        let template = try makeTestWAV(duration: 3)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            fallbackClient: RecordingFallbackAudioClient()
        )
        _ = try client.prepareSpeechText("A short rendered sentence remains reusable at every transport speed.")
        try client.play(targetId: "rate")
        let initialRenderCount = await waitForRenderCount(renderer, minimum: 1)
        XCTAssertEqual(initialRenderCount, 1)

        try client.setPlaybackRate(1.7)
        try? await Task.sleep(for: .milliseconds(100))

        let renderCount = await renderer.renderCount
        let requestedSpeeds = await renderer.requestedSpeeds
        XCTAssertEqual(renderCount, 1)
        XCTAssertEqual(requestedSpeeds, [1.0])
        XCTAssertEqual(client.currentPlaybackPosition()?.playbackRate ?? 0, 1.7, accuracy: 0.001)

        try client.setPlaybackRate(0.25)
        XCTAssertEqual(client.currentPlaybackPosition()?.playbackRate ?? 0, 0.25, accuracy: 0.001)
        let quarterSpeedRenderCount = await renderer.renderCount
        XCTAssertEqual(quarterSpeedRenderCount, 1)
        try client.stop()
    }

    func testPauseDuringInitialRenderPreventsAutoplayAndResumeReusesResult() async throws {
        let template = try makeTestWAV(duration: 1)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(
            templateURL: template,
            firstRenderDelay: .milliseconds(150)
        )
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            fallbackClient: RecordingFallbackAudioClient()
        )
        _ = try client.prepareSpeechText("Pause must win even while the first audio chunk is still rendering.")
        try client.play(targetId: "pending-pause")
        try client.pause()
        let initialRenderCount = await waitForRenderCount(renderer, minimum: 1)
        XCTAssertEqual(initialRenderCount, 1)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(client.playbackTransportState(targetId: "pending-pause"), .paused)
        XCTAssertEqual(client.currentRecoveryCharOffset(), 0)

        try client.play(targetId: "pending-pause", from: 0)
        for _ in 0..<50 where client.playbackStartStatus(targetId: "pending-pause") != .confirmed {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(client.playbackStartStatus(targetId: "pending-pause"), .confirmed)
        let renderCount = await renderer.renderCount
        XCTAssertEqual(renderCount, 1)
        try client.stop()
    }

    func testMediaServicesResetRetainsRenderedChunkForExplicitResume() async throws {
        let template = try makeTestWAV(duration: 5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let notificationCenter = NotificationCenter()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionNotificationCenter: notificationCenter,
            audioSessionActivator: {},
            audioPlayerStarter: { _, _ in },
            observesPlayerLifecycle: false,
            fallbackClient: RecordingFallbackAudioClient()
        )
        _ = try client.prepareSpeechText("A media services reset should preserve this rendered audio chunk.")
        try client.play(targetId: "media-services-reset")
        for _ in 0..<50 where !client.debugActiveAudioState().hasURL {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(client.playbackStartStatus(targetId: "media-services-reset"), .confirmed)
        let preResetRenderCount = await renderer.renderCount
        XCTAssertEqual(preResetRenderCount, 1, "Unexpected render before media-services reset")
        let preResetAudio = client.debugActiveAudioState()
        XCTAssertTrue(preResetAudio.hasURL)
        XCTAssertGreaterThan(preResetAudio.duration, 0)
        XCTAssertEqual(preResetAudio.targetId, "media-services-reset")
        XCTAssertEqual(preResetAudio.startOffset, 0)

        notificationCenter.post(
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance()
        )
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(client.playbackTransportState(targetId: "media-services-reset"), .paused)
        let postResetRenderCount = await renderer.renderCount
        XCTAssertEqual(postResetRenderCount, 1, "Media-services reset unexpectedly re-rendered audio")
        XCTAssertEqual(client.currentRecoveryCharOffset(), 0)
        XCTAssertEqual(client.debugRenderedCacheOffsets(), [0])

        try client.play(targetId: "media-services-reset", from: client.currentRecoveryCharOffset() ?? 0)
        for _ in 0..<50 where client.playbackStartStatus(targetId: "media-services-reset") != .confirmed {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(client.playbackStartStatus(targetId: "media-services-reset"), .confirmed)
        let renderCount = await renderer.renderCount
        XCTAssertEqual(renderCount, 1)
        try client.stop()
    }

    func testMediaServicesResetCheckpointsIntraChunkProgressBeforeCanonicalPause() async throws {
        let template = try makeTestWAV(duration: 5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let notificationCenter = NotificationCenter()
        let interruptions = PlaybackInterruptionCapture()
        let source = "A rendered native text chunk must keep its precise listening position when media services disappear."
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionNotificationCenter: notificationCenter,
            audioSessionActivator: {},
            audioPlayerStarter: { player, _ in
                player.seek(
                    to: CMTime(seconds: 2.5, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            },
            observesPlayerLifecycle: false,
            fallbackClient: RecordingFallbackAudioClient(),
            interruptionHandler: { interruptions.record($0) }
        )
        let item = Item(
            id: "media-services-reset-progress",
            title: "Media reset checkpoint",
            mediaType: "text",
            text: source,
            externalReference: nil,
            status: "ready"
        )
        let profile = RuntimeCapabilityProfile(
            id: "media-reset-checkpoint",
            displayName: "Media reset checkpoint",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"]
            ]
        )
        let repository = InMemorySessionRepository(items: [item.id: item])
        let engine = SessionEngine(profile: profile, repository: repository, audio: client)
        _ = try engine.startSession(itemId: item.id)
        for _ in 0..<50 where (client.currentCharOffset() ?? 0) == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let checkpoint = try XCTUnwrap(client.currentCharOffset())
        XCTAssertGreaterThan(checkpoint, 0)
        XCTAssertLessThan(checkpoint, source.count)

        notificationCenter.post(
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance()
        )
        try? await Task.sleep(for: .milliseconds(50))
        let paused = try engine.reconcileSystemInitiatedPause()
        let sessionID = try XCTUnwrap(paused.sessionId)
        let persisted = try XCTUnwrap(repository.loadSession(id: sessionID))

        XCTAssertEqual(client.currentRecoveryCharOffset(), checkpoint)
        XCTAssertEqual(client.currentCharOffset(), checkpoint)
        XCTAssertEqual(client.playbackTransportState(targetId: item.id), .paused)
        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(persisted.position.charOffset, checkpoint)
        XCTAssertGreaterThan(persisted.completionPercent, 0)
        XCTAssertEqual(interruptions.values, [.began])
        XCTAssertEqual(client.debugRenderedCacheOffsets(), [0])
        try client.stop()
    }

    func testAirPodRouteLossPublishesCanonicalPauseAndRemoteResumeDuringPartialGeneration() async throws {
        let template = try makeTestWAV(duration: 5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(
            templateURL: template,
            renderDelays: [3: .milliseconds(750)]
        )
        let notificationCenter = NotificationCenter()
        let interruptions = PlaybackInterruptionCapture()
        let progress = GenerationProgressCapture()
        let fallback = RecordingFallbackAudioClient()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionNotificationCenter: notificationCenter,
            audioSessionActivator: {},
            fallbackClient: fallback,
            interruptionHandler: { interruptions.record($0) },
            onGenerationProgress: { progress.record($0) }
        )
        let source = String(repeating: "A long native text keeps rendering later chunks while the current chunk plays. ", count: 18)
        let item = Item(
            id: "route-loss-partial-render",
            title: "Route loss",
            mediaType: "text",
            text: source,
            externalReference: nil,
            status: "ready"
        )
        let profile = RuntimeCapabilityProfile(
            id: "route-loss-remote-controls",
            displayName: "Route loss remote controls",
            capabilities: [
                "sync": ["canonical_persistence"],
                "playback": ["realtime_tts"],
                "remoteControl": ["display_snapshot", "send_transport_commands"],
                "timeline": ["playback_rate_observation"]
            ]
        )
        let engine = SessionEngine(
            profile: profile,
            repository: InMemorySessionRepository(items: [item.id: item]),
            audio: client
        )

        _ = try engine.startSession(itemId: item.id)
        for _ in 0..<100 where engine.snapshot.status != .playing {
            try? await Task.sleep(for: .milliseconds(20))
            _ = try engine.syncPlaybackProgress()
        }
        XCTAssertEqual(engine.snapshot.status, .playing)
        XCTAssertTrue(progress.values.contains { $0.completedChunks < $0.totalChunks })

        let dispatcher = CompactControlDispatcher(
            surfaceProfile: profile,
            canonicalRuntime: engine,
            defaultSkipUnit: "paragraph"
        )

        for cycle in 0..<2 {
            notificationCenter.post(
                name: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [
                    AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                ]
            )

            let paused = try engine.reconcileSystemInitiatedPause()
            XCTAssertEqual(paused.status, .paused)
            XCTAssertTrue(dispatcher.snapshot().availableCommands.contains(.play))
            XCTAssertFalse(dispatcher.snapshot().availableCommands.contains(.pause))

            if cycle == 1 {
                XCTAssertTrue(try client.stopOnDeviceRenderingAndUseSystemSpeech())
                _ = try engine.syncPlaybackProgress()
                _ = try dispatcher.dispatch(.setPlaybackRate, playbackRate: 1.5)
                XCTAssertEqual(fallback.playbackRates, [1.5])
            }

            _ = try dispatcher.dispatch(.play)
            for _ in 0..<50 where engine.snapshot.status != .playing {
                try? await Task.sleep(for: .milliseconds(20))
                _ = try engine.syncPlaybackProgress()
            }
            XCTAssertEqual(engine.snapshot.status, .playing)
        }
        XCTAssertEqual(interruptions.values, [.began, .began])
        try client.stop()
    }

    func testRenderedSpeechDiskCacheReusesAudioAcrossPlaybackClients() async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rendered-speech-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "This rendered sentence should survive stopping playback and constructing a new client."

        let firstRenderer = CountingAudioSupertonicRenderer(templateURL: template)
        let firstCache = try RenderedSpeechDiskCache(directory: root, limitBytes: 10 * 1024 * 1024)
        let firstClient = SupertonicSpeechPlaybackClient(
            renderer: firstRenderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            diskCache: firstCache,
            fallbackClient: RecordingFallbackAudioClient()
        )
        _ = try firstClient.prepareSpeechText(source)
        try firstClient.play(targetId: "first")
        let firstRenderCount = await waitForRenderCount(firstRenderer, minimum: 1)
        XCTAssertEqual(firstRenderCount, 1)
        try firstClient.stop()
        XCTAssertGreaterThan(firstCache.sizeBytes, 0)

        let secondRenderer = CountingAudioSupertonicRenderer(templateURL: template)
        let secondCache = try RenderedSpeechDiskCache(directory: root, limitBytes: 10 * 1024 * 1024)
        let secondClient = SupertonicSpeechPlaybackClient(
            renderer: secondRenderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            diskCache: secondCache,
            fallbackClient: RecordingFallbackAudioClient()
        )
        _ = try secondClient.prepareSpeechText(source)
        try secondClient.play(targetId: "second")
        for _ in 0..<50 where secondClient.playbackStartStatus(targetId: "second") != .confirmed {
            try? await Task.sleep(for: .milliseconds(20))
        }

        let secondRenderCount = await secondRenderer.renderCount
        XCTAssertEqual(secondRenderCount, 0)
        XCTAssertEqual(secondClient.playbackStartStatus(targetId: "second"), .confirmed)
        try secondClient.stop()
    }

    func testBundledRendererSynthesizesJamesAndLilyAndReusesSessions() async throws {
        guard let resourceURL = Bundle.main.resourceURL else {
            throw XCTSkip("Hosted app resources unavailable")
        }
        let root = resourceURL.appending(path: "Supertonic", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("Supertonic assets are not present in this test host")
        }
        let output = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-integration-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: output) }
        let renderer = try SupertonicNarrationRenderer(
            assets: SupertonicAssetLocation(rootURL: root),
            outputDirectory: output
        )

        let james = try await renderer.render(text: "James reads this short test.", voice: .m2)
        let lily = try await renderer.render(text: "Lily reads this short test.", voice: .f2)

        XCTAssertEqual(james.sampleRate, 44_100)
        XCTAssertEqual(lily.sampleRate, 44_100)
        XCTAssertGreaterThan(james.duration, 0)
        XCTAssertGreaterThan(lily.duration, 0)
        XCTAssertGreaterThan(try audioPeak(at: james.audioURL), 0.000_001)
        XCTAssertGreaterThan(try audioPeak(at: lily.audioURL), 0.000_001)
        XCTAssertEqual(james.sessionLoadCount, 1)
        XCTAssertEqual(lily.sessionLoadCount, 1)
        let diagnostics = await renderer.diagnostics()
        XCTAssertEqual(diagnostics.sessionLoadCount, 1)
        await renderer.unload()
    }

    private func audioPeak(at url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ))
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(channels[channel][frame]))
            }
        }
        return peak
    }

    private func makeTestWAV(duration: TimeInterval) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-test-\(UUID().uuidString).wav")
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

    private func waitForRenderCount(
        _ renderer: CountingAudioSupertonicRenderer,
        minimum: Int
    ) async -> Int {
        for _ in 0..<100 {
            let count = await renderer.renderCount
            if count >= minimum { return count }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await renderer.renderCount
    }

    private func waitForDiscardCount(
        _ renderer: CountingAudioSupertonicRenderer,
        minimum: Int
    ) async -> Int {
        for _ in 0..<100 {
            let count = await renderer.discardCount
            if count >= minimum { return count }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await renderer.discardCount
    }

    private func renderedChunkCount(_ source: String) -> Int {
        let normalized = SpeechTextNormalizer.normalizeWithSourceOffsets(source).text
        var offset = 0
        var count = 0
        while offset < normalized.count {
            let slice = RenderedSpeechChunker.sourceSlice(from: normalized, startOffset: offset)
            guard slice.sourceLength > 0 else { break }
            offset += slice.sourceLength
            count += 1
        }
        return count
    }
}

private struct Failure: Error {}

private final class ResumeDecisionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String: String]] = []
    var values: [[String: String]] { lock.withLock { stored } }
    func append(_ value: [String: String]) { lock.withLock { stored.append(value) } }
}

private final class PlaybackStartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

private final class PlaybackStartCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func record() {
        lock.withLock { value += 1 }
    }
}

private final class RenderingAvailabilitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var allowedChecks: Int

    init(allowedChecks: Int) {
        self.allowedChecks = allowedChecks
    }

    func next() -> Bool {
        lock.withLock {
            guard allowedChecks > 0 else { return false }
            allowedChecks -= 1
            return true
        }
    }
}

private final class PreparedAudioCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedItemId: String?
    private var recordedPrepared: PreparedTextAudio?

    var itemId: String? { lock.withLock { recordedItemId } }
    var prepared: PreparedTextAudio? { lock.withLock { recordedPrepared } }

    func record(itemId: String, prepared: PreparedTextAudio) {
        lock.withLock {
            recordedItemId = itemId
            recordedPrepared = prepared
        }
    }
}

private final class GenerationProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [RenderedSpeechGenerationProgress] = []

    var values: [RenderedSpeechGenerationProgress] {
        lock.withLock { recordedValues }
    }

    func record(_ progress: RenderedSpeechGenerationProgress) {
        lock.withLock { recordedValues.append(progress) }
    }
}

private final class GenerationStateCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [RenderedSpeechGenerationState] = []
    private var recordedStopReasons: [String?] = []

    var values: [RenderedSpeechGenerationState] {
        lock.withLock { recordedValues }
    }

    /// The reason sent with each `.stopped`, in order; nil where a stop came without one.
    var stopReasons: [String?] {
        lock.withLock { recordedStopReasons }
    }

    func record(_ state: RenderedSpeechGenerationState, stopReason: String?) {
        lock.withLock {
            recordedValues.append(state)
            if state == .stopped { recordedStopReasons.append(stopReason) }
        }
    }
}

private final class PlaybackInterruptionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [AudioPlaybackInterruptionEvent] = []

    var values: [AudioPlaybackInterruptionEvent] {
        lock.withLock { recordedValues }
    }

    func record(_ event: AudioPlaybackInterruptionEvent) {
        lock.withLock { recordedValues.append(event) }
    }
}

private struct FailingSupertonicRenderer: SupertonicRendering {
    func render(
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int
    ) async throws -> SupertonicNarrationResult {
        throw Failure()
    }

    func discardGeneratedAudio(at url: URL) async {}
}

private struct FixedAudioSupertonicRenderer: SupertonicRendering {
    let audioURL: URL

    func render(
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int
    ) async throws -> SupertonicNarrationResult {
        SupertonicNarrationResult(
            audioURL: audioURL,
            duration: 1,
            sampleRate: 44_100,
            renderDuration: 0.01,
            sessionLoadCount: 1
        )
    }

    func discardGeneratedAudio(at url: URL) async {}
}

private actor CountingAudioSupertonicRenderer: SupertonicRendering {
    let templateURL: URL
    let firstRenderDelay: Duration?
    let firstRenderGate: AsyncStream<Void>?
    let renderDelays: [Int: Duration]
    let renderGates: [Int: AsyncStream<Void>]
    private(set) var renderCount = 0
    private(set) var discardCount = 0
    private(set) var requestedSpeeds: [Float] = []

    init(
        templateURL: URL,
        firstRenderDelay: Duration? = nil,
        firstRenderGate: AsyncStream<Void>? = nil,
        renderDelays: [Int: Duration] = [:],
        renderGates: [Int: AsyncStream<Void>] = [:]
    ) {
        self.templateURL = templateURL
        self.firstRenderDelay = firstRenderDelay
        self.firstRenderGate = firstRenderGate
        self.renderDelays = renderDelays
        self.renderGates = renderGates
    }

    func render(
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int
    ) async throws -> SupertonicNarrationResult {
        renderCount += 1
        requestedSpeeds.append(speed)
        if let gate = renderGates[renderCount] {
            for await _ in gate {}
            try Task.checkCancellation()
        }
        if renderCount == 1, let firstRenderGate {
            for await _ in firstRenderGate {}
            try Task.checkCancellation()
        }
        if renderCount == 1, let firstRenderDelay {
            try await Task.sleep(for: firstRenderDelay)
        } else if let delay = renderDelays[renderCount] {
            try await Task.sleep(for: delay)
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "counting-render-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: templateURL, to: url)
        let audio = try AVAudioFile(forReading: url)
        return SupertonicNarrationResult(
            audioURL: url,
            duration: Double(audio.length) / audio.processingFormat.sampleRate,
            sampleRate: Int(audio.processingFormat.sampleRate.rounded()),
            renderDuration: 0.01,
            sessionLoadCount: 1
        )
    }

    func discardGeneratedAudio(at url: URL) async {
        discardCount += 1
        try? FileManager.default.removeItem(at: url)
    }
}

private final class PreparedLookupLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, PreparedChunkPlan)] = []
    var values: [(String, PreparedChunkPlan)] { lock.withLock { entries } }
    func add(_ source: String, _ plan: PreparedChunkPlan) { lock.withLock { entries.append((source, plan)) } }
}

/// Its discard of a temporary file waits on a gate, as the real renderer's does on its serial
/// queue behind another item's inference.
private actor GatedDiscardSupertonicRenderer: SupertonicRendering {
    let templateURL: URL
    let discardGate: AsyncStream<Void>
    private(set) var discards = 0

    init(templateURL: URL, discardGate: AsyncStream<Void>) {
        self.templateURL = templateURL
        self.discardGate = discardGate
    }

    func render(
        text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int
    ) async throws -> SupertonicNarrationResult {
        let url = FileManager.default.temporaryDirectory.appending(path: "gated-discard-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: templateURL, to: url)
        let audio = try AVAudioFile(forReading: url)
        return SupertonicNarrationResult(
            audioURL: url, duration: Double(audio.length) / audio.processingFormat.sampleRate,
            sampleRate: Int(audio.processingFormat.sampleRate.rounded()), renderDuration: 0.01, sessionLoadCount: 1
        )
    }

    func discardGeneratedAudio(at url: URL) async {
        discards += 1
        for await _ in discardGate {}
        try? FileManager.default.removeItem(at: url)
    }
}

private actor TextRecordingSupertonicRenderer: SupertonicRendering {
    let template: URL
    private(set) var renders: [String] = []
    init(template: URL) { self.template = template }
    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        renders.append(text)
        let url = FileManager.default.temporaryDirectory.appending(path: "count-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: template, to: url)
        return SupertonicNarrationResult(audioURL: url, duration: 1, sampleRate: 44_100, renderDuration: 0.01, sessionLoadCount: 1)
    }
    func discardGeneratedAudio(at url: URL) async { try? FileManager.default.removeItem(at: url) }
}

private final class ResumeStartCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    var value: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

private final class GenerationProgressLog: @unchecked Sendable {
    private let lock = NSLock(); private var values: [Int] = []
    var completed: [Int] { lock.withLock { values } }
    func append(_ value: Int) { lock.withLock { values.append(value) } }
}

private final class PreparedChunkCommitGate: @unchecked Sendable {
    let stream: AsyncStream<Void>; let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock(); private var commits = 0
    init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
    /// Holds the second chunk's commit, as a slow copy/hash/persist would.
    func commit() async {
        let index = lock.withLock { commits += 1; return commits }
        if index == 2 { for await _ in stream {} }
    }
}

/// Returns audio far too long for its text: the babble signature the guard replaces. Like the
/// real renderer (#262), it deletes only files it generated.
private actor BabbleSupertonicRenderer: SupertonicRendering {
    let template: URL
    let seconds: TimeInterval
    private var generated: Set<URL> = []
    init(template: URL, seconds: TimeInterval) { self.template = template; self.seconds = seconds }
    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        let url = FileManager.default.temporaryDirectory.appending(path: "babble-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: template, to: url)
        generated.insert(url)
        return SupertonicNarrationResult(audioURL: url, duration: seconds, sampleRate: 44_100, renderDuration: 0.01, sessionLoadCount: 1)
    }
    func discardGeneratedAudio(at url: URL) async {
        if generated.remove(url) != nil { try? FileManager.default.removeItem(at: url) }
    }
}

/// Returns an iOS-voice stand-in after a delay, ignoring cancellation, like a synthesizer that
/// doesn't check for it. Deletes only files it made.
private final class SlowStandInRenderer: SupertonicRendering, @unchecked Sendable {
    let template: URL
    private let lock = NSLock()
    private var files: [URL] = []
    var made: [URL] { lock.withLock { files } }
    init(template: URL) { self.template = template }
    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        let url = FileManager.default.temporaryDirectory.appending(path: "system-voice-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: template, to: url)
        lock.withLock { files.append(url) }
        Thread.sleep(forTimeInterval: 0.3)
        return SupertonicNarrationResult(audioURL: url, duration: 1, sampleRate: 44_100, renderDuration: 0.3, sessionLoadCount: 0,
                                         engine: SupertonicNarrationResult.systemVoiceEngine)
    }
    func discardGeneratedAudio(at url: URL) async {
        if lock.withLock({ files.contains(url) }) { try? FileManager.default.removeItem(at: url) }
    }
}

private actor OrderGatedSupertonicRenderer: SupertonicRendering {
    let template: URL
    let gates: [Int: AsyncStream<Void>]
    private(set) var count = 0
    init(template: URL, gates: [Int: AsyncStream<Void>]) { self.template = template; self.gates = gates }
    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        count += 1
        if let gate = gates[count] { for await _ in gate {} }
        let url = FileManager.default.temporaryDirectory.appending(path: "order-gated-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: template, to: url)
        return SupertonicNarrationResult(audioURL: url, duration: 3, sampleRate: 44_100, renderDuration: 0.01, sessionLoadCount: 1)
    }
    func discardGeneratedAudio(at url: URL) async { try? FileManager.default.removeItem(at: url) }
}

private final class StallEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [String] = []
    private var starts = 0
    private var last: [String: String] = [:]
    var values: [String] { lock.withLock { kinds } }
    var startCount: Int { lock.withLock { starts } }
    var lastFields: [String: String] { lock.withLock { last } }
    func stall(_ kind: String, _ fields: [String: String]) { lock.withLock { kinds.append(kind); last = fields } }
    func started() { lock.withLock { starts += 1 } }
}

/// Switches to another item the first time a stall is about to be handled.
private final class ItemSwitch: @unchecked Sendable {
    weak var client: SupertonicSpeechPlaybackClient?
    private let lock = NSLock()
    private var done = false

    func run() {
        let first = lock.withLock { () -> Bool in defer { done = true }; return !done }
        guard first, let client else { return }
        try? client.stop()
        _ = try? client.prepareSpeechText("A different article starts playing here instead.")
        try? client.play(targetId: "second", from: 0)
    }
}

private final class MonitorExitResume: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var client: SupertonicSpeechPlaybackClient?
    func run() {
        let first = lock.withLock { () -> Bool in defer { done = true }; return !done }
        guard first, let client, let offset = client.currentCharOffset() else { return }
        try? client.play(targetId: "exit", from: offset)
    }
}

private actor CancellationAwareSupertonicRenderer: SupertonicRendering {
    let templateURL: URL
    private(set) var startedCount = 0
    private(set) var cancelledCount = 0

    private let onStart: @Sendable () -> Void
    private let onCancel: @Sendable () -> Void
    private var gate: AsyncStream<Void>.Continuation?

    init(templateURL: URL, onStart: @escaping @Sendable () -> Void, onCancel: @escaping @Sendable () -> Void) {
        self.templateURL = templateURL
        self.onStart = onStart
        self.onCancel = onCancel
    }

    func render(
        text: String,
        voice: SupertonicVoiceID,
        language: String,
        speed: Float,
        synthesisSteps: Int
    ) async throws -> SupertonicNarrationResult {
        startedCount += 1
        if startedCount == 1 {
            let stream = AsyncStream<Void> { gate = $0 }
            onStart()
            // Remain suspended until cancellation, without a wall-clock delay.
            for await _ in stream {}
            gate = nil
            do {
                try Task.checkCancellation()
            } catch {
                cancelledCount += 1
                onCancel()
                throw error
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cancellation-aware-render-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: templateURL, to: url)
        let audio = try AVAudioFile(forReading: url)
        return SupertonicNarrationResult(
            audioURL: url,
            duration: Double(audio.length) / audio.processingFormat.sampleRate,
            sampleRate: Int(audio.processingFormat.sampleRate.rounded()),
            renderDuration: 0.01,
            sessionLoadCount: 1
        )
    }

    func discardGeneratedAudio(at url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }
}

private final class ResourceConditionSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var isAllowed: Bool

    init(allowed: Bool) { isAllowed = allowed }

    var allowed: Bool {
        get { lock.withLock { isAllowed } }
        set { lock.withLock { isAllowed = newValue } }
    }
}

private final class RecordingFallbackAudioClient: AudioPlaybackClient, @unchecked Sendable {
    var preparedText = ""
    var playedOffsets: [Int] = []
    var playbackRates: [Double] = []
    var mixingStates: [Bool] = []
    var backgroundAudioStates: [Bool] = []
    var playbackVolumes: [Float] = []
    var pauseCount = 0
    var offset = 0
    /// How far the place moves each time it is read, as a speaking voice's would.
    var advancesPerRead = 0
    var completedTargetId: String?

    func prepareSpeechText(_ text: String) throws -> String {
        preparedText = text
        return text
    }

    func isPlaybackComplete(targetId: String) -> Bool { completedTargetId == targetId }

    func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        offset = charOffset
        playedOffsets.append(charOffset)
    }

    func currentCharOffset() -> Int? {
        defer { offset += advancesPerRead }
        return offset
    }

    func setPlaybackRate(_ rate: Double) throws {
        playbackRates.append(rate)
    }

    func setMixesWithOtherAudio(_ enabled: Bool) throws {
        mixingStates.append(enabled)
    }

    func setLowersBackgroundAudio(_ enabled: Bool) throws {
        backgroundAudioStates.append(enabled)
    }

    func setPlaybackVolume(_ volume: Float) throws {
        playbackVolumes.append(volume)
    }

    func pause() throws {
        pauseCount += 1
    }
}
