import Combine
import CryptoKit
import SessionKit
import SessionKitAudio
import SessionKitPersistence
import XCTest
@testable import SpokenMarginsApp

/// #957: private episode map preparation, run for real. The library is a temporary SQLite file, the audio is a
/// real file on disk, and only the services that are expensive or need the device (the transcriber, the
/// on-device model) are replaced. The fixture is 30 s long, shorter than the first fingerprint window, so no
/// ShazamKit work happens; the other stages run as they do on a phone.
@MainActor
final class EpisodeMapPreparerTests: XCTestCase {
    private struct Fixture {
        let model: Gate1AppModel
        let store: SQLiteSessionStore
        let itemId: String
        let audioURL: URL
        let transcriber: ScriptedEpisodeTranscriber
    }

    private func makeFixture(hangFirstTranscription: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "p957-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let itemId = "p957-\(UUID().uuidString)"
        let audioURL = root.appending(path: "episode.mp3")
        try Data((0..<2_048).map { UInt8($0 % 251) }).write(to: audioURL)
        let transcriber = ScriptedEpisodeTranscriber(hangFirstCall: hangFirstTranscription)
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            sourceTranscriptionClient: transcriber,
            localFoundationModelClient: UnavailableFoundationModel(),
            databaseURLOverride: root.appending(path: "library.sqlite")
        )
        model.resetAndSeed()
        let store = try model.libraryStoreForTesting()
        try store.saveItem(Item(
            id: itemId, title: "P957 episode", mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
            externalReference: nil, status: "ready",
            media: ItemMedia(sourceType: .nativeMediaFile, url: audioURL.absoluteString, durationMs: 30_000)
        ))
        addTeardownBlock { @MainActor in
            // The map folder is under the app's real Application Support, so every item id is unique to one run.
            model.removeEpisodeMapArtifacts(itemId: itemId)
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(model: model, store: store, itemId: itemId, audioURL: audioURL, transcriber: transcriber)
    }

