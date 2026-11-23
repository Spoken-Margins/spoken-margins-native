import AVFoundation
import CryptoKit
import SessionKit
import SessionKitAudio
import SessionKitPersistence
import SessionKitSupertonic
import UIKit
import XCTest
@testable import SpokenMarginsApp

@MainActor
final class SupertonicSpeechTests: XCTestCase {
    /// #2088: the governor is process-wide, and app test classes that run first can leave it counting the app as
    /// away. Tests here that want that state set it themselves.
    override func setUp() {
        super.setUp()
        OnDeviceVoiceGovernor.app.setAppBackgrounded(false)
    }

    /// #1109: the audio session's and the player's fields join a playback.state record only while
    /// playing, which left a pause with nothing from the client. The client's own fields are always there.
    func testPlaybackStateRecordKeepsTheClientsFieldsWhenPaused() {
        var snapshot = SessionSnapshot()
        snapshot.status = .paused
        let fields = DeveloperDiagnosticRecording.playbackStateFields(
            snapshot,
            player: ["playerRate": "0"],
            narration: PlaybackDiagnosticFields.narration(intent: "paused", systemVoiceActive: true, standInPassage: false)
        )
        XCTAssertEqual(fields["status"], "paused")
        XCTAssertEqual(fields["clientIntent"], "paused")
        XCTAssertEqual(fields["clientVoice"], "system_voice")
        XCTAssertNil(fields["playerRate"], "the player's own fields still join the record only while playing")
    }

