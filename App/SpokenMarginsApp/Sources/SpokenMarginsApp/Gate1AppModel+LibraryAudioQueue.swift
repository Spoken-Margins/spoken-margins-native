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

/// Library audio preparation: policy, scheduling, enqueue and queue actions (#991), moved unchanged out of the central model.
extension Gate1AppModel {
    func automaticAudioPreparationPolicyChanged() {
        UserDefaults.standard.set(
            automaticAudioPreparationPolicy.rawValue,
            forKey: "automaticAudioPreparationPolicy"
        )
        diagnostics["automaticAudioPreparation"] = automaticAudioPreparationPolicy.rawValue
        scheduleAutomaticAudioPreparationIfNeeded()
    }

    func automaticEpisodeMapPreparationPolicyChanged() {
        UserDefaults.standard.set(
            automaticEpisodeMapPreparationPolicy.rawValue,
            forKey: "automaticEpisodeMapPreparationPolicy"
        )
        diagnostics["automaticEpisodeMapPreparation"] = automaticEpisodeMapPreparationPolicy.rawValue
        submitAutomaticEpisodeMapPreparationIfNeeded()
    }

    func scheduleAutomaticAudioPreparationIfNeeded() {
        #if canImport(BackgroundTasks) && canImport(UIKit)
        let enabled = automaticAudioPreparationPolicy == .whileCharging
        Task { [weak self] in
            guard let self else { return }
            if enabled { await self.enqueueAutomaticAudioPreparationJobs() }
            self.hangTelemetry.labels.scoped("scheduleAudioPreparation") { self.scheduleAudioPreparationBackgroundTask() }
        }
        #endif
    }

    func scheduleAudioPreparationBackgroundTask() {
        #if canImport(BackgroundTasks) && canImport(UIKit)
        AudioPreparationBackgroundController.shared.submitIfEnabled(OfflinePreparationRecovery.shouldSchedule(
            jobs: (try? store?.loadAudioPreparationJobs()) ?? [],
            automaticAudio: automaticAudioPreparationPolicy,
            automaticEpisodeMaps: automaticEpisodeMapPreparationPolicy
        ))
        #endif
    }

    func scheduleStartupAudioPreparationIfNeeded(itemId: String) {
        guard audioPlaybackClientOverride == nil,
              hasAcceptedCurrentTerms,
              ttsVoiceSelection.supertonicVoice != nil,
              !suppressedAutomaticAudioPreparationItemIds.contains(itemId),
              !liveSpeechFallbackItemIds.contains(itemId),
              !pendingStartupAudioPreparationItemIds.contains(itemId),
              libraryItems.first(where: { $0.id == itemId })?.startupAudioState != .ready else {
            return
        }
        do {
            let store = try requireStore()
            // A summary has everything these checks read; the item's text is not needed to decide (#2506).
            guard let item = try store.loadItemSummary(id: itemId),
                  item.deletedAt == nil, item.sourceCompletedAt == nil,
                  !PreparationChunkGate.itemAlreadyListened(try store.loadSessions(itemId: itemId)),
                  LibraryRowBuilder.shouldPrewarmTextAudio(for: item),
                  item.hasListenableText else {
                return
            }
            pendingStartupAudioPreparationItemIds.insert(itemId)
            failedStartupAudioPreparationItemIds.remove(itemId)
            updateLibraryStartupAudioState(itemId: itemId, state: .waiting)
            diagnostics["startupAudioPreparation:\(itemId)"] = "queued"
            Task { @MainActor [weak self] in
                await self?.enqueueStartupAudioPreparation(itemId: itemId)
            }
        } catch {
            failedStartupAudioPreparationItemIds.insert(itemId)
            updateLibraryStartupAudioState(itemId: itemId, state: .failed)
            diagnostics["startupAudioPreparation:\(itemId)"] = "enqueue_failed:\(error.localizedDescription)"
        }
    }