    private func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<2_000 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), description)
    }

    // MARK: a run that completes

    func testAFullRunSavesTheMapInStageOrderAndLeavesNothingBehind() async throws {
        let fixture = try makeFixture()
        let model = fixture.model, store = fixture.store, itemId = fixture.itemId
        let stageAtTranscription = StageBox()
        fixture.transcriber.onCall = {
            stageAtTranscription.stage = (try? store.loadEpisodeMapPreparationJobs())?.first { $0.itemId == itemId }?.stage
        }

        model.prepareEpisodeMap(itemId: itemId)
        XCTAssertEqual(model.episodeMapPreparationStatus, "Preparing")
        XCTAssertEqual(model.episodeMapPreparationItemId, itemId)
        XCTAssertTrue(
            model.diagnostics["episodeMapPreparation:\(itemId)"]?.hasPrefix(
                "started:trigger=listener_request:policy=explicit:stage=verify_source:unit=0:heat="
            ) == true,
            model.diagnostics["episodeMapPreparation:\(itemId)"] ?? "nil"
        )
        let task = try XCTUnwrap(model.episodeMapPreparationTask)
        await task.value

        XCTAssertEqual(stageAtTranscription.stage, .transcribe, "the job was saved at the transcribe stage before the transcriber ran")
        XCTAssertEqual(model.episodeMapPreparationStatus, "Fingerprint map ready; scene summaries unavailable")
        XCTAssertNil(model.episodeMapPreparationTask)
        XCTAssertNil(model.episodeMapPreparationItemId)
        XCTAssertEqual(try store.loadEpisodeMapPreparationJobs(), [], "a finished job is deleted")

        let timeline = fixture.transcriber.timeline
        let drafts = EpisodeSceneSegmenter.makeDrafts(timeline: timeline)
        XCTAssertFalse(drafts.isEmpty)
        XCTAssertEqual(
            model.diagnostics["episodeMapPreparation:\(itemId)"],
            "complete:landmarks=0:scenes=\(drafts.count):transcript_deleted"
        )

        let digest = SHA256.hash(data: try Data(contentsOf: fixture.audioURL)).map { String(format: "%02x", $0) }.joined()
        let spine = try XCTUnwrap(store.loadEditionFingerprintSpine(itemId: itemId))
        XCTAssertEqual(spine.id, "episode-spine-\(itemId)")
        XCTAssertEqual(spine.producingEditionDurationMs, 30_000)
        XCTAssertEqual(spine.producingEditionSHA256, digest)
        XCTAssertEqual(spine.landmarks, [])

        let sketch = try XCTUnwrap(store.loadTranscriptPhraseSketch(itemId: itemId))
        XCTAssertEqual(sketch.id, "episode-sketch-\(itemId)")

        let proposal = try XCTUnwrap(store.loadPortableListeningMapProposals(itemId: itemId).first)
        XCTAssertEqual(proposal.id, "episode-map-proposal-\(itemId)")
        XCTAssertEqual(proposal.generator, "deterministic-scene-boundaries.v1")
        XCTAssertEqual(proposal.scenes.map(\.id), drafts.map(\.id))
        XCTAssertTrue(proposal.scenes.allSatisfy { $0.summaryText == nil && $0.eligibility == .unknown })

        let projection = try XCTUnwrap(store.loadResolvedListeningMapProjection(itemId: itemId))
        XCTAssertEqual(projection.id, "episode-projection-\(itemId)")
        XCTAssertEqual(projection.proposalId, proposal.id)
        XCTAssertEqual(projection.recipientEditionSHA256, digest)
        XCTAssertEqual(projection.algorithmVersion, "episode-projection.exact-edition.v1")

        let transient = try model.episodeMapDirectory(itemId: itemId).appending(path: "Transient")
        XCTAssertFalse(FileManager.default.fileExists(atPath: transient.path), "the transcript is deleted once the map is saved")
        XCTAssertTrue(try store.loadOwnedOfflineAssets().filter { $0.itemId == itemId }.isEmpty, "no asset rows are left for the item")
    }

    // MARK: an item that is not there

    /// The start reads the item's summary now, not the whole item (#2507); a missing item must still fail the same way
    /// (`loadItem` threw), with no job saved and no run started.
    func testAnItemThatIsNotThereFailsTheStartAndSavesNoJob() throws {
        let fixture = try makeFixture()

        fixture.model.prepareEpisodeMap(itemId: "p957-no-such-item")

        XCTAssertEqual(fixture.model.episodeMapPreparationStatus, "Failed")
        XCTAssertNil(fixture.model.episodeMapPreparationTask)
        XCTAssertEqual(try fixture.store.loadEpisodeMapPreparationJobs(), [], "no job is saved for an item that does not exist")
    }

    // MARK: cancellation and restart

    func testCancellingAnotherItemLeavesTheRunAloneAndCancellingTheItemRecordsACancelledJob() async throws {
        let fixture = try makeFixture(hangFirstTranscription: true)
        let model = fixture.model, store = fixture.store, itemId = fixture.itemId

        model.prepareEpisodeMap(itemId: itemId)
        let task = try XCTUnwrap(model.episodeMapPreparationTask)
        try await waitUntil("the run reaches the transcriber") { model.episodeMapPreparationStatus == "Transcribing on device" }

        // One run at a time: a second request for any item is turned away and starts nothing.
        model.prepareEpisodeMap(itemId: "another-item")
        XCTAssertEqual(model.statusMessage, "An episode map is already being prepared.")

        model.episodeMapPreparer.cancel(itemId: "another-item")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(task.isCancelled, "cancelling a different item must not cancel this run")
        XCTAssertEqual(model.episodeMapPreparationStatus, "Transcribing on device")

        model.episodeMapPreparer.cancel(itemId: itemId)
        await task.value

        XCTAssertEqual(model.episodeMapPreparationStatus, "Cancelled")
        XCTAssertNil(model.episodeMapPreparationTask)
        XCTAssertNil(model.episodeMapPreparationItemId)
        let job = try XCTUnwrap(store.loadEpisodeMapPreparationJobs().first { $0.itemId == itemId })
        XCTAssertTrue(job.isCancelled)
        XCTAssertEqual(job.lastFailureCode, "cancelled")
        XCTAssertEqual(job.stage, .transcribe)
        let calls = await fixture.transcriber.callCount()
        XCTAssertEqual(calls, 1, "the refused second request never reached the transcriber")
        XCTAssertNil(try store.loadEditionFingerprintSpine(itemId: itemId), "a cancelled run publishes nothing")
    }

    func testTheNextRequestAfterACancelIgnoresTheCancelledJobAndRunsFromTheStart() async throws {
        let fixture = try makeFixture(hangFirstTranscription: true)
        let model = fixture.model, store = fixture.store, itemId = fixture.itemId

        model.prepareEpisodeMap(itemId: itemId)
        let first = try XCTUnwrap(model.episodeMapPreparationTask)
        try await waitUntil("the run reaches the transcriber") { model.episodeMapPreparationStatus == "Transcribing on device" }
        model.episodeMapPreparer.cancel(itemId: itemId)
        await first.value
        XCTAssertTrue(try XCTUnwrap(store.loadEpisodeMapPreparationJobs().first).isCancelled)

        model.prepareEpisodeMap(itemId: itemId)
        let second = try XCTUnwrap(model.episodeMapPreparationTask)
        await second.value

        XCTAssertEqual(model.episodeMapPreparationStatus, "Fingerprint map ready; scene summaries unavailable")
        XCTAssertEqual(try store.loadEpisodeMapPreparationJobs(), [], "the new job finished and was deleted")
        XCTAssertNotNil(try store.loadEditionFingerprintSpine(itemId: itemId))
        let calls = await fixture.transcriber.callCount()
        XCTAssertEqual(calls, 2, "the cancelled run left no transcript to reuse, so the second run transcribed again")
    }

    // MARK: heat and background time pause the job instead of cancelling it (#2092)

    func testSeriousHeatDuringTranscriptionPausesTheRunAndTheNextPassFinishesIt() async throws {
        let fixture = try makeFixture(hangFirstTranscription: true)
        let model = fixture.model, store = fixture.store, itemId = fixture.itemId
        let device = DeviceBox()
        model.preparationSeams.deviceConditions = { device.conditions }
        model.episodeMapPreparer.heatCheckInterval = .milliseconds(10)

        model.prepareEpisodeMap(itemId: itemId)
        try await waitUntil("the run reaches the transcriber") { model.episodeMapPreparationStatus == "Transcribing on device" }
        device.conditions = SpeechEngineConditions(thermal: .serious)
        try await waitUntil("serious heat pauses the run mid-transcription") {
            model.episodeMapPreparationStatus == "Paused while the phone is warm"
        }
        try await waitUntil("the run ends") { model.episodeMapPreparationTask == nil }

        let job = try XCTUnwrap(store.loadEpisodeMapPreparationJobs().first { $0.itemId == itemId })
        XCTAssertFalse(job.isCancelled, "a heat pause keeps the job for a later pass")
        XCTAssertEqual(job.lastFailureCode, "paused:heat_serious")
        XCTAssertEqual(job.stage, .transcribe)
        XCTAssertTrue(
            model.diagnostics["episodeMapPreparation:\(itemId)"]?.hasPrefix("paused:heat_serious:stage=transcribe:at=") == true,
            model.diagnostics["episodeMapPreparation:\(itemId)"] ?? "nil"
        )
        XCTAssertNil(try store.loadEditionFingerprintSpine(itemId: itemId), "a paused run publishes nothing")

        device.conditions = SpeechEngineConditions(thermal: .fair)
        model.prepareEpisodeMap(itemId: itemId, policy: job.policy, trigger: .backgroundPass)
        XCTAssertTrue(
            model.diagnostics["episodeMapPreparation:\(itemId)"]?.hasPrefix(
                "started:trigger=background_pass:policy=explicit:stage=transcribe:unit=0:heat=fair:at="
            ) == true,
            model.diagnostics["episodeMapPreparation:\(itemId)"] ?? "nil"
        )
        XCTAssertNil(model.diagnostics["episodeMapPreparationInterrupted:\(itemId)"], "the pause was recorded, so it is no interruption")
        await (try XCTUnwrap(model.episodeMapPreparationTask)).value
        XCTAssertEqual(model.episodeMapPreparationStatus, "Fingerprint map ready; scene summaries unavailable")
        XCTAssertEqual(try store.loadEpisodeMapPreparationJobs(), [], "the resumed job finished and was deleted")
    }

    func testIOSEndingBackgroundTimePausesTheJobInsteadOfCancellingIt() async throws {
        let fixture = try makeFixture(hangFirstTranscription: true)
        let model = fixture.model, store = fixture.store, itemId = fixture.itemId

        model.prepareEpisodeMap(itemId: itemId, trigger: .backgroundPass)
        let task = try XCTUnwrap(model.episodeMapPreparationTask)
        try await waitUntil("the run reaches the transcriber") { model.episodeMapPreparationStatus == "Transcribing on device" }
        model.episodeMapPreparer.pause(.backgroundTimeExpired)
        await task.value

        let job = try XCTUnwrap(store.loadEpisodeMapPreparationJobs().first { $0.itemId == itemId })
        XCTAssertFalse(job.isCancelled, "the background pass can pick it up again")
        XCTAssertEqual(job.lastFailureCode, "paused:background_time_expired")
        XCTAssertEqual(
            BackgroundPreparationPlanner.eligibleEpisodeJobs([job], episodePolicy: .off, hasLocalAudio: { _ in true }),
            [job]
        )
        XCTAssertTrue(
            model.diagnostics["episodeMapPreparation:\(itemId)"]?.hasPrefix("paused:background_time_expired:stage=transcribe:at=") == true,
            model.diagnostics["episodeMapPreparation:\(itemId)"] ?? "nil"
        )
    }

    /// Audit on #2093: a pause and the listener's stop can both land before the transcriber unwinds. The listener's
    /// stop must win in either order, or a map they removed comes back as a live job.
    func testTheListenersCancelWinsOverAPauseInEitherOrder() async throws {
        for pauseFirst in [true, false] {
            let fixture = try makeFixture(hangFirstTranscription: true)
            let model = fixture.model, store = fixture.store, itemId = fixture.itemId

            model.prepareEpisodeMap(itemId: itemId)
            let task = try XCTUnwrap(model.episodeMapPreparationTask)
            try await waitUntil("the run reaches the transcriber") { model.episodeMapPreparationStatus == "Transcribing on device" }
            if pauseFirst {
                model.episodeMapPreparer.pause(.heat(.serious))
                model.episodeMapPreparer.cancel(itemId: itemId)
            } else {
                model.episodeMapPreparer.cancel(itemId: itemId)
                model.episodeMapPreparer.pause(.heat(.serious))
            }
            await task.value

            let order = pauseFirst ? "pause then cancel" : "cancel then pause"
            let job = try XCTUnwrap(store.loadEpisodeMapPreparationJobs().first { $0.itemId == itemId }, order)
            XCTAssertTrue(job.isCancelled, order)
            XCTAssertEqual(job.lastFailureCode, "cancelled", order)
            XCTAssertEqual(model.episodeMapPreparationStatus, "Cancelled", order)
            XCTAssertEqual(
                BackgroundPreparationPlanner.eligibleEpisodeJobs([job], episodePolicy: .off, hasLocalAudio: { _ in true }),
                [], "\(order): a cancelled job is never picked up again"
            )
        }
    }

    func testARunThatEndedWithoutRecordingIsNamedOnTheNextRequest() async throws {
        let fixture = try makeFixture()
        let model = fixture.model, store = fixture.store, itemId = fixture.itemId
        try store.saveEpisodeMapPreparationJob(EpisodeMapPreparationJob(
            id: "episode-map-job-\(itemId)", itemId: itemId, policy: .explicit, stage: .transcribe,
            lastFailureCode: EpisodeMapRunGuard.runningCode
        ))

        model.prepareEpisodeMap(itemId: itemId)
        XCTAssertEqual(
            model.diagnostics["episodeMapPreparationInterrupted:\(itemId)"],
            "previous_run_ended_unrecorded:stage=transcribe:unit=0"
        )
        await (try XCTUnwrap(model.episodeMapPreparationTask)).value
        XCTAssertEqual(try store.loadEpisodeMapPreparationJobs(), [])
    }

    // MARK: waiting for a download, and the one pending request

    func testWaitingForADownloadHoldsOnePendingRequestAndTellsObserversBeforeTheStatusChanges() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "p957-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Gate1AppModel(
            audioPlaybackClient: NoopAudioPlaybackClient(),
            databaseURLOverride: root.appending(path: "library.sqlite")
        )
        let store = try model.libraryStoreForTesting()
        for id in ["p957-first", "p957-second"] {
            try store.saveItem(Item(
                id: id, title: id, mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
                externalReference: nil, status: "ready",
                media: ItemMedia(sourceType: .remoteStream, durationMs: 10_000)
            ))
        }
        var statusSeenByObservers: [String] = []
        let observation = model.objectWillChange.sink { statusSeenByObservers.append(model.episodeMapPreparationStatus) }
        defer { observation.cancel() }

        XCTAssertEqual(model.episodeMapPreparationStatus, "Not started")
        XCTAssertNil(model.pendingMapGenerationItemId)
        model.prepareEpisodeMap(itemId: "p957-first")
        XCTAssertEqual(model.episodeMapPreparationStatus, "Waiting for download")
        XCTAssertEqual(model.pendingMapGenerationItemId, "p957-first")
        XCTAssertEqual(statusSeenByObservers.first, "Not started", "observers are told before the value changes, as @Published did")
        XCTAssertNil(model.episodeMapPreparationTask, "waiting for a download starts no run")

        model.prepareEpisodeMap(itemId: "p957-second")
        XCTAssertEqual(model.pendingMapGenerationItemId, "p957-second", "there is one pending slot, and the newest request takes it")

        model.pendingMapGenerationItemId = nil
        XCTAssertNil(model.pendingMapGenerationItemId)
    }

    // MARK: clean-up files go off the main thread (#2510)

    private struct Leftovers {
        let chunks: URL
        let mapDirectory: URL
        let transient: URL
    }

    /// What a run leaves for the clean-up: exported audio chunks in Caches, a transient transcript folder in the map
    /// folder, and the ledger row that names it.
    private func seedLeftovers(_ fixture: Fixture) throws -> Leftovers {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let chunks = SourceTranscriptionCaches.directory(for: .chunks, itemId: fixture.itemId, cachesDirectory: caches)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        try Data(count: 64).write(to: chunks.appending(path: "chunk-0.caf"))
        let mapDirectory = try fixture.model.episodeMapDirectory(itemId: fixture.itemId)
        let transient = mapDirectory.appending(path: "Transient", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: transient, withIntermediateDirectories: true)
        try Data(count: 8).write(to: transient.appending(path: "timeline.json"))
        try fixture.store.saveOwnedOfflineAsset(OwnedOfflineAsset(
            id: "episode-transcript-\(fixture.itemId)", itemId: fixture.itemId, category: .transientEpisodeTranscript,
            relativePath: "Transient/timeline.json", byteCount: 8, isReproducible: true
        ))
        return Leftovers(chunks: chunks, mapDirectory: mapDirectory, transient: transient)
    }

    func testTheAwaitedPurgeRemovesTheAudioChunksTheTransientFolderAndItsLedgerRow() async throws {
        let fixture = try makeFixture()
        let left = try seedLeftovers(fixture)
        let summaryBridge = left.mapDirectory.appending(path: "SummaryBridges/kept.caf")
        try FileManager.default.createDirectory(at: summaryBridge.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 8).write(to: summaryBridge)

        try await fixture.model.purgeTransientEpisodeTranscriptionCaches(itemId: fixture.itemId)

        XCTAssertFalse(FileManager.default.fileExists(atPath: left.chunks.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.transient.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: summaryBridge.path), "only the transient folder goes, not the finished map")
        XCTAssertEqual(try fixture.store.loadOwnedOfflineAssets().filter { $0.itemId == fixture.itemId }, [])
    }

    func testRemovingAnItemsMapArtifactsDeletesItsFilesInTheBackground() async throws {
        let fixture = try makeFixture()
        let left = try seedLeftovers(fixture)

        fixture.model.removeEpisodeMapArtifacts(itemId: fixture.itemId)

        XCTAssertEqual(try fixture.store.loadOwnedOfflineAssets().filter { $0.itemId == fixture.itemId }, [], "the ledger row goes at once")
        try await waitUntil("the map folder and the audio chunks to be removed") {
            !FileManager.default.fileExists(atPath: left.mapDirectory.path)
                && !FileManager.default.fileExists(atPath: left.chunks.path)
        }
    }

    func testTheExpiredJobCleanUpKeepsASavedMapAndRemovesOnlyItsTransientFolder() async throws {
        let fixture = try makeFixture()
        let left = try seedLeftovers(fixture)
        let kept = left.mapDirectory.appending(path: "SummaryBridges/kept.caf")
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 8).write(to: kept)
        try fixture.store.saveEpisodeMapPreparationJob(EpisodeMapPreparationJob(
            id: "episode-map-job-\(fixture.itemId)", itemId: fixture.itemId, policy: .whileCharging,
            requestedAt: Date().addingTimeInterval(-8 * 24 * 60 * 60)
        ))
        try fixture.store.saveEditionFingerprintSpine(EditionFingerprintSpineArtifact(
            id: "spine-\(fixture.itemId)", itemId: fixture.itemId, landmarks: []
        ))

        fixture.model.purgeExpiredEpisodeMapPreparationJobs(store: fixture.store)

        XCTAssertEqual(try fixture.store.loadEpisodeMapPreparationJobs(), [])
        try await waitUntil("the transient folder and the audio chunks to be removed") {
            !FileManager.default.fileExists(atPath: left.transient.path)
                && !FileManager.default.fileExists(atPath: left.chunks.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "a saved map keeps its folder")
    }
}