    // testSystemVoiceClientReportsItsIntentForPlaybackRecords (#1109) runs on the host, in SessionKitCoreTests:
    // here it drove the real iOS synthesizer and hung past the 2-minute allowance in 2 of 31 lane runs.

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
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Plays one text and moves from its first chunk to its second; returns the cues heard and the narration's text
    /// offset once the second chunk has started.
    private func playTwoChunks(standInFrom: Int) async throws -> (cues: Int, offsetAtSecondChunk: Int?) {
        let root = FileManager.default.temporaryDirectory.appending(path: "voice-cue-two-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = StandInAfterFirstRenderer(template: try silentTemplate(root), standInFrom: standInFrom)
        let starts = ResumeStartCounter()
        let cues = ResumeStartCounter()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in starts.bump() },
            observesPlayerLifecycle: false, voiceChangeCue: { cues.bump() },
            fallbackClient: RecordingFallbackAudioClient()
        )
        let sentence = "The quick brown fox jumps over the lazy dog near the river bank. "
        _ = try client.prepareSpeechText(String(repeating: sentence, count: (RenderedSpeechChunker.spokenCostBudget * 2) / sentence.count + 3))
        try client.play(targetId: "voice-cue-two", from: 0)
        await waitUntil { starts.value >= 1 }
        client.debugFinishActiveChunk()
        await waitUntil { starts.value >= 2 }
        XCTAssertEqual(starts.value, 2)
        let offset = client.currentCharOffset()
        try client.stop()
        return (cues.value, offset)
    }

    // #258: playing an article's durable prepared chunk and then stopping deleted that chunk,
    // because cleanup handed it to the renderer, which removed any file it was given.
    // Real player, real prepared-audio coordinator and SQLite, real renderer deletion.
    func testStoppingPlaybackKeepsAnArticlesDurablePreparedChunk() async throws {
        let assets = try SupertonicTestAssets.installPlaceholderDownload(in: self) // it plays a prepared chunk; nothing renders (#1820)
        let root = FileManager.default.temporaryDirectory.appending(path: "prepared-survives-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        let coordinator = PreparedAudioCoordinator(repository: store, rootDirectory: root.appending(path: "PreparedAudio", directoryHint: .isDirectory))
        let text = "Prepared audio must survive stopping playback."
        // Preparation checks the stored item's text in its transaction, so the article must exist.
        try store.saveItem(Item(id: "item-258", title: "Article", mediaType: "article", text: text, externalReference: nil, status: "ready"))
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
            assets: assets,
            outputDirectory: root.appending(path: "Playback", directoryHint: .isDirectory),
            governor: OnDeviceVoiceGovernor()
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

    /// Stall-monitor samples that span stallClient's 400 ms stall threshold at one per 100 ms, with one to spare (#4313).
    private let samplesPastTheStallThreshold = 6

    private func stallClient(
        _ log: StallEventLog, template: URL, plays: Bool,
        playsFromStart: Int? = nil, onStart: (@Sendable (AVPlayer) -> Void)? = nil,
        fallback: RecordingFallbackAudioClient = RecordingFallbackAudioClient(),
        renderer: CountingAudioSupertonicRenderer? = nil,
        articleText: SupertonicSpeechPlaybackClient.ArticleTextLookup? = nil,
        renderingAllowed: (@Sendable () -> Bool)? = nil,
        maxCharacters: Int = RenderedSpeechChunker.spokenCostBudget,
        playerClock: (@Sendable (AVPlayer) -> TimeInterval)? = nil,
        pressureRenderer: (any BundledVoiceRendering)? = nil
    ) -> SupertonicSpeechPlaybackClient {
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer ?? CountingAudioSupertonicRenderer(templateURL: template), voice: .m2, speed: 1,
            fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            maxCharacters: maxCharacters,
            audioSessionActivator: {},
            audioPlayerStarter: { player, rate in
                log.started()
                onStart?(player)
                if plays || playsFromStart.map({ log.startCount >= $0 }) == true {
                    player.volume = 0; player.playImmediately(atRate: rate)
                }
            },
            playerClock: playerClock,
            observesPlayerLifecycle: false,
            onDeviceRenderingAllowed: renderingAllowed ?? { SupertonicResourcePolicy.allowsRendering() },
            pressureRenderer: pressureRenderer,
            fallbackClient: fallback,
            interruptionHandler: { event in log.stall("interruption.\(event)", [:]) },
            articleText: articleText,
            onFallback: { reason, _, _ in log.fellBack(reason) },
            onStall: { kind, fields in log.stall(kind, fields) },
            stallThreshold: .milliseconds(400), stallSampleInterval: .milliseconds(100)
        )
        client.debugStallSampleWasTaken = { log.sampled() }
        return client
    }

    /// Waits until the stall monitor has taken enough samples, from now, to span stallClient's 400 ms threshold. A
    /// sample takes at least its 100 ms interval, so a stall that was going to be noticed has been by then, however
    /// slowly the runner got there (#4368).
    private func waitForSamplesPastTheStallThreshold(_ log: StallEventLog) async throws {
        // One more than the threshold needs: a loop already under way when this starts read its facts before the test
        // changed them, so it does not count toward spanning the threshold.
        let wanted = log.sampleCount + samplesPastTheStallThreshold + 1
        try await pollUntil { log.sampleCount >= wanted }
        XCTAssertGreaterThanOrEqual(log.sampleCount, wanted, "the stall monitor kept sampling")
    }

    /// A client whose render times out, so the iOS voice (`fallback`) takes over at offset 17.
    private func systemVoiceStallClient(_ log: StallEventLog, fallback: RecordingFallbackAudioClient) throws -> SupertonicSpeechPlaybackClient {
        let template = try makeTestWAV(duration: 0.5)
        addTeardownBlock { try? FileManager.default.removeItem(at: template) }
        let client = SupertonicSpeechPlaybackClient(
            renderer: CountingAudioSupertonicRenderer(templateURL: template, firstRenderDelay: .seconds(1)),
            voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: { fallback.record("activate") }, audioPlayerStarter: { _, _ in }, observesPlayerLifecycle: false,
            fallbackClient: fallback,
            interruptionHandler: { event in log.stall("interruption.\(event)", [:]) },
            onFallback: { _, _, _ in log.stall("fallback", [:]) },
            onStall: { kind, fields in log.stall(kind, fields) },
            stallThreshold: .milliseconds(400), stallSampleInterval: .milliseconds(100),
            renderWaitLimit: .milliseconds(100)
        )
        client.debugStallSampleWasTaken = { log.sampled() }
        return client
    }

    // #336: a PDF on the new reader is spoken from its listenable text, without references or
    // running heads. Preparation, the player's lookups and assembly all read Item.text, so nothing
    // matched and these PDFs were never prepared. They now share PreparedSpeechHooks' text: a
    // prepared paper plays from its prepared chunks, and its narration's timeline stays in Item.text.
    func testAPreparedNewReaderPDFPlaysFromItsChunksAndItsNarrationStaysInItemText() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "v2-prepared-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let template = try makeTestWAV(duration: 0.1)
        defer { try? FileManager.default.removeItem(at: template) }
        let store = try SQLiteSessionStore(path: root.appending(path: "store.sqlite").path)
        let body = (1...6).map { "Sentence \($0) of the methods carries enough ordinary words to fill part of a chunk." }
        let document = StructuredDocumentBuilder.build(lines: [
            StructuredDocumentLine(text: "J Biol 12 (2020) 1-9", role: .pageHeader, pageIndex: 0),
            StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 2),
        ] + body.map { StructuredDocumentLine(text: $0, role: .body, pageIndex: 0) } + [
            StructuredDocumentLine(text: "References", role: .heading, pageIndex: 1, level: 2),
            StructuredDocumentLine(text: "[1] A. Author. A cited title. 2019.", role: .reference, pageIndex: 1),
            StructuredDocumentLine(text: "Appendix", role: .heading, pageIndex: 1, level: 2),
            StructuredDocumentLine(text: "Supplementary methods are read aloud after the references.", role: .body, pageIndex: 1),
        ], engine: "pdfkit_baseline", version: 2, pageCount: 2)
        let item = Item(id: "item-paper", title: "Paper", mediaType: "pdf", text: document.text, externalReference: nil, status: "ready")
        try store.saveItem(item)
        try store.saveStructuredDocument(document, itemId: item.id)

        // Background preparation, planned as the app's preparation pass plans it.
        let text = try XCTUnwrap(PreparedSpeechHooks.preparedText(of: item, in: store))
        XCTAssertFalse(text.contains("A cited title"), "references aren't prepared")
        XCTAssertFalse(text.contains("J Biol"), "running heads aren't prepared")
        let signature = TTSRenderSignature(
            engine: "supertonic", modelRevision: "3", assetManifestHash: "assets", voiceStyleHash: "v2",
            synthesisParametersHash: "parameters", normalizationVersion: "normalization", chunkingVersion: "chunking", digest: "v2-paper"
        )
        let preparedRoot = root.appending(path: "PreparedAudio", directoryHint: .isDirectory)
        let coordinator = PreparedAudioCoordinator(repository: store, rootDirectory: preparedRoot)
        let plan = PreparedChunkPlan.articlePlan(text)
        XCTAssertGreaterThan(plan.count, 1)
        _ = try await coordinator.begin(itemId: item.id, sourceText: text, signature: signature, plan: plan)
        for chunk in plan {
            try await coordinator.commit(itemId: item.id, signature: signature, plan: chunk, sourceText: text, audioURL: template, durationMs: 100)
        }

        // The player, wired as Gate1AppModel wires it, speaks what SessionEngine hands it.
        let hooks = PreparedSpeechHooks(store: store, coordinator: coordinator, signatureTask: Task<TTSRenderSignature, Error> { signature })
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let hits = PreparedLookupLog()
        let misses = PreparedLookupLog()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1,
            fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { _, _ in },
            observesPlayerLifecycle: false, fallbackClient: RecordingFallbackAudioClient(),
            articleText: { hooks.articleText(itemId: $0) },
            preparedChunkLookup: { itemId, identity, chunk in
                let found = await hooks.lookup(itemId: itemId, articleIdentity: identity, plan: chunk)
                (found == nil ? misses : hits).add(identity, chunk)
                return found
            }
        )
        _ = try client.prepareSpeechText(text)
        try client.play(targetId: item.id, from: 0)
        try await pollUntil { Set(hits.values.map { $0.1.index }).count >= plan.count }
        try client.stop()
        XCTAssertEqual(Set(hits.values.map { $0.1.index }), Set(plan.map(\.index)), "every prepared chunk is found")
        XCTAssertTrue(misses.values.isEmpty, "\(misses.values.count) lookups found nothing")
        let renders = await renderer.renderCount
        XCTAssertEqual(renders, 0, "nothing renders live")

        // Assembly, as finishBackgroundPreparedAudio does it: attaching the narration keeps
        // Item.text, and each stretch of audio points at its own words there.
        let speech = try XCTUnwrap(PreparedSpeechHooks.texts.resolve(item: item, documents: store))
        let manifest = try XCTUnwrap(try store.loadPreparedAudioManifests(itemId: item.id).first)
        let narration = try await SupertonicPreparedAudioAssembler.assemble(
            itemId: item.id,
            sourceText: speech.itemText,
            projection: speech.assemblyProjection(),
            voice: .m2,
            chunks: try PreparedAudioCoordinator.assemblyChunks(plan: plan, manifest: manifest, sourceText: text, preparedRoot: preparedRoot),
            outputDirectory: root.appending(path: "Narration", directoryHint: .isDirectory)
        )
        XCTAssertEqual(narration.normalizedText, item.text, "the narration keeps Item.text")
        let itemCharacters = Array(document.text)
        let starts = narration.timeline.segments.compactMap(\.startChar)
        XCTAssertEqual(starts, starts.sorted(), "the narration moves forward through Item.text")
        let appendix = try XCTUnwrap(narration.timeline.segments.first { $0.text.contains("Supplementary methods") })
        XCTAssertTrue(String(itemCharacters[(appendix.startChar ?? 0)..<(appendix.endChar ?? 0)]).contains("Supplementary methods"),
                      "a Margin made during the appendix opens at the appendix")
    }

    // #336, Codex audit on 2a0d49f: a short body, forty references and a short appendix. The
    // references aren't spoken, so one chunk says "References skipped" and the appendix, though
    // the references sit between them in Item.text. Its narration segment used to span them: a
    // place partway through that chunk's audio landed in the references, and a Margin made while
    // the appendix played opened on the whole span. Each stretch of Item.text now gets its own
    // segment, so a Margin made through SessionEngine and reopened from the store opens on the
    // words that were playing.
    func testAMarginMadeDuringANewReaderPDFsNarrationReopensOnTheWordsThatWerePlaying() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "v2-margin-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let template = try makeTestWAV(duration: 0.1)
        defer { try? FileManager.default.removeItem(at: template) }
        let storePath = root.appending(path: "store.sqlite").path
        let store = try SQLiteSessionStore(path: storePath)
        let references = (1...40).map { "[\($0)] A. Author. A cited title number \($0). Journal of Examples. 2019." }
        let document = StructuredDocumentBuilder.build(lines: [
            StructuredDocumentLine(text: "Methods", role: .heading, pageIndex: 0, level: 2),
            StructuredDocumentLine(text: "Levels rose as expected in every cohort we followed.", role: .body, pageIndex: 0),
            StructuredDocumentLine(text: "References", role: .heading, pageIndex: 1, level: 2),
        ] + references.map { StructuredDocumentLine(text: $0, role: .reference, pageIndex: 1) } + [
            StructuredDocumentLine(text: "Appendix", role: .heading, pageIndex: 2, level: 2),
            StructuredDocumentLine(text: "Supplementary methods are read aloud.", role: .body, pageIndex: 2),
        ], engine: "pdfkit_baseline", version: 2, pageCount: 3)
        let item = Item(id: "item-paper-margins", title: "Paper", mediaType: "pdf", text: document.text, externalReference: nil, status: "ready")
        try store.saveItem(item)
        try store.saveStructuredDocument(document, itemId: item.id)
        let itemText = document.text
        let firstReference = itemText.distance(from: itemText.startIndex, to: try XCTUnwrap(itemText.range(of: "[1] A. Author")).lowerBound)
        let lastReference = itemText.distance(from: itemText.startIndex, to: try XCTUnwrap(itemText.range(of: "number 40. Journal of Examples. 2019.")).upperBound)
        // "References skipped." is spoken at the first reference's first character; nothing may go further in.
        let unheard = (firstReference + 1)..<lastReference

        // Prepared and assembled as finishBackgroundPreparedAudio does it.
        let text = try XCTUnwrap(PreparedSpeechHooks.preparedText(of: item, in: store))
        let plan = PreparedChunkPlan.articlePlan(text)
        XCTAssertTrue(plan.contains { $0.text.contains("References skipped") && $0.text.contains("Supplementary") },
                      "precondition: one chunk speaks across the references")
        let signature = TTSRenderSignature(
            engine: "supertonic", modelRevision: "3", assetManifestHash: "assets", voiceStyleHash: "v2",
            synthesisParametersHash: "parameters", normalizationVersion: "normalization", chunkingVersion: "chunking", digest: "v2-margins"
        )
        let preparedRoot = root.appending(path: "PreparedAudio", directoryHint: .isDirectory)
        let coordinator = PreparedAudioCoordinator(repository: store, rootDirectory: preparedRoot)
        _ = try await coordinator.begin(itemId: item.id, sourceText: text, signature: signature, plan: plan)
        for chunk in plan {
            try await coordinator.commit(itemId: item.id, signature: signature, plan: chunk, sourceText: text, audioURL: template, durationMs: 100)
        }
        let speech = try XCTUnwrap(PreparedSpeechHooks.texts.resolve(item: item, documents: store))
        let manifest = try XCTUnwrap(try store.loadPreparedAudioManifests(itemId: item.id).first)
        let narration = try await SupertonicPreparedAudioAssembler.assemble(
            itemId: item.id,
            sourceText: speech.itemText,
            projection: speech.assemblyProjection(),
            voice: .m2,
            chunks: try PreparedAudioCoordinator.assemblyChunks(plan: plan, manifest: manifest, sourceText: text, preparedRoot: preparedRoot),
            outputDirectory: root.appending(path: "Narration", directoryHint: .isDirectory)
        )
        let durationMs = try XCTUnwrap(narration.media.durationMs)
        for time in stride(from: 0, to: durationMs, by: 5) {
            let offset = PreparedNarrationFallback.textOffset(mediaTimeMs: time, timeline: narration.timeline)
            XCTAssertFalse(unheard.contains(offset), "at \(time) ms the narration's place is \(offset), inside the references")
        }

        // Played and annotated through SessionEngine, as the app does.
        let audio = NarrationClockAudioClient(durationMs: durationMs)
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone", displayName: "Phone",
                capabilities: [
                    "sync": ["canonical_persistence"],
                    "playback": ["realtime_tts", "prerendered_audio", "native_media"],
                    "timeline": ["transcript_segments", "media_time", "chapter_timing"],
                ]
            ),
            repository: store,
            audio: audio
        )
        _ = try engine.attachPreparedTextAudio(itemId: item.id, prepared: narration)
        let started = try engine.startSession(itemId: item.id)
        XCTAssertEqual(started.targetType, TargetType.transcriptBackedMedia.rawValue, "the narration plays")
        let sessionId = try XCTUnwrap(started.sessionId)
        // Inside the appendix's own audio: the narration ends in a transition silence no segment covers.
        let appendixOffset = itemText.distance(from: itemText.startIndex, to: try XCTUnwrap(itemText.range(of: "Supplementary methods")).lowerBound)
        let appendixAudio = try XCTUnwrap(narration.timeline.segments.first { ($0.endChar ?? 0) > appendixOffset })
        for (time, note) in [(5, "During the methods"), ((appendixAudio.startMs + appendixAudio.endMs) / 2, "During the appendix")] {
            audio.mediaTimeMs = time
            let capture = try engine.beginWrittenInterjection()
            _ = try engine.saveWrittenInterjection(captureId: capture.id, text: note)
        }

        // Reopened from the database.
        let reopened = try SQLiteSessionStore(path: storePath)
        let margins = try reopened.loadInterjections(sessionId: sessionId)
        let characters = Array(try XCTUnwrap(try reopened.loadItem(id: item.id).text))
        func passage(_ note: String) throws -> (text: String, range: Range<Int>) {
            let margin = try XCTUnwrap(margins.first { $0.displayText == note }, note)
            let start = try XCTUnwrap(margin.anchor.startChar), end = try XCTUnwrap(margin.anchor.endChar)
            let range = start..<max(start, min(end, characters.count))
            return (String(characters[range]), range)
        }
        let methods = try passage("During the methods")
        XCTAssertTrue(methods.text.contains("Levels rose") || methods.text.contains("Methods"), methods.text)
        XCTAssertFalse(methods.range.overlaps(unheard), "the methods Margin opens in the references: \(methods.range)")
        let appendix = try passage("During the appendix")
        XCTAssertTrue(appendix.text.contains("Supplementary methods"), appendix.text)
        XCTAssertFalse(appendix.range.overlaps(unheard), "the appendix Margin opens in the references: \(appendix.range)")
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
        try await pollUntil { Set(log.values.map { $0.1.index }).count >= count }
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

    /// The client's render wait for a stand-in chunk. These tests used to wait on real iOS speech
    /// synthesis (#417), so it outlasts the synthesizer's 30 s limit; with `copyStandIn` it is spare.
    private let standInRenderWaitLimit: Duration = .seconds(60)

    /// #1688: the guard tests check which file the guard keeps, caches, assembles and deletes, not
    /// Apple's synthesis. They used real iOS speech, and on a freshly cloned lane simulator the
    /// first voice lookup or write waited 2 to 6 minutes behind the simulator's background-task
    /// daemon (`dasd`) settling after boot. Waiting longer (#1230, #1623, #1689) and naming a
    /// built-in voice (#1694) did not help, and the same head passed and failed. So the guard is
    /// given a stand-in that copies the Supertonic chunk, already in its format. Real synthesis is
    /// covered by `SystemVoiceSessionTests` (which skips a stalled runtime, #768) and on the host by
    /// `SystemVoiceChunkRendererTests`.
    private let copyStandIn: SupertonicOutputGuard.StandInRender = { _, _, reference, output in
        try FileManager.default.copyItem(at: reference, to: output)
        let file = try AVAudioFile(forReading: output)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func awaitStandIn(_ reports: GuardReports) async throws {
        await fulfillment(of: [reports.reported], timeout: 45)
        let report = try XCTUnwrap(reports.values.first, "the guard never reported: the iOS voice took over 45 s")
        XCTAssertTrue(report.contains("last system_voice:"), "the iOS voice stood in; the guard reported \"\(report)\"")
    }

    // Leaving the app while a chunk plays: the next chunk is ready already, so it goes onto the player then.
    func testLeavingTheAppQueuesTheNextChunk() async throws {
        let presence = AppPresence()
        let center = NotificationCenter()
        let harness = try SupertonicClientHarness(applicationIsActive: { presence.isActive }, notificationCenter: center)
        defer { harness.tearDown() }
        let chunk = harness.chunkStarts
        try await harness.start(waitingForRenders: 3)
        await harness.waitForRendersHandled(3)                      // B and C landed, and nothing was queued for them
        XCTAssertNil(harness.client.debugQueuedChunkStart, "the app is in front")

        presence.isActive = false
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        let queued = await harness.waitForQueuedChunk(chunk[1])
        XCTAssertTrue(queued, "B is queued as the app leaves")
    }

    func testSelectableCatalogExposesJamesLilyKittenAndSystem() {
        XCTAssertEqual(AppTTSVoiceSelection.allCases, [.james, .lily, .kitten, .system, .phonon, .kokoro])
        XCTAssertEqual(AppTTSVoiceSelection.kitten.rawValue, "kitten:jasper")
        XCTAssertNil(AppTTSVoiceSelection.kitten.supertonicVoice)
        XCTAssertEqual(AppTTSVoiceSelection.james.rawValue, "supertonic:M2")
        XCTAssertEqual(AppTTSVoiceSelection.james.supertonicVoice, .m2)
        XCTAssertEqual(AppTTSVoiceSelection.lily.rawValue, "supertonic:F2")
        XCTAssertEqual(AppTTSVoiceSelection.lily.supertonicVoice, .f2)
        XCTAssertNil(AppTTSVoiceSelection.system.supertonicVoice)
    }

    /// #849: with Supertonic refused (heat, Low Power Mode, memory), the bundled Kitten voice renders the chunks
    /// and the iOS voice is never asked. The first chunk is split in two so audio starts quickly.
    func testResourcePressureRendersWithTheBundledKittenVoiceNotTheIOSVoice() async throws {
        let root = try XCTUnwrap(Bundle.main.resourceURL?.appending(path: "Kitten", directoryHint: .isDirectory))
        let output = FileManager.default.temporaryDirectory.appending(path: "kitten-client-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let kitten = try KittenNarrationRenderer(assets: KittenAssetLocation(rootURL: root), outputDirectory: output, governor: OnDeviceVoiceGovernor())
        let template = try makeTestWAV(duration: 0.2)
        defer { try? FileManager.default.removeItem(at: template) }
        let supertonic = CountingAudioSupertonicRenderer(templateURL: template)
        let fallback = RecordingFallbackAudioClient()
        let log = KittenClientLog()
        let started = expectation(description: "audio started")
        started.assertForOverFulfill = false
        let client = SupertonicSpeechPlaybackClient(
            renderer: supertonic, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {},
            audioPlayerStarter: { player, rate in
                player.volume = 0
                player.playImmediately(atRate: rate)
                started.fulfill()
            },
            observesPlayerLifecycle: false,
            onDeviceRenderingAllowed: { false },
            pressureRenderer: kitten,
            fallbackClient: fallback,
            onGenerationProgress: { log.record($0) },
            onFallback: { reason, _, _ in log.recordFallback(reason) },
            onBundledVoice: { _, _, _ in log.recordNotice("bundled_voice") },
            // #2731: the claim is which voice renders, not that the player's clock advances. A volume-0 AVPlayer on a loaded
            // hosted Mac can sit still for 5 s and trip the stall monitor, which hands the item to the iOS voice.
            stallThreshold: .seconds(3600)
        )
        let text = (0..<4).map { _ in
            "The committee met on Tuesday to discuss the proposal, which had been circulating among members for several weeks and had attracted a surprising amount of criticism from both sides. Most of the objections concerned cost."
        }.joined(separator: " ")
        let plannedChunks = NarrationChunkPlanner.spokenPlan(
            spokenText: SpeechTextNormalizer.normalize(text), articleText: nil, articleSpokenStart: 0).chunks.count
        _ = try client.prepareSpeechText(text)
        try client.play(targetId: "pressure-kitten")

        await fulfillment(of: [started], timeout: 60)
        let deadline = ContinuousClock.now + .seconds(120)
        while log.completedChunks < log.totalChunks, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        let supertonicRenders = await supertonic.renderCount
        XCTAssertEqual(supertonicRenders, 0, "Supertonic is refused")
        XCTAssertEqual(fallback.playedOffsets, [], "the iOS voice is never asked")
        XCTAssertEqual(log.fallbacks, [])
        XCTAssertEqual(log.notices, ["bundled_voice"], "I14: the listener is told once why the voice changed")
        XCTAssertEqual(log.totalChunks, plannedChunks + 1, "the first chunk is split in two")
        XCTAssertEqual(log.completedChunks, log.totalChunks)
        let kittenDiagnostics = await kitten.diagnostics()
        XCTAssertEqual(kittenDiagnostics.sessionLoadCount, 1)
        try client.stop()
        await kitten.unload()
    }

    /// #849 audit (I14): once the bundled voice takes a generation, it keeps it. Supertonic is allowed again while the
    /// chain renders (the phone cools), yet no later chunk switches to it mid-play: the split head ends at a comma,
    /// so before the fix the tail came back in Supertonic mid-sentence. The next play releases it.
    func testTheBundledVoiceKeepsTheItemAfterTheConditionClearsAndTheNextItemGetsTheChosenVoice() async throws {
        let root = try XCTUnwrap(Bundle.main.resourceURL?.appending(path: "Kitten", directoryHint: .isDirectory))
        let output = FileManager.default.temporaryDirectory.appending(path: "kitten-hold-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let kitten = try KittenNarrationRenderer(assets: KittenAssetLocation(rootURL: root), outputDirectory: output, governor: OnDeviceVoiceGovernor())
        let template = try makeTestWAV(duration: 0.2)
        defer { try? FileManager.default.removeItem(at: template) }
        let supertonic = CountingAudioSupertonicRenderer(templateURL: template)
        let fallback = RecordingFallbackAudioClient()
        let log = KittenClientLog()
        let allowed = KittenAllowedFlag()
        let started = expectation(description: "audio started")
        started.assertForOverFulfill = false
        let client = SupertonicSpeechPlaybackClient(
            renderer: supertonic, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {},
            audioPlayerStarter: { player, rate in
                player.volume = 0
                player.playImmediately(atRate: rate)
                started.fulfill()
            },
            observesPlayerLifecycle: false,
            onDeviceRenderingAllowed: { allowed.value },
            pressureRenderer: kitten,
            fallbackClient: fallback,
            onGenerationProgress: { progress in
                log.record(progress)
                // The condition clears as soon as the bundled voice has rendered the first chunk.
                if progress.completedChunks >= 1 { allowed.value = true }
            },
            onFallback: { reason, _, _ in log.recordFallback(reason) },
            onRestore: { _ in log.recordRestore() },
            onBundledVoice: { _, _, _ in log.recordNotice("bundled_voice") },
            // #2731: the claim is which voice renders, not that the player's clock advances. A volume-0 AVPlayer on a loaded
            // hosted Mac can sit still for 5 s and trip the stall monitor, which hands the item to the iOS voice.
            stallThreshold: .seconds(3600)
        )
        let text = (0..<4).map { _ in
            "The committee met on Tuesday to discuss the proposal, which had been circulating among members for several weeks and had attracted a surprising amount of criticism from both sides. Most of the objections concerned cost."
        }.joined(separator: " ")
        _ = try client.prepareSpeechText(text)
        try client.play(targetId: "kitten-hold")

        await fulfillment(of: [started], timeout: 60)
        let deadline = ContinuousClock.now + .seconds(120)
        while log.totalChunks == 0 || log.completedChunks < log.totalChunks, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(log.completedChunks, log.totalChunks)
        XCTAssertTrue(allowed.value, "the condition cleared during the generation")
        let rendersDuringGeneration = await supertonic.renderCount
        XCTAssertEqual(rendersDuringGeneration, 0, "no chunk of the generation switches back to Supertonic mid-play")
        XCTAssertEqual(fallback.playedOffsets, [])
        XCTAssertEqual(log.notices, ["bundled_voice"])

        // A play of the same item keeps the bundled voice (#1786); a new item releases it: the listener's notice is
        // cleared and Supertonic renders the new item.
        try client.pause()
        try client.play(targetId: "kitten-hold", from: client.currentCharOffset() ?? 0)
        XCTAssertEqual(log.restores, 0, "a play inside the item doesn't release the bundled voice")
        try client.stop()
        _ = try client.prepareSpeechText("The next item. The phone is cool now, so the chosen voice reads it.")
        try client.play(targetId: "kitten-next")
        XCTAssertEqual(log.restores, 1, "the next item releases the bundled voice")
        let releaseDeadline = ContinuousClock.now + .seconds(30)
        var rendersAfterPlay = await supertonic.renderCount
        while rendersAfterPlay == 0, ContinuousClock.now < releaseDeadline {
            try await Task.sleep(for: .milliseconds(100))
            rendersAfterPlay = await supertonic.renderCount
        }
        XCTAssertGreaterThan(rendersAfterPlay, 0, "Supertonic reads the next item")
        try client.stop()
        await kitten.unload()
    }

    /// #1681 audit: while the chain rested, the app's 45-second watch marked the render delayed, showed "Still
    /// preparing" and wrote a delay into diagnostics on every rest. A rest starts no watch; waking starts it again.
    func testARestingRenderChainIsNotWatchedAsADelayedRender() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.updateOnDeviceSpeechGenerationState(.rendering, stopReason: nil)
        model.updateOnDeviceSpeechGenerationProgress(RenderedSpeechGenerationProgress(completedChunks: 4, totalChunks: 30))
        XCTAssertNotNil(model.onDeviceSpeechGenerationDelayTask, "a render that owes progress is watched")
        model.updateOnDeviceSpeechGenerationProgress(
            RenderedSpeechGenerationProgress(completedChunks: 5, totalChunks: 30, isRestingAhead: true))
        XCTAssertNil(model.onDeviceSpeechGenerationDelayTask, "a resting chain is not")
        XCTAssertFalse(model.isOnDeviceSpeechGenerationDelayed)
        XCTAssertEqual(model.diagnostics["onDeviceSpeechGenerationProgress"], "5/30 resting")
        model.updateOnDeviceSpeechGenerationProgress(RenderedSpeechGenerationProgress(completedChunks: 5, totalChunks: 30))
        XCTAssertNotNil(model.onDeviceSpeechGenerationDelayTask, "waking from the rest starts the watch again")
        model.onDeviceSpeechGenerationDelayTask?.cancel()
    }

    private func renderAhead(
        window: TimeInterval?, playsAudio: Bool
    ) async throws -> (
        renders: Int, completed: Int, total: Int, restarts: Int, restingReports: Int, last: RenderedSpeechGenerationProgress,
        reports: [RenderedSpeechGenerationProgress]
    ) {
        let template = try makeTestWAV(duration: 0.2)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let log = KittenClientLog()
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {},
            audioPlayerStarter: { player, rate in
                guard playsAudio else { return }
                player.volume = 0
                player.playImmediately(atRate: rate)
            },
            // The player's own end moves playback on, which is what lets a resting chain start again.
            observesPlayerLifecycle: playsAudio,
            onDeviceRenderingAllowed: { true },
            onGenerationProgress: { log.record($0) },
            renderAheadWindow: { window }
        )
        let text = (1...30).map { "Sentence \($0) carries enough words to make a chunk of its own for the planner here." }
            .joined(separator: " ")
        _ = try client.prepareSpeechText(text)
        try client.play(targetId: "render-ahead")
        let deadline = ContinuousClock.now + .seconds(playsAudio ? 30 : 3)
        var lastCount = -1
        var steadySince = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            if log.totalChunks > 0, log.completedChunks == log.totalChunks { break }
            let count = await renderer.renderCount
            if count != lastCount {
                lastCount = count
                steadySince = ContinuousClock.now
            } else if !playsAudio, ContinuousClock.now - steadySince > .seconds(1) {
                break
            }
        }
        let renders = await renderer.renderCount
        let restarts = client.debugRenderAheadRestarts
        try client.stop()
        return (renders, log.completedChunks, log.totalChunks, restarts, log.restingProgressReports, log.lastProgress,
                log.progressReports)
    }

    /// An article of paragraphs for the pressure tests: the planner runs chunks across the breaks. Every sentence
    /// names its paragraph, so no two chunks have the same text and a chunk's text says which chunk it is.
    private static func pressureArticle(paragraphs: Int) -> String {
        (1...paragraphs).map {
            "Section \($0). The committee met on day \($0) to discuss proposal \($0), which had been circulating among members for several weeks. Most of the objections to proposal \($0) concerned cost, and a smaller group worried about its timeline."
        }.joined(separator: "\n\n")
    }

    /// `chunks` article chunks from the first paragraph seam at or after chunk `start` (the planner's own plan and
    /// seam rule), as the client sees them without a preface.
    private static func savedRun(
        in text: String, startingAtOrAfter start: Int, chunks count: Int
    ) throws -> (indices: ClosedRange<Int>, texts: [String], plan: [NarrationChunkPlanner.SpokenChunk]) {
        let projection = SpeechTextNormalizer.normalizeWithSourceOffsets(text)
        let plan = NarrationChunkPlanner.spokenPlan(spokenText: projection.text, articleText: nil, articleSpokenStart: 0).chunks
        let seam = try XCTUnwrap(plan.indices.first { index in
            index >= start && index + count < plan.count - 1 && SavedVoiceRunRule.isParagraphSeam(
                in: text, at: index,
                sourceStart: { projection.sourceOffset(atSpokenCharacterOffset: plan[$0].startOffset) },
                endsSentence: { plan[$0].boundary == .sentence || plan[$0].boundary == .hard })
        }, "no seam with room for the run in \(plan.count) chunks")
        let indices = seam...(seam + count - 1)
        return (indices, indices.map { plan[$0].text }, plan)
    }

    /// Renders `text` to the end on a phone that refuses Supertonic, with saved Supertonic audio for the article chunks
    /// at `savedSupertonic`, each declared `declaredSeconds` long.
    /// The lookup matches the full key, as the coordinator does (#1892): the item, the article's identity, and each
    /// chunk's index, start, length and text against the article plan, with `savedStartShift` added to the start to
    /// make a wrong one. `servedIndices` are the chunks it answered for, once each, in the order first answered.
    private func renderUnderPressure(
        text: String, savedSupertonic: Set<Int>, declaredSeconds: TimeInterval, playbackRate: Double = 1,
        savedStartShift: Int = 0, coolsAfterCompleted: Int? = nil, heatsAgainAfterCompleted: Int? = nil
    ) async throws -> (bundledTexts: [String], supertonicRenders: Int, servedIndices: [Int]) {
        let template = try makeTestWAV(duration: 0.2)
        defer { try? FileManager.default.removeItem(at: template) }
        let supertonic = CountingAudioSupertonicRenderer(templateURL: template)
        let bundled = RecordingBundledVoiceRenderer(templateURL: template)
        let log = KittenClientLog()
        let served = ServedChunkLog()
        let expectedIdentity = NarrationChunkPlanner.identity(ofArticle: text)
        let expectedPlan = Self.expectedArticlePlan(for: text)
        // The phone starts hot (Supertonic may not render). The weather can turn while the generation runs: it cools
        // once `coolsAfterCompleted` chunks are done and is hot again once `heatsAgainAfterCompleted` are. A chunk's
        // voice is chosen as its render starts, so a change lands on the chunk after the one that completed.
        let cool = KittenAllowedFlag()
        let client = SupertonicSpeechPlaybackClient(
            renderer: supertonic, voice: .m2, speed: 1, fallbackVoiceIdentifier: nil, fallbackRate: 0.5,
            audioSessionActivator: {}, audioPlayerStarter: { player, rate in player.volume = 0; player.playImmediately(atRate: rate) },
            observesPlayerLifecycle: false,
            onDeviceRenderingAllowed: { cool.value },
            pressureRenderer: bundled,
            fallbackClient: RecordingFallbackAudioClient(),
            onGenerationProgress: { progress in
                log.record(progress)
                if let coolAt = coolsAfterCompleted, progress.completedChunks >= coolAt { cool.value = true }
                if let heatAt = heatsAgainAfterCompleted, progress.completedChunks >= heatAt { cool.value = false }
            },
            preparedChunkLookup: { itemId, identity, plan in
                guard itemId == "saved-run", identity == expectedIdentity,
                      let expected = expectedPlan.first(where: { $0.index == plan.index }), savedSupertonic.contains(plan.index),
                      plan.startOffset == expected.startOffset + savedStartShift,
                      plan.sourceLength == expected.sourceLength, plan.text == expected.text else { return nil }
                served.add(plan.index)
                return .init(audioURL: template, duration: declaredSeconds)
            },
            onFallback: { reason, _, _ in log.recordFallback(reason) },
            // #2088: the default window reads the shared governor and the device. If an earlier test class left the
            // app counted as away, a 300 s window rested the chain mid-run, and with no player lifecycle nothing woke
            // it. #1681's limit has its own tests; this helper renders to the end.
            renderAheadWindow: { nil }
        )
        _ = try client.prepareSpeechText(text)
        try client.setPlaybackRate(playbackRate)
        try client.play(targetId: "saved-run")
        // Returns as soon as the last chunk is reported (#2386); the timeout only bounds a failure.
        await fulfillment(of: [log.finished], timeout: 60)
        XCTAssertEqual(log.completedChunks, log.totalChunks, "the generation finished")
        XCTAssertEqual(log.fallbacks, [])
        try client.stop()
        return (await bundled.renderedTexts, await supertonic.renderCount, served.indices)
    }

    /// The article plan the way the planner makes it, in the article's own coordinates: what a lookup must be asked for.
    private static func expectedArticlePlan(for text: String) -> [PreparedChunkPlan] {
        let projection = SpeechTextNormalizer.normalizeWithSourceOffsets(text)
        return NarrationChunkPlanner.spokenPlan(spokenText: projection.text, articleText: nil, articleSpokenStart: 0).chunks
            .enumerated().map { position, chunk in
                PreparedChunkPlan(index: chunk.articleIndex ?? position, startOffset: chunk.startOffset,
                                  sourceLength: chunk.sourceLength, text: chunk.text)
            }
    }

    private func waitForEngine(
        _ engine: SessionEngine, status: PlaybackStatus, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
            if try engine.syncPlaybackProgress().status == status { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("\(message): engine stayed \(try engine.syncPlaybackProgress().status)", file: file, line: line)
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

    /// #1109 (Codex audit on 834f9d7): the client answers true to a stop even when the iOS voice already
    /// reads, so a later memory warning must not record a second switch. Only the change of voice records one.
    func testStoppingGenerationRecordsTheFallbackOnlyWhenTheVoiceChanges() async throws {
        let template = try makeTestWAV(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template, firstRenderDelay: .milliseconds(300))
        let client = SupertonicSpeechPlaybackClient(
            renderer: renderer,
            voice: .m2,
            speed: 1,
            fallbackVoiceIdentifier: nil,
            fallbackRate: 0.5,
            audioSessionActivator: {},
            observesPlayerLifecycle: false,
            fallbackClient: RecordingFallbackAudioClient()
        )
        _ = try client.prepareSpeechText(String(repeating: "Only a change of voice is worth a record. ", count: 8))
        try client.play(targetId: "record-once", from: 0)
        _ = await waitForRenderCount(renderer, minimum: 1)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        XCTAssertFalse(client.isSystemVoiceActive)

        XCTAssertTrue(try model.stopOnDeviceRenderingRecordingFallback(
            client, code: "listener_stop", reason: .listenerStoppedGeneration
        ))
        XCTAssertTrue(client.isSystemVoiceActive)
        XCTAssertTrue(
            try model.stopOnDeviceRenderingRecordingFallback(
                client, returnsAutomatically: true, code: "memory_warning_stop", reason: .memoryWarning
            ),
            "the client still answers true when the iOS voice already reads"
        )

        let file = try XCTUnwrap(model.diagnosticsExportFileURL())
        defer { try? FileManager.default.removeItem(at: file) }
        let text = try String(contentsOf: file, encoding: .utf8)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        let eventJSON = try XCTUnwrap(payload["playbackEvents"]?.data(using: .utf8))
        let events = try JSONDecoder().decode(DeveloperDiagnosticRecording.Capture.self, from: eventJSON).events
        let fallbacks = events.filter { $0.kind == "supertonic.fallback" }
        XCTAssertEqual(fallbacks.map { $0.fields["code"] }, ["listener_stop"])
        XCTAssertEqual(fallbacks.first?.fields["reason"], "listener_stopped_generation")
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
        try? await pollUntil { client.debugActiveAudioState().hasURL }
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
        try? await pollUntil { client.playbackStartStatus(targetId: "media-services-reset") == .confirmed }
        XCTAssertEqual(client.playbackStartStatus(targetId: "media-services-reset"), .confirmed)
        let renderCount = await renderer.renderCount
        XCTAssertEqual(renderCount, 1)
        try client.stop()
    }

    // #538: the owner's export showed speech "paused" when he left the app, with no cause. Each
    // system pause now reports why, whether it paused, and the app's state, for the event log.
    func testSystemPausesReportTheirCause() async throws {
        let template = try makeTestWAV(duration: 5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let notificationCenter = NotificationCenter()
        let pauses = SystemPauseCapture()
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
            fallbackClient: RecordingFallbackAudioClient(),
            onPauseLog: { pauses.record($0, $1) }
        )
        _ = try client.prepareSpeechText("Leaving the app should never pause this without saying why.")
        try client.play(targetId: "system-pause")
        try? await pollUntil { client.playbackStartStatus(targetId: "system-pause") == .confirmed }
        XCTAssertEqual(client.playbackStartStatus(targetId: "system-pause"), .confirmed)

        notificationCenter.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
            AVAudioSessionInterruptionReasonKey: UInt(1),
        ])
        notificationCenter.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: UInt(0),
        ])
        try? await Task.sleep(for: .milliseconds(50))

        let recorded = pauses.values
        XCTAssertEqual(recorded.map(\.kind), ["speech.interruption_began", "speech.interruption_ended"])
        XCTAssertEqual(recorded.first?.fields["reason"], "app_was_suspended")
        XCTAssertEqual(recorded.first?.fields["paused"], "true")
        XCTAssertNotNil(recorded.first?.fields["appState"])
        XCTAssertNotNil(recorded.first?.fields["lowPowerMode"])
        XCTAssertEqual(recorded.last?.fields["shouldResume"], "false")
        XCTAssertEqual(recorded.last?.fields["resumeRequested"], "false", "no resume without shouldResume")
        XCTAssertEqual(client.playbackTransportState(targetId: "system-pause"), .paused)
        try client.stop()
    }

    // #1434: the owner's AirPods announced a message in the background, narration paused, and no "ended" ever
    // reached the app, which iOS can suspend once its audio stops. The client holds background time for that wait.
    func testInterruptionHoldsBackgroundTimeUntilItEndsOrTheListenerActs() async throws {
        let template = try makeTestWAV(duration: 5)
        defer { try? FileManager.default.removeItem(at: template) }
        let renderer = CountingAudioSupertonicRenderer(templateURL: template)
        let notificationCenter = NotificationCenter()
        let probe = InterruptionHoldProbe()
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
            fallbackClient: RecordingFallbackAudioClient(),
            interruptionHold: probe.hold
        )
        _ = try client.prepareSpeechText("A message announced through the headphones must not leave this paused.")
        try client.play(targetId: "held-interruption")
        try? await pollUntil { client.playbackStartStatus(targetId: "held-interruption") == .confirmed }
        XCTAssertEqual(client.playbackStartStatus(targetId: "held-interruption"), .confirmed)

        // The observers deliver on the main queue, after the post returns.
        func settle(_ condition: () -> Bool) async {
            try? await pollUntil { condition() }
        }

        func post(_ type: AVAudioSession.InterruptionType, shouldResume: Bool = false) {
            var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
            if type == .ended {
                info[AVAudioSessionInterruptionOptionKey] = shouldResume
                    ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : UInt(0)
            }
            notificationCenter.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), userInfo: info)
        }

        post(.began)
        await settle { probe.begins == 1 }
        XCTAssertEqual(client.playbackTransportState(targetId: "held-interruption"), .paused)
        XCTAssertEqual(probe.begins, 1, "the app stays awake to hear the interruption end")
        XCTAssertEqual(probe.ends, 0)

        post(.ended, shouldResume: true)
        await settle { probe.ends == 1 }
        XCTAssertEqual(probe.ends, 1, "the time is given back once iOS reports the end")
        XCTAssertEqual(probe.hold.outcome, .ended)

        try client.play(targetId: "held-interruption")
        post(.began)
        await settle { probe.begins == 2 }
        XCTAssertEqual(probe.begins, 2)
        try client.pause()
        XCTAssertEqual(probe.ends, 2, "the listener's own Pause takes over before an end arrives")
        XCTAssertEqual(probe.hold.outcome, .listenerActed)
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
        try? await pollUntil { (client.currentCharOffset() ?? 0) != 0 }
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
        try await pollUntil {
            _ = try engine.syncPlaybackProgress()
            return engine.snapshot.status == .playing
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
            try await pollUntil {
                _ = try engine.syncPlaybackProgress()
                return engine.snapshot.status == .playing
            }
            XCTAssertEqual(engine.snapshot.status, .playing)
        }
        XCTAssertEqual(interruptions.values, [.began, .began])
        try client.stop()
    }

    // APA-15 (#1042): the only test that runs the real model inside the app. Since #1820 the model is a download,
    // not in the app, so it comes through the supertonicModel input (SupertonicTestAssets.realModel). The adapters
    // plan fetches it before the run (scripts/verify-tests.py), so on the lane it runs; elsewhere it skips, naming
    // the input. A peak of 0.000001 also accepted near-silence; 0.01 is quiet speech.
    // Whether each voice loads its own style is checked on the host, by pitch (SupertonicVoiceSelectionTests):
    // renders start from random noise, so samples can't be compared.
    func testDownloadedRendererSynthesizesJamesAndLilyAndReusesSessions() async throws {
        let model = try SupertonicTestAssets.realModel()
        let output = FileManager.default.temporaryDirectory
            .appending(path: "supertonic-integration-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: output) }
        let renderer = try SupertonicNarrationRenderer(
            assets: model,
            outputDirectory: output,
            governor: OnDeviceVoiceGovernor()
        )

        let james = try await renderer.render(text: "James reads this short test.", voice: .m2)
        let lily = try await renderer.render(text: "Lily reads this short test.", voice: .f2)

        XCTAssertEqual(james.sampleRate, 44_100)
        XCTAssertEqual(lily.sampleRate, 44_100)
        XCTAssertGreaterThan(james.duration, 0)
        XCTAssertGreaterThan(lily.duration, 0)
        XCTAssertGreaterThan(try audioPeak(at: james.audioURL), 0.01, "James is audible, not near-silence")
        XCTAssertGreaterThan(try audioPeak(at: lily.audioURL), 0.01, "Lily is audible, not near-silence")
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
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
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
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
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

private final class SystemPauseCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(kind: String, fields: [String: String])] = []
    var values: [(kind: String, fields: [String: String])] { lock.withLock { entries } }
    func record(_ kind: String, _ fields: [String: String]) {
        lock.withLock { entries.append((kind, fields)) }
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
            sessionLoadCount: 1,
            engine: SupertonicNarrationResult.supertonicEngine
        )
    }

    func discardGeneratedAudio(at url: URL) async {}
}