    private func enqueueStartupAudioPreparation(itemId: String) async {
        defer { pendingStartupAudioPreparationItemIds.remove(itemId) }
        do {
            try Task.checkCancellation()
            let store = try requireStore()
            let item = try store.loadItem(id: itemId)
            guard item.sourceCompletedAt == nil,
                  !PreparationChunkGate.itemAlreadyListened(try store.loadSessions(itemId: itemId)),
                  let sourceText = PreparedSpeechHooks.preparedText(of: item, in: store),
                  LibraryRowBuilder.shouldPrewarmTextAudio(for: item),
                  let voice = ttsVoiceSelection.supertonicVoice,
                  let assets = SupertonicAssetResolver.location() else {
                updateLibraryStartupAudioState(itemId: itemId, state: .notRequired)
                return
            }
            let plan = await Task.detached(priority: .utility) {
                Self.preparedChunkPlan(for: sourceText)
            }.value
            guard !plan.isEmpty else {
                updateLibraryStartupAudioState(itemId: itemId, state: .notRequired)
                return
            }
            let signature = try await Task.detached(priority: .utility) {
                try SupertonicRenderIdentity.make(assets: assets, voice: voice)
            }.value
            try Task.checkCancellation()
            let support = try applicationSupportDirectory()
            let coordinator = requirePreparedAudioCoordinator(store: store, supportDirectory: support)
            currentSupertonicRenderSignature = signature
            let manifest = try await coordinator.begin(
                itemId: item.id,
                sourceText: sourceText,
                signature: signature,
                plan: plan
            )
            let targetChunkCount = min(Self.startupAudioChunkCount, plan.count)
            _ = try PreparedAudioEnqueue.configureJob(
                manifest: manifest, sourceText: sourceText, repository: store,
                request: .startup(maximumChunkCount: targetChunkCount, requestedAt: item.createdAt)
            )
            diagnostics["startupAudioPreparation:\(itemId)"] = manifest.chunks.count < targetChunkCount
                ? "queued_0_of_\(targetChunkCount)" : "ready_from_cache"
            refreshLibraryRowsInBackground()
            startForegroundAudioPreparationIfNeeded()
        } catch PreparedAudioEnqueue.Rejection.staleSource {
            diagnostics["startupAudioPreparation:\(itemId)"] = "retired_source"
            // The import may have requested startup audio while the old request was still pending.
            // Re-read the new source after this call's defer releases that pending entry.
            Task { @MainActor [weak self] in self?.scheduleStartupAudioPreparationIfNeeded(itemId: itemId) }
        } catch is CancellationError {
            diagnostics["startupAudioPreparation:\(itemId)"] = "cancelled"
        } catch {
            failedStartupAudioPreparationItemIds.insert(itemId)
            updateLibraryStartupAudioState(itemId: itemId, state: .failed)
            diagnostics["startupAudioPreparation:\(itemId)"] = "failed:\(error.localizedDescription)"
        }
    }

    func updateLibraryStartupAudioState(itemId: String, state: NativeTextStartupAudioState) {
        guard let index = libraryItems.firstIndex(where: { $0.id == itemId }),
              libraryItems[index].startupAudioState != state else { return }
        libraryItems[index].startupAudioState = state
    }

    func libraryStartupAudioPresentation(
        item: Item,
        manifest: PreparedAudioManifest?,
        job: AudioPreparationJob?
    ) -> (state: NativeTextStartupAudioState, completed: Int, target: Int) {
        LibraryRowBuilder.startupAudioPresentation(item: item, manifest: manifest, job: job, context: startupAudioContext)
    }

    func applyPreparedChunkProgress(item: Item, manifest: PreparedAudioManifest, remainingJobs: [AudioPreparationJob]) {
        var manifest = manifest
        // Finishing the final chunk persists a terminal state and removes its
        // job. The caller's pre-finalization snapshot must not downgrade that
        // result. Intermediate chunks still avoid any persistence reload.
        if manifest.state == .preparing,
           manifest.chunks.count == manifest.plannedChunkCount,
           !remainingJobs.contains(where: { $0.manifestId == manifest.id && !$0.isCancelled }),
           let persisted = try? store?.loadPreparedAudioManifest(id: manifest.id) {
            manifest = persisted
        }
        let job = remainingJobs.first { $0.manifestId == manifest.id && !$0.isCancelled }
        if let index = libraryItems.firstIndex(where: { $0.id == item.id }), !libraryItems[index].isCompleted {
            let startup = libraryStartupAudioPresentation(item: item, manifest: manifest, job: job)
            var row = libraryItems[index]
            row.startupAudioState = startup.state
            row.startupAudioCompletedChunkCount = startup.completed
            row.startupAudioTargetChunkCount = startup.target
            row.offlineState = LibraryOfflineStateFilter.forItem(
                preparedState: [.preparing, .pausedForThermal].contains(manifest.state) && job == nil ? .notPrepared : manifest.state,
                mediaSourceType: item.media?.sourceType, podcastDownloadState: nil)
            if row != libraryItems[index] { libraryItems[index] = row }
        }
        let rows = AudioPreparationQueueProjection.rows(
            audioPreparationQueue, afterProgressOn: manifest, currentJob: job,
            remainingJobs: remainingJobs, activeItemId: activePlaybackItemId)
        if audioPreparationQueue != rows { audioPreparationQueue = rows }
    }

