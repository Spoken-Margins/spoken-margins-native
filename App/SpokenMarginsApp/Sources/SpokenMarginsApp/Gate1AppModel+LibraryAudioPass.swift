import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitSharing
import SessionKitSupertonic
import SessionKitPersistence
import SessionKitFeeds
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(PDFKit)
import PDFKit
#endif

/// Library audio preparation passes: the foreground loop and the background task's pass (#991).
extension Gate1AppModel: LibraryAudioPreparationHost {
    func runForegroundAudioPreparationPasses() async {
        await runForegroundPreparationLoop { await self.performBackgroundAudioPreparationPass(foregroundDemandOnly: true) }
    }

    func foregroundAudioPreparationLoopDidEnd() {
        refreshLibraryRowsInBackground()
    }

    func performBackgroundPreparationPass() async -> BackgroundPreparationWorkResult {
        guard let store else { return .finished }
        let progressToken = {
            BackgroundPreparationPlanner.progressToken(
                audioJobs: (try? store.loadAudioPreparationJobs()) ?? [],
                episodeJobs: (try? store.loadEpisodeMapPreparationJobs()) ?? []
            )
        }
        let progressBefore = progressToken()
        let episodeJobs = BackgroundPreparationPlanner.eligibleEpisodeJobs(
            (try? store.loadEpisodeMapPreparationJobs()) ?? [],
            episodePolicy: automaticEpisodeMapPreparationPolicy,
            hasLocalAudio: { self.podcastDownloadCoordinator?.validatedLocalURL(for: $0) != nil }
        )
        let hasAudioWork = !OfflinePreparationRecovery.backgroundJobs(
            (try? store.loadAudioPreparationJobs()) ?? [], automaticPolicy: automaticAudioPreparationPolicy
        ).isEmpty
        if let job = backgroundPreparationPlanner.plan(
            hasAudioWork: hasAudioWork,
            episodeJobs: episodeJobs,
            environment: .init(
                thermalIsSerious: ProcessInfo.processInfo.thermalState == .serious
                    || ProcessInfo.processInfo.thermalState == .critical,
                lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                episodeTaskIsRunning: episodeMapPreparationTask != nil
            )
        ) {
            prepareEpisodeMap(itemId: job.itemId, policy: job.policy, trigger: .backgroundPass)
            if let task = episodeMapPreparationTask {
                let preparer = episodeMapPreparer
                await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    // iOS ending background time pauses the job; a plain cancel dropped it for good (#2092).
                    Task { @MainActor in preparer.pause(.backgroundTimeExpired) }
                }
            }
            backgroundPreparationPlanner.afterEpisodePass()
            let hasEpisodeWork = ((try? store.loadEpisodeMapPreparationJobs()) ?? []).contains {
                !$0.isCancelled && $0.stage != .completed
            }
            return BackgroundPreparationPlanner.result(
                hasRemainingWork: hasEpisodeWork || hasAudioWork,
                before: progressBefore,
                after: progressToken()
            )
        }
        let audioHasMore = await performBackgroundAudioPreparationPass()
        let plannerHasMore = backgroundPreparationPlanner.afterAudioPass(
            audioHasMore: audioHasMore, hadAudioWork: hasAudioWork, hadEpisodeJobs: !episodeJobs.isEmpty
        )
        // A pass can stop for heat, playback or expiry without consuming its durable job.
        let hasRemainingWork = plannerHasMore || !OfflinePreparationRecovery.backgroundJobs(
            (try? store.loadAudioPreparationJobs()) ?? [], automaticPolicy: automaticAudioPreparationPolicy
        ).isEmpty
        return BackgroundPreparationPlanner.result(
            hasRemainingWork: hasRemainingWork, before: progressBefore, after: progressToken()
        )
    }

    func startForegroundAudioPreparationIfNeeded() {
        libraryAudioLoop.start(host: self)
    }

    #if canImport(BackgroundTasks) && canImport(UIKit)
    /// The background task stopped: its item stops showing progress, and the foreground loop picks its own work again (#534).
    func libraryAudioBackgroundDrainEnded() {
        libraryAudioLoop.turns.stopped(.background)
        refreshLibraryRowsInBackground()
        if canPrepareLibraryAudio, UIApplication.shared.applicationState == .active { startForegroundAudioPreparationIfNeeded() }
    }
    #endif

    var canPrepareLibraryAudio: Bool {
        !preparationSeams.memoryBackoffActive() && playbackAllowsLibraryAudioPreparation
    }

    /// The foreground loop and the background task take turns, so two Library items never render at once (#281).
    func performBackgroundAudioPreparationPass(foregroundDemandOnly: Bool = false) async -> Bool {
        await libraryAudioLoop.renderGate.run { await self.preparationPassInTurn(foregroundDemandOnly: foregroundDemandOnly) }
    }

    private func preparationPassInTurn(foregroundDemandOnly: Bool) async -> Bool {
        var attemptedJob: AudioPreparationJob?
        let caller: LibraryAudioPreparationCaller = foregroundDemandOnly ? .foreground : .background
        // Live speech owns the serial renderer while the listener has active
        // demand. A stale/background job must not queue ahead of its next chunk.
        guard canPrepareLibraryAudio else { libraryAudioLoop.turns.stopped(caller); return false }
        guard hasAcceptedCurrentTerms,
              let preparationVoice = PreparationVoice.current(for: ttsVoiceSelection, model: self) else { libraryAudioLoop.turns.blocked(caller); return false } // settles until these change (#647)
        let voice = preparationVoice.renderVoice
        let device = preparationSeams.deviceConditions() // heat and Low Power Mode, checked per chunk (#64)
        do {
            try Task.checkCancellation()
            let store = try requireStore()
            // Jobs another voice's engine filed (James's while Phonon is chosen) wait for that voice: they are neither
            // picked, so they can't hold up this voice's jobs behind them, nor marked for re-preparing. The engines are
            // read off the main thread, once per pass.
            let manifestEngines = await Task.detached(priority: .utility) {
                var engines: [String: String] = [:]
                for job in (try? store.loadAudioPreparationJobs()) ?? [] {
                    if let manifest = try? store.loadPreparedAudioManifest(id: job.manifestId) { engines[job.manifestId] = manifest.signature.engine }
                }
                return engines
            }.value
            let ownJobs: ([AudioPreparationJob]) -> [AudioPreparationJob] = { jobs in
                preparationVoice.jobsFiledUnderItsEngine(jobs, manifestEngines: manifestEngines)
            }
            var queuedJobs = ownJobs(try store.loadAudioPreparationJobs())
                .filter({ !PreparationChunkGate.setsAsideForLowPowerMode($0.policy, thermal: device.thermal, isLowPowerModeEnabled: device.isLowPowerModeEnabled) })
            if !foregroundDemandOnly {
                queuedJobs = OfflinePreparationRecovery.backgroundJobs(queuedJobs, automaticPolicy: automaticAudioPreparationPolicy)
            }
            if !foregroundDemandOnly, !queuedJobs.contains(where: { !$0.isCancelled }),
               PreparationChunkGate.allowsAutomaticWork(thermal: device.thermal, isLowPowerModeEnabled: device.isLowPowerModeEnabled) {
                await enqueueAutomaticAudioPreparationJobs()
                queuedJobs = OfflinePreparationRecovery.backgroundJobs(
                    ownJobs(try store.loadAudioPreparationJobs()), automaticPolicy: automaticAudioPreparationPolicy
                )
            }
            let hasMoreMatchingJobs = {
                let jobs = ownJobs(try store.loadAudioPreparationJobs())
                return !LibraryAudioPreparationTurns.eligible(
                    foregroundDemandOnly ? jobs : OfflinePreparationRecovery.backgroundJobs(jobs, automaticPolicy: self.automaticAudioPreparationPolicy),
                    for: caller
                ).isEmpty
            }
            let previous = libraryAudioPreparingItemId // nil job: nothing to do, or the foreground loop waits for the background task (#534)
            guard let job = libraryAudioLoop.turns.select(queuedJobs, activeItemId: activePlaybackItemId, for: caller) else { libraryAudioLoop.turns.stopped(caller); return false }
            if let previous, previous != job.itemId,
               libraryItems.first(where: { $0.id == previous })?.startupAudioState == .preparing { updateLibraryStartupAudioState(itemId: previous, state: .waiting) }
            if libraryItems.first(where: { $0.id == job.itemId })?.startupAudioState == .waiting { updateLibraryStartupAudioState(itemId: job.itemId, state: .preparing) }
            // The manifest and the item with its text are read off the main actor (#2506):
            // this runs once per chunk, and a book's text is megabytes to decode.
            let jobManifestId = job.manifestId, jobItemId = job.itemId
            let source = try await StoreReader(store).read { store -> PreparationPassSource? in
                guard let manifest = try store.loadPreparedAudioManifest(id: jobManifestId),
                      let item = try? store.loadItem(id: jobItemId), item.deletedAt == nil, // a job saved back mid-render for an item since trashed (#883)
                      let sourceText = PreparedSpeechHooks.preparedText(of: item, in: store) else { return nil }
                return PreparationPassSource(manifest: manifest, item: item, sourceText: sourceText)
            }
            guard let source else {
                try await discardPreparationJob(job.id, store: store)
                diagnostics["backgroundAudioPreparation"] = "discarded_missing_source_job"
                return try hasMoreMatchingJobs()
            }
            var manifest = source.manifest
            let item = source.item, sourceText = source.sourceText
            attemptedJob = job
            recordDeveloperDiagnostic("preparation.selected", ["item": DeveloperDiagnosticRecording.token(job.itemId), "policy": String(describing: job.policy), "nextChunk": String(job.nextChunkIndex)])
            let support = try applicationSupportDirectory()
            guard preparationVoice.isInstalled() else { return !foregroundDemandOnly }
            let signature = try await Task.detached(priority: .utility) {
                try preparationVoice.signature()
            }.value
            guard manifest.signature == signature else {
                manifest.state = .needsRepreparation
                manifest.updatedAt = Date()
                let retired = manifest, jobId = job.id
                _ = try await preparationWrite(store) { try AudioPreparationPassWrites.retireManifest(retired, discardingJobId: jobId, in: $0) }
                return try hasMoreMatchingJobs()
            }
            let plan = await Task.detached(priority: .utility) {
                Self.preparedChunkPlan(for: sourceText)
            }.value
            let eligiblePlan = Self.preparationHorizon(
                plan: plan,
                maximumChunkCount: job.maximumChunkCount
            )
            let ledger = requireOfflineLedger(store: store, rootDirectory: support)
            let coordinator = requirePreparedAudioCoordinator(store: store, supportDirectory: support)
            let atRender = preparationSeams.deviceConditions() // read again here: heat can rise during the setup above (Codex audit on 27fd1bd)
            var alreadyListened = item.sourceCompletedAt != nil
            if !alreadyListened { // the sessions are read here, as before, off the main actor (#2506)
                let sessions = try await StoreReader(store).read { try $0.loadSessions(itemId: jobItemId) }
                alreadyListened = PreparationChunkGate.itemAlreadyListened(sessions)
            }
            let gate = try PreparationChunkGate.decide(policy: job.policy, thermal: atRender.thermal, isLowPowerModeEnabled: atRender.isLowPowerModeEnabled,
                                                       itemAlreadyListened: alreadyListened)
            let gated = try await coordinator.applyGate(gate, manifestId: manifest.id) // applied to the saved manifest: chunks committed meanwhile stay
            manifest = gated.manifest ?? manifest
            if gated.changed { refreshLibraryRowsInBackground() }
            if gate == .dropListenedItem {
                // Removing speculative work must never invalidate committed audio.
                try await discardPreparationJob(job.id, store: store)
                diagnostics["automaticAudioPreparation:\(item.id)"] = "cancelled_existing_progress"
                return try hasMoreMatchingJobs()
            }
            guard gate == .render else { diagnostics["backgroundAudioPreparation"] = gate.rawValue; return false }
            // After the heat gate, so a hot phone pauses the manifest as it always did (#2857).
            guard preparationVoice.allowedNow() else { diagnostics["backgroundAudioPreparation"] = "voice_not_allowed_now"; return false }
            manifest = try await coordinator.droppingMissingChunks(manifestId: manifest.id) ?? manifest // a lost chunk is rendered again, not assembled (#645)
            let completedIndexes = PreparedAudioCoordinator.completedIndexes(manifest, plan: plan, sourceText: sourceText, retryingStandInsFor: job)
            guard let next = eligiblePlan.first(where: { !completedIndexes.contains($0.index) }) else {
                // All chunks are intact but nothing is assembled (#278): assemble now, because it
                // otherwise happens only right after the last chunk is committed.
                if manifest.isCompleteButUnassembled, manifest.plannedChunkCount == plan.count, completedIndexes.count == plan.count {
                    try await finishBackgroundPreparedAudio(
                        item: item, sourceText: sourceText, voice: voice, assemblyVoiceKey: preparationVoice.assemblyVoiceKey(signature), signature: signature,
                        manifest: manifest, plan: plan, store: store, ledger: ledger,
                        coordinator: coordinator, support: support
                    )
                }
                try await discardPreparationJob(job.id, store: store)
                return try hasMoreMatchingJobs()
            }
            let reservation = try await ledger.reserve(
                ownerId: "prepared-chunk-\(manifest.id)-\(next.index)",
                byteCount: 64 * 1_024 * 1_024,
                pinning: PreparedAudioCoordinator.ledgerPaths(ofChunksIn: manifest) // never evicts this article's own chunks (#645)
            )
            // Paced per render, not through the shared lifecycle flag (#377).
            let pacedRenderer: any SupertonicRendering = try preparationSeams.renderer?() ?? preparationVoice.makeRenderer()
            if try await preparationHeldAtRenderStart(policy: job.policy, manifestId: manifest.id, reservationId: reservation.id, ledger: ledger, coordinator: coordinator, store: store) != nil { return false }
            var renderStarted = Date(), renderMs = 0
            do {
                try Task.checkCancellation()
                renderStarted = Date()
                recordDeveloperDiagnostic("preparation.render.begin", ["item": DeveloperDiagnosticRecording.token(item.id), "chunk": String(next.index), "thermal": atRender.thermal.rawValue])
                // The render is discarded once committed (copied), or on any failure.
                try await supertonicOutputGuard(wrapping: pacedRenderer, systemVoice: speechVoiceIdentifier).render(
                    text: next.text, voice: voice, language: "en", speed: 1, synthesisSteps: 8
                ) { rendered in
                    renderMs = Int(Date().timeIntervalSince(renderStarted) * 1_000) // the render alone, before the copy and saves (Codex audit on e5088b9)
                    try Task.checkCancellation()
                    guard !suppressedAutomaticAudioPreparationItemIds.contains(item.id) else {
                        throw CancellationError()
                    }
                    try await coordinator.commit(
                        itemId: item.id,
                        signature: signature,
                        plan: next,
                        sourceText: sourceText,
                        audioURL: rendered.audioURL,
                        durationMs: Int((rendered.duration * 1_000).rounded()), engine: rendered.engine
                    )
                }
            } catch {
                try? await ledger.release(reservationId: reservation.id)
                throw error
            }
            let renderedManifestId = manifest.id
            guard let updated = try await StoreReader(store).readInOrder(AudioPreparationQueueEdits.orderKey, { try $0.loadPreparedAudioManifest(id: renderedManifestId) }), // runs even if the pass was just cancelled, as the commit after it does
                  let committed = updated.chunks.first(where: { $0.index == next.index }) else {
                try? await ledger.release(reservationId: reservation.id)
                return try hasMoreMatchingJobs()
            }
            guard try await ledger.commitPrepared(reservationId: reservation.id, asset: PreparedAudioCoordinator.ledgerAsset(for: committed, itemId: item.id), manifest: updated) else {
                return try hasMoreMatchingJobs()
            }
            // The record is written off the main thread, on the job as the store holds it then, so a priority the
            // listener set while this chunk rendered is kept (#2509).
            let automaticPolicy = automaticAudioPreparationPolicy
            let jobBeforeRender = job
            let decision = try await preparationWrite(store) { [plan, sourceText] store in
                try AudioPreparationPassWrites.recordChunk(
                    in: updated, jobId: jobBeforeRender.id, fallback: jobBeforeRender, decide: { fresh in
                        var job = fresh
                        job.nextChunkIndex = updated.chunks.count
                        job.lastFailureCode = PreparedAudioCoordinator.hasStandIns(updated) ? PreparedAudioCoordinator.standInRetried : nil
                        if PreparedAudioCoordinator.matchingChunks(in: updated, plan: plan, sourceText: sourceText).count == plan.count {
                            return .init(change: .save(job), needsAssembly: true)
                        } else if let maximumChunkCount = job.maximumChunkCount {
                            let horizon = plan.prefix(min(maximumChunkCount, plan.count))
                            guard PreparedAudioCoordinator.isPrepared(Array(horizon), in: updated, sourceText: sourceText) else {
                                return .init(change: .save(job), needsAssembly: false)
                            }
                            let note = "ready_\(horizon.count)_of_\(plan.count)"
                            if automaticPolicy == .whileCharging {
                                job.policy = .whileCharging
                                job.maximumChunkCount = nil
                                return .init(change: .save(job), needsAssembly: false, note: note)
                            }
                            return .init(change: .delete(id: job.id), needsAssembly: false, note: note)
                        } else {
                            return .init(change: .save(job), needsAssembly: false)
                        }
                    }, store: store)
            }
            let needsAssembly = decision?.needsAssembly
            if let decision {
                recordDeveloperDiagnostic("preparation.committed", ["item": DeveloperDiagnosticRecording.token(item.id), "chunks": String(updated.chunks.count),
                                                                    "renderMs": String(renderMs), "thermal": SupertonicResourcePolicy.currentConditions().thermal.rawValue])
                if let note = decision.note { diagnostics["startupAudioPreparation:\(item.id)"] = note }
            }
            guard let needsAssembly else { return try hasMoreMatchingJobs() }
            if needsAssembly {
                try await finishBackgroundPreparedAudio(
                    item: item,
                    sourceText: sourceText,
                    voice: voice,
                    assemblyVoiceKey: preparationVoice.assemblyVoiceKey(signature),
                    signature: signature,
                    manifest: updated,
                    plan: plan,
                    store: store,
                    ledger: ledger,
                    coordinator: coordinator,
                    support: support
                )
            }
            applyPreparedChunkProgress(item: item, manifest: updated,
                                       remainingJobs: try store.loadAudioPreparationJobs())
            let hasMore = try hasMoreMatchingJobs()
            diagnostics["backgroundAudioPreparation"] = hasMore ? "chunk_committed" : "complete"
            return hasMore
        } catch is CancellationError {
            if let job = attemptedJob,
               !suppressedAutomaticAudioPreparationItemIds.contains(job.itemId),
               let store {
                await markPreparationFailure(job, code: OfflinePreparationRecovery.waitingForSystem, store: store)
                await refreshAudioPreparationPresentation()
            }
            diagnostics["backgroundAudioPreparation"] = "expired"
            return !foregroundDemandOnly
        } catch {
            if let job = attemptedJob, let store {
                await markPreparationFailure(job, code: String(describing: type(of: error)), store: store)
                if job.maximumChunkCount != nil {
                    failedStartupAudioPreparationItemIds.insert(job.itemId)
                }
                refreshLibraryRowsInBackground()
            }
            diagnostics["backgroundAudioPreparation"] = "paused:\(error.localizedDescription)"
            if attemptedJob?.policy == .explicit {
                reportWarning("Audio preparation paused: \(error.localizedDescription)")
            }
            return false
        }
    }


    /// The pass's store writes run off the main thread, in line behind the queue's own edits (#2509). The lines up to a
    /// write read the store on main; the write itself no longer waits for its lock there.
    private func preparationWrite<T: Sendable>(
        _ store: SQLiteSessionStore, _ body: @escaping @Sendable (SQLiteSessionStore) throws -> T
    ) async throws -> T {
        try await StoreReader(store).readInOrder(AudioPreparationQueueEdits.orderKey, body)
    }

    private func discardPreparationJob(_ id: String, store: SQLiteSessionStore) async throws {
        try await preparationWrite(store) { try AudioPreparationPassWrites.discardJob(id: id, in: $0) }
    }

    /// Notes why the pass stopped, on the job as it is now. Best effort: a failed note must not hide the failure it describes.
    private func markPreparationFailure(_ job: AudioPreparationJob, code: String, store: SQLiteSessionStore) async {
        let jobId = job.id, manifestId = job.manifestId
        _ = try? await preparationWrite(store) {
            try AudioPreparationPassWrites.markFailure(jobId: jobId, manifestId: manifestId, code: code, in: $0)
        }
    }
}

/// What one pass over a preparation job needs from the store, read together off the main actor (#2506).
private struct PreparationPassSource: Sendable {
    var manifest: PreparedAudioManifest
    var item: Item
    var sourceText: String
}