/// What a client built with the bundled fallback voice reported while it generated (#849).
private final class KittenClientLog: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = RenderedSpeechGenerationProgress(completedChunks: 0, totalChunks: 0)
    private var fallbackReasons: [String] = []
    private var noticeReasons: [String] = []
    private var restoreCount = 0

    private var reports: [RenderedSpeechGenerationProgress] = []
    /// Fulfilled when a report says every chunk is done (#2386). Not registered with the test, so a test that never
    /// waits on it needn't care.
    let finished = XCTestExpectation(description: "every chunk is reported done")
    init() { finished.assertForOverFulfill = false }
    func record(_ value: RenderedSpeechGenerationProgress) {
        lock.withLock {
            progress = value
            reports.append(value)
        }
        if value.totalChunks > 0, value.completedChunks >= value.totalChunks { finished.fulfill() }
    }
    var progressReports: [RenderedSpeechGenerationProgress] { lock.withLock { reports } }
    var restingProgressReports: Int { lock.withLock { reports.filter(\.isRestingAhead).count } }
    var lastProgress: RenderedSpeechGenerationProgress { lock.withLock { progress } }
    func recordFallback(_ reason: String) { lock.withLock { fallbackReasons.append(reason) } }
    func recordNotice(_ reason: String) { lock.withLock { noticeReasons.append(reason) } }
    func recordRestore() { lock.withLock { restoreCount += 1 } }
    private var voiceRestoredReasons: [String] = []
    func recordVoiceRestored(_ fields: [String: String]) { lock.withLock { voiceRestoredReasons.append(fields["reason"] ?? "?") } }
    var voiceRestorations: [String] { lock.withLock { voiceRestoredReasons } }
    var notices: [String] { lock.withLock { noticeReasons } }
    var restores: Int { lock.withLock { restoreCount } }
    var completedChunks: Int { lock.withLock { progress.completedChunks } }
    var totalChunks: Int { lock.withLock { progress.totalChunks } }
    var fallbacks: [String] { lock.withLock { fallbackReasons } }
}

