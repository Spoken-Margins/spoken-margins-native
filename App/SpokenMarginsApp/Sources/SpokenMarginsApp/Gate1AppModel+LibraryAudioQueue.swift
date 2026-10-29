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
        let automaticAudio = automaticAudioPreparationPolicy
        let automaticEpisodeMaps = automaticEpisodeMapPreparationPolicy
        guard let store else {
            AudioPreparationBackgroundController.shared.submitIfEnabled(OfflinePreparationRecovery.shouldSchedule(
                jobs: [], automaticAudio: automaticAudio, automaticEpisodeMaps: automaticEpisodeMaps))
            return
        }
        // The job table is read off the main actor (#2507); asking iOS a moment later changes nothing.
        Task { @MainActor in
            let jobs = (try? await StoreReader(store).read { try $0.loadAudioPreparationJobs() }) ?? []
            AudioPreparationBackgroundController.shared.submitIfEnabled(OfflinePreparationRecovery.shouldSchedule(
                jobs: jobs, automaticAudio: automaticAudio, automaticEpisodeMaps: automaticEpisodeMaps))
        }
        #endif
    }

    /// Queues or updates `manifest`'s job off the main actor, in line with the queue's edits (#2507).
    @discardableResult
    func configurePreparationJob(
        manifest: PreparedAudioManifest, sourceText: String, store: SQLiteSessionStore,
        request: PreparedAudioEnqueue.Request
    ) async throws -> AudioPreparationJob? {
        try await StoreReader(store).readInOrder(AudioPreparationQueueEdits.orderKey) {
            try PreparedAudioEnqueue.configureJob(manifest: manifest, sourceText: sourceText, repository: $0, request: request)
        }
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
            try await configurePreparationJob(
                manifest: manifest, sourceText: sourceText, store: store,
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

    /// Reads the items, sessions, manifests and jobs off the main actor (#2507), in line behind any queue edit, so the
    /// rows show what the last edit left.
    func refreshAudioPreparationPresentation(announceNewCompletions: Bool = false) async {
        guard let store else { return }
        let activeItemId = activePlaybackItemId
        do {
            let presentation = try await StoreReader(store).readInOrder(AudioPreparationQueueEdits.orderKey) {
                try AudioPreparationPresentation.readDeletingStaleJobs(from: $0, activeItemId: activeItemId)
            }
            audioPreparationQueue = presentation.queue
            recentlyPreparedAudio = presentation.recentlyPrepared
            if announceNewCompletions { announcePreparedAudioIfNeeded() }
        } catch {
            diagnostics["audioPreparationPresentation"] = "failed:\(String(describing: type(of: error)))"
        }
    }

    /// The same refresh from a Library read the caller has just made, so it costs no second pass over the items,
    /// sessions, manifests and jobs (#2507). Call it only with a snapshot read in this same main-actor step: an older one
    /// would list jobs that were since moved or finished.
    func applyAudioPreparationPresentation(
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

    func moveAudioPreparationJobEarlier(id: String) async {
        await moveAudioPreparationJob(id: id, offset: -1)
    }

    func moveAudioPreparationJobLater(id: String) async {
        await moveAudioPreparationJob(id: id, offset: 1)
    }

    func skipAudioPreparationJob(id: String) async {
        // Nothing is queued before the store is open, so there is nothing to edit without one.
        guard let store else { return }
        do {
            // The jobs go first, in one transaction; the item is suppressed once we know which it is. A job the
            // automatic pass adds in that moment for the same item stays queued, and Skip removes it again.
            let skipped = try await StoreReader(store).readInOrder(AudioPreparationQueueEdits.orderKey) {
                try AudioPreparationQueueEdits.skipItem(ofJob: id, in: $0)
            }
            guard let skipped else { return }
            suppressAudioPreparation(itemId: skipped.itemId)
            cancelStartupAudioPreparation(itemIds: [skipped.itemId])
            failedStartupAudioPreparationItemIds.remove(skipped.itemId)
            startupAudioPreparationCooldown.clear(Self.startupAudioCooldownKeys([skipped.itemId]))
            refreshLibraryRowsInBackground(mustPublish: true)
            diagnostics["audioPreparationSuppressed:\(skipped.itemId)"] = "user"
            reportConfirmation("Removed \(skipped.title ?? "this item") from audio preparation.")
        } catch {
            reportFailure(error, context: "Removing the item from audio preparation failed")
        }
    }

    func clearAudioPreparationQueue() async {
        // Nothing is queued before the store is open, so there is nothing to edit without one.
        guard let store else { return }
        do {
            libraryAudioLoop.stopAndInvalidate()
            let cleared = try await StoreReader(store).readInOrder(AudioPreparationQueueEdits.orderKey) {
                try AudioPreparationQueueEdits.clear(in: $0)
            }
            let itemIds = cleared.itemIds
            suppressAudioPreparation(itemIds: itemIds)
            cancelStartupAudioPreparation(itemIds: itemIds)
            failedStartupAudioPreparationItemIds.subtract(itemIds)
            startupAudioPreparationCooldown.clear(Self.startupAudioCooldownKeys(itemIds))
            refreshLibraryRowsInBackground(mustPublish: true)
            diagnostics["audioPreparationQueueCleared"] = "\(cleared.count)"
            reportConfirmation("Cleared \(cleared.count) audio preparation job\(cleared.count == 1 ? "" : "s"). Existing audio and Library items were kept.")
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

    func prioritizeAudioPreparationJob(id: String) async {
        // Nothing is queued before the store is open, so there is nothing to edit without one.
        guard let store else { return }
        do {
            let pinned = try await StoreReader(store).readInOrder(AudioPreparationQueueEdits.orderKey) {
                try AudioPreparationQueueEdits.prioritize(id: id, in: $0)
            }
            guard pinned else { return }
            libraryAudioLoop.renderPolicy.noteListenerEngaged()
            await refreshAudioPreparationPresentation()
            startForegroundAudioPreparationIfNeeded()
        } catch {
            reportFailure(error, context: "Unable to prepare this item next")
        }
    }

    private func moveAudioPreparationJob(id: String, offset: Int) async {
        guard offset == -1 || offset == 1, let store else { return }
        let activeItemId = activePlaybackItemId
        do {
            let moved = try await StoreReader(store).readInOrder(AudioPreparationQueueEdits.orderKey) {
                try AudioPreparationQueueEdits.move(id: id, by: offset, activeItemId: activeItemId, in: $0)
            }
            guard moved else { return }
            await refreshAudioPreparationPresentation()
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
            try await configurePreparationJob(manifest: manifest, sourceText: sourceText, store: store, request: .explicit)
            hangTelemetry.labels.scoped("explicitAudioPreparationQueued") {
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
              let voice = ttsVoiceSelection.supertonicVoice,
              let store else { return } // the queue is filled from Library rows, which come from an open store
        do {
            let support = try applicationSupportDirectory()
            guard let assets = SupertonicAssetResolver.location() else { return }
            let signature = try await Task.detached(priority: .utility) {
                try SupertonicRenderIdentity.make(assets: assets, voice: voice)
            }.value
            let coordinator = requirePreparedAudioCoordinator(store: store, supportDirectory: support)
            currentSupertonicRenderSignature = signature
            let sessions = try await StoreReader(store).read { try $0.loadSessions() }
            let sessionsByItemId = Dictionary(grouping: sessions, by: \.itemId)
            for row in libraryItems where !suppressedAutomaticAudioPreparationItemIds.contains(row.id) {
                // The whole item and its prepared text are decoded off the main actor, one row at a time (#2507).
                let rowId = row.id
                let candidate = try? await StoreReader(store).read { store -> (item: Item, text: String)? in
                    let item = try store.loadItem(id: rowId)
                    guard !LibraryAudioPreparationAdmission.playsItsOwnAudio(item),
                          let text = PreparedSpeechHooks.preparedText(of: item, in: store),
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return (item, text)
                }
                guard let candidate else { continue }
                let (item, text) = candidate
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
                    try await configurePreparationJob(manifest: manifest, sourceText: text, store: store,
                                                      request: .automatic(requestedAt: item.createdAt))
                } catch PreparedAudioEnqueue.Rejection.staleSource { continue }
            }
            await refreshAudioPreparationPresentation()
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