    func refreshAudioPreparationPresentation() {
        guard let store else { return }
        do {
            try refreshAudioPreparationPresentation(store: store)
        } catch {
            diagnostics["audioPreparationPresentation"] = "failed:\(String(describing: type(of: error)))"
        }
    }

    func refreshAudioPreparationPresentation(
        store: SQLiteSessionStore,
        announceNewCompletions: Bool = false,
        now: Date = Date()
    ) throws {
        let presentation = AudioPreparationPresentation(
            items: try store.listItemSummaries(), sessions: try store.loadSessions(),
            manifests: try store.loadPreparedAudioManifests(), jobs: try store.loadAudioPreparationJobs(),
            activeItemId: activePlaybackItemId)
        try store.deleteAudioPreparationJobs(ids: presentation.staleJobIds)
        audioPreparationQueue = presentation.queue
        recentlyPreparedAudio = presentation.recentlyPrepared

        guard announceNewCompletions else { return }
        let defaults = UserDefaults.standard
        guard let notice = AudioPreparationQueueProjection.preparedAudioNotice(
            recentlyPrepared: recentlyPreparedAudio,
            lastNoticeTimestamp: defaults.object(forKey: Self.lastPreparedAudioNoticeDateKey) as? Double,
            now: now
        ) else { return }
        defaults.set(notice.newestCompletedAt.timeIntervalSince1970, forKey: Self.lastPreparedAudioNoticeDateKey)
        reportConfirmation(notice.message)
    }

    func moveAudioPreparationJobEarlier(id: String) {
        moveAudioPreparationJob(id: id, offset: -1)
    }

    func moveAudioPreparationJobLater(id: String) {
        moveAudioPreparationJob(id: id, offset: 1)
    }

    func skipAudioPreparationJob(id: String) {
        do {
            let store = try requireStore()
            let jobs = try store.loadAudioPreparationJobs()
            guard let selected = jobs.first(where: { $0.id == id }) else { return }
            suppressAudioPreparation(itemId: selected.itemId)
            try store.deleteAudioPreparationJobs(
                ids: jobs.filter { $0.itemId == selected.itemId }.map(\.id)
            )
            pendingStartupAudioPreparationItemIds.remove(selected.itemId)
            failedStartupAudioPreparationItemIds.remove(selected.itemId)
            refreshLibraryRowsInBackground(mustPublish: true)
            diagnostics["audioPreparationSuppressed:\(selected.itemId)"] = "user"
            reportConfirmation("Removed \(itemsTitle(itemId: selected.itemId, store: store)) from audio preparation.")
        } catch {
            reportFailure(error, context: "Removing the item from audio preparation failed")
        }
    }

    func clearAudioPreparationQueue() {
        do {
            let store = try requireStore()
            let jobs = try store.loadAudioPreparationJobs().filter { !$0.isCancelled }
            let itemIds = Set(jobs.map(\.itemId))
            libraryAudioLoop.stopAndInvalidate()
            suppressAudioPreparation(itemIds: itemIds)
            try store.deleteAudioPreparationJobs(ids: jobs.map(\.id))
            pendingStartupAudioPreparationItemIds.subtract(itemIds)
            failedStartupAudioPreparationItemIds.subtract(itemIds)
            refreshLibraryRowsInBackground(mustPublish: true)
            diagnostics["audioPreparationQueueCleared"] = "\(jobs.count)"
            reportConfirmation("Cleared \(jobs.count) audio preparation job\(jobs.count == 1 ? "" : "s"). Existing audio and Library items were kept.")
        } catch {
            reportFailure(error, context: "Clearing the audio preparation queue failed")
        }
    }