/// The chunk indices a saved-audio lookup answered for, once each, in the order first answered (#1892).
private final class ServedChunkLog: @unchecked Sendable {
    private let lock = NSLock()
    private var served: [Int] = []
    func add(_ index: Int) { lock.withLock { if !served.contains(index) { served.append(index) } } }
    var indices: [Int] { lock.withLock { served } }
}

/// Whether Supertonic may render, flipped by a test while a generation runs (#849 audit).
private final class KittenAllowedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = false
    var value: Bool {
        get { lock.withLock { allowed } }
        set { lock.withLock { allowed = newValue } }
    }
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
    private var generatedURLs: Set<URL> = []

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
        generatedURLs.insert(url)
        let audio = try AVAudioFile(forReading: url)
        return SupertonicNarrationResult(
            audioURL: url,
            duration: Double(audio.length) / audio.processingFormat.sampleRate,
            sampleRate: Int(audio.processingFormat.sampleRate.rounded()),
            renderDuration: 0.01,
            sessionLoadCount: 1,
            engine: SupertonicNarrationResult.supertonicEngine
        )
    }

    /// Deletes only what this fake rendered, as SupertonicNarrationRenderer does (#258). The client
    /// also discards prepared chunks it played; deleting those raced the assembly after a stop.
    func discardGeneratedAudio(at url: URL) async {
        discardCount += 1
        if generatedURLs.remove(url) != nil {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Renders a copy of a template file, until `holdFromNow()`: from then each render waits until `release()` or its
/// task is cancelled, so a test can look at the client while a render is in flight and no chunk has finished.
private actor HoldableAudioSupertonicRenderer: SupertonicRendering {
    let templateURL: URL
    private(set) var renderCount = 0
    private var holding = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var generatedURLs: Set<URL> = []

    init(templateURL: URL) {
        self.templateURL = templateURL
    }

    func holdFromNow() { holding = true }

    func release() {
        holding = false
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func render(
        text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int
    ) async throws -> SupertonicNarrationResult {
        renderCount += 1
        if holding {
            await withCheckedContinuation { waiters.append($0) }
            throw CancellationError()
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "holdable-render-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: templateURL, to: url)
        generatedURLs.insert(url)
        let audio = try AVAudioFile(forReading: url)
        return SupertonicNarrationResult(
            audioURL: url,
            duration: Double(audio.length) / audio.processingFormat.sampleRate,
            sampleRate: Int(audio.processingFormat.sampleRate.rounded()),
            renderDuration: 0.01,
            sessionLoadCount: 1,
            engine: SupertonicNarrationResult.supertonicEngine
        )
    }

    func discardGeneratedAudio(at url: URL) async {
        if generatedURLs.remove(url) != nil {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// A bundled-voice stand-in: each render copies a template file and reports it as the bundled voice's. One render
/// waits on a gate the test controls, so a chunk can be in flight at the moment a play releases the voice (#849 audit).
private actor GatedBundledVoiceRenderer: BundledVoiceRendering {
    let templateURL: URL
    let gatedRender: Int
    let gate: AsyncStream<Void>
    private(set) var renderCount = 0
    private var generatedURLs: Set<URL> = []

    init(templateURL: URL, gatedRender: Int, gate: AsyncStream<Void>) {
        self.templateURL = templateURL
        self.gatedRender = gatedRender
        self.gate = gate
    }

    func render(text: String) async throws -> SupertonicNarrationResult {
        renderCount += 1
        if renderCount == gatedRender {
            for await _ in gate {}
            try Task.checkCancellation()
        }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "bundled-stand-in-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: templateURL, to: url)
        generatedURLs.insert(url)
        let audio = try AVAudioFile(forReading: url)
        return SupertonicNarrationResult(
            audioURL: url,
            duration: Double(audio.length) / audio.processingFormat.sampleRate,
            sampleRate: Int(audio.processingFormat.sampleRate.rounded()),
            renderDuration: 0.01,
            sessionLoadCount: 1,
            engine: KittenNarrationRenderer.engine
        )
    }

    func discardGeneratedAudio(at url: URL) async {
        if generatedURLs.remove(url) != nil { try? FileManager.default.removeItem(at: url) }
    }
}

private final class HarnessStartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    var count: Int { lock.withLock { starts } }
    func add() { lock.withLock { starts += 1 } }
}

/// A bundled-voice stand-in that records the text of each render (#1680).
private actor RecordingBundledVoiceRenderer: BundledVoiceRendering {
    let templateURL: URL
    private(set) var renderedTexts: [String] = []
    private var generatedURLs: Set<URL> = []

    init(templateURL: URL) { self.templateURL = templateURL }

    func render(text: String) async throws -> SupertonicNarrationResult {
        renderedTexts.append(text)
        let url = FileManager.default.temporaryDirectory.appending(path: "bundled-recorded-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: templateURL, to: url)
        generatedURLs.insert(url)
        return SupertonicNarrationResult(audioURL: url, duration: 0.2, sampleRate: 44_100, renderDuration: 0.01,
                                         sessionLoadCount: 1, engine: KittenNarrationRenderer.engine)
    }

    func discardGeneratedAudio(at url: URL) async {
        if generatedURLs.remove(url) != nil { try? FileManager.default.removeItem(at: url) }
    }
}

private final class ResumeDecisionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[String: String]] = []
    var values: [[String: String]] { lock.withLock { entries } }
    func add(_ fields: [String: String]) { lock.withLock { entries.append(fields) } }
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
            sampleRate: Int(audio.processingFormat.sampleRate.rounded()), renderDuration: 0.01, sessionLoadCount: 1,
            engine: SupertonicNarrationResult.supertonicEngine
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
        return SupertonicNarrationResult(audioURL: url, duration: 1, sampleRate: 44_100, renderDuration: 0.01, sessionLoadCount: 1, engine: SupertonicNarrationResult.supertonicEngine)
    }
    func discardGeneratedAudio(at url: URL) async { try? FileManager.default.removeItem(at: url) }
}

/// Renders every chunk from the `standInFrom`th on as the iOS voice would (the guard's replacement).
private actor StandInAfterFirstRenderer: SupertonicRendering {
    let template: URL
    let standInFrom: Int
    private var count = 0
    init(template: URL, standInFrom: Int) { self.template = template; self.standInFrom = standInFrom }
    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        count += 1
        let url = FileManager.default.temporaryDirectory.appending(path: "stand-in-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: template, to: url)
        return SupertonicNarrationResult(
            audioURL: url, duration: 1, sampleRate: 44_100, renderDuration: 0.01, sessionLoadCount: 1,
            engine: count >= standInFrom ? SupertonicNarrationResult.systemVoiceEngine : SupertonicNarrationResult.supertonicEngine
        )
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

/// Counts `onPreparedAudio` calls: how many times the client assembled the article (#2386).
private final class AssemblyCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

/// Collects `SupertonicOutputGuard`'s replacement reports and fulfills `reported` on the first.
/// `reported` isn't registered with the test, so a test that expects no stand-in needn't wait on it.
private final class GuardReports: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    let reported = XCTestExpectation(description: "the guard reports a replacement")
    var values: [String] { lock.withLock { entries } }
    init() { reported.assertForOverFulfill = false }
    func add(_ report: String) {
        lock.withLock { entries.append(report) }
        reported.fulfill()
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
        return SupertonicNarrationResult(audioURL: url, duration: seconds, sampleRate: 44_100, renderDuration: 0.01, sessionLoadCount: 1, engine: SupertonicNarrationResult.supertonicEngine)
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

/// Whether the app is in front, for a test to change.
private final class AppPresence: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool {
        get { lock.withLock { active } }
        set { lock.withLock { active = newValue } }
    }
}

private final class PaceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var values: [String] { lock.withLock { items } }
    func add(_ value: String) { lock.withLock { items.append(value) } }
}

/// Counts the background time the client asked for and gave back across a chunk seam.
@MainActor
private final class HandOverLedger {
    var begins = 0
    var ends = 0
}

private final class StallEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [String] = []
    private var starts = 0
    private var last: [String: String] = [:]
    var values: [String] { lock.withLock { kinds } }
    var startCount: Int { lock.withLock { starts } }
    var lastFields: [String: String] { lock.withLock { last } }
    private var fallbacks: [String] = []
    private var samples = 0
    var fallbackReasons: [String] { lock.withLock { fallbacks } }
    /// How many stall-monitor loops have run, counted by `debugStallSampleWasTaken` (#4368).
    var sampleCount: Int { lock.withLock { samples } }
    func sampled() { lock.withLock { samples += 1 } }
    func stall(_ kind: String, _ fields: [String: String]) { lock.withLock { kinds.append(kind); last = fields } }
    func started() { lock.withLock { starts += 1 } }
    func fellBack(_ reason: String) { lock.withLock { fallbacks.append(reason) } }
}

/// A player clock that can be made to block, as `AVPlayer.currentTime()` does when the media server is slow (#2119).
private final class BlockableClock: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var blocking = false
    private var waiting = 0
    var isStuck: Bool { lock.withLock { waiting > 0 } }

    func blockReads() { lock.withLock { blocking = true } }

    /// Lets every blocked read go, and every later one through.
    func release() {
        let stuck = lock.withLock { () -> Int in blocking = false; return waiting }
        for _ in 0..<stuck { gate.signal() }
    }

    func read() -> TimeInterval {
        let mustWait = lock.withLock { () -> Bool in
            if blocking { waiting += 1 }
            return blocking
        }
        if mustWait {
            gate.wait()
            lock.withLock { waiting -= 1 }
        }
        return 0.1
    }
}

/// A queue-player reader (#2242) that, once armed, answers the first end-of-chunk reading as a player stopped at the
/// end of the playing chunk, and every reading after it as a queue that has moved on to the queued chunk.
private final class StaleThenMovedReads: @unchecked Sendable {
    private let lock = NSLock()
    private var playing: AVPlayerItem?
    private var armed = false
    private var gave = false
    var gaveStaleFacts: Bool { lock.withLock { gave } }

    func arm(playing item: AVPlayerItem?) { lock.withLock { playing = item; armed = true } }

    func read(_ player: AVQueuePlayer, _ queuedItem: AVPlayerItem, _ includesEndFacts: Bool)
        -> SupertonicSpeechPlaybackClient.QueuedPlayerReading {
        let answer = lock.withLock { () -> SupertonicSpeechPlaybackClient.QueuedPlayerReading? in
            if armed, !gave, includesEndFacts { gave = true; return .init(current: playing) }
            if gave { return .init(current: queuedItem) }
            return nil
        }
        if let answer { return answer }
        var reading = SupertonicSpeechPlaybackClient.QueuedPlayerReading(current: player.currentItem)
        if includesEndFacts {
            reading.queuedChunkIsOnThePlayer = player.items().contains(queuedItem)
            reading.playerAdvancesAtItemEnd = player.actionAtItemEnd == .advance
            reading.playerIsPlaying = player.rate != 0
        }
        return reading
    }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var isSet: Bool { lock.withLock { done } }
    func set() { lock.withLock { done = true } }
}

/// Switches to another item the first time a stall is about to be handled.
private final class ItemSwitch: @unchecked Sendable {
    weak var client: SupertonicSpeechPlaybackClient?
    private let lock = NSLock()
    private var done = false
    var didRun: Bool { lock.withLock { done } }

    func run() {
        let first = lock.withLock { () -> Bool in defer { done = true }; return !done }
        guard first, let client else { return }
        try? client.stop()
        _ = try? client.prepareSpeechText("A different article starts playing here instead.")
        try? client.play(targetId: "second", from: 0)
    }
}

/// Hands the test each player the client starts, so it can wait on that player's own notices instead of a fixed
/// sleep (#2747). A start is recorded before the starter asks the player to play.
private final class StartedPlayers: @unchecked Sendable {
    private let lock = NSLock()
    private var players: [AVPlayer] = []
    private var waiters: [Int: XCTestExpectation] = [:]

    func record(_ player: AVPlayer) {
        let due = lock.withLock { () -> XCTestExpectation? in
            players.append(player)
            return waiters.removeValue(forKey: players.count)
        }
        due?.fulfill()
    }

    /// The `n`th player started, counting from 1.
    func started(_ n: Int) -> AVPlayer? { lock.withLock { players.count >= n ? players[n - 1] : nil } }

    /// Fulfilled once the `n`th player has started.
    func expectation(forStart n: Int) -> XCTestExpectation {
        let started = XCTestExpectation(description: "player \(n) started")
        let already = lock.withLock { () -> Bool in
            if players.count >= n { return true }
            waiters[n] = started
            return false
        }
        if already { started.fulfill() }
        return started
    }
}

/// Watches one player for a test. Not main-actor isolated, so AVFoundation may call its handlers from any thread.
private final class PlayerObservation: @unchecked Sendable {
    private var observation: NSKeyValueObservation?
    private var token: Any?
    private weak var player: AVPlayer?

    /// Fulfils `asked` once the player's rate is above zero: the starter's `playImmediately` sets it at once.
    init(rateOf player: AVPlayer, fulfilling asked: XCTestExpectation) {
        self.player = player
        observation = player.observe(\.rate, options: [.initial, .new]) { player, _ in
            if player.rate > 0 { asked.fulfill() }
        }
    }

    /// Fulfils `passed` once the player's own clock passes `seconds`.
    init(clockOf player: AVPlayer, passing seconds: TimeInterval, fulfilling passed: XCTestExpectation) {
        self.player = player
        token = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: seconds, preferredTimescale: 600))], queue: .main
        ) { passed.fulfill() }
        if player.currentTime().seconds >= seconds { passed.fulfill() }
    }

    func end() {
        observation?.invalidate()
        if let token { player?.removeTimeObserver(token) }
    }
}

