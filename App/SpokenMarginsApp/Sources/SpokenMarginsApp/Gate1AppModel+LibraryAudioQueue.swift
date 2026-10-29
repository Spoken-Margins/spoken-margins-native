import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitSharing
import SessionKitSupertonic
import SessionKitPersistence
import SessionKitFeeds
/// Startup audio preparation's bookkeeping, held as one value so `Gate1AppModel.swift` doesn't grow (hot-file ratchet).
struct StartupAudioPreparationState {
    /// The in-flight task per item; a task that was replaced or cancelled can't clear its successor's mark (#2812).
    var pending = OwnedWorkRegistry<Task<Void, Never>>()
    var failedItemIds: Set<String> = []
    /// Failed or not-ready items wait before the next trigger retries (#2653).
    var cooldown = RetryCooldown(base: 30, ceiling: 10 * 60)
}

extension Gate1AppModel {
    /// Drops the pending mark for these items and cancels their tasks, so none keeps running unmarked.
    func cancelStartupAudioPreparation<S: Sequence>(itemIds: S) where S.Element == String {
        startupAudioPreparation.pending.remove(itemIds).forEach { $0.cancel() }
    }
    var failedStartupAudioPreparationItemIds: Set<String> { get { startupAudioPreparation.failedItemIds } set { startupAudioPreparation.failedItemIds = newValue } }
    var startupAudioPreparationCooldown: RetryCooldown { get { startupAudioPreparation.cooldown } set { startupAudioPreparation.cooldown = newValue } }

