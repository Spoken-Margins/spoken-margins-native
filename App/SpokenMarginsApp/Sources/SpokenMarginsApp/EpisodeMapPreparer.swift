import Foundation
import SessionKit
import SessionKitAudio
import SessionKitPersistence
#if canImport(AVFoundation)
import AVFoundation
#endif

/// What the preparer asks of the model that owns it (#957). The preparer holds its host weakly; a run promotes it
/// once and holds it to the end, so a run in flight keeps the model alive exactly as it did when the model owned the task.
@MainActor
protocol EpisodeMapPreparerHost: AnyObject {
    var store: SQLiteSessionStore? { get }
    /// Read live at each use: tests and the model replace these services.
    var sourceTranscriptionClient: SourceTranscriptionClient { get }
    var localFoundationModelClient: any LocalFoundationModelClient { get }
    var podcastDownloadCoordinator: PodcastDownloadCoordinator? { get }

    func requireStore() throws -> SQLiteSessionStore
    func applicationSupportDirectory() throws -> URL
    func episodeMapDirectory(itemId: String) throws -> URL
    func requireOfflineLedger(store: SQLiteSessionStore, rootDirectory: @autoclosure () throws -> URL) rethrows -> OfflineStorageLedger
    func safePodcastEvidenceComponent(_ value: String) -> String
    func purgeSourceTranscriptionAudioCaches(itemId: String) async throws
    func purgeTransientEpisodeTranscriptionCaches(itemId: String) async throws
    /// The summary bridge audio for one scene. It is shared with package import and imported-podcast placement.
    func prepareSummaryBridgeAsset(
        itemId: String,
        proposalId: String,
        scene: PortableListeningMapScene,
        store: SQLiteSessionStore
    ) async throws -> OwnedOfflineAsset?

    /// The status is about to change. The model publishes it to its observers, as its `@Published` copy did.
    func episodeMapPreparationStatusWillChange()
    func recordEpisodeMapDiagnostic(_ key: String, _ value: String)
    /// Heat and Low Power Mode, read before a run and every `heatCheckInterval` while it works (#2092).
    func episodeMapDeviceConditions() -> SpeechEngineConditions
    /// The phone transcribed the episode for its map: the opt-in community upload hook sees the transcript here.
    func episodeMapTranscribed(itemId: String, timeline: TranscriptTimeline, store: SQLiteSessionStore)

    func episodeMapWarn(_ message: String)
    func episodeMapSucceeded(_ message: String)
    /// Preparation could not start (no store, not a native audio item, a failed save).
    func episodeMapFailedToStart(_ error: Error)
    /// A run finished: when the item is the one on screen, refresh it, then Skim availability, then confirm.
    func episodeMapPreparationDidComplete(itemId: String, status: String)
    /// A run failed: when the item is the one on screen, report it.
    func episodeMapPreparationDidFail(itemId: String, error: Error)
}

/// Private episode map preparation (#957): the task, the item it runs for, the status and the one pending
/// request, moved out of the central model. The stages, the order they are saved in, every id, path and string
/// are the ones the model saved before the move; the pure steps are `EpisodeMapAssembly`.
///
/// Cancellation is cooperative: checks sit where they sat, a cancelled run records `isCancelled` and the next
/// request starts a new job at landmark zero. A pause (heat, Low Power Mode, iOS ending background time) cancels
/// the task the same way but keeps the job, so the background pass resumes it at its saved stage (#2092).
@MainActor
final class EpisodeMapPreparer {
    /// What the item screen shows. Every assignment tells the host first, as `@Published` did.
    private(set) var status = "Not started" {
        willSet { host?.episodeMapPreparationStatusWillChange() }
    }
    private(set) var task: Task<Void, Never>?
    private(set) var itemId: String?
    /// The one item whose map was asked for and is waiting on something else: its download, or a transcript
    /// the model is making. The model sets and clears it through `pendingMapGenerationItemId`.
    var pendingRequestItemId: String?
    /// How often a run reads the phone's heat while it works. Tests shorten it.
    var heatCheckInterval: Duration = .seconds(10)
    /// Why the running task was cancelled, when it was a pause rather than the listener (#2092).
    private var stopReason: EpisodeMapRunStop?
    private var heatWatch: Task<Void, Never>?

    private weak var host: (any EpisodeMapPreparerHost)?

    init(host: any EpisodeMapPreparerHost) {
        self.host = host
    }

    /// Cancels the running preparation when it is for `itemId`. The listener's stop always wins over a pause that
    /// is still unwinding, so the run ends with the job cancelled and a removed map is not brought back (#2092).
    func cancel(itemId: String) {
        if self.itemId == itemId {
            stopReason = .cancelled
            task?.cancel()
        }
    }