extension SupertonicSpeechTests {
    /// Waits for the starter's `playImmediately`, which sets the player's rate at once, whatever AVFoundation's load.
    fileprivate func waitUntilAskedToPlay(_ player: AVPlayer) async {
        let asked = expectation(description: "the player was asked to play")
        asked.assertForOverFulfill = false
        let watch = PlayerObservation(rateOf: player, fulfilling: asked)
        await fulfillment(of: [asked], timeout: 5)
        watch.end()
    }

    /// Waits for the player's own clock to pass `seconds`, as AVFoundation's boundary observer reports it.
    fileprivate func waitUntilClockPasses(_ player: AVPlayer, seconds: TimeInterval) async {
        let passed = expectation(description: "the player's clock passed \(seconds) s")
        passed.assertForOverFulfill = false
        let watch = PlayerObservation(clockOf: player, passing: seconds, fulfilling: passed)
        await fulfillment(of: [passed], timeout: 5)
        watch.end()
    }
}

/// The listener pauses the iOS voice and plays it again from offset 40, once, and it speaks.
private final class SystemVoiceReplay: @unchecked Sendable {
    weak var client: SupertonicSpeechPlaybackClient?
    var fallback: RecordingFallbackAudioClient?
    private let lock = NSLock()
    private var done = false
    var didRun: Bool { lock.withLock { done } }