    func suppressAudioPreparation(itemId: String) {
        suppressAudioPreparation(itemIds: Set([itemId]))
    }

    func suppressAudioPreparation(itemIds: Set<String>) {
        suppressedAutomaticAudioPreparationItemIds.formUnion(itemIds)
        UserDefaults.standard.set(
            suppressedAutomaticAudioPreparationItemIds.sorted(),
            forKey: Self.suppressedAudioPreparationItemIdsKey
        )
    }

    func allowAudioPreparation(itemId: String) {
        guard suppressedAutomaticAudioPreparationItemIds.remove(itemId) != nil else { return }
        UserDefaults.standard.set(
            suppressedAutomaticAudioPreparationItemIds.sorted(),
            forKey: Self.suppressedAudioPreparationItemIdsKey
        )
    }

    private func itemsTitle(itemId: String, store: SQLiteSessionStore) -> String {
        (try? store.loadItem(id: itemId).title) ?? "this item"
    }

    func prioritizeAudioPreparationJob(id: String) {
        do {
            let store = try requireStore()
            let jobs = try store.loadAudioPreparationJobs().filter { !$0.isCancelled }
            guard var selected = jobs.first(where: { $0.id == id }) else { return }
            // Pin only the selected job. Assigning ranks to the whole queue
            // would demote every future import behind all existing work.
            selected.userPriority = AudioPreparationQueueProjection.nextUserPriority(among: jobs)
            try store.saveAudioPreparationJob(selected)
            try refreshAudioPreparationPresentation(store: store)
            startForegroundAudioPreparationIfNeeded()
        } catch {
            reportFailure(error, context: "Unable to prepare this item next")
        }
    }

    private func moveAudioPreparationJob(id: String, offset: Int) {
        guard offset == -1 || offset == 1 else { return }
        do {
            let store = try requireStore()
            let allJobs = try store.loadAudioPreparationJobs().filter { !$0.isCancelled }
            guard let reordered = AudioPreparationQueueProjection.reorderedTier(
                of: allJobs, moving: id, by: offset, activeItemId: activePlaybackItemId
            ) else { return }
            for job in reordered { try store.saveAudioPreparationJob(job) }
            try refreshAudioPreparationPresentation(store: store)
            reportConfirmation("Updated the audio preparation order.")
        } catch {
            reportFailure(error, context: "Updating the audio preparation queue failed")
        }
    }

    func enqueueExplicitAudioPreparation(item: Item) async {
        guard let sourceText = PreparedSpeechHooks.preparedText(of: item, in: store),
              !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let voice = ttsVoiceSelection.supertonicVoice else { return }
        do {
            allowAudioPreparation(itemId: item.id)
            failedStartupAudioPreparationItemIds.remove(item.id)
            let store = try requireStore()
            let support = try applicationSupportDirectory()
            guard let assets = SupertonicAssetResolver.location() else {
                reportFailure("Supertonic isn't downloaded. Get it in Settings › Voices.")
                return
            }
            let signature = try await Task.detached(priority: .utility) {
                try SupertonicRenderIdentity.make(assets: assets, voice: voice)
            }.value
            let coordinator = requirePreparedAudioCoordinator(store: store, supportDirectory: support)
            currentSupertonicRenderSignature = signature
            let plan = await Task.detached(priority: .utility) {
                Self.preparedChunkPlan(for: sourceText)
            }.value
            guard !plan.isEmpty else { return }
            let manifest = try await coordinator.begin(
                itemId: item.id,
                sourceText: sourceText,
                signature: signature,
                plan: plan
            )
            guard manifest.state != .readyOffline else {
                refreshLibraryRowsInBackground()
                reportConfirmation("\(item.title) is already available offline.")
                return
            }
            try hangTelemetry.labels.scoped("explicitAudioPreparationQueued") {
                _ = try PreparedAudioEnqueue.configureJob(manifest: manifest, sourceText: sourceText, repository: store, request: .explicit)
                refreshLibraryRowsInBackground()
                diagnostics["explicitAudioPreparation:\(item.id)"] = "queued"
                reportConfirmation("Prioritized \(item.title) for audio preparation.")
                scheduleAudioPreparationBackgroundTask()
                startForegroundAudioPreparationIfNeeded()
            }
        } catch PreparedAudioEnqueue.Rejection.staleSource {
            diagnostics["explicitAudioPreparation:\(item.id)"] = "retired_source"
        } catch {
            diagnostics["explicitAudioPreparation:\(item.id)"] = "failed:\(error.localizedDescription)"
            reportFailure(error, context: "Preparing audio failed to start")
        }
    }