@MainActor
private final class DeviceBox {
    var conditions = SpeechEngineConditions()
}

private final class StageBox {
    var stage: EpisodeMapPreparationStage?
}

private actor CallCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
    var value: Int { count }
}

private final class ScriptedEpisodeTranscriber: SourceTranscriptionClient, @unchecked Sendable {
    let timeline = TranscriptTimeline(
        segments: [
            .init(id: "seg-1", startMs: 0, endMs: 12_000, text: "Distributed episode maps keep spoken margins aligned across dynamic editions"),
            .init(id: "seg-2", startMs: 12_000, endMs: 30_000, text: "Listeners hear a private summary bridge between the scenes of a long conversation")
        ],
        chapters: [],
        durationMs: 30_000
    )
    var onCall: (@MainActor () -> Void)?
    private let hangFirstCall: Bool
    private let counter = CallCounter()

    init(hangFirstCall: Bool) {
        self.hangFirstCall = hangFirstCall
    }

    func callCount() async -> Int {
        await counter.value
    }

    func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        let call = await counter.next()
        if let onCall { await onCall() }
        if hangFirstCall, call == 1 {
            // Stands in for a long transcription: it ends only when the run is cancelled.
            try await Task.sleep(for: .seconds(600))
        }
        return timeline
    }
}