    func run() {
        let first = lock.withLock { () -> Bool in defer { done = true }; return !done }
        guard first, let client else { return }
        try? client.pause()
        fallback?.advancesPerRead = 3
        try? client.play(targetId: "replayed", from: 40)
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
            sessionLoadCount: 1,
            engine: SupertonicNarrationResult.supertonicEngine
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

final class RecordingFallbackAudioClient: AudioPlaybackClient, SpokenProgressReporting, @unchecked Sendable {
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
    /// Words started, as the iOS voice counts them; nil for a voice that can't count them.
    var spokenWords: Int?
    var wordsPerRead = 0
    /// How many times the place was asked for: the stall monitor asks once per sample (#4313).
    private(set) var progressReads = 0
    /// Set to make the iOS voice refuse to start, as a session that can't be activated would.
    var playError: Error?
    /// What the iOS voice says about having begun: `.pending` is speech queued that never started.
    var startStatus: PlaybackStartStatus = .confirmed
    var stopCount = 0
    /// Plays ("play:<offset>"), pauses and stops in the order they happened, with anything else the test
    /// records into it (an audio session activation), so a test can check the order of a recovery (APA-05).
    var events: [String] { eventLock.withLock { recordedEvents } }
    private let eventLock = NSLock()
    private var recordedEvents: [String] = []
    func record(_ event: String) { eventLock.withLock { recordedEvents.append(event) } }

    func prepareSpeechText(_ text: String) throws -> String {
        preparedText = text
        return text
    }

    func isPlaybackComplete(targetId: String) -> Bool { completedTargetId == targetId }

    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { startStatus }

    func stop() throws { stopCount += 1; record("stop") }

    func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        if let playError { throw playError }
        offset = charOffset
        playedOffsets.append(charOffset)
        record("play:\(charOffset)")
    }

    func currentCharOffset() -> Int? {
        defer { offset += advancesPerRead }
        return offset
    }

    func spokenProgress() -> Int? {
        progressReads += 1
        defer { spokenWords = spokenWords.map { $0 + wordsPerRead } }
        return spokenWords
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
        record("pause")
    }
}

/// A narration player whose clock the test sets: SessionEngine reads the Margin's moment from it.
private final class NarrationClockAudioClient: AudioPlaybackClient {
    var mediaTimeMs: Int?
    private let durationMs: Int
    private var target: String?