    /// Stops the running preparation but keeps its job for a later pass (#2092). A run that was already cancelled,
    /// by the listener or an earlier pause, is left as it is.
    func pause(_ reason: EpisodeMapRunStop) {
        guard let task, !task.isCancelled, reason.keepsJob else { return }
        stopReason = stopReason ?? reason
        task.cancel()
    }

    /// Starts preparing the private map for `itemId`, or waits for its download.
    func prepare(
        itemId requestedItemId: String,
        policy: PreparationJobPolicy = .explicit,
        trigger: EpisodeMapPreparationTrigger = .listenerRequest
    ) {
        guard let host else { return }
        guard task == nil else {
            host.episodeMapWarn("An episode map is already being prepared.")
            return
        }
        do {
            let store = try host.requireStore()
            let item = try store.loadItem(id: requestedItemId)
            guard item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream else {
                throw SessionKitError.invalidCommandForState("episode_map_requires_native_audio")
            }
            let existingJob = (try store.loadEpisodeMapPreparationJobs()).first {
                $0.itemId == requestedItemId && !$0.isCancelled
            }
            if let interrupted = EpisodeMapRunGuard.interruptedRunDiagnostic(previous: existingJob) {
                host.recordEpisodeMapDiagnostic("episodeMapPreparationInterrupted:\(requestedItemId)", interrupted)
            }
            var job = existingJob ?? EpisodeMapPreparationJob(
                id: "episode-map-job-\(host.safePodcastEvidenceComponent(requestedItemId))",
                itemId: requestedItemId,
                policy: policy
            )
            job.policy = policy
            if existingJob == nil {
                job.stage = .verifySource
                job.nextUnitIndex = 0
            }
            job.lastFailureCode = nil
            try store.saveEpisodeMapPreparationJob(job)

            guard let localURL = host.podcastDownloadCoordinator?.validatedLocalURL(for: requestedItemId)
                ?? item.media?.url.flatMap(URL.init(string:)).flatMap({ $0.isFileURL ? $0 : nil }) else {
                pendingRequestItemId = requestedItemId
                status = "Waiting for download"
                host.recordEpisodeMapDiagnostic(
                    "episodeMapPreparation:\(requestedItemId)",
                    EpisodeMapRunGuard.waitingDiagnostic(trigger: trigger, at: Date())
                )
                if host.podcastDownloadCoordinator?.downloadNow(itemId: requestedItemId) != true,
                   let remote = item.media?.url.flatMap(URL.init(string:)) {
                    host.podcastDownloadCoordinator?.register(
                        itemId: requestedItemId,
                        remoteURL: remote,
                        userInitiated: policy == .explicit
                    )
                }
                if policy == .explicit {
                    host.episodeMapSucceeded("Downloading the episode. Its private Listening Map will continue automatically.")
                }
                return
            }
            run(item: item, localURL: localURL, job: job, trigger: trigger)
        } catch {
            status = "Failed"
            host.episodeMapFailedToStart(error)
        }
    }