private struct UnavailableFoundationModel: LocalFoundationModelClient {
    func availability() -> LocalFoundationModelAvailability { .unavailable("test") }
    func summarizeInterjections(context: String) async throws -> String { throw LocalFoundationModelError.unavailable("test") }
    func labelListeningMapChapter(text: String, chapterNumber: Int) async throws -> LocalListeningMapLabel {
        throw LocalFoundationModelError.unavailable("test")
    }
    func summarizeListeningMap(labels: [LocalListeningMapLabel]) async throws -> String {
        throw LocalFoundationModelError.unavailable("test")
    }
}

/// #2082: the phone's name check follows the scene's language, so a German summary's role nouns are not refused.
final class ListeningMapSummaryLanguageTests: XCTestCase {
    private let german = """
    Der Gast erklärt, warum die Stadt in diesem Jahr so viele neue Wohnungen baut. \
    Der Sprecher findet, dass die neuen Regeln für den Wohnungsbau sehr geholfen haben.
    """

    func testTheSceneLanguageIsRecognisedForGermanAndEnglish() {
        XCTAssertEqual(ListeningMapSummaryValidator.transcriptLanguage(of: german), "de")
        XCTAssertEqual(ListeningMapSummaryValidator.transcriptLanguage(of: "The mayor explains why the city is building so many new homes this year."), "en")
    }

    func testAGermanSceneKeepsASummaryWithARoleNounItNeverSays() throws {
        let label = LocalListeningMapLabel(
            title: "Neue Wohnungen", description: "Der Moderator lobt den Wohnungsbau der Stadt.",
            eligibility: .eligible)
        XCTAssertNoThrow(try ListeningMapSummaryValidator.validate(label, sourceText: german))
    }
}