    init(durationMs: Int) { self.durationMs = durationMs }

    func prepareSpeechText(_ text: String) throws -> String { SpeechTextNormalizer.normalize(text) }
    func play(targetId: String) throws { target = targetId; mediaTimeMs = mediaTimeMs ?? 0 }
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws { target = targetId; self.mediaTimeMs = mediaTimeMs }
    func pause() throws {}
    func stop() throws { target = nil }
    func currentCharOffset() -> Int? { nil }
    func currentRecoveryCharOffset() -> Int? { nil }
    func currentMediaTimeMs() -> Int? { mediaTimeMs }
    func currentPlaybackDurationMs() -> Int? { durationMs }
    func currentPlaybackPosition() -> PlaybackPosition? {
        mediaTimeMs.map { PlaybackPosition(targetId: target, mediaTimeMs: $0, durationMs: durationMs, playbackRate: 1, anchorConfidence: .mediaTime) }
    }
    func isPlaybackComplete(targetId: String) -> Bool { false }
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { .confirmed }
    func isAwaitingRenderedAudio(targetId: String) -> Bool { false }
    func playbackTransportState(targetId: String) -> PlaybackTransportState? { nil }
    func setRemoteCommandHandlingEnabled(_ enabled: Bool) {}
}

/// A renderer whose first render spends `loadTime` loading its model and says so through `isLoadingModel` (#2856).
private final class LoadingModelRenderer: SupertonicRendering, @unchecked Sendable {
    private let inner: CountingAudioSupertonicRenderer
    private let loadTime: Duration
    private let lock = NSLock()
    private var loading = false