    func enqueueAutomaticAudioPreparationJobs() async {
        guard automaticAudioPreparationPolicy == .whileCharging,
              hasAcceptedCurrentTerms,
              let voice = ttsVoiceSelection.supertonicVoice else { return }
        do {
            let store = try requireStore()
            let support = try applicationSupportDirectory()
            guard let assets = SupertonicAssetResolver.location() else { return }
            let signature = try await Task.detached(priority: .utility) {
                try SupertonicRenderIdentity.make(assets: assets, voice: voice)
            }.value
            let coordinator = requirePreparedAudioCoordinator(store: store, supportDirectory: support)
            currentSupertonicRenderSignature = signature
            let sessionsByItemId = Dictionary(grouping: try store.loadSessions(), by: \.itemId)
            for row in libraryItems {
                guard let item = try? store.loadItem(id: row.id),
                      !LibraryAudioPreparationAdmission.playsItsOwnAudio(item),
                      let text = PreparedSpeechHooks.preparedText(of: item, in: store),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !suppressedAutomaticAudioPreparationItemIds.contains(item.id) else { continue }
                guard LibraryAudioPreparationAdmission.admitsAutomatically(item, sessions: sessionsByItemId[item.id] ?? []) else {
                    diagnostics["automaticAudioPreparation:\(item.id)"] = "skipped_existing_progress"
                    continue
                }
                let plan = await Task.detached(priority: .utility) {
                    Self.preparedChunkPlan(for: text)
                }.value
                guard !plan.isEmpty else { continue }
                let manifest: PreparedAudioManifest
                do {
                    manifest = try await coordinator.begin(itemId: item.id, sourceText: text, signature: signature, plan: plan)
                } catch PreparedAudioEnqueue.Rejection.staleSource { continue }
                guard manifest.state != .readyOffline else { continue }
                do {
                    _ = try PreparedAudioEnqueue.configureJob(manifest: manifest, sourceText: text, repository: store,
                                                             request: .automatic(requestedAt: item.createdAt))
                } catch PreparedAudioEnqueue.Rejection.staleSource { continue }
            }
            try refreshAudioPreparationPresentation(store: store)
            diagnostics["automaticAudioPreparationQueue"] = "queued"
        } catch {
            diagnostics["automaticAudioPreparationQueue"] = "failed:\(error.localizedDescription)"
        }
    }

    nonisolated static func audioPreparationJobPrecedes(
        _ lhs: AudioPreparationJob,
        _ rhs: AudioPreparationJob
    ) -> Bool {
        audioPreparationJobPrecedes(lhs, rhs, activeItemId: nil)
    }

    nonisolated static func audioPreparationJobPrecedes(
        _ lhs: AudioPreparationJob,
        _ rhs: AudioPreparationJob,
        activeItemId: String?
    ) -> Bool {
        LibraryAudioPreparationQueue.precedes(lhs, rhs, activeItemId: activeItemId)
    }

    nonisolated static let preparationPlanCache = PreparedChunkPlanCache()

    nonisolated static func preparedChunkPlan(for sourceText: String) -> [PreparedChunkPlan] {
        preparationPlanCache.value(for: sourceText) { PreparedChunkPlan.articlePlan(sourceText) }
    }

    nonisolated static func preparationHorizon(
        plan: [PreparedChunkPlan],
        maximumChunkCount: Int?
    ) -> [PreparedChunkPlan] {
        Array(plan.prefix(min(maximumChunkCount ?? plan.count, plan.count)))
    }
}