    private func run(
        item: Item,
        localURL: URL,
        job initialJob: EpisodeMapPreparationJob,
        trigger: EpisodeMapPreparationTrigger
    ) {
        guard let host else { return }
        status = "Preparing"
        host.recordEpisodeMapDiagnostic(
            "episodeMapPreparation:\(item.id)",
            EpisodeMapRunGuard.startedDiagnostic(
                trigger: trigger,
                job: initialJob,
                thermal: host.episodeMapDeviceConditions().thermal,
                at: Date()
            )
        )
        itemId = item.id
        stopReason = nil
        // The task holds the preparer weakly, then the model strongly for the whole run, as it did when the model
        // owned the task. It is not cancelled when the model goes away.
        task = Task { [weak self] in
            guard let self, let host = self.host else { return }
            var job = initialJob
            defer {
                self.heatWatch?.cancel()
                self.heatWatch = nil
                self.stopReason = nil
                self.task = nil
                self.itemId = nil
            }
            do {
                let store = try host.requireStore()
                job.stage = .generateFingerprintSpine
                // Saved while the run is in flight, so a run iOS kills is named on the next request.
                job.lastFailureCode = EpisodeMapRunGuard.runningCode
                try await self.saveJob(job, store: store)
                let mapDirectory = try host.episodeMapDirectory(itemId: item.id)
                try FileManager.default.createDirectory(at: mapDirectory, withIntermediateDirectories: true)
                let digest = try await Task.detached(priority: .utility) {
                    try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: localURL)
                }.value
                try Task.checkCancellation()
                let durationMs: Int
                if let declaredDurationMs = item.media?.durationMs {
                    durationMs = declaredDurationMs
                } else if let duration = try? await AVURLAsset(url: localURL).load(.duration) {
                    durationMs = Int((CMTimeGetSeconds(duration) * 1_000).rounded())
                } else {
                    durationMs = 0
                }
                let resumed = EpisodeMapAssembly.resumeFingerprints(
                    safeItemComponent: host.safePodcastEvidenceComponent(item.id),
                    nextUnitIndex: job.nextUnitIndex,
                    durationMs: durationMs,
                    minimumEvidenceDurationMs: PodcastAnchorEvidenceGenerator.minimumEvidenceDurationMs,
                    signatureExists: { assetID in
                        FileManager.default.fileExists(
                            atPath: mapDirectory.appending(path: "\(assetID).shazamsignature").path
                        )
                    }
                )
                var generatedLandmarks = resumed.landmarks
                var gridIndex = resumed.gridIndex
                var startMs = resumed.startMs
                job.nextUnitIndex = resumed.nextUnitIndex
                while startMs + PodcastAnchorEvidenceGenerator.minimumEvidenceDurationMs <= durationMs {
                    try Task.checkCancellation()
                    let assetID = EpisodeMapAssembly.signatureAssetId(
                        safeItemComponent: host.safePodcastEvidenceComponent(item.id),
                        gridIndex: gridIndex
                    )
                    let ledger = try host.requireOfflineLedger(store: store, rootDirectory: try host.applicationSupportDirectory())
                    let reservation = try await ledger.reserve(
                        ownerId: "episode-fingerprint-\(item.id)-\(gridIndex)",
                        byteCount: 2 * 1_024 * 1_024
                    )
                    let generated: GeneratedPodcastAnchorEvidence
                    do {
                        generated = try await PodcastAnchorEvidenceGenerator.generateLandmark(
                            sourceURL: localURL,
                            sourceStartMs: startMs,
                            outputDirectory: mapDirectory,
                            id: assetID
                        )
                    } catch {
                        try? await ledger.release(reservationId: reservation.id)
                        throw error
                    }
                    generatedLandmarks.append(EpisodeMapAssembly.downloadedLandmark(
                        safeItemComponent: host.safePodcastEvidenceComponent(item.id),
                        gridIndex: gridIndex,
                        startMs: startMs,
                        durationMs: generated.durationMs
                    ))
                    let generatedFileURL = generated.fileURL
                    let generatedByteCount = try await Gate1AppModel.offMain {
                        Int64((try? Data(contentsOf: generatedFileURL).count) ?? 0)
                    }
                    try await ledger.commit(reservationId: reservation.id, asset: OwnedOfflineAsset(
                        id: assetID,
                        itemId: item.id,
                        category: .fingerprintMap,
                        relativePath: "SpokenMargins/EpisodeMaps/\(host.safePodcastEvidenceComponent(item.id))/\(assetID).shazamsignature",
                        byteCount: generatedByteCount,
                        isReproducible: true,
                        protections: [.activeEpisodeMapPreparation]
                    ))
                    gridIndex += 1
                    startMs += SparseFingerprintSchedule.periodicIntervalMs
                    job.nextUnitIndex = gridIndex
                    try await self.saveJob(job, store: store)
                    if job.policy == .whileCharging {
                        job.lastFailureCode = nil
                        try await self.saveJob(job, store: store)
                        self.status = "Fingerprinting paused at landmark \(gridIndex)"
                        host.recordEpisodeMapDiagnostic(
                            "episodeMapPreparation:\(item.id)",
                            EpisodeMapRunGuard.checkpointDiagnostic(landmark: gridIndex, at: Date())
                        )
                        return
                    }
                }

                job.stage = .transcribe
                try await self.saveJob(job, store: store)
                self.status = "Transcribing on device"
                let supportDirectory = try host.applicationSupportDirectory()
                var timeline: TranscriptTimeline
                let cachedTimeline: TranscriptTimeline? = if let relativePath = job.transientTranscriptRelativePath {
                    try await Gate1AppModel.offMain {
                        guard let cached = try? Data(contentsOf: supportDirectory.appending(path: relativePath)) else { return nil }
                        return try? JSONDecoder().decode(TranscriptTimeline.self, from: cached)
                    }
                } else {
                    nil
                }
                if let decoded = cachedTimeline {
                    timeline = decoded
                } else {
                    timeline = try await host.sourceTranscriptionClient.transcribeSourceAudio(
                        url: localURL,
                        itemId: item.id,
                        durationMs: durationMs
                    )
                    let transcriptData = try JSONEncoder().encode(timeline)
                    let safeItemID = host.safePodcastEvidenceComponent(item.id)
                    let relativePath = "SpokenMargins/EpisodeMaps/\(safeItemID)/Transient/timeline.json"
                    let transcriptURL = supportDirectory.appending(path: relativePath)
                    try FileManager.default.createDirectory(at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let ledger = host.requireOfflineLedger(store: store, rootDirectory: supportDirectory)
                    let reservation = try await ledger.reserve(
                        ownerId: "episode-transcript-\(item.id)",
                        byteCount: Int64(transcriptData.count)
                    )
                    do {
                        try await Gate1AppModel.offMain { try transcriptData.write(to: transcriptURL, options: .atomic) }
                        try await ledger.commit(reservationId: reservation.id, asset: OwnedOfflineAsset(
                            id: "episode-transcript-\(safeItemID)",
                            itemId: item.id,
                            category: .transientEpisodeTranscript,
                            relativePath: relativePath,
                            byteCount: Int64(transcriptData.count),
                            isReproducible: true,
                            protections: [.activeEpisodeMapPreparation]
                        ))
                    } catch {
                        try? await ledger.release(reservationId: reservation.id)
                        try? await Gate1AppModel.offMain { try FileManager.default.removeItem(at: transcriptURL) }
                        throw error
                    }
                    job.transientTranscriptRelativePath = relativePath
                    try await self.saveJob(job, store: store)
                }
                try await host.purgeSourceTranscriptionAudioCaches(itemId: item.id)
                let itemID = item.id
                let savedTimeline = try await Gate1AppModel.offMain { try store.loadTranscriptTimeline(itemId: itemID) }
                if let publisherChapters = savedTimeline?.timeline.chapters,
                   !publisherChapters.isEmpty {
                    timeline.chapters = publisherChapters
                }
                host.episodeMapTranscribed(itemId: item.id, timeline: timeline, store: store)

                job.stage = .generatePhraseSketch
                try await self.saveJob(job, store: store)
                let sketch = TranscriptPhraseSketchBuilder.makeArtifact(
                    id: "episode-sketch-\(host.safePodcastEvidenceComponent(item.id))",
                    itemId: item.id,
                    timeline: timeline
                )

                let savedSpine = try await Gate1AppModel.offMain { try store.loadEditionFingerprintSpine(itemId: itemID) }
                let allLandmarks = EpisodeMapAssembly.mergedLandmarks(
                    existing: savedSpine?.landmarks ?? [],
                    generated: generatedLandmarks,
                    sketchWindows: sketch.windows
                )
                let spine = EditionFingerprintSpineArtifact(
                    id: "episode-spine-\(host.safePodcastEvidenceComponent(item.id))",
                    itemId: item.id,
                    canonicalURL: item.externalReference ?? item.media?.url,
                    producingEditionDurationMs: durationMs,
                    producingEditionSHA256: digest,
                    landmarks: allLandmarks
                )

                job.stage = .segmentScenes
                try await self.saveJob(job, store: store)
                let drafts = EpisodeSceneSegmenter.makeDrafts(timeline: timeline)
                var scenes: [PortableListeningMapScene] = []
                job.stage = .generateSummaries
                try await self.saveJob(job, store: store)
                for draft in drafts {
                    try Task.checkCancellation()
                    let text = EpisodeMapAssembly.sceneText(for: draft, in: timeline)
                    var label: ListeningMapSummaryValidator.SceneLabel?
                    if host.localFoundationModelClient.availability().isAvailable, !text.isEmpty {
                        for _ in 0..<2 where label == nil {
                            if let candidate = try? await host.localFoundationModelClient.labelListeningMapChapter(
                                text: text,
                                chapterNumber: draft.order + 1
                            ) {
                                label = try? ListeningMapSummaryValidator.validate(candidate, sourceText: text)
                            }
                        }
                    }
                    scenes.append(EpisodeMapAssembly.scene(draft: draft, label: label, landmarks: allLandmarks))
                }
                let proposal = PortableListeningMapProposalArtifact(
                    id: "episode-map-proposal-\(host.safePodcastEvidenceComponent(item.id))",
                    createdAt: Date(),
                    generator: EpisodeMapAssembly.proposalGenerator(
                        foundationModelAvailable: host.localFoundationModelClient.availability().isAvailable
                    ),
                    scenes: scenes
                )

                job.stage = .renderBridges
                try await self.saveJob(job, store: store)
                for scene in scenes where scene.eligibility == .eligible && scene.summaryText?.isEmpty == false {
                    try Task.checkCancellation()
                    _ = try await host.prepareSummaryBridgeAsset(
                        itemId: item.id,
                        proposalId: proposal.id,
                        scene: scene,
                        store: store
                    )
                }

                job.stage = .commit
                // One background step, so a cancel can't land between the saves and leave half a map.
                let commitJob = job
                let projection = EpisodeFingerprintAlignment.makeProjection(
                    id: "episode-projection-\(host.safePodcastEvidenceComponent(item.id))",
                    itemId: item.id,
                    proposalId: proposal.id,
                    recipientEditionSHA256: digest,
                    matches: EpisodeMapAssembly.identityMatches(for: allLandmarks),
                    exactEdition: true
                )
                try await Gate1AppModel.offMain {
                    try store.saveEpisodeMapPreparationJob(commitJob)
                    try store.saveEditionFingerprintSpine(spine)
                    try store.saveTranscriptPhraseSketch(sketch)
                    try store.savePortableListeningMapProposal(proposal, itemId: itemID)
                    try store.saveResolvedListeningMapProjection(projection)
                    for asset in try store.loadOwnedOfflineAssets(itemId: itemID) where asset.category == .fingerprintMap {
                        try store.updateOwnedOfflineAsset(id: asset.id) { $0.protections.remove(.activeEpisodeMapPreparation) }
                    }
                }
                try await host.purgeTransientEpisodeTranscriptionCaches(itemId: item.id)
                try Task.checkCancellation() // the purge now suspends; a cancel that lands there must not complete the run
                job.stage = .completed
                let jobID = job.id
                try await Gate1AppModel.offMain { try store.deleteEpisodeMapPreparationJob(id: jobID) }
                self.status = EpisodeMapAssembly.completionStatus(scenes: scenes)
                host.recordEpisodeMapDiagnostic("episodeMapPreparation:\(item.id)", EpisodeMapAssembly.completionDiagnostic(
                    landmarkCount: allLandmarks.count,
                    sceneCount: scenes.count
                ))
                host.episodeMapPreparationDidComplete(itemId: item.id, status: self.status)
            } catch where self.stopReason != nil || error is CancellationError {
                // A pause can surface as the transcriber's own error rather than CancellationError.
                let stop = self.stopReason ?? .cancelled
                let diagnostic = EpisodeMapRunGuard.stop(stop, job: &job, at: Date())
                try? await self.saveJob(job, store: host.store)
                if stop.keepsJob {
                    // The saved transcript stays, so the next pass skips transcription; only scratch audio goes.
                    try? await host.purgeSourceTranscriptionAudioCaches(itemId: item.id)
                } else {
                    try? await host.purgeTransientEpisodeTranscriptionCaches(itemId: item.id)
                }
                self.status = EpisodeMapRunGuard.pausedStatus(stop)
                host.recordEpisodeMapDiagnostic("episodeMapPreparation:\(item.id)", diagnostic)
            } catch {
                job.lastFailureCode = String(describing: error)
                try? await self.saveJob(job, store: host.store)
                self.status = "Failed"
                host.recordEpisodeMapDiagnostic(
                    "episodeMapPreparation:\(item.id)",
                    EpisodeMapRunGuard.failedDiagnostic(error.localizedDescription, stage: job.stage, at: Date())
                )
                host.episodeMapPreparationDidFail(itemId: item.id, error: error)
            }
        }
        watchHeat(policy: initialJob.policy)
    }

    /// Saves the job on a background thread. It is not tied to the run's cancellation: a cancelled run still records
    /// where it stopped, as the synchronous save did.
    private func saveJob(_ job: EpisodeMapPreparationJob, store: SQLiteSessionStore?) async throws {
        guard let store else { return }
        try await Gate1AppModel.offMain { try store.saveEpisodeMapPreparationJob(job) }
    }

    /// Reads the phone's heat while the run works, and pauses it at serious heat (#2092). Before this, heat was
    /// read only when a run started, and a 60-minute episode kept transcribing for 21 minutes at serious heat.
    private func watchHeat(policy: PreparationJobPolicy) {
        heatWatch?.cancel()
        let interval = heatCheckInterval
        heatWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard self?.pauseIfDeviceAsks(policy: policy) == false else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// True when the run is gone or was just paused.
    private func pauseIfDeviceAsks(policy: PreparationJobPolicy) -> Bool {
        guard task != nil, let host else { return true }
        guard let reason = EpisodeMapRunGuard.yieldReason(conditions: host.episodeMapDeviceConditions(), policy: policy) else {
            return false
        }
        pause(reason)
        return true
    }
}