    init(inner: CountingAudioSupertonicRenderer, loadTime: Duration) {
        self.inner = inner
        self.loadTime = loadTime
    }

    var isLoadingModel: Bool { lock.withLock { loading } }

    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        lock.withLock { loading = true }
        defer { lock.withLock { loading = false } }
        try await Task.sleep(for: loadTime)
        return try await inner.render(text: text, voice: voice, language: language, speed: speed, synthesisSteps: synthesisSteps)
    }

    func discardGeneratedAudio(at url: URL) async { await inner.discardGeneratedAudio(at: url) }
}


/// A renderer that is loading its model from the moment it exists and holds its render until `finishLoading()` (#3437).
/// It counts how often the client asked whether it was loading, so a test can wait for the wait limit to pass.
private final class HeldLoadingModelRenderer: SupertonicRendering, @unchecked Sendable {
    struct NoLoadingChecks: Error {}

    private let inner: CountingAudioSupertonicRenderer
    private let gate: AsyncStream<Void>
    private let openGate: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var checks = 0

    init(inner: CountingAudioSupertonicRenderer) {
        self.inner = inner
        let pair = AsyncStream<Void>.makeStream()
        gate = pair.stream
        openGate = pair.continuation
    }

    /// True for as long as the render is held and after it, so the client never sees a gap between load and result.
    var isLoadingModel: Bool { lock.withLock { checks += 1; return true } }

    func finishLoading() { openGate.finish() }

    func waitForLoadingChecks(_ count: Int, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while lock.withLock({ checks }) < count {
            guard ContinuousClock.now < deadline else { throw NoLoadingChecks() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func render(text: String, voice: SupertonicVoiceID, language: String, speed: Float, synthesisSteps: Int) async throws -> SupertonicNarrationResult {
        for await _ in gate {}
        try Task.checkCancellation()
        return try await inner.render(text: text, voice: voice, language: language, speed: speed, synthesisSteps: synthesisSteps)
    }

    func discardGeneratedAudio(at url: URL) async { await inner.discardGeneratedAudio(at: url) }
}
