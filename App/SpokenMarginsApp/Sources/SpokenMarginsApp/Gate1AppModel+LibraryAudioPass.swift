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
              let voice = ttsVoiceSelection.supertonicVoice else { libraryAudioLoop.turns.blocked(caller); return false } // settles until these change (#647)
        let device = preparationSeams.deviceConditions() // heat and Low Power Mode, checked per chunk (#64)
        do {
            try Task.checkCancellation()
            let store = try requireStore()
            var queuedJobs = try store.loadAudioPreparationJobs()
                .filter({ !PreparationChunkGate.setsAsideForLowPowerMode($0.policy, thermal: device.thermal, isLowPowerModeEnabled: device.isLowPowerModeEnabled) })
            if !foregroundDemandOnly {
                queuedJobs = OfflinePreparationRecovery.backgroundJobs(queuedJobs, automaticPolicy: automaticAudioPreparationPolicy)
            }
            if !foregroundDemandOnly, !queuedJobs.contains(where: { !$0.isCancelled }),
               PreparationChunkGate.allowsAutomaticWork(thermal: device.thermal, isLowPowerModeEnabled: device.isLowPowerModeEnabled) {
                await enqueueAutomaticAudioPreparationJobs()
                queuedJobs = OfflinePreparationRecovery.backgroundJobs(
                    try store.loadAudioPreparationJobs(), automaticPolicy: automaticAudioPreparationPolicy
                )
            }
            let hasMoreMatchingJobs = {
                let jobs = try store.loadAudioPreparationJobs()
                return !LibraryAudioPreparationTurns.eligible(
                    foregroundDemandOnly ? jobs : OfflinePreparationRecovery.backgroundJobs(jobs, automaticPolicy: self.automaticAudioPreparationPolicy),
                    for: caller
                ).isEmpty
            }
            let previous = libraryAudioPreparingItemId // nil job: nothing to do, or the foreground loop waits for the background task (#534)
            guard var job = libraryAudioLoop.turns.select(queuedJobs, activeItemId: activePlaybackItemId, for: caller) else { libraryAudioLoop.turns.stopped(caller); return false }
            if let previous, previous != job.itemId,
               libraryItems.first(where: { $0.id == previous })?.startupAudioState == .preparing { updateLibraryStartupAudioState(itemId: previous, state: .waiting) }
            if libraryItems.first(where: { $0.id == job.itemId })?.startupAudioState == .waiting { updateLibraryStartupAudioState(itemId: job.itemId, state: .preparing) }
            guard var manifest = try store.loadPreparedAudioManifest(id: job.manifestId),
                  let item = try? store.loadItem(id: job.itemId), item.deletedAt == nil, // a job saved back mid-render for an item since trashed (#883)
                  let sourceText = PreparedSpeechHooks.preparedText(of: item, in: store) else {
                try store.deleteAudioPreparationJob(id: job.id)
                diagnostics["backgroundAudioPreparation"] = "discarded_missing_source_job"
                return try hasMoreMatchingJobs()
            }
            attemptedJob = job
            recordDeveloperDiagnostic("preparation.selected", ["item": DeveloperDiagnosticRecording.token(job.itemId), "policy": String(describing: job.policy), "nextChunk": String(job.nextChunkIndex)])
            let support = try applicationSupportDirectory()
            guard let assets = SupertonicAssetResolver.location() else {
                return !foregroundDemandOnly
            }
            let signature = try await Task.detached(priority: .utility) {
                try SupertonicRenderIdentity.make(assets: assets, voice: voice)
            }.value
            guard manifest.signature == signature else {
                manifest.state = .needsRepreparation
                manifest.updatedAt = Date()
                _ = try PreparedAudioEnqueue.withCurrentManifest(manifest, repository: store) { _, _ in
                    try store.savePreparedAudioManifest(manifest)
                    PreparedAudioChangeSignal.shared.bump()
                    try store.deleteAudioPreparationJob(id: job.id)
                }
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
            let gate = try PreparationChunkGate.decide(policy: job.policy, thermal: atRender.thermal, isLowPowerModeEnabled: atRender.isLowPowerModeEnabled,
                                                       itemAlreadyListened: item.sourceCompletedAt != nil || PreparationChunkGate.itemAlreadyListened(store.loadSessions(itemId: item.id)))
            let gated = try await coordinator.applyGate(gate, manifestId: manifest.id) // applied to the saved manifest: chunks committed meanwhile stay
            manifest = gated.manifest ?? manifest
            if gated.changed { refreshLibraryRowsInBackground() }
            if gate == .dropListenedItem {
                // Removing speculative work must never invalidate committed audio.
                try store.deleteAudioPreparationJob(id: job.id)
                diagnostics["automaticAudioPreparation:\(item.id)"] = "cancelled_existing_progress"
                return try hasMoreMatchingJobs()
            }
            guard gate == .render else { diagnostics["backgroundAudioPreparation"] = gate.rawValue; return false }
            manifest = try await coordinator.droppingMissingChunks(manifestId: manifest.id) ?? manifest // a lost chunk is rendered again, not assembled (#645)
            let completedIndexes = PreparedAudioCoordinator.completedIndexes(manifest, plan: plan, sourceText: sourceText, retryingStandInsFor: job)
            guard let next = eligiblePlan.first(where: { !completedIndexes.contains($0.index) }) else {
                // All chunks are intact but nothing is assembled (#278): assemble now, because it
                // otherwise happens only right after the last chunk is committed.
                if manifest.isCompleteButUnassembled, manifest.plannedChunkCount == plan.count, completedIndexes.count == plan.count {
                    try await finishBackgroundPreparedAudio(
                        item: item, sourceText: sourceText, voice: voice, signature: signature,
                        manifest: manifest, plan: plan, store: store, ledger: ledger,
                        coordinator: coordinator, support: support
                    )
                }
                try store.deleteAudioPreparationJob(id: job.id)
                return try hasMoreMatchingJobs()
            }
            let reservation = try await ledger.reserve(
                ownerId: "prepared-chunk-\(manifest.id)-\(next.index)",
                byteCount: 64 * 1_024 * 1_024,
                pinning: PreparedAudioCoordinator.ledgerPaths(ofChunksIn: manifest) // never evicts this article's own chunks (#645)
            )
            // Paced per render, not through the shared lifecycle flag (#377).
            let pacedRenderer: any SupertonicRendering = try preparationSeams.renderer?() ?? BackgroundPreparationRenderer(base: makeSupertonicRenderer())
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
            guard let updated = try store.loadPreparedAudioManifest(id: manifest.id),
                  let committed = updated.chunks.first(where: { $0.index == next.index }) else {
                try? await ledger.release(reservationId: reservation.id)
                return try hasMoreMatchingJobs()
            }
            guard try await ledger.commitPrepared(reservationId: reservation.id, asset: PreparedAudioCoordinator.ledgerAsset(for: committed, itemId: item.id), manifest: updated) else {
                return try hasMoreMatchingJobs()
            }
            let needsAssembly = try PreparedAudioEnqueue.withCurrentManifest(updated, repository: store) { _, _ in
                job = (try store.loadAudioPreparationJobs()).first(where: { $0.id == job.id }) ?? job
                recordDeveloperDiagnostic("preparation.committed", ["item": DeveloperDiagnosticRecording.token(item.id), "chunks": String(updated.chunks.count),
                                                                    "renderMs": String(renderMs), "thermal": SupertonicResourcePolicy.currentConditions().thermal.rawValue])
                job.nextChunkIndex = updated.chunks.count
                job.lastFailureCode = PreparedAudioCoordinator.hasStandIns(updated) ? PreparedAudioCoordinator.standInRetried : nil
                if PreparedAudioCoordinator.matchingChunks(in: updated, plan: plan, sourceText: sourceText).count == plan.count {
                    try store.saveAudioPreparationJob(job)
                    return true
                } else if let maximumChunkCount = job.maximumChunkCount {
                    let horizon = plan.prefix(min(maximumChunkCount, plan.count))
                    if PreparedAudioCoordinator.isPrepared(Array(horizon), in: updated, sourceText: sourceText) {
                        if automaticAudioPreparationPolicy == .whileCharging {
                            job.policy = .whileCharging
                            job.maximumChunkCount = nil
                            try store.saveAudioPreparationJob(job)
                        } else {
                            try store.deleteAudioPreparationJob(id: job.id)
                        }
                        diagnostics["startupAudioPreparation:\(item.id)"] = "ready_\(horizon.count)_of_\(plan.count)"
                    } else {
                        try store.saveAudioPreparationJob(job)
                    }
                } else {
                    try store.saveAudioPreparationJob(job)
                }
                return false
            }
            guard let needsAssembly else { return try hasMoreMatchingJobs() }
            if needsAssembly {
                try await finishBackgroundPreparedAudio(
                    item: item,
                    sourceText: sourceText,
                    voice: voice,
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
            if var job = attemptedJob,
               !suppressedAutomaticAudioPreparationItemIds.contains(job.itemId),
               let store {
                job.lastFailureCode = OfflinePreparationRecovery.waitingForSystem
                if let current = try? store.loadPreparedAudioManifest(id: job.manifestId) {
                    _ = try? PreparedAudioEnqueue.withCurrentManifest(current, repository: store) { _, _ in
                        if try store.loadAudioPreparationJobs().contains(where: { $0.id == job.id }) { try store.saveAudioPreparationJob(job) }
                    }
                }
                try? refreshAudioPreparationPresentation(store: store)
            }
            diagnostics["backgroundAudioPreparation"] = "expired"
            return !foregroundDemandOnly
        } catch {
            if var job = attemptedJob, let store {
                job.lastFailureCode = String(describing: type(of: error))
                if let current = try? store.loadPreparedAudioManifest(id: job.manifestId) {
                    _ = try? PreparedAudioEnqueue.withCurrentManifest(current, repository: store) { _, _ in
                        if try store.loadAudioPreparationJobs().contains(where: { $0.id == job.id }) { try store.saveAudioPreparationJob(job) }
                    }
                }
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

}