    /// The cooldown is per item and voice, because the startup job is: a not-ready job for voice A must not hold
    /// back voice B's after the listener switches (#2690 audit). Clearing an item clears every voice.
    static func startupAudioCooldownKey(_ itemId: String, _ voice: SupertonicVoiceID) -> String { "\(itemId)|\(voice.rawValue)" }
    static func startupAudioCooldownKeys<S: Sequence>(_ itemIds: S) -> Set<String> where S.Element == String {
        Set(itemIds.flatMap { id in SupertonicVoiceID.allCases.map { startupAudioCooldownKey(id, $0) } })
    }
}

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
              let voice = ttsVoiceSelection.supertonicVoice,
              !suppressedAutomaticAudioPreparationItemIds.contains(itemId),
              !liveSpeechFallbackItemIds.contains(itemId),
              !startupAudioPreparation.pending.contains(itemId),
              startupAudioPreparationCooldown.canAttempt(Self.startupAudioCooldownKey(itemId, voice)),
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
            let claim = startupAudioPreparation.pending.begin(itemId)
            failedStartupAudioPreparationItemIds.remove(itemId)
            updateLibraryStartupAudioState(itemId: itemId, state: .waiting)
            diagnostics["startupAudioPreparation:\(itemId)"] = "queued"
            let task = Task<Void, Never> { @MainActor [weak self] in
                guard let self else { return }
                await self.enqueueStartupAudioPreparation(itemId: itemId, token: claim.token)
            }
            startupAudioPreparation.pending.attach(task, to: itemId, token: claim.token)
        } catch {
            failedStartupAudioPreparationItemIds.insert(itemId)
            updateLibraryStartupAudioState(itemId: itemId, state: .failed)
            startupAudioPreparationCooldown.recordFailure(Self.startupAudioCooldownKey(itemId, voice))
            diagnostics["startupAudioPreparation:\(itemId)"] = "enqueue_failed:\(error.localizedDescription)"
        }
    }

    private func enqueueStartupAudioPreparation(itemId: String, token: OwnedWorkRegistry<Task<Void, Never>>.Token) async {
        defer { startupAudioPreparation.pending.finish(itemId, token: token) }
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
            if manifest.chunks.count < targetChunkCount {
                // Not ready yet: the queued job is the answer, so later triggers wait instead of re-enqueueing.
                startupAudioPreparationCooldown.recordFailure(Self.startupAudioCooldownKey(itemId, voice))
            } else {
                startupAudioPreparationCooldown.recordSuccess(Self.startupAudioCooldownKey(itemId, voice))
            }
            diagnostics["startupAudioPreparation:\(itemId)"] = manifest.chunks.count < targetChunkCount
                ? "queued_0_of_\(targetChunkCount)" : "ready_from_cache"
            refreshLibraryRowsInBackground()
            startForegroundAudioPreparationIfNeeded()
        } catch where Task.isCancelled {
            // Cancelled by an engine rebuild or a skip: an error thrown on the way out is not a failure of the item.
            diagnostics["startupAudioPreparation:\(itemId)"] = "cancelled"
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
            if let voice = ttsVoiceSelection.supertonicVoice {
                startupAudioPreparationCooldown.recordFailure(Self.startupAudioCooldownKey(itemId, voice))
            }
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
        LibraryRowBuilder.startupAudioPresentation(item: item, manifest: manifest?.summary, job: job, context: startupAudioContext)
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
            manifests: try store.loadPreparedAudioManifestSummaries(), jobs: try store.loadAudioPreparationJobs(),
            activeItemId: activePlaybackItemId)
        try applyAudioPreparationPresentation(presentation, store: store, announceNewCompletions: announceNewCompletions, now: now)
    }

    /// The same refresh from a Library read the caller has just made, so it costs no second pass over the items,
    /// sessions, manifests and jobs (#2507). Call it only with a snapshot read in this same main-actor step: an older one
    /// would list jobs that were since moved or finished.
    func refreshAudioPreparationPresentation(
        from data: LibraryReadSnapshot,
        store: SQLiteSessionStore,
        announceNewCompletions: Bool = false,
        now: Date = Date()
    ) throws {
        let presentation = AudioPreparationPresentation(snapshot: data, activeItemId: activePlaybackItemId)
        try applyAudioPreparationPresentation(presentation, store: store, announceNewCompletions: announceNewCompletions, now: now)
    }

    private func applyAudioPreparationPresentation(
        _ presentation: AudioPreparationPresentation,
        store: SQLiteSessionStore,
        announceNewCompletions: Bool,
        now: Date
    ) throws {
        try store.deleteAudioPreparationJobs(ids: presentation.staleJobIds)
        audioPreparationQueue = presentation.queue
        recentlyPreparedAudio = presentation.recentlyPrepared

        if announceNewCompletions { announcePreparedAudioIfNeeded(now: now) }
    }

    /// Says once that audio finished preparing while the listener was away, from the lists as they stand now.
    func announcePreparedAudioIfNeeded(now: Date = Date()) {
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
            guard let selected = try store.loadAudioPreparationJob(id: id) else { return }
            suppressAudioPreparation(itemId: selected.itemId)
            try store.deleteAudioPreparationJobs(
                ids: try store.loadAudioPreparationJobs(itemId: selected.itemId).map(\.id)
            )
            cancelStartupAudioPreparation(itemIds: [selected.itemId])
            failedStartupAudioPreparationItemIds.remove(selected.itemId)
            startupAudioPreparationCooldown.clear(Self.startupAudioCooldownKeys([selected.itemId]))
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
            cancelStartupAudioPreparation(itemIds: itemIds)
            failedStartupAudioPreparationItemIds.subtract(itemIds)
            startupAudioPreparationCooldown.clear(Self.startupAudioCooldownKeys(itemIds))
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
            libraryAudioLoop.renderPolicy.noteListenerEngaged()
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
              let preparationVoice = PreparationVoice.current(for: ttsVoiceSelection, model: self) else { return }
        do {
            allowAudioPreparation(itemId: item.id)
            libraryAudioLoop.renderPolicy.noteListenerEngaged() // an explicit request ends the post-relaunch hold (#2694)
            failedStartupAudioPreparationItemIds.remove(item.id)
            startupAudioPreparationCooldown.clear(Self.startupAudioCooldownKeys([item.id]))
            let store = try requireStore()
            let support = try applicationSupportDirectory()
            guard preparationVoice.isInstalled() else {
                reportFailure(preparationVoice.notInstalledMessage)
                return
            }
            let signature = try await Task.detached(priority: .utility) {
                try preparationVoice.signature()
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
