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

private struct ResolvedSkimPlaybackPlan {
    let direction: SkimDirection
    let itemId: String
    let originMediaTimeMs: Int
    let summarySceneId: String
    let destinationSceneId: String?
    let destinationMediaTimeMs: Int
    let summaryAssetId: String
    let summaryAudioURL: URL
}

struct SkimResourceContext {
    let itemId: String
    let projection: ResolvedListeningMapProjection?
    let proposal: PortableListeningMapProposalArtifact?
    let assets: [OwnedOfflineAsset]
}

enum SummaryBridgeRatePolicy {
    // Keep pronunciation independent of listening speed. Version generated assets
    // so summaries synthesized with the former accelerated policy are not reused.
    static let synthesisSpeed: Float = 1
    static let systemSynthesisRate: Float = 0.5
    static let cacheVersion = "natural-rate-v2"
    static func transportRate(_ listeningRate: Double) -> Float { Float(listeningRate) }
}


typealias PreparedTextAudioPrewarmHandler = @Sendable (
    _ itemId: String,
    _ title: String,
    _ text: String,
    _ outputDirectory: URL,
    _ voiceIdentifier: String?,
    _ speechRate: Float
) async -> Result<PreparedTextAudio?, Error>

private enum ManualListeningMapError: Error, CustomStringConvertible {
    case empty
    case invalidUTF8
    case rootMustBeObject
    case invalidSchema
    case missingOverview
    case missingChapters
    case itemHasNoText
    case missingChapterId
    case duplicateChapterId(String)
    case missingChapterTitle(String)
    case missingChapterDescription(String)
    case missingChapterAnchor(String)
    case anchorNotFound(String)
    case invalidChapterRange(String)
    case jsonParseFailed(String)

    var description: String {
        switch self {
        case .empty:
            return "manual_map_empty"
        case .invalidUTF8:
            return "manual_map_invalid_utf8"
        case .rootMustBeObject:
            return "manual_map_root_must_be_object"
        case .invalidSchema:
            return "manual_map_schemaVersion_must_be_listening-map.v1"
        case .missingOverview:
            return "manual_map_missing_overview"
        case .missingChapters:
            return "manual_map_missing_chapters"
        case .itemHasNoText:
            return "manual_map_item_has_no_text"
        case .missingChapterId:
            return "manual_map_missing_chapter_id"
        case .duplicateChapterId(let id):
            return "manual_map_duplicate_chapter_id:\(id)"
        case .missingChapterTitle(let id):
            return "manual_map_missing_chapter_title:\(id)"
        case .missingChapterDescription(let id):
            return "manual_map_missing_chapter_description:\(id)"
        case .missingChapterAnchor(let id):
            return "manual_map_missing_chapter_anchor:\(id)"
        case .anchorNotFound(let id):
            return "manual_map_anchor_not_found:\(id)"
        case .invalidChapterRange(let id):
            return "manual_map_invalid_chapter_range:\(id)"
        case .jsonParseFailed(let error):
            return "manual_map_json_parse_failed:\(error)"
        }
    }
}

private final class UnavailableSpeechPlaybackClient: AudioPlaybackClient, @unchecked Sendable {
    private let reason: String
    private var failedTargetId: String?

    init(reason: String) {
        self.reason = reason
    }

    func prepareSpeechText(_ text: String) throws -> String {
        SpeechTextNormalizer.normalize(text)
    }

    func play(targetId: String) throws {
        try fail(targetId: targetId)
    }

    func play(targetId: String, from charOffset: Int) throws {
        try fail(targetId: targetId)
    }

    func pause() throws {}

    func stop() throws {}

    func playbackStartStatus(targetId: String) -> PlaybackStartStatus {
        failedTargetId == targetId ? .failed(reason) : .confirmed
    }

    private func fail(targetId: String) throws {
        failedTargetId = targetId
        throw SessionKitError.invalidCommandForState(reason)
    }
}

extension Gate1AppModel {
    var activePlaybackIsPlaying: Bool {
        if playingImportedCommentary != nil { return !importedCommentaryIsPaused }
        if marginMomentConductor?.isPlayingVoice == true { return !marginMomentVoiceIsPaused }
        return snapshot.skimBridgeState?.status == .playing || snapshot.status.isPlaybackActive
    }

    var selectedPodcastDownloadState: PodcastDownloadState? {
        if let state = podcastDownloadRecords[selectedItem.id]?.state { return state }
        if let item = try? store?.loadItem(id: selectedItem.id), item.media?.sourceType == .remoteStream { return .streamingOnly }
        return nil
    }

    var selectedPodcastDownloadDescription: String? {
        guard let record = podcastDownloadRecords[selectedItem.id] else { return nil }
        if record.state == .downloading, let progress = record.progress {
            return "Downloading \(Int((progress * 100).rounded()))%"
        }
        if record.state == .failed, let reason = record.failureReason {
            return "Failed: \(reason)"
        }
        switch record.state {
        case .availableOffline:
            return "Downloaded for offline playback"
        case .waitingForWiFi:
            return "Waiting for Wi-Fi · Download Now can force it"
        case .streamingOnly:
            return "Online only · Download Now saves it in the app"
        case .downloading:
            return "Downloading"
        case .failed:
            return "Download failed"
        case .evicted:
            return "Download was removed to free space"
        }
    }

    func reconcilePlaybackProgressTicker() {
        if snapshot.status.isPlaybackActive {
            startPlaybackProgressTicker()
        } else {
            stopPlaybackProgressTicker()
        }
    }

    private func startPlaybackProgressTicker() {
        guard playbackProgressTask == nil else { return }
        playbackProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run {
                    guard let self else { return }
                    guard self.snapshot.status.isPlaybackActive else {
                        self.stopPlaybackProgressTicker()
                        return
                    }
                    guard let engine = self.engine else { return }
                    do {
                        self.synchronizeStreamingSpeechAnchorIfNeeded()
                        let previousSnapshot = self.snapshot
                        let previousStatus = self.snapshot.status
                        let previousTargetId = self.snapshot.targetId
                        let previousEngagementProgress = self.snapshot.currentPlaybackProgressPercent
                        let updated = self.snapshotReflectingTextAudioPrewarmStatus(
                            try engine.syncPlaybackProgress(),
                            itemId: self.activeItemId
                        )
                        self.recordMediaSeekEvidence(from: engine)
                        let completedCurrentAudio = previousStatus.isPlaybackActive &&
                            updated.status == .paused &&
                            previousTargetId == updated.targetId &&
                            updated.currentPlaybackProgressPercent >= 100
                        if updated != self.snapshot {
                            self.snapshot = updated
                        }
                        if previousEngagementProgress < 25,
                           updated.currentPlaybackProgressPercent >= 25,
                           let itemId = updated.itemId,
                           let store = self.store {
                            self.offerFollowSuggestionIfEligible(itemId: itemId, store: store)
                        }
                        self.reconcileImportedCommentary(previous: previousSnapshot, current: updated)
                        self.observeMarginMoment(updated)
                        let playedPendingTurn = self.playPendingTurnIfReady(completedCurrentAudio: completedCurrentAudio)
                        if completedCurrentAudio && !playedPendingTurn {
                            self.closeCompletedSessionIfReady()
                        }
                    } catch {
                        self.diagnostics["playbackProgressSyncError"] = String(describing: error)
                    }
                }
            }
        }
    }

    private func stopPlaybackProgressTicker() {
        playbackProgressTask?.cancel()
        playbackProgressTask = nil
    }

    func syncPlaybackProgressForLifecycle() {
        guard snapshot.status.isPlaybackActive, let engine else { return }
        do {
            synchronizeStreamingSpeechAnchorIfNeeded()
            let previousStatus = snapshot.status
            let previousTargetId = snapshot.targetId
            let updated = snapshotReflectingTextAudioPrewarmStatus(
                try engine.syncPlaybackProgress(),
                itemId: activeItemId
            )
            recordMediaSeekEvidence(from: engine)
            let completedCurrentAudio = previousStatus.isPlaybackActive &&
                updated.status == .paused &&
                previousTargetId == updated.targetId &&
                updated.currentPlaybackProgressPercent >= 100
            if updated != snapshot {
                snapshot = updated
            }
            let playedPendingTurn = playPendingTurnIfReady(completedCurrentAudio: completedCurrentAudio)
            if completedCurrentAudio && !playedPendingTurn {
                closeCompletedSessionIfReady()
            }
            refreshSelectedItem()
            diagnostics["playbackLifecycleSync"] = "saved"
        } catch {
            diagnostics["playbackLifecycleSyncError"] = String(describing: error)
        }
    }

    func refreshLockScreenSurfacesForLifecycle() {
        gate2CompactControls.reconcileLiveActivities()
        diagnostics["lockScreenLifecycleRefresh"] = snapshot.targetType ?? "none"
    }

    func handleAppBecameInactiveOrBackground() {
        marginNotesDelivery.finishBeforeBackground(); readwiseHighlightSync.stop()
        supertonicRenderer?.setBackgroundInferencePacingEnabled(true)
        if snapshot.status == .starting,
           let supertonic = speechPlaybackClient as? SupertonicSpeechPlaybackClient,
           supertonic.ensurePlaybackStartsBeforeBackgrounding() {
            diagnostics["textAudioBackgroundStartup"] = "system_fallback_started"
        }
        syncPlaybackProgressForLifecycle()
        refreshLockScreenSurfacesForLifecycle()
        scheduleAutomaticAudioPreparationIfNeeded()
    }

    private func reflectTextAudioPrewarmStatusIfActive(itemId: String) {
        let updated = snapshotReflectingTextAudioPrewarmStatus(snapshot, itemId: itemId)
        guard updated != snapshot else { return }
        snapshot = updated
    }

    private func snapshotReflectingTextAudioPrewarmStatus(_ snapshot: SessionSnapshot, itemId: String) -> SessionSnapshot {
        guard textAudioPrewarmTasks[itemId] != nil else { return snapshot }
        guard snapshot.preparedTextAudioStatus == nil || snapshot.preparedTextAudioStatus == "live_fallback" else { return snapshot }
        var updated = snapshot
        updated.preparedTextAudioStatus = "rendering"
        return updated
    }

    func handleAppBecameActive() {
        openReadyListeningEdition()
        marginNotesDelivery.start(); readwiseHighlightSync.start { [weak self] in self?.store }
        supertonicRenderer?.setBackgroundInferencePacingEnabled(false)
        let refreshedAvailability = localFoundationModelClient.availability()
        if refreshedAvailability != localFoundationModelAvailability {
            localFoundationModelAvailability = refreshedAvailability
            diagnostics["localFoundationModelAvailability"] = refreshedAvailability.description
            _ = rebuildEngineForCurrentSettings()
        }
        syncPlaybackProgressForLifecycle()
        gate2CompactControls.reconcileLiveActivities()
        importPendingSourceLinkHandoffs()
        if let store {
            try? refreshLibraryRows(store: store)
            try? refreshAudioPreparationPresentation(store: store, announceNewCompletions: true)
        }
        scheduleAutomaticAudioPreparationIfNeeded()
        submitAutomaticEpisodeMapPreparationIfNeeded()
        refreshQuickAddFeed(force: false)
    }

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

    func offlineStorageBudgetChanged() {
        guard OfflineStorageBudget.allowedGigabytes.contains(offlineStorageLimitGB) else {
            offlineStorageLimitGB = 5
            return
        }
        UserDefaults.standard.set(offlineStorageLimitGB, forKey: "offlineStorageLimitGB")
        podcastCacheLimitGB = offlineStorageLimitGB
        Task { [weak self] in
            guard let self else { return }
            do {
                let store = try self.requireStore()
                try store.saveOfflineStorageBudget(OfflineStorageBudget(
                    limitBytes: Int64(self.offlineStorageLimitGB) * OfflineStorageBudget.bytesPerGigabyte
                ))
                _ = try await self.offlineStorageLedger?.enforceBudget()
                self.tryRefreshOfflineStorageUsage()
            } catch {
                self.reportFailure(error, context: "Offline storage budget update failed")
            }
        }
    }

    func clearReproducibleOfflineAudio() {
        guard let ledger = offlineStorageLedger else { return }
        Task { [weak self, renderedSpeechDiskCache = self.renderedSpeechDiskCache] in
            do {
                let bytes = try await ledger.clearReproducibleAudio(renderedSpeechCache: renderedSpeechDiskCache)
                await MainActor.run {
                    self?.reportConfirmation("Cleared \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of reproducible offline audio.")
                    self?.tryRefreshOfflineStorageUsage()
                }
            } catch {
                await MainActor.run { self?.reportFailure(error, context: "Offline audio clear failed") }
            }
        }
    }

    func tryRefreshOfflineStorageUsage() {
        guard let ledger = offlineStorageLedger else { return }
        Task { [weak self] in
            guard let snapshot = try? await ledger.presentationSnapshot() else { return }
            await MainActor.run {
                self?.offlineStorageSnapshot = snapshot
                let base = "\(ByteCountFormatter.string(fromByteCount: snapshot.usedBytes, countStyle: .decimal)) of \(ByteCountFormatter.string(fromByteCount: snapshot.budgetBytes, countStyle: .decimal)) used · \(ByteCountFormatter.string(fromByteCount: snapshot.protectedBytes, countStyle: .decimal)) protected"
                self?.offlineStorageUsageDescription = snapshot.currentOverageBytes > 0
                    ? "\(base) · \(ByteCountFormatter.string(fromByteCount: snapshot.currentOverageBytes, countStyle: .decimal)) over budget"
                    : base
            }
        }
    }

    func scheduleAutomaticAudioPreparationIfNeeded() {
        #if canImport(BackgroundTasks) && canImport(UIKit)
        let enabled = automaticAudioPreparationPolicy == .whileCharging
        Task { [weak self] in
            if enabled { await self?.enqueueAutomaticAudioPreparationJobs() }
            AudioPreparationBackgroundController.shared.submitIfEnabled(
                enabled || self?.automaticEpisodeMapPreparationPolicy == .whileCharging
            )
        }
        #endif
    }

    func performBackgroundPreparationPass() async -> BackgroundPreparationWorkResult {
        guard let store else { return .finished }
        let progressBefore = backgroundPreparationProgressToken(store: store)
        let episodeJobs = ((try? store.loadEpisodeMapPreparationJobs()) ?? [])
            .filter {
                !$0.isCancelled
                    && $0.stage != .completed
                    && ($0.policy == .explicit || automaticEpisodeMapPreparationPolicy == .whileCharging)
                    && podcastDownloadCoordinator?.validatedLocalURL(for: $0.itemId) != nil
            }
            .sorted {
                if $0.policy != $1.policy { return $0.policy == .explicit }
                return $0.requestedAt < $1.requestedAt
            }
        let hasAudioWork = ((try? store.loadAudioPreparationJobs()) ?? []).contains { !$0.isCancelled }
        let shouldRunEpisode = !episodeJobs.isEmpty
            && (!hasAudioWork || backgroundPreparationPrefersEpisodeMap)
        if shouldRunEpisode,
           episodeMapPreparationTask == nil,
           ProcessInfo.processInfo.thermalState != .serious,
           ProcessInfo.processInfo.thermalState != .critical,
           !ProcessInfo.processInfo.isLowPowerModeEnabled,
           let job = episodeJobs.first {
            prepareEpisodeMap(itemId: job.itemId, policy: job.policy)
            if let task = episodeMapPreparationTask {
                await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    task.cancel()
                }
            }
            backgroundPreparationPrefersEpisodeMap = false
            let hasEpisodeWork = ((try? store.loadEpisodeMapPreparationJobs()) ?? []).contains {
                !$0.isCancelled && $0.stage != .completed
            }
            return backgroundPreparationResult(
                hasRemainingWork: hasEpisodeWork || hasAudioWork,
                progressBefore: progressBefore,
                store: store
            )
        }
        let audioHasMore = await performBackgroundAudioPreparationPass()
        if hasAudioWork { backgroundPreparationPrefersEpisodeMap = true }
        if audioHasMore {
            return backgroundPreparationResult(
                hasRemainingWork: true,
                progressBefore: progressBefore,
                store: store
            )
        }
        if !episodeJobs.isEmpty {
            backgroundPreparationPrefersEpisodeMap = true
            return backgroundPreparationResult(
                hasRemainingWork: true,
                progressBefore: progressBefore,
                store: store
            )
        }
        return .finished
    }

    private func backgroundPreparationResult(
        hasRemainingWork: Bool,
        progressBefore: [String],
        store: SQLiteSessionStore
    ) -> BackgroundPreparationWorkResult {
        guard hasRemainingWork else { return .finished }
        return backgroundPreparationProgressToken(store: store) == progressBefore
            ? .retryLater
            : .continueNow
    }

    private func backgroundPreparationProgressToken(store: SQLiteSessionStore) -> [String] {
        let audio = ((try? store.loadAudioPreparationJobs()) ?? [])
            .filter { !$0.isCancelled }
            .map { "audio:\($0.id):\($0.nextChunkIndex)" }
        let episode = ((try? store.loadEpisodeMapPreparationJobs()) ?? [])
            .filter { !$0.isCancelled && $0.stage != .completed }
            .map { "episode:\($0.id):\($0.stage.rawValue):\($0.nextUnitIndex)" }
        return (audio + episode).sorted()
    }

    func handleApplicationWillTerminate() {
        stopImportedCommentaryPlayback(resumeSource: false)
        cancelSkimBridge(restoringOrigin: true, resumeSource: false)
        syncPlaybackProgressForLifecycle()
        endTextPlaybackStartupBackgroundTask()
        gate2CompactControls.endLiveActivities()
    }

    func handleMemoryWarning() {
        Self.preparationPlanCache.removeAll()
        activePlaybackDetail = nil
        SupertonicResourcePolicy.memoryBackoff.recordWarning()
        // Cancel demand before unloading: otherwise the next chunk can reload
        // the same sessions immediately after the warning.
        foregroundAudioPreparationTask?.cancel()
        if let client = speechPlaybackClient as? SupertonicSpeechPlaybackClient {
            do {
                if try client.stopOnDeviceRenderingAndUseSystemSpeech(returnsAutomatically: true) {
                    speechFallbackReason = .memoryWarning
                    let message = SpeechFallbackReason.memoryWarning.listenerExplanation
                    statusMessage = message
                    presentFeedback(UserFeedbackEvent(kind: .warning, message: message))
                }
            } catch {
                reportFailure(error, context: "Memory-pressure voice recovery failed")
            }
        }
        diagnostics["supertonicMemoryPressure"] = "sessions_unloaded"
        if let renderer = supertonicRenderer {
            Task { await renderer.unload(removingGeneratedAudio: false) }
        }
    }

    func start() {
        guard !requireTermsDecisionBeforePlayback(.startCurrentItem) else { return }
        if !hasActiveSession {
            resetMixWithOtherAudioForNewSession()
        }
        stopSpeechPreviews()
        streamingSpeechQueue.stopAndClear()
        scheduleTextAudioPrewarmIfNeeded(itemId: activeItemId)
        beginTextPlaybackStartupBackgroundTaskIfNeeded(itemId: activeItemId)
        run { engine in
            try prepareSourceMediaPlayback(itemId: activeItemId)
            let started = try engine.startSession(itemId: activeItemId)
            snapshot = try applyPreferredPlaybackRate(to: started, engine: engine)
            if let store, let sessionId = snapshot.sessionId {
                try seedUITestingSummaryInterjectionIfNeeded(sessionId: sessionId, engine: engine, store: store)
                try seedUITestingGeneratedTimelineIfNeeded(sessionId: sessionId, engine: engine, store: store)
            }
            if let store {
                selectedItem = try loadItemDetail(id: activeItemId, store: store)
                try refreshLibraryRows(store: store)
            }
            reflectTextAudioPrewarmStatusIfActive(itemId: activeItemId)
            screen = .playback
            reportSuccess("Started \(snapshot.title ?? "session").")
        }
        reconcileTextPlaybackStartupBackgroundTask()
    }

    private func beginTextPlaybackStartupBackgroundTaskIfNeeded(itemId: String) {
        #if canImport(UIKit) && os(iOS)
        guard textPlaybackStartupBackgroundTask == .invalid,
              ttsVoiceSelection.supertonicVoice != nil,
              let item = try? store?.loadItem(id: itemId),
              item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        textPlaybackStartupBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Start native text audio"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.diagnostics["textAudioBackgroundStartup"] = "expired"
                self?.endTextPlaybackStartupBackgroundTask()
            }
        }
        diagnostics["textAudioBackgroundStartup"] = textPlaybackStartupBackgroundTask == .invalid
            ? "unavailable"
            : "protected"
        #endif
    }

    func reconcileTextPlaybackStartupBackgroundTask() {
        guard snapshot.status != .starting else { return }
        endTextPlaybackStartupBackgroundTask()
    }

    private func endTextPlaybackStartupBackgroundTask() {
        #if canImport(UIKit) && os(iOS)
        guard textPlaybackStartupBackgroundTask != .invalid else { return }
        let identifier = textPlaybackStartupBackgroundTask
        textPlaybackStartupBackgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
        if diagnostics["textAudioBackgroundStartup"] != "expired" {
            diagnostics["textAudioBackgroundStartup"] = "completed"
        }
        #endif
    }

    func playPause() {
        if playingImportedCommentary != nil {
            setImportedCommentaryPaused(!importedCommentaryIsPaused)
            return
        }
        if let conductor = marginMomentConductor, conductor.isPlayingVoice {
            conductor.setVoicePaused(!conductor.isVoicePaused)
            return
        }
        if snapshot.phase == .finished, let itemID = snapshot.itemId {
            startNewSession(id: itemID)
            return
        }
        if let bridge = snapshot.skimBridgeState {
            setSkimBridgePaused(bridge.status == .playing)
            return
        }
        if snapshot.status.isPlaybackActive {
            pause()
        } else if hasActiveSession {
            resumePlayback()
        } else {
            start()
        }
    }

    func pause() {
        if playingImportedCommentary != nil {
            setImportedCommentaryPaused(true)
            return
        }
        if let conductor = marginMomentConductor, conductor.isPlayingVoice, !conductor.isVoicePaused {
            conductor.setVoicePaused(true)
            return
        }
        if snapshot.skimBridgeState != nil {
            setSkimBridgePaused(true)
            return
        }
        synchronizeStreamingSpeechAnchorIfNeeded()
        run { engine in
            snapshot = try engine.pause()
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            refreshSelectedItem()
            reportSuccess("Paused.")
        }
    }

    var sleepTimerIsActive: Bool {
        if case .inactive = sleepTimerState { return false }
        return true
    }

    var sleepTimerDescription: String {
        switch sleepTimerState {
        case .inactive: return "Sleep Timer"
        case .armed(let mode, _, _):
            if mode == .endOfChapter { return "End of Chapter" }
            guard let seconds = sleepTimerRemainingSeconds else { return "Sleep Timer" }
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .expiryDeferred: return "Pauses after recording"
        }
    }

    var canUseEndOfChapterSleepTimer: Bool {
        endOfChapterTarget() != nil
    }

    func armSleepTimer(_ mode: SleepTimerMode) {
        let deadline: Date?
        let chapterId: String?
        switch mode {
        case .minutes15: deadline = Date().addingTimeInterval(15 * 60); chapterId = nil
        case .minutes30: deadline = Date().addingTimeInterval(30 * 60); chapterId = nil
        case .minutes45: deadline = Date().addingTimeInterval(45 * 60); chapterId = nil
        case .minutes60: deadline = Date().addingTimeInterval(60 * 60); chapterId = nil
        case .endOfChapter:
            guard let target = endOfChapterTarget() else { return }
            deadline = nil
            chapterId = target.chapterId
        }
        sleepTimerState = .armed(mode: mode, deadline: deadline, chapterId: chapterId)
        startSleepTimerTicker()
        reconcileSleepTimer(now: Date())
    }

    func extendSleepTimerBy15Minutes() {
        let now = Date()
        let deadline: Date
        switch sleepTimerState {
        case .armed(_, let current?, _): deadline = max(current, now).addingTimeInterval(15 * 60)
        case .expiryDeferred: deadline = now.addingTimeInterval(15 * 60)
        case .inactive, .armed(_, nil, _): deadline = now.addingTimeInterval(15 * 60)
        }
        sleepTimerState = .armed(mode: .minutes15, deadline: deadline, chapterId: nil)
        startSleepTimerTicker()
        reconcileSleepTimer(now: now)
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerState = .inactive
        sleepTimerRemainingSeconds = nil
    }

    private func startSleepTimerTicker() {
        sleepTimerTask?.cancel()
        sleepTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.reconcileSleepTimer(now: Date())
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func reconcileSleepTimer(now: Date) {
        switch sleepTimerState {
        case .inactive:
            sleepTimerRemainingSeconds = nil
        case .expiryDeferred(let mode):
            sleepTimerRemainingSeconds = 0
            if !snapshot.isRecording { expireSleepTimer(mode: mode) }
        case .armed(let mode, let deadline, let chapterId):
            if let deadline {
                let remaining = max(0, Int(ceil(deadline.timeIntervalSince(now))))
                sleepTimerRemainingSeconds = remaining
                if remaining == 0 { requestSleepTimerExpiry(mode: mode) }
            } else if mode == .endOfChapter,
                      let target = endOfChapterTarget(chapterId: chapterId),
                      (snapshot.currentMediaTimeMs ?? 0) >= target.endMs {
                requestSleepTimerExpiry(mode: mode)
            }
        }
    }

    private func requestSleepTimerExpiry(mode: SleepTimerMode) {
        if snapshot.isRecording {
            sleepTimerState = .expiryDeferred(mode: mode)
        } else {
            expireSleepTimer(mode: mode)
        }
    }

    private func expireSleepTimer(mode: SleepTimerMode) {
        if snapshot.status.isPlaybackActive { pause() }
        cancelSleepTimer()
        reportConfirmation(mode == .endOfChapter ? "Paused at the end of the chapter." : "Sleep timer paused playback.")
    }

    private func endOfChapterTarget(chapterId: String? = nil) -> (chapterId: String, endMs: Int)? {
        let chapters = selectedItem.mediaChapters.sorted { $0.startMs < $1.startMs }
        guard chapters.count > 1 else { return nil }
        let currentMs = snapshot.currentMediaTimeMs ?? 0
        let index: Int
        if let chapterId, let exact = chapters.firstIndex(where: { $0.id == chapterId }) { index = exact }
        else { index = chapters.lastIndex(where: { $0.startMs <= currentMs }) ?? 0 }
        guard chapters.indices.contains(index + 1) else { return nil }
        return (chapters[index].id, chapters[index + 1].startMs)
    }

    func stopOnDeviceSpeechGeneration() {
        guard let client = speechPlaybackClient as? SupertonicSpeechPlaybackClient else {
            reportFailure("On-device voice generation is not active for this playback.")
            return
        }
        do {
            if snapshot.status.isPlaybackActive, let engine {
                snapshot = snapshotReflectingTextAudioPrewarmStatus(
                    try engine.syncPlaybackProgress(),
                    itemId: activeItemId
                )
            }
            guard try client.stopOnDeviceRenderingAndUseSystemSpeech() else {
                reportFailure("There is no active Supertonic generation to stop.")
                return
            }
            speechFallbackReason = .listenerStoppedGeneration
            suppressAudioPreparation(itemId: activeItemId)
            if let coordinator = preparedAudioCoordinator,
               let signature = currentSupertonicRenderSignature {
                let itemId = activeItemId
                Task {
                    try? await coordinator.stop(itemId: itemId, signature: signature)
                }
            }
            if let engine {
                snapshot = snapshotReflectingTextAudioPrewarmStatus(
                    try engine.syncPlaybackProgress(),
                    itemId: activeItemId
                )
                refreshSelectedItem()
            }
            onDeviceSpeechGenerationStatus = RenderedSpeechGenerationState.stopped.rawValue
            onDeviceSpeechGenerationDelayTask?.cancel()
            onDeviceSpeechGenerationDelayTask = nil
            isOnDeviceSpeechGenerationDelayed = false
            diagnostics["onDeviceSpeechGeneration"] = "stopped_by_user"
            reportConfirmation("Stopped on-device voice generation. Playback is continuing with the iOS system voice.")
        } catch {
            reportFailure(error, context: "Stop on-device voice generation failed")
        }
    }

    func resumePlayback() {
        if playingImportedCommentary != nil {
            setImportedCommentaryPaused(false)
            return
        }
        if let conductor = marginMomentConductor, conductor.isVoicePaused {
            conductor.setVoicePaused(false)
            return
        }
        if snapshot.skimBridgeState != nil {
            setSkimBridgePaused(false)
            return
        }
        guard let sessionId = snapshot.sessionId else {
            reportFailure("There is no listening session to resume.")
            return
        }
        guard !requireTermsDecisionBeforePlayback(.resumeSession(sessionId)) else { return }
        stopSpeechPreviews()
        streamingSpeechQueue.relinquishToCanonicalPlayback()
        run { engine in
            snapshot = try engine.resumePlayback()
            refreshSelectedItem()
            reportSuccess("Resumed.")
        }
    }

    func generateListeningMap() {
        guard !isGeneratingListeningMap else { return }
        guard selectedItem.chapters.isEmpty, selectedItem.mediaChapters.isEmpty else {
            reportSuccess("This item already has a Listening Map.")
            return
        }
        isGeneratingListeningMap = true
        let selectedItemRecord = try? store?.loadItem(id: activeItemId)
        if let item = selectedItemRecord,
           item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream {
            isGeneratingListeningMap = false
            prepareEpisodeMap(itemId: item.id, policy: .explicit)
            return
        }
        if !remoteProviderExperienceEnabled {
            guard selectedItemRecord?.media == nil else {
                diagnostics["lastListeningMapMode"] = "on_device_generation_disabled"
                isGeneratingListeningMap = false
                reportFailure("Publisher chapters appear when available. AI-generated podcast maps are reserved for a future server-hosted option.")
                return
            }
            generateLocalListeningMap()
            isGeneratingListeningMap = false
            return
        }
        if let item = selectedItemRecord,
           item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
            item.media?.url != nil {
            if sourceTranscriptStatus == "transcribing" || sourceTranscriptStatus == "queued" || sourceTranscriptStatus == "downloading" {
                pendingMapGenerationItemId = item.id
                isGeneratingListeningMap = false
                reportSuccess("Preparing the podcast transcript. Listening Map generation will continue when it is ready.")
                return
            }
            pendingMapGenerationItemId = item.id
            isGeneratingListeningMap = false
            scheduleFullSourceTranscriptionForListeningMap(for: item)
            reportSuccess("Preparing the podcast transcript for its Listening Map. Playback remains available.")
            return
        }
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            run { engine in
                snapshot = try engine.generateListeningMap(itemId: activeItemId)
                if let store {
                    libraryItems = try loadLibraryRows(store: store)
                }
                refreshSelectedItem()
                diagnostics["lastGeneratedMapItem"] = activeItemId
                diagnostics["lastListeningMapMode"] = "local_deterministic"
                scheduleTextAudioPrewarmIfNeeded(itemId: activeItemId)
                reportConfirmation("Generated local Listening Map.")
            }
            isGeneratingListeningMap = false
            return
        }

        guard aiDataSharingConsent == .grantedV1 else {
            pendingMapGenerationAfterConsent = true
            isGeneratingListeningMap = false
            isAIDataSharingConsentPresented = true
            reportSuccess("Review how live AI uses this source before continuing.")
            return
        }

        statusMessage = "Calling \(modelForAIJob(kind: "listening_map")) for Listening Map."
        lastError = nil
        Task {
            await generateProviderListeningMap()
        }
    }

    private func generateProviderListeningMap() async {
        defer { isGeneratingListeningMap = false }
        do {
            let store = try requireStore()
            var item = try store.loadItem(id: activeItemId)
            guard let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManualListeningMapError.itemHasNoText
            }
            let model = modelForAIJob(kind: "listening_map")
            diagnostics["lastListeningMapModel"] = model
            let firstPrompt = listeningMapPrompt(sourceText: text)
            let firstResponse = try await callProvider(messages: [firstPrompt], model: model, systemPrompt: systemPromptForAIJob(kind: "listening_map"))
            do {
                try saveProviderListeningMapResponse(firstResponse, item: &item, store: store)
                diagnostics["lastListeningMapRepairAttempt"] = "0"
                reportConfirmation("Generated Listening Map with \(model).")
            } catch {
                let repairPrompt = listeningMapRepairPrompt(sourceText: text, invalidResponse: firstResponse, error: String(describing: error))
                let repairedResponse = try await callProvider(messages: [repairPrompt], model: model, systemPrompt: systemPromptForAIJob(kind: "listening_map"))
                try saveProviderListeningMapResponse(repairedResponse, item: &item, store: store)
                diagnostics["lastListeningMapRepairAttempt"] = "1"
                diagnostics["lastListeningMapInitialError"] = String(describing: error)
                reportConfirmation("Generated repaired Listening Map with \(model).")
            }
        } catch {
            reportFailure(error, context: "Listening Map generation failed")
        }
    }

    private func saveProviderListeningMapResponse(_ response: String, item: inout Item, store: SQLiteSessionStore) throws {
        let map = try parseListeningMapJSON(response, item: item)
        if let engine {
            snapshot = try engine.attachListeningMap(map)
        } else {
            try store.saveListeningMap(map)
        }
        item.status = "ready"
        try store.saveItem(item)
        libraryItems = try loadLibraryRows(store: store)
        selectedItem = try loadItemDetail(id: item.id, store: store)
        diagnostics["lastGeneratedMapItem"] = item.id
        diagnostics["lastListeningMapMode"] = "provider"
        scheduleTextAudioPrewarmIfNeeded(itemId: item.id)
    }

    private func generateLocalListeningMap() {
        run { engine in
            snapshot = try engine.generateListeningMap(itemId: activeItemId)
            if let store {
                libraryItems = try loadLibraryRows(store: store)
            }
            refreshSelectedItem()
            diagnostics["lastGeneratedMapItem"] = activeItemId
            diagnostics["lastListeningMapMode"] = "local_deterministic"
            scheduleTextAudioPrewarmIfNeeded(itemId: activeItemId)
            reportConfirmation("Generated Listening Map.")
        }
    }

    func prepareEpisodeMap(itemId: String? = nil, policy: PreparationJobPolicy = .explicit) {
        let requestedItemId = itemId ?? activeItemId
        guard episodeMapPreparationTask == nil else {
            reportWarning("An episode map is already being prepared.")
            return
        }
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: requestedItemId)
            guard item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream else {
                throw SessionKitError.invalidCommandForState("episode_map_requires_native_audio")
            }
            let existingJob = (try store.loadEpisodeMapPreparationJobs()).first {
                $0.itemId == requestedItemId && !$0.isCancelled
            }
            var job = existingJob ?? EpisodeMapPreparationJob(
                id: "episode-map-job-\(safePodcastEvidenceComponent(requestedItemId))",
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

            guard let localURL = podcastDownloadCoordinator?.validatedLocalURL(for: requestedItemId)
                ?? item.media?.url.flatMap(URL.init(string:)).flatMap({ $0.isFileURL ? $0 : nil }) else {
                pendingMapGenerationItemId = requestedItemId
                episodeMapPreparationStatus = "Waiting for download"
                diagnostics["episodeMapPreparation:\(requestedItemId)"] = "waiting_for_local_audio"
                if podcastDownloadCoordinator?.downloadNow(itemId: requestedItemId) != true,
                   let remote = item.media?.url.flatMap(URL.init(string:)) {
                    podcastDownloadCoordinator?.register(
                        itemId: requestedItemId,
                        remoteURL: remote,
                        userInitiated: policy == .explicit
                    )
                }
                if policy == .explicit {
                    reportSuccess("Downloading the episode. Its private Listening Map will continue automatically.")
                }
                return
            }
            runEpisodeMapPreparation(item: item, localURL: localURL, job: job)
        } catch {
            episodeMapPreparationStatus = "Failed"
            reportFailure(error, context: "Episode map preparation failed")
        }
    }

    private func runEpisodeMapPreparation(
        item: Item,
        localURL: URL,
        job initialJob: EpisodeMapPreparationJob
    ) {
        episodeMapPreparationStatus = "Preparing"
        diagnostics["episodeMapPreparation:\(item.id)"] = "started"
        episodeMapPreparationItemId = item.id
        episodeMapPreparationTask = Task { [weak self] in
            guard let self else { return }
            var job = initialJob
            defer {
                self.episodeMapPreparationTask = nil
                self.episodeMapPreparationItemId = nil
            }
            do {
                let store = try self.requireStore()
                job.stage = .generateFingerprintSpine
                try store.saveEpisodeMapPreparationJob(job)
                let mapDirectory = try self.episodeMapDirectory(itemId: item.id)
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
                var generatedLandmarks: [EpisodeFingerprintLandmark] = []
                var gridIndex = 0
                var startMs = SparseFingerprintSchedule.initialMediaTimeMs
                while gridIndex < job.nextUnitIndex,
                      startMs + PodcastAnchorEvidenceGenerator.minimumEvidenceDurationMs <= durationMs {
                    let assetID = "episode-signature-\(self.safePodcastEvidenceComponent(item.id))-downloaded-\(gridIndex)"
                    let existingURL = mapDirectory.appending(path: "\(assetID).shazamsignature")
                    guard FileManager.default.fileExists(atPath: existingURL.path) else {
                        job.nextUnitIndex = gridIndex
                        break
                    }
                    generatedLandmarks.append(EpisodeFingerprintLandmark(
                        id: "downloaded-landmark-\(gridIndex)",
                        order: gridIndex,
                        sourceMediaStartMs: startMs,
                        sourceMediaEndMs: startMs + SparseFingerprintSchedule.targetDurationMs,
                        anchorMediaTimeMs: startMs,
                        continuityEpoch: 0,
                        trigger: .downloadedPreparation,
                        provenance: .downloadedSourceReference,
                        signatureAssetId: assetID
                    ))
                    gridIndex += 1
                    startMs += SparseFingerprintSchedule.periodicIntervalMs
                }
                while startMs + PodcastAnchorEvidenceGenerator.minimumEvidenceDurationMs <= durationMs {
                    try Task.checkCancellation()
                    let assetID = "episode-signature-\(self.safePodcastEvidenceComponent(item.id))-downloaded-\(gridIndex)"
                    let ledger: OfflineStorageLedger
                    if let existingLedger = self.offlineStorageLedger {
                        ledger = existingLedger
                    } else {
                        ledger = OfflineStorageLedger(
                            repository: store,
                            rootDirectory: try self.applicationSupportDirectory()
                        )
                        self.offlineStorageLedger = ledger
                    }
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
                    generatedLandmarks.append(EpisodeFingerprintLandmark(
                        id: "downloaded-landmark-\(gridIndex)",
                        order: gridIndex,
                        sourceMediaStartMs: startMs,
                        sourceMediaEndMs: startMs + generated.durationMs,
                        anchorMediaTimeMs: startMs,
                        continuityEpoch: 0,
                        trigger: .downloadedPreparation,
                        provenance: .downloadedSourceReference,
                        signatureAssetId: assetID
                    ))
                    try await ledger.commit(reservationId: reservation.id, asset: OwnedOfflineAsset(
                        id: assetID,
                        itemId: item.id,
                        category: .fingerprintMap,
                        relativePath: "SpokenMargins/EpisodeMaps/\(self.safePodcastEvidenceComponent(item.id))/\(assetID).shazamsignature",
                        byteCount: Int64((try? Data(contentsOf: generated.fileURL).count) ?? 0),
                        isReproducible: true,
                        protections: [.activeEpisodeMapPreparation]
                    ))
                    gridIndex += 1
                    startMs += SparseFingerprintSchedule.periodicIntervalMs
                    job.nextUnitIndex = gridIndex
                    try store.saveEpisodeMapPreparationJob(job)
                    if job.policy == .whileCharging {
                        self.episodeMapPreparationStatus = "Fingerprinting paused at landmark \(gridIndex)"
                        self.diagnostics["episodeMapPreparation:\(item.id)"] = "checkpoint:fingerprint_landmark=\(gridIndex)"
                        return
                    }
                }

                job.stage = .transcribe
                try store.saveEpisodeMapPreparationJob(job)
                self.episodeMapPreparationStatus = "Transcribing on device"
                let supportDirectory = try self.applicationSupportDirectory()
                var timeline: TranscriptTimeline
                if let relativePath = job.transientTranscriptRelativePath,
                   let cached = try? Data(contentsOf: supportDirectory.appending(path: relativePath)),
                   let decoded = try? JSONDecoder().decode(TranscriptTimeline.self, from: cached) {
                    timeline = decoded
                } else {
                    timeline = try await self.sourceTranscriptionClient.transcribeSourceAudio(
                        url: localURL,
                        itemId: item.id,
                        durationMs: durationMs
                    )
                    let transcriptData = try JSONEncoder().encode(timeline)
                    let safeItemID = self.safePodcastEvidenceComponent(item.id)
                    let relativePath = "SpokenMargins/EpisodeMaps/\(safeItemID)/Transient/timeline.json"
                    let transcriptURL = supportDirectory.appending(path: relativePath)
                    try FileManager.default.createDirectory(
                        at: transcriptURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let ledger: OfflineStorageLedger
                    if let existingLedger = self.offlineStorageLedger {
                        ledger = existingLedger
                    } else {
                        ledger = OfflineStorageLedger(repository: store, rootDirectory: supportDirectory)
                        self.offlineStorageLedger = ledger
                    }
                    let reservation = try await ledger.reserve(
                        ownerId: "episode-transcript-\(item.id)",
                        byteCount: Int64(transcriptData.count)
                    )
                    do {
                        try transcriptData.write(to: transcriptURL, options: .atomic)
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
                        try? FileManager.default.removeItem(at: transcriptURL)
                        throw error
                    }
                    job.transientTranscriptRelativePath = relativePath
                    try store.saveEpisodeMapPreparationJob(job)
                }
                try self.purgeSourceTranscriptionAudioCaches(itemId: item.id)
                if let publisherChapters = try store.loadTranscriptTimeline(itemId: item.id)?.timeline.chapters,
                   !publisherChapters.isEmpty {
                    timeline.chapters = publisherChapters
                }

                job.stage = .generatePhraseSketch
                try store.saveEpisodeMapPreparationJob(job)
                let sketch = TranscriptPhraseSketchBuilder.makeArtifact(
                    id: "episode-sketch-\(self.safePodcastEvidenceComponent(item.id))",
                    itemId: item.id,
                    timeline: timeline
                )

                let existingPlaybackLandmarks = try store.loadEditionFingerprintSpine(itemId: item.id)?.landmarks
                    .filter { $0.provenance == .observedDecodedPlayback } ?? []
                let allLandmarks = (existingPlaybackLandmarks + generatedLandmarks)
                    .sorted { $0.sourceMediaStartMs < $1.sourceMediaStartMs }
                    .enumerated().map { index, landmark in
                        let sketchWindow = sketch.windows.first {
                            landmark.anchorMediaTimeMs >= $0.sourceStartMs
                                && landmark.anchorMediaTimeMs < $0.sourceEndMs
                        }
                        return EpisodeFingerprintLandmark(
                            id: landmark.id,
                            order: index,
                            sourceMediaStartMs: landmark.sourceMediaStartMs,
                            sourceMediaEndMs: landmark.sourceMediaEndMs,
                            anchorMediaTimeMs: landmark.anchorMediaTimeMs,
                            continuityEpoch: landmark.continuityEpoch,
                            trigger: landmark.trigger,
                            provenance: landmark.provenance,
                            signatureAssetId: landmark.signatureAssetId,
                            transcriptSketchWindowId: sketchWindow?.id,
                            generatorVersion: landmark.generatorVersion
                        )
                    }
                let spine = EditionFingerprintSpineArtifact(
                    id: "episode-spine-\(self.safePodcastEvidenceComponent(item.id))",
                    itemId: item.id,
                    canonicalURL: item.externalReference ?? item.media?.url,
                    producingEditionDurationMs: durationMs,
                    producingEditionSHA256: digest,
                    landmarks: allLandmarks
                )

                job.stage = .segmentScenes
                try store.saveEpisodeMapPreparationJob(job)
                let drafts = EpisodeSceneSegmenter.makeDrafts(timeline: timeline)
                var scenes: [PortableListeningMapScene] = []
                job.stage = .generateSummaries
                try store.saveEpisodeMapPreparationJob(job)
                for draft in drafts {
                    try Task.checkCancellation()
                    let text = timeline.segments
                        .filter { $0.endMs > draft.startMs && $0.startMs < draft.endMs }
                        .map(\.text)
                        .joined(separator: " ")
                    var label: ListeningMapSummaryValidator.SceneLabel?
                    if self.localFoundationModelClient.availability().isAvailable, !text.isEmpty {
                        for _ in 0..<2 where label == nil {
                            if let candidate = try? await self.localFoundationModelClient.labelListeningMapChapter(
                                text: text,
                                chapterNumber: draft.order + 1
                            ) {
                                label = try? ListeningMapSummaryValidator.validate(candidate, sourceText: text)
                            }
                        }
                    }
                    let nearestEvidence = allLandmarks.min {
                        abs($0.anchorMediaTimeMs - draft.startMs) < abs($1.anchorMediaTimeMs - draft.startMs)
                    }?.signatureAssetId
                    let machineEvidence = nearestEvidence.map { [$0] } ?? []
                    let eligibility = label?.eligibility ?? .unknown
                    scenes.append(PortableListeningMapScene(
                        id: draft.id,
                        order: draft.order,
                        title: label?.title ?? draft.publisherTitle,
                        summaryText: ListeningMapSummaryValidator.storedSummary(for: label).text,
                        summaryAssetId: nil,
                        summaryProvenance: ListeningMapSummaryValidator.storedSummary(for: label).provenance,
                        eligibility: eligibility,
                        eligibilityReason: label?.eligibilityReason,
                        startAnchor: PortableAnchorEvidence(
                            anchorType: .transcript,
                            mediaTimeMs: draft.startMs,
                            transcriptSegmentId: draft.startTranscriptSegmentId,
                            chapterTitle: label?.title ?? draft.publisherTitle,
                            machineEvidenceAssetIds: machineEvidence
                        ),
                        endAnchor: PortableAnchorEvidence(
                            anchorType: .transcript,
                            mediaTimeMs: draft.endMs,
                            transcriptSegmentId: draft.endTranscriptSegmentId,
                            chapterTitle: label?.title ?? draft.publisherTitle,
                            machineEvidenceAssetIds: machineEvidence
                        )
                    ))
                }
                let proposal = PortableListeningMapProposalArtifact(
                    id: "episode-map-proposal-\(self.safePodcastEvidenceComponent(item.id))",
                    createdAt: Date(),
                    generator: self.localFoundationModelClient.availability().isAvailable
                        ? "on-device-scene-map.v1"
                        : "deterministic-scene-boundaries.v1",
                    scenes: scenes
                )

                job.stage = .renderBridges
                try store.saveEpisodeMapPreparationJob(job)
                for scene in scenes where scene.eligibility == .eligible && scene.summaryText?.isEmpty == false {
                    try Task.checkCancellation()
                    _ = try await self.prepareSummaryBridgeAsset(
                        itemId: item.id,
                        proposalId: proposal.id,
                        scene: scene,
                        store: store
                    )
                }

                job.stage = .commit
                try store.saveEpisodeMapPreparationJob(job)
                try store.saveEditionFingerprintSpine(spine)
                try store.saveTranscriptPhraseSketch(sketch)
                try store.savePortableListeningMapProposal(proposal, itemId: item.id)
                let identityMatches = allLandmarks.map { landmark in
                    FingerprintLandmarkMatch(
                        id: "exact-\(landmark.id)",
                        landmarkId: landmark.id,
                        sourceMediaTimeMs: landmark.anchorMediaTimeMs,
                        recipientMediaTimeMs: landmark.anchorMediaTimeMs,
                        acousticConfidence: 1,
                        transcriptCorroborated: true,
                        isUniqueWithinEpisode: true
                    )
                }
                try store.saveResolvedListeningMapProjection(EpisodeFingerprintAlignment.makeProjection(
                    id: "episode-projection-\(self.safePodcastEvidenceComponent(item.id))",
                    itemId: item.id,
                    proposalId: proposal.id,
                    recipientEditionSHA256: digest,
                    matches: identityMatches,
                    exactEdition: true
                ))
                for asset in try store.loadOwnedOfflineAssets() where
                    asset.itemId == item.id && asset.category == .fingerprintMap {
                    try store.updateOwnedOfflineAsset(id: asset.id) { $0.protections.remove(.activeEpisodeMapPreparation) }
                }
                try self.purgeTransientEpisodeTranscriptionCaches(itemId: item.id)
                job.stage = .completed
                try store.saveEpisodeMapPreparationJob(job)
                try store.deleteEpisodeMapPreparationJob(id: job.id)
                self.episodeMapPreparationStatus = scenes.contains(where: { $0.summaryText != nil })
                    ? "Ready with scene summaries"
                    : "Fingerprint map ready; scene summaries unavailable"
                self.diagnostics["episodeMapPreparation:\(item.id)"] =
                    "complete:landmarks=\(allLandmarks.count):scenes=\(scenes.count):transcript_deleted"
                if item.id == self.activeItemId {
                    self.refreshSelectedItem()
                    self.updateSkimAvailability()
                    self.reportConfirmation(self.episodeMapPreparationStatus)
                }
            } catch is CancellationError {
                job.isCancelled = true
                job.lastFailureCode = "cancelled"
                try? self.store?.saveEpisodeMapPreparationJob(job)
                try? self.purgeTransientEpisodeTranscriptionCaches(itemId: item.id)
                self.episodeMapPreparationStatus = "Cancelled"
            } catch {
                job.lastFailureCode = String(describing: error)
                try? self.store?.saveEpisodeMapPreparationJob(job)
                self.episodeMapPreparationStatus = "Failed"
                self.diagnostics["episodeMapPreparation:\(item.id)"] = "failed:\(error.localizedDescription)"
                if item.id == self.activeItemId { self.reportFailure(error, context: "Episode map preparation failed", itemId: item.id) }
            }
        }
    }

    func episodeMapDirectory(itemId: String) throws -> URL {
        try applicationSupportDirectory()
            .appending(path: "SpokenMargins/EpisodeMaps", directoryHint: .isDirectory)
            .appending(path: safePodcastEvidenceComponent(itemId), directoryHint: .isDirectory)
    }

    private func currentSummaryBridgeVoiceKey() -> String {
        let systemIdentifier = ttsVoiceSelection == .system ? speechVoiceIdentifier : ""
        return safePodcastEvidenceComponent("\(ttsVoiceSelection.rawValue)-\(systemIdentifier)-\(SummaryBridgeRatePolicy.cacheVersion)")
    }

    /// Why a friend's shared map couldn't be placed on this item's copy, as stored on its packets (#481).
    func sharedListeningMapRefusal(itemId: String) -> String? {
        guard let store, let layers = try? store.loadImportedCommentaryLayers(itemId: itemId),
              let hasMap = try? Self.listenerHasListeningMap(itemId: itemId, store: store) else { return nil }
        return SharedListeningMapPlacement.storedRefusalReason(layers: layers, listenerHasMap: hasMap)
    }

    /// The listener's own map or the publisher's chapters, which a friend's map never replaces.
    static func listenerHasListeningMap(itemId: String, store: SQLiteSessionStore) throws -> Bool {
        try !store.loadPortableListeningMapProposals(itemId: itemId).isEmpty
            || store.loadTranscriptTimeline(itemId: itemId)?.timeline.chapters.isEmpty == false
    }

    func summaryBridgeAssetID(itemId: String, proposalId: String, sceneId: String, suppliedAssetId: String? = nil) -> String {
        let voiceKey = suppliedAssetId.map { "supplied-\(safePodcastEvidenceComponent($0))" } ?? currentSummaryBridgeVoiceKey()
        return "summary-bridge-\(safePodcastEvidenceComponent(itemId))-\(safePodcastEvidenceComponent(proposalId))-\(safePodcastEvidenceComponent(sceneId))-\(voiceKey)"
    }

    func prepareSummaryBridgeAsset(
        itemId: String,
        proposalId: String,
        scene: PortableListeningMapScene,
        store: SQLiteSessionStore
    ) async throws -> OwnedOfflineAsset? {
        guard let summary = scene.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else { return nil }
        let assetID = summaryBridgeAssetID(itemId: itemId, proposalId: proposalId, sceneId: scene.id, suppliedAssetId: scene.summaryAssetId)
        if let existing = try store.loadOwnedOfflineAssets().first(where: {
            $0.id == assetID && $0.integrity == .valid
        }), resolvedApplicationSupportAssetURL(for: existing.relativePath) != nil { return existing }
        // An authored voice is part of the imported experience, not a request
        // to silently synthesize replacement speech in the current system voice.
        guard scene.summaryAssetId == nil else { return nil }
        let directory = try episodeMapDirectory(itemId: itemId)
            .appending(path: "SummaryBridges", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger: OfflineStorageLedger
        if let existingLedger = offlineStorageLedger {
            ledger = existingLedger
        } else {
            ledger = OfflineStorageLedger(
                repository: store,
                rootDirectory: try applicationSupportDirectory()
            )
            offlineStorageLedger = ledger
        }
        let reservation = try await ledger.reserve(
            ownerId: "summary-bridge-\(assetID)",
            byteCount: 64 * 1_024 * 1_024
        )
        do {
            let sourceURL: URL
            if let voice = ttsVoiceSelection.supertonicVoice {
                let renderer = try makeSupertonicRenderer()
                let result = try await renderer.render(
                    text: summary,
                    voice: voice,
                    language: "en",
                    speed: SummaryBridgeRatePolicy.synthesisSpeed,
                    synthesisSteps: 8
                )
                sourceURL = result.audioURL
            } else {
                let title = scene.title ?? "Scene summary"
                // An injected preparation job renders in place of the system voice, as it does for text items.
                let prepared: PreparedTextAudio?
                if let prewarm = preparedTextAudioPrewarmHandler {
                    prepared = try await prewarm(
                        assetID, title, summary, directory, speechVoiceIdentifier, SummaryBridgeRatePolicy.systemSynthesisRate
                    ).get()
                } else {
                    prepared = try SystemTextAudioPreparationClient(
                        outputDirectory: directory,
                        voiceIdentifier: speechVoiceIdentifier,
                        speechRate: SummaryBridgeRatePolicy.systemSynthesisRate,
                        allowsSynchronousRendering: true
                    ).prepareTextAudio(itemId: assetID, title: title, text: summary)
                }
                guard let prepared, let value = prepared.media.url, let url = URL(string: value) else {
                    try? await ledger.release(reservationId: reservation.id)
                    return nil
                }
                sourceURL = url
            }
            let destination = directory.appending(path: "\(assetID).\(sourceURL.pathExtension.isEmpty ? "caf" : sourceURL.pathExtension)")
            if sourceURL.standardizedFileURL != destination.standardizedFileURL {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            }
            let bytes = (try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let asset = OwnedOfflineAsset(
                id: assetID,
                itemId: itemId,
                category: .summaryBridge,
                relativePath: "SpokenMargins/EpisodeMaps/\(safePodcastEvidenceComponent(itemId))/SummaryBridges/\(destination.lastPathComponent)",
                byteCount: bytes,
                isReproducible: true
            )
            try await ledger.commit(reservationId: reservation.id, asset: asset)
            return asset
        } catch {
            try? await ledger.release(reservationId: reservation.id)
            throw error
        }
    }

    var skimForwardTitle: String { PlaybackQualityPresentation.skimTitle(destinationMs: skimForwardDestinationMs, backward: false) }

    var skimBackwardTitle: String { PlaybackQualityPresentation.skimTitle(destinationMs: skimBackwardDestinationMs, backward: true) }

    #if DEBUG
    var skimAudioTransportRate: Float? { skimBridgePlayer?.rate }
    #endif

    func updateSkimAvailability(refreshResources: Bool = true) {
        if refreshResources { skimResourceContext = nil }
        guard !isUpdatingSkimAvailability else { return }
        let effectiveTime = snapshot.skimBridgeState?.destinationMediaTimeMs ?? snapshot.currentMediaTimeMs
        let forward = effectiveTime.flatMap { resolvedSkimPlaybackPlan(direction: .forward, at: $0) }
        let backward = effectiveTime.flatMap { resolvedSkimPlaybackPlan(direction: .backward, at: $0) }
        let forwardTime = snapshot.skimBridgeState?.destinationMediaTimeMs ?? forward?.destinationMediaTimeMs
        let backwardTime = snapshot.skimBridgeState?.destinationMediaTimeMs ?? backward?.destinationMediaTimeMs
        if skimForwardDestinationMs != forwardTime { skimForwardDestinationMs = forwardTime }
        if skimBackwardDestinationMs != backwardTime { skimBackwardDestinationMs = backwardTime }
        let canForward = forwardTime != nil
        let canBackward = backwardTime != nil
        guard snapshot.canSkimForward != canForward || snapshot.canSkimBackward != canBackward else { return }
        isUpdatingSkimAvailability = true
        snapshot.canSkimForward = canForward
        snapshot.canSkimBackward = canBackward
        isUpdatingSkimAvailability = false
    }

    private func resolvedSkimPlaybackPlan(
        direction: SkimDirection,
        at recipientMediaTimeMs: Int
    ) -> ResolvedSkimPlaybackPlan? {
        guard isMediaPlaybackSnapshot, !snapshot.isRecording, let store else { return nil }
        if skimResourceContext?.itemId != activeItemId {
            #if DEBUG
            skimResourceLoadCount += 1
            #endif
            let projection = try? store.loadResolvedListeningMapProjection(itemId: activeItemId)
            skimResourceContext = SkimResourceContext(
                itemId: activeItemId,
                projection: projection,
                proposal: SharedListeningMapPlacement.proposal(
                    for: projection, committed: (try? store.loadPortableListeningMapProposals(itemId: activeItemId)) ?? [],
                    layers: (try? store.loadImportedCommentaryLayers(itemId: activeItemId)) ?? []),
                assets: (try? store.loadOwnedOfflineAssets()) ?? []
            )
        }
        guard let resources = skimResourceContext, let projection = resources.projection else { return nil }
        guard let proposal = resources.proposal else { return nil }
        let scenes = proposal.scenes.sorted { $0.order < $1.order }
        guard !scenes.isEmpty else { return nil }
        let exactIdentityProjection = projection.algorithmVersion == "episode-projection.exact-edition.v1"
            || (!projection.points.isEmpty && projection.points.allSatisfy {
                ($0.confidence == .exactEdition || $0.confidence == .verified)
                    && $0.recipientMediaTimeMs == $0.sourceMediaTimeMs
            })
        func projectedTime(_ sourceTimeMs: Int?) -> Int? {
            guard let sourceTimeMs else { return nil }
            return projection.projectedRecipientTime(for: sourceTimeMs)
                ?? (exactIdentityProjection ? sourceTimeMs : nil)
        }
        let sceneStarts = scenes.map { projectedTime($0.startAnchor.mediaTimeMs) }
        guard let currentIndex = scenes.indices.last(where: {
            guard let start = sceneStarts[$0] else { return false }
            return start <= recipientMediaTimeMs
        }) else { return nil }

        let summaryIndex: Int
        let destinationSceneId: String?
        let destinationMediaTimeMs: Int
        switch direction {
        case .forward:
            summaryIndex = currentIndex
            if scenes.indices.contains(currentIndex + 1) {
                guard let destination = sceneStarts[currentIndex + 1] else { return nil }
                destinationSceneId = scenes[currentIndex + 1].id
                destinationMediaTimeMs = destination
            } else {
                guard let duration = snapshot.currentPlaybackDurationMs ?? selectedItem.mediaDurationMs else { return nil }
                destinationSceneId = nil
                destinationMediaTimeMs = duration
            }
        case .backward:
            guard currentIndex > 0, let destination = sceneStarts[currentIndex] else { return nil }
            summaryIndex = currentIndex - 1
            destinationSceneId = scenes[currentIndex].id
            destinationMediaTimeMs = destination
        }

        let summaryScene = scenes[summaryIndex]
        guard summaryScene.eligibility == .eligible,
              summaryScene.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        let assetID = summaryBridgeAssetID(
            itemId: activeItemId,
            proposalId: SharedListeningMapPlacement.isSharedProjection(id: projection.id) ? projection.id : proposal.id,
            sceneId: summaryScene.id,
            suppliedAssetId: summaryScene.summaryAssetId
        )
        guard let asset = resources.assets.first(where: {
            $0.id == assetID && $0.category == .summaryBridge && $0.integrity == .valid
        }), let url = resolvedApplicationSupportAssetURL(for: asset.relativePath) else {
            return nil
        }
        return ResolvedSkimPlaybackPlan(
            direction: direction,
            itemId: activeItemId,
            originMediaTimeMs: recipientMediaTimeMs,
            summarySceneId: summaryScene.id,
            destinationSceneId: destinationSceneId,
            destinationMediaTimeMs: destinationMediaTimeMs,
            summaryAssetId: assetID,
            summaryAudioURL: url
        )
    }

    func skimForward() {
        performSkim(direction: .forward)
    }

    func skimBackward() {
        performSkim(direction: .backward)
    }

    private func performSkim(direction: SkimDirection) {
        if snapshot.skimBridgeState != nil {
            // A second tap exits the current bridge at its destination. Do not
            // resolve another summary against the asynchronous source seek.
            completeSkimBridge()
            return
        }
        let effectiveTime = snapshot.currentMediaTimeMs ?? 0
        guard let plan = resolvedSkimPlaybackPlan(direction: direction, at: effectiveTime) else {
            reportWarning("Skim is unavailable until a verified scene summary is ready.")
            return
        }
        startSkimBridge(plan)
    }

    private func startSkimBridge(_ plan: ResolvedSkimPlaybackPlan) {
        #if canImport(AVFoundation)
        guard let engine else { return }
        let wasPlaying = snapshot.status.isPlaybackActive
        do {
            snapshot = try engine.pause()
            var state = SkimBridgeState(
                direction: plan.direction,
                itemId: plan.itemId,
                originMediaTimeMs: plan.originMediaTimeMs,
                summarySceneId: plan.summarySceneId,
                destinationSceneId: plan.destinationSceneId,
                destinationMediaTimeMs: plan.destinationMediaTimeMs,
                summaryAssetId: plan.summaryAssetId,
                wasSourcePlaying: wasPlaying,
                status: .preparing
            )
            snapshot.skimBridgeState = state
            protectSummaryBridgeAsset(plan.summaryAssetId, protected: true)
            let player = AVPlayer(url: plan.summaryAudioURL)
            skimBridgePlayer = player
            state.status = .playing
            snapshot.skimBridgeState = state
            player.currentItem?.audioTimePitchAlgorithm = .timeDomain
            player.playImmediately(atRate: SummaryBridgeRatePolicy.transportRate(mediaPlaybackRate))
            skimBridgeTask?.cancel()
            skimBridgeTask = Task { @MainActor [weak self, weak player] in
                while !Task.isCancelled {
                    guard let self, let player, let item = player.currentItem else { return }
                    if item.status == .failed {
                        self.cancelSkimBridge(restoringOrigin: true, resumeSource: false)
                        self.reportWarning("The scene summary could not be played. Your original position was restored.")
                        return
                    }
                    let duration = CMTimeGetSeconds(item.duration)
                    let current = CMTimeGetSeconds(player.currentTime())
                    if duration.isFinite, duration > 0, current >= duration - 0.08 {
                        self.completeSkimBridge()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            reportSuccess(plan.direction == .forward ? "Skimming forward." : "Skimming backward.")
        } catch {
            protectSummaryBridgeAsset(plan.summaryAssetId, protected: false)
            reportFailure(error, context: "Skim failed")
        }
        #else
        reportWarning("Skim audio is unavailable on this device.")
        #endif
    }

    private func completeSkimBridge() {
        guard var bridge = snapshot.skimBridgeState, let engine else { return }
        bridge.status = .completing
        snapshot.skimBridgeState = bridge
        skimBridgePlayer?.pause()
        skimBridgePlayer = nil
        skimBridgeTask?.cancel()
        skimBridgeTask = nil
        protectSummaryBridgeAsset(bridge.summaryAssetId, protected: false)
        do {
            snapshot.skimBridgeState = nil
            snapshot = try seekOrStageMedia(engine, toMediaTimeMs: bridge.destinationMediaTimeMs)
            if bridge.destinationSceneId == nil {
                snapshot = try engine.pause()
                reportConfirmation("Finished the final scene summary.")
            } else if bridge.wasSourcePlaying {
                snapshot = try engine.resumePlayback()
            } else {
                snapshot = try engine.pause()
            }
            refreshSelectedItem()
        } catch {
            cancelSkimBridge(restoringOrigin: true, resumeSource: false)
            reportFailure(error, context: "Completing Skim failed")
        }
    }

    private func setSkimBridgePaused(_ paused: Bool) {
        #if canImport(AVFoundation)
        guard var bridge = snapshot.skimBridgeState, let player = skimBridgePlayer else { return }
        if paused {
            player.pause()
            bridge.status = .paused
        } else {
            player.playImmediately(atRate: SummaryBridgeRatePolicy.transportRate(mediaPlaybackRate))
            bridge.status = .playing
        }
        snapshot.skimBridgeState = bridge
        #endif
    }

    func returnFromSkim() {
        cancelSkimBridge(restoringOrigin: true, resumeSource: true)
    }

    private func cancelSkimBridge(restoringOrigin: Bool, resumeSource: Bool) {
        guard var bridge = snapshot.skimBridgeState else { return }
        bridge.status = .cancelled
        skimBridgePlayer?.pause()
        skimBridgePlayer = nil
        skimBridgeTask?.cancel()
        skimBridgeTask = nil
        protectSummaryBridgeAsset(bridge.summaryAssetId, protected: false)
        snapshot.skimBridgeState = nil
        guard restoringOrigin, let engine else { return }
        snapshot = (try? seekOrStageMedia(engine, toMediaTimeMs: bridge.originMediaTimeMs)) ?? snapshot
        if resumeSource && bridge.wasSourcePlaying {
            snapshot = (try? engine.resumePlayback()) ?? snapshot
        } else {
            snapshot = (try? engine.pause()) ?? snapshot
        }
    }

    private func restoreSkimOriginBeforeCanonicalTransport() {
        if playingImportedCommentary != nil { stopImportedCommentaryPlayback(resumeSource: false) }
        guard let bridge = snapshot.skimBridgeState else { return }
        cancelSkimBridge(restoringOrigin: true, resumeSource: bridge.wasSourcePlaying)
    }

    private func protectSummaryBridgeAsset(_ assetID: String, protected: Bool) {
        _ = try? store?.updateOwnedOfflineAsset(id: assetID) { asset in
            if protected {
                asset.protections.insert(.activeSummaryBridge)
            } else {
                asset.protections.remove(.activeSummaryBridge)
            }
        }
    }

    func purgeTransientEpisodeTranscriptionCaches(itemId: String) throws {
        try purgeSourceTranscriptionAudioCaches(itemId: itemId)
        let transientDirectory = try episodeMapDirectory(itemId: itemId)
            .appending(path: "Transient", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: transientDirectory.path) {
            try FileManager.default.removeItem(at: transientDirectory)
        }
        if let store {
            for asset in try store.loadOwnedOfflineAssets() where
                asset.itemId == itemId && asset.category == .transientEpisodeTranscript {
                try store.deleteOwnedOfflineAsset(id: asset.id)
            }
        }
    }

    private func purgeSourceTranscriptionAudioCaches(itemId: String) throws {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        for relative in [
            "SourceAudioTranscriptionChunksV3/\(itemId)",
            "SourceAudioTranscriptionWindows/\(itemId)"
        ] {
            let url = caches.appending(path: relative, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func submitAutomaticEpisodeMapPreparationIfNeeded() {
        guard automaticEpisodeMapPreparationPolicy == .whileCharging,
              let store else { return }
        let candidates = libraryItems.compactMap { row -> Item? in
            guard (try? store.loadEditionFingerprintSpine(itemId: row.id)) == nil,
                  let item = try? store.loadItem(id: row.id),
                  item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream,
                  podcastDownloadCoordinator?.validatedLocalURL(for: row.id) != nil else { return nil }
            return item
        }
        for item in candidates {
            let id = "episode-map-job-\(safePodcastEvidenceComponent(item.id))"
            if let existing = try? store.loadEpisodeMapPreparationJobs().first(where: { $0.id == id && !$0.isCancelled }) {
                _ = existing
                continue
            }
            try? store.saveEpisodeMapPreparationJob(EpisodeMapPreparationJob(
                id: id,
                itemId: item.id,
                policy: .whileCharging
            ))
        }
        #if canImport(BackgroundTasks) && canImport(UIKit)
        AudioPreparationBackgroundController.shared.submitIfEnabled(!candidates.isEmpty)
        #endif
    }

    func applyListeningMapJSON() {
        do {
            let store = try requireStore()
            var item = try store.loadItem(id: activeItemId)
            let map = try parseListeningMapJSON(listeningMapJSON, item: item)
            if let engine {
                snapshot = try engine.attachListeningMap(map)
            } else {
                try store.saveListeningMap(map)
            }
            item.status = "ready"
            try store.saveItem(item)
            libraryItems = try loadLibraryRows(store: store)
            selectedItem = try loadItemDetail(id: activeItemId, store: store)
            diagnostics["lastAppliedMap"] = map.id
            diagnostics["lastAppliedMapChapters"] = "\(map.chapters.count)"
            scheduleTextAudioPrewarmIfNeeded(itemId: activeItemId)
            reportSuccess("Applied Listening Map.")
        } catch {
            reportFailure(error, context: "Listening Map validation failed")
        }
    }

    var nextPlaybackChapter: Chapter? {
        guard snapshot.itemId == selectedItem.id,
              snapshot.targetType == TargetType.itemTextTTS.rawValue,
              let index = selectedItem.chapters.firstIndex(where: { isCurrentTimelineChapter($0) }),
              selectedItem.chapters.indices.contains(index + 1) else { return nil }
        return selectedItem.chapters[index + 1]
    }

    var nextPlaybackMediaChapter: MediaTimelineChapter? {
        guard snapshot.itemId == selectedItem.id,
              snapshot.targetType == TargetType.transcriptBackedMedia.rawValue
                || snapshot.targetType == TargetType.browserOwnedMedia.rawValue,
              let position = snapshot.currentMediaTimeMs else { return nil }
        let chapters = selectedItem.mediaChapters.isEmpty ? selectedItem.listeningMapScenes : selectedItem.mediaChapters
        return chapters.sorted { $0.startMs < $1.startMs }.first { $0.startMs > position }
    }

    var canJumpToNextChapter: Bool {
        !recordingNavigationIsLocked && snapshot.skimBridgeState == nil && playingImportedCommentary == nil
            && (nextPlaybackChapter != nil || nextPlaybackMediaChapter != nil)
    }

    func jumpToNextChapter() {
        guard canJumpToNextChapter else { return }
        if let chapter = nextPlaybackChapter { jumpToChapter(chapter) }
        else if let chapter = nextPlaybackMediaChapter {
            if selectedItem.mediaChapters.isEmpty { jumpToListeningMapScene(chapter) }
            else { jumpToMediaChapter(chapter) }
        }
    }

    func jumpToChapter(_ chapter: Chapter, fromTimeline: Bool = false) {
        guard !requireTermsDecisionBeforePlayback(.jumpToChapter(chapter.id, fromTimeline: fromTimeline)) else { return }
        stopSpeechPreviews()
        clearPendingAutoPlayTurns()
        run { engine in
            _ = try ensureSessionForSelectedItem(engine)
            snapshot = try engine.jumpToChapter(chapterId: chapter.id)
            refreshSelectedItem()
            screen = .playback
            if fromTimeline {
                recordTimelineReviewCompleted()
            }
            reportSuccess("Jumped to \(chapter.title).")
        }
    }

    func jumpToMediaChapter(_ chapter: MediaTimelineChapter, fromTimeline: Bool = false) {
        guard !requireTermsDecisionBeforePlayback(.jumpToChapter(chapter.id, fromTimeline: fromTimeline)) else { return }
        stopSpeechPreviews()
        clearPendingAutoPlayTurns()
        run { engine in
            _ = try ensureSessionForSelectedItem(engine)
            snapshot = try engine.jumpToChapter(chapterId: chapter.id)
            refreshSelectedItem()
            screen = .playback
            if fromTimeline {
                recordTimelineReviewCompleted()
            }
            reportSuccess("Jumped to \(chapter.title).")
        }
    }

    func jumpToListeningMapScene(_ scene: MediaTimelineChapter, fromTimeline: Bool = false) {
        guard !requireTermsDecisionBeforePlayback(.jumpToChapter(scene.id, fromTimeline: fromTimeline)) else { return }
        stopSpeechPreviews()
        clearPendingAutoPlayTurns()
        run { engine in
            _ = try ensureSessionForSelectedItem(engine)
            snapshot = try seekOrStageMedia(engine, toMediaTimeMs: scene.startMs)
            if !snapshot.status.isPlaybackActive {
                snapshot = try engine.resumePlayback()
            }
            refreshSelectedItem()
            screen = .playback
            if fromTimeline {
                recordTimelineReviewCompleted()
            }
            reportSuccess("Jumped to \(scene.title).")
        }
    }

    func playSourceFromBeginning(fromTimeline: Bool = false) {
        guard !requireTermsDecisionBeforePlayback(.playSourceFromBeginning(fromTimeline: fromTimeline)) else { return }
        stopSpeechPreviews()
        clearPendingAutoPlayTurns()
        run { engine in
            let startedSelectedItem = try ensureSessionForSelectedItem(engine)
            if !startedSelectedItem {
                snapshot = try engine.playSourceFromBeginning()
            }
            refreshSelectedItem()
            screen = .playback
            if fromTimeline {
                recordTimelineReviewCompleted()
            }
            reportSuccess("Playing source from the beginning.")
        }
    }

    /// Item Detail can be opened while another item remains in the mini player. Chapter
    /// actions belong to the item being viewed, not merely to whichever session happens
    /// to be restored in the engine.
    @discardableResult
    private func ensureSessionForSelectedItem(_ engine: SessionEngine) throws -> Bool {
        try prepareSourceMediaPlayback(itemId: activeItemId)
        if let session = engine.currentSession, session.itemId == activeItemId,
           session.status != "finished", session.phase != .finished, session.completionPercent < 100 {
            return false
        }
        resetMixWithOtherAudioForNewSession()
        if engine.currentSession != nil {
            snapshot = try engine.endSession()
        }
        let started = try engine.startSession(itemId: activeItemId)
        snapshot = try applyPreferredPlaybackRate(to: started, engine: engine)
        return true
    }

    var activePlaybackItemId: String? {
        snapshot.sessionId == nil ? nil : snapshot.itemId
    }

    var recordingNavigationIsLocked: Bool {
        isRequestingRecordingPermission || snapshot.isRecording || writtenMarginDraft != nil
    }

    @discardableResult
    func rejectNavigationOrSessionMutationWhileRecording(_ operation: String) -> Bool {
        guard recordingNavigationIsLocked else { return false }
        diagnostics["recordingNavigationGuard"] = "blocked_\(operation)"
        statusMessage = "Finish or cancel this Margin before leaving its listening position."
        return true
    }

    func openPlayback() {
        guard !isRequestingRecordingPermission else { return }
        guard hasActiveSession else { return }
        screen = .playback
        if let itemId = snapshot.itemId, let store {
            activeItemId = itemId
            if selectedItem.id != itemId {
                if let detail = activePlaybackDetail, detail.id == itemId {
                    selectedItem = detail
                } else {
                    navigationRefreshTask?.cancel()
                    navigationRefreshTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled, let self, self.screen == .playback,
                              self.snapshot.itemId == itemId,
                              let detail = try? self.loadItemDetail(id: itemId, store: store) else { return }
                        self.selectedItem = detail
                    }
                }
            }
        }
    }

    func openTimeline(focusMarginID: String? = nil) {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_timeline") else { return }
        guard hasActiveSession else { return }
        requestedTimelineFocusMarginID = focusMarginID
        screen = .timeline
    }

    func startItem(id: String) {
        guard !rejectNavigationOrSessionMutationWhileRecording("start_item") else { return }
        prepareImportedLocalAudioBridges(itemId: id)
        if libraryItems.first(where: { $0.id == id })?.startupAudioState == .preparing {
            scheduleStartupAudioPreparationIfNeeded(itemId: id)
            diagnostics["startupAudioPlayback:\(id)"] = "started_without_waiting_for_opening_buffer"
        }
        do {
            let store = try requireStore()
            if let continuation = Self.preferredContinuationSession(in: try store.loadSessions(itemId: id)),
               continuation.phase != .finished, continuation.status != "finished", continuation.completionPercent < 100 {
                resumeSession(continuation)
            } else {
                startNewSession(id: id)
            }
        } catch {
            reportFailure(error, context: "Continue listening failed")
        }
    }

    func startNewSession(id: String) {
        guard !rejectNavigationOrSessionMutationWhileRecording("start_new_session") else { return }
        resetMixWithOtherAudioForNewSession()
        cancelSkimBridge(restoringOrigin: true, resumeSource: false)
        cancelSleepTimer()
        announcedImportedInterjectionIDs.removeAll()
        pendingImportedCommentary = nil
        stopSpeechPreviews()
        streamingSpeechQueue.stopAndClear()
        if hasActiveSession, let engine {
            _ = try? engine.endSession()
            snapshot = engine.snapshot
        }
        activeItemId = id
        start()
    }

    func playLiveSpeechInstead() {
        guard canPlayLiveSpeechInstead else { return }
        liveSpeechFallbackItemIds.insert(activeItemId)
        pendingPreparedTextStartItemId = nil
        preparedTextAudioStatus = "live_fallback"
        snapshot.preparedTextAudioStatus = "live_fallback"
        diagnostics["textAudioFallback:\(activeItemId)"] = "explicit_user_action"
        start()
    }

    func openSession(_ session: Session) {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_session") else { return }
        resetMixWithOtherAudioForNewSession()
        announcedImportedInterjectionIDs.removeAll()
        pendingImportedCommentary = nil
        stopSpeechPreviews()
        do {
            let store = try requireStore()
            activeItemId = session.itemId
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return }
            if hasActiveSession {
                _ = try? engine.stopPlayback()
            }
            let inspected = try engine.inspectSession(sessionId: session.id)
            try prepareSourceMediaPlayback(itemId: session.itemId)
            snapshot = try applyPreferredPlaybackRate(to: inspected, engine: engine)
            selectedItem = try loadItemDetail(id: session.itemId, store: store)
            try refreshLibraryRows(store: store)
            screen = .playback
            reportSuccess("Opened session at \(session.completionPercent)% complete.")
        } catch {
            reportFailure(error, context: "Open session failed")
        }
    }

    func resumeSession(_ session: Session) {
        guard !rejectNavigationOrSessionMutationWhileRecording("resume_session") else { return }
        resetMixWithOtherAudioForNewSession()
        cancelSleepTimer()
        announcedImportedInterjectionIDs.removeAll()
        pendingImportedCommentary = nil
        guard !requireTermsDecisionBeforePlayback(.resumeSession(session.id)) else { return }
        stopSpeechPreviews()
        do {
            let store = try requireStore()
            activeItemId = session.itemId
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return }
            if hasActiveSession {
                _ = try? engine.stopPlayback()
            }
            _ = try engine.inspectSession(sessionId: session.id)
            try prepareSourceMediaPlayback(itemId: session.itemId)
            do {
                if session.completionPercent >= 100 {
                    let inspected = try engine.inspectSession(sessionId: session.id)
                    snapshot = try applyPreferredPlaybackRate(to: inspected, engine: engine)
                } else {
                    let resumed = try engine.resumePlayback()
                    snapshot = try applyPreferredPlaybackRate(to: resumed, engine: engine)
                }
            } catch SessionKitError.invalidCommandForState("playback_text_empty") {
                snapshot = try engine.playSourceFromBeginning()
            }
            selectedItem = try loadItemDetail(id: session.itemId, store: store)
            try refreshLibraryRows(store: store)
            screen = .playback
            reportSuccess(session.completionPercent >= 100
                ? "Opened completed session. Use Play from Beginning to restart."
                : "Resumed session at \(session.completionPercent)% complete.")
        } catch {
            reportFailure(error, context: "Resume session failed")
        }
    }

    func skipBack() {
        recordDeveloperDiagnostic("skip.request", ["direction": "back", "origin": "app_ui", "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1)])
        restoreSkimOriginBeforeCanonicalTransport()
        synchronizeStreamingSpeechAnchorIfNeeded()
        run { engine in
            snapshot = try engine.skipBack(unit: skipUnitForCurrentTarget())
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            refreshSelectedItem()
            reportSuccess("Skipped back.")
        }
    }

    func skipBackMedia() {
        recordDeveloperDiagnostic("skip.request", ["direction": "back", "origin": "app_ui", "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1)])
        restoreSkimOriginBeforeCanonicalTransport()
        run { engine in
            snapshot = try engine.skipBack(unit: mediaSkipUnit(seconds: mediaSkipBackSeconds))
            refreshSelectedItem()
        }
    }

    func skipForward() {
        recordDeveloperDiagnostic("skip.request", ["direction": "forward", "origin": "app_ui", "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1)])
        restoreSkimOriginBeforeCanonicalTransport()
        synchronizeStreamingSpeechAnchorIfNeeded()
        run { engine in
            let unit = skipUnitForCurrentTarget()
            snapshot = try engine.skipForward(unit: unit)
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            refreshSelectedItem()
            reportSuccess("Skipped forward.")
        }
    }

    func skipForwardMedia() {
        recordDeveloperDiagnostic("skip.request", ["direction": "forward", "origin": "app_ui", "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1)])
        restoreSkimOriginBeforeCanonicalTransport()
        run { engine in
            snapshot = try engine.skipForward(unit: mediaSkipUnit(seconds: mediaSkipForwardSeconds))
            refreshSelectedItem()
        }
    }

    func setMediaPlaybackRate(_ rate: Double) {
        guard !rejectNavigationOrSessionMutationWhileRecording("set_media_playback_rate") else { return }
        let clamped = max(0.5, min(2.0, (rate * 4).rounded() / 4))
        mediaPlaybackRate = clamped
        UserDefaults.standard.set(clamped, forKey: "mediaPlaybackRate")
        if var bridge = snapshot.skimBridgeState {
            if bridge.status == .playing {
                skimBridgePlayer?.rate = SummaryBridgeRatePolicy.transportRate(clamped)
            }
            snapshot.playbackRate = clamped
            bridge.status = snapshot.skimBridgeState?.status ?? bridge.status
            snapshot.skimBridgeState = bridge
            diagnostics["mediaPlaybackRate"] = String(format: "%.2f", clamped)
            return
        }
        run { engine in
            snapshot = try engine.setPlaybackRate(clamped)
            refreshSelectedItem()
            diagnostics["mediaPlaybackRate"] = String(format: "%.2f", clamped)
        }
    }

    /// Seeks the source player, or records the destination when a restored paused session
    /// has no player yet; the next playback start then opens the source there.
    private func seekOrStageMedia(_ engine: SessionEngine, toMediaTimeMs mediaTimeMs: Int) throws -> SessionSnapshot {
        do {
            return try engine.seekMedia(toMediaTimeMs: mediaTimeMs)
        } catch SessionKitError.invalidCommandForState(let reason)
            where reason == "media_seek_player_unavailable" && engine.snapshot.status == .paused {
            return try engine.stagePausedMediaPosition(toMediaTimeMs: mediaTimeMs)
        }
    }

    func seekMedia(toMediaTimeMs mediaTimeMs: Int) {
        recordDeveloperDiagnostic("seek.media.request", ["timeMs": String(mediaTimeMs)])
        restoreSkimOriginBeforeCanonicalTransport()
        run { engine in
            snapshot = try seekOrStageMedia(engine, toMediaTimeMs: mediaTimeMs)
            recordMediaSeekEvidence(from: engine)
            refreshSelectedItem()
        }
    }

    func cyclePlaybackRate() {
        guard !rejectNavigationOrSessionMutationWhileRecording("cycle_playback_rate") else { return }
        let current = isMediaPlaybackSnapshot ? mediaPlaybackRate : speechPlaybackRateMultiplier
        let next = Self.nextPlaybackRate(after: current)
        if isMediaPlaybackSnapshot {
            setMediaPlaybackRate(next)
        } else {
            speechRate = next * 0.5
            playbackSpeechRateChanged()
        }
    }

    func resetMixWithOtherAudioForNewSession() {
        if mixesWithOtherAudio {
            setMixesWithOtherAudio(false)
        } else {
            sessionAudioPlaybackClient?.setRemoteCommandHandlingEnabled(true)
            gate2CompactControls.setNowPlayingEnabled(true)
        }
        diagnostics["mixWithOtherAudio"] = "default_off_for_session"
    }

    nonisolated static func nextPlaybackRate(after current: Double) -> Double {
        supportedPlaybackRates.first(where: { $0 > current + 0.001 }) ?? supportedPlaybackRates[0]
    }

    private func recordMediaSeekEvidence(from engine: SessionEngine) {
        guard let request = engine.lastMediaSeekRequest,
              let resolution = engine.lastMediaSeekResolution else { return }
        let outcome: String
        switch resolution {
        case .pending:
            outcome = "pending"
        case .accepted(let mediaTimeMs):
            outcome = "accepted:\(mediaTimeMs)"
        case .failed(let actualMediaTimeMs, let reason):
            outcome = "failed:\(actualMediaTimeMs.map(String.init) ?? "unknown"):\(reason)"
        }
        let evidence = "id:\(request.id),requested:\(request.requestedMediaTimeMs),outcome:\(outcome)"
        if diagnostics["mediaSeek"] != evidence {
            recordDeveloperDiagnostic("seek.media.result", ["id": String(request.id),
                "requested": String(request.requestedMediaTimeMs), "outcome": outcome])
        }
        diagnostics["mediaSeek"] = evidence
    }

    func seekText(toCharOffset charOffset: Int) {
        if playingImportedCommentary != nil { stopImportedCommentaryPlayback(resumeSource: false) }
        recordDeveloperDiagnostic("seek.text.request", ["offset": String(charOffset)])
        synchronizeStreamingSpeechAnchorIfNeeded()
        run { engine in
            snapshot = try engine.seekText(toCharOffset: charOffset)
            streamingSpeechQueue.relinquishToCanonicalPlayback()
            refreshSelectedItem()
        }
    }

    func playbackSpeechRateChanged() {
        guard !rejectNavigationOrSessionMutationWhileRecording("set_speech_playback_rate") else { return }
        saveSpeechSettings()
        guard !isMediaPlaybackSnapshot else {
            return
        }
        if ttsVoiceSelection.supertonicVoice != nil, audioPlaybackClientOverride == nil {
            applySupertonicPlaybackRate()
            return
        }
        run { engine in
            snapshot = try engine.updateSpeechPlaybackSettings(
                voiceIdentifier: speechVoiceIdentifier.isEmpty ? nil : speechVoiceIdentifier,
                rate: Float(speechRate)
            )
            refreshSelectedItem()
            diagnostics["speechRateApplied"] = String(format: "%.2f", speechRate)
        }
    }

    func applySupertonicPlaybackRate() {
        let transportRate = speechPlaybackRateMultiplier
        do {
            try speechPlaybackClient?.configureSpeechSettings(
                voiceIdentifier: speechVoiceIdentifier.isEmpty ? nil : speechVoiceIdentifier,
                rate: Float(speechRate)
            )
            if let engine, hasActiveSession {
                snapshot = try engine.setPlaybackRate(transportRate)
                refreshSelectedItem()
            }
            diagnostics["speechRateApplied"] = String(format: "%.2f", transportRate)
        } catch {
            reportFailure(error, context: "Speaking rate update failed")
        }
    }

    func applyPreferredPlaybackRate(
        to started: SessionSnapshot,
        engine: SessionEngine
    ) throws -> SessionSnapshot {
        switch started.targetType {
        case TargetType.transcriptBackedMedia.rawValue, TargetType.browserOwnedMedia.rawValue:
            return started.playbackRate == mediaPlaybackRate
                ? started
                : try engine.setPlaybackRate(mediaPlaybackRate)
        case TargetType.itemTextTTS.rawValue,
             TargetType.assistantTurnTTS.rawValue,
             TargetType.summaryTurnTTS.rawValue where ttsVoiceSelection.supertonicVoice != nil:
            let transportRate = speechPlaybackRateMultiplier
            return started.playbackRate == transportRate
                ? started
                : try engine.setPlaybackRate(transportRate)
        default:
            return started
        }
    }

    func stopStalledPodcastStart(itemID: String) {
        guard snapshot.itemId == itemID, snapshot.status == .starting,
              selectedPodcastDownloadState != nil else { return }
        pause()
        reportFailure("Podcast playback did not start. Use Download Again in More to replace the saved audio, then press Play.")
    }

    func redownloadSelectedPodcast() {
        guard let coordinator = podcastDownloadCoordinator else { return }
        requestedPodcastTransportReplacements.insert(selectedItem.id)
        if coordinator.recordsByItemId[selectedItem.id] == nil {
            prioritizeOfflinePreparation(id: selectedItem.id)
        } else { coordinator.redownload(itemId: selectedItem.id) }
        reportConfirmation("Downloading a fresh copy of the podcast.")
    }

    func retrySelectedPodcastDownload() {
        guard !selectedItem.id.isEmpty, podcastDownloadCoordinator != nil else {
            reportFailure("Podcast download retry is unavailable.")
            return
        }
        podcastDownloadCoordinator?.retry(itemId: selectedItem.id)
        reportSuccess("Retrying podcast download.")
    }

    func downloadSelectedPodcastNow() {
        guard !selectedItem.id.isEmpty, podcastDownloadCoordinator != nil else {
            reportFailure("Podcast download is unavailable.")
            return
        }
        if podcastDownloadCoordinator?.downloadNow(itemId: selectedItem.id) == true {
            reportSuccess("Starting podcast download. Available storage will be checked first.")
        } else {
            reportWarning("The download could not start yet. Check the connection and try again.")
        }
    }

    func clearPodcastDownloads() {
        podcastDownloadCoordinator?.clearDownloads()
        reportConfirmation("Cleared downloaded podcast audio. Remote sources remain available.")
    }

    private func skipUnitForCurrentTarget() -> String {
        switch snapshot.targetType {
        case TargetType.transcriptBackedMedia.rawValue, TargetType.browserOwnedMedia.rawValue:
            return mediaSkipUnit(seconds: mediaSkipForwardSeconds)
        default:
            return skipUnit
        }
    }

    private func mediaSkipUnit(seconds: Int) -> String {
        "time_\(Self.validatedMediaSkipSeconds(seconds))s"
    }

    static func validatedMediaSkipSeconds(_ seconds: Int) -> Int {
        supportedMediaSkipSeconds.contains(seconds) ? seconds : 15
    }

    func endSession() {
        guard !rejectNavigationOrSessionMutationWhileRecording("end_session") else { return }
        closeCurrentSession(navigateHome: true)
    }

    func dismissMiniPlayer() {
        recordDeveloperDiagnostic("miniPlayer.close")
        guard !rejectNavigationOrSessionMutationWhileRecording("dismiss_mini_player") else { return }
        guard !isDismissingMiniPlayer else { return }
        isDismissingMiniPlayer = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.closeCurrentSession(navigateHome: false)
            self.isDismissingMiniPlayer = false
        }
    }

    private func closeCurrentSession(
        navigateHome: Bool,
        successMessage: String = "Session saved. You can resume it later."
    ) {
        cancelSkimBridge(restoringOrigin: true, resumeSource: false)
        let closedItemId = snapshot.itemId ?? activeItemId
        run { engine in
            snapshot = try engine.endSession(stoppingInlinePlayback: endMarginMoment)
            activeItemId = closedItemId
            refreshSelectedItem()
            if let store {
                try refreshLibraryRows(store: store)
            }
            reportConfirmation(successMessage)
        }
        streamingSpeechQueue.stopAndClear()
        gate2CompactControls.endLiveActivities()
        resetMixWithOtherAudioForNewSession()
        if let renderer = supertonicRenderer {
            Task { await renderer.unload() }
        }
        if navigateHome {
            screen = .home
        }
    }

    #if SPOKEN_MARGINS_WATCH
    func renderSelectedItemForWatchPackage() {
        renderWatchPackage(itemId: selectedItem.id, transferAfterRender: false)
    }
    #endif

    func playTurn(_ turn: ConversationTurn, fromTimeline: Bool = false) {
        stopSpeechPreviews()
        run { engine in
            try playTurn(turn.id, engine: engine)
            if fromTimeline {
                recordTimelineReviewCompleted()
            }
            reportSuccess("Playing \(turnTitleText(turn)).")
        }
    }

    func jumpToTurnChapter(turn: ConversationTurn, chapter: Chapter, fromTimeline: Bool = false) {
        stopSpeechPreviews()
        clearPendingAutoPlayTurns()
        run { engine in
            snapshot = try engine.jumpToTurnChapter(turnId: turn.id, chapterId: chapter.id)
            refreshSelectedItem()
            screen = .playback
            if fromTimeline {
                recordTimelineReviewCompleted()
            }
            reportSuccess("Jumped to \(chapter.title).")
        }
    }

    private func playTurn(_ turnId: String, engine: SessionEngine) throws {
        try playTurn(turnId, engine: engine, clearsPendingQueue: true)
    }

    private func playTurn(_ turnId: String, engine: SessionEngine, clearsPendingQueue: Bool) throws {
        stopSpeechPreviews()
        streamingSpeechQueue.stopAndClear()
        if clearsPendingQueue {
            clearPendingAutoPlayTurns()
        }
        snapshot = try engine.playTurn(turnId: turnId)
        refreshSelectedItem()
        screen = .playback
    }

    func autoPlayCompletedTurn(
        kind: String,
        turnId: String,
        engine: SessionEngine,
        completedCurrentAudio: Bool = false
    ) throws {
        guard kind == "interjection_summary" || kind == "assistant_response" else { return }
        if shouldDeferGeneratedTurnPlayback(turnId: turnId, completedCurrentAudio: completedCurrentAudio) {
            enqueuePendingAutoPlayTurn(turnId)
            return
        }
        try playTurn(turnId, engine: engine)
    }

    @discardableResult
    private func playPendingTurnIfReady(completedCurrentAudio: Bool = false) -> Bool {
        guard let engine,
              let turnId = pendingAutoPlayQueue.popReadyTurn(snapshot: snapshot, completedCurrentAudio: completedCurrentAudio) else {
            return false
        }
        do {
            updatePendingAutoPlayDiagnostics(reason: "draining_queue")
            try playTurn(turnId, engine: engine, clearsPendingQueue: false)
            reportSuccess("Playing generated response.")
            return true
        } catch {
            reportFailure(error, context: "Auto-play generated response failed")
            return false
        }
    }

    private func closeCompletedSessionIfReady() {
        guard snapshot.sourceProgressPercent >= 100,
              snapshot.currentPlaybackProgressPercent >= 100,
              pendingAutoPlayQueue.count == 0,
              !selectedItem.turns.contains(where: { $0.status == "pending" || $0.status == "streaming" }) else {
            return
        }
        guard snapshot.phase == .finished else { return }
        if let store {
            try? refreshLibraryRows(store: store)
        }
        refreshMarginRows()
        diagnostics["completedSessionPresentation"] = "retained_finished_session"
        reportConfirmation("Session complete and saved.")
    }

    func shouldDeferGeneratedTurnPlayback(turnId: String, completedCurrentAudio: Bool = false) -> Bool {
        pendingAutoPlayQueue.shouldDeferGeneratedTurnPlayback(
            snapshot: snapshot,
            turnId: turnId,
            completedCurrentAudio: completedCurrentAudio
        )
    }

    private func shouldPlayPendingTurnNow(turnId: String, completedCurrentAudio: Bool = false) -> Bool {
        pendingAutoPlayQueue.shouldPlayPendingTurnNow(snapshot: snapshot, turnId: turnId, completedCurrentAudio: completedCurrentAudio)
    }

    private func enqueuePendingAutoPlayTurn(_ turnId: String) {
        pendingAutoPlayQueue.enqueue(turnId)
        updatePendingAutoPlayDiagnostics(reason: "waiting_for_current_audio")
    }

    private func clearPendingAutoPlayTurns() {
        pendingAutoPlayQueue.clear()
        diagnostics["pendingAutoPlayTurnId"] = nil
        diagnostics["pendingAutoPlayQueue"] = "0"
        diagnostics["pendingAutoPlayReason"] = nil
    }

    func dispatchGate2CompactCommand(
        _ command: CompactControlCommand,
        chapterId: String? = nil,
        mediaTimeMs: Int? = nil,
        playbackRate: Double? = nil,
        origin: String = "app_ui"
    ) {
        if command == .beginInterjection {
            guard !recordingNavigationIsLocked else { return }
            if recordingClientOverride != nil {
                performGate2CompactCommand(command, chapterId: chapterId, mediaTimeMs: mediaTimeMs, playbackRate: playbackRate, origin: origin)
                return
            }
            isRequestingRecordingPermission = true
            Task {
                let granted = await SystemRecordingClient.requestRecordPermission()
                guard granted else {
                    isRequestingRecordingPermission = false
                    reportFailure("Microphone access is required to record Margins from compact controls.")
                    return
                }
                performGate2CompactCommand(command, chapterId: chapterId, mediaTimeMs: mediaTimeMs, playbackRate: playbackRate, origin: origin)
                isRequestingRecordingPermission = false
            }
            return
        }
        performGate2CompactCommand(command, chapterId: chapterId, mediaTimeMs: mediaTimeMs, playbackRate: playbackRate, origin: origin)
    }

    func handleGate2CompactURL(_ url: URL) {
        guard let rawCommand = Gate2CompactCommandURL.command(from: url) else {
            reportFailure("Unsupported compact control URL.")
            return
        }
        guard let command = CompactControlCommand(rawValue: rawCommand) else {
            if !handleGate2CompactApplicationCommand(
                rawCommand,
                targetID: Gate2CompactCommandURL.chapterId(from: url)
            ) {
                reportFailure("Unsupported compact control URL.")
            }
            return
        }
        dispatchGate2CompactCommand(
            command,
            chapterId: Gate2CompactCommandURL.chapterId(from: url),
            origin: "compact_url"
        )
    }

    @discardableResult
    func handleGate2CompactApplicationCommand(_ command: String, targetID: String? = nil) -> Bool {
        switch command {
        case Gate2CompactApplicationCommand.summarizeInterjections:
            guard gate2CompactSnapshot?.availableCommands.contains(.generateInterjectionSummary) == true else {
                reportFailure("Summary is unavailable for the current compact surface state.")
                return false
            }
            summarize()
            return true
        case Gate2CompactApplicationCommand.discussInterjections:
            guard gate2CompactSnapshot?.availableCommands.contains(.submitFollowup) == true else {
                reportFailure("Discuss is unavailable for the current compact surface state.")
                return false
            }
            discuss(followUp: "")
            return true
        case Gate2CompactApplicationCommand.listenToSharedMargin:
            guard pendingImportedCommentary != nil else { return false }
            listenToPendingImportedCommentary()
            screen = .playback
            return true
        case Gate2CompactApplicationCommand.dismissSharedMargin:
            guard pendingImportedCommentary != nil else { return false }
            dismissPendingImportedCommentary()
            return true
        case Gate2CompactApplicationCommand.jumpToSharedMargin:
            guard let targetID, !targetID.isEmpty else { return false }
            return jumpToImportedCommentary(interjectionID: targetID)
        default:
            reportFailure("Unsupported compact application command.")
            return false
        }
    }

    var hasActiveSession: Bool {
        snapshot.sessionId != nil
    }

    static func isResumableSession(_ session: Session) -> Bool {
        session.status == "in_progress" && session.phase != .abandoned
    }

    static func preferredContinuationSession(in sessions: [Session]) -> Session? {
        sessions.sorted { lhs, rhs in
            let left = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
            let right = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
            return left == right ? lhs.id < rhs.id : left > right
        }.first { session in
            isResumableSession(session)
                || (session.status == "finished" && session.completionPercent >= 100)
        }
    }

    var selectedItemPreferredContinuationSession: Session? {
        Self.preferredContinuationSession(in: selectedItem.sessions)
    }

    var shouldShowMiniPlayer: Bool {
        hasActiveSession && !isDismissingMiniPlayer && screen != .playback && snapshot.phase != .finished && snapshot.phase != .abandoned
    }

    var isMediaPlaybackSnapshot: Bool {
        snapshot.targetType == TargetType.transcriptBackedMedia.rawValue ||
            snapshot.targetType == TargetType.browserOwnedMedia.rawValue
    }

    /// Starter audio represents only a bounded prefix of a text source. Exposing
    /// a full-range scrubber in that state would imply that every destination is
    /// already prepared, so the player falls back to truthful progress until the
    /// complete render is available.
    var canShowFullPlaybackScrubber: Bool {
        guard snapshot.targetType == TargetType.itemTextTTS.rawValue else { return true }
        return snapshot.preparedTextAudioStatus != "starter_ready"
    }

    var displayPlaybackProgressPercent: Int {
        switch snapshot.targetType {
        case TargetType.itemTextTTS.rawValue,
            TargetType.transcriptBackedMedia.rawValue,
            TargetType.browserOwnedMedia.rawValue:
            return snapshot.sourceProgressPercent
        default:
            return snapshot.currentPlaybackProgressPercent
        }
    }

    var canPlayLiveSpeechInstead: Bool {
        pendingPreparedTextStartItemId == activeItemId
    }

    var mediaPlaybackRateDescription: String {
        String(format: "%.2fx", mediaPlaybackRate)
    }

    var compactPlaybackRateDescription: String {
        if isMediaPlaybackSnapshot {
            return String(format: "%.2f×", mediaPlaybackRate)
        }
        return String(format: "%.2f×", speechPlaybackRateMultiplier)
    }

    var playbackHeaderTitle: String {
        let itemTitle = selectedItem.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let reportedTitle = (snapshot.chapterTitle ?? snapshot.title ?? itemTitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshotTitle = reportedTitle.isEmpty || reportedTitle.caseInsensitiveCompare(itemTitle) == .orderedSame
            ? (inferredPlaybackChapterTitle ?? itemTitle)
            : reportedTitle
        guard !snapshotTitle.isEmpty else { return itemTitle }
        guard snapshotTitle.caseInsensitiveCompare(itemTitle) != .orderedSame else { return itemTitle }

        let chapterTitles = playbackChapterTitles
        guard let chapterIndex = chapterTitles.firstIndex(where: {
            $0.caseInsensitiveCompare(snapshotTitle) == .orderedSame
        }) else {
            return snapshotTitle
        }
        return ChapterHeaderLabel.title(snapshotTitle, index: chapterIndex)
    }

    private var inferredPlaybackChapterTitle: String? {
        switch snapshot.targetType {
        case TargetType.itemTextTTS.rawValue:
            return currentChapter?.title
        case TargetType.transcriptBackedMedia.rawValue, TargetType.browserOwnedMedia.rawValue:
            let mediaTimeMs = snapshot.currentMediaTimeMs ?? 0
            let authoredChapters = selectedItem.mediaChapters
                .filter { !$0.id.hasPrefix("ch-transcript-") && !$0.id.contains("-ch-transcript-") }
                .sorted { $0.startMs < $1.startMs }
            if let title = authoredChapters.last(where: { $0.startMs <= mediaTimeMs })?.title {
                return title
            }
            return selectedItem.listeningMapScenes
                .sorted { $0.startMs < $1.startMs }
                .last(where: { $0.startMs <= mediaTimeMs })?
                .title
        default:
            return nil
        }
    }

    var playbackItemHeaderTitle: String {
        // The mini player appears on every screen, so it names what is playing, not whichever item page is open.
        if let playingId = snapshot.itemId, playingId != selectedItem.id {
            let title = (libraryItems.first { $0.id == playingId }?.title ?? snapshot.title ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return selectedItem.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var playbackChapterHeaderTitle: String? {
        let itemTitle = playbackItemHeaderTitle
        let combined = playbackHeaderTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty,
              combined.caseInsensitiveCompare(itemTitle) != .orderedSame else {
            return nil
        }
        return combined
    }

    func openCurrentPlaybackItem() {
        guard let itemId = snapshot.itemId ?? (selectedItem.id.isEmpty ? nil : selectedItem.id) else { return }
        openItem(id: itemId)
    }

    func isCurrentTimelineChapter(_ chapter: Chapter, turnId: String? = nil) -> Bool {
        if turnId == nil {
            let sourceTargetTypes = [
                TargetType.itemTextTTS.rawValue,
                TargetType.transcriptBackedMedia.rawValue,
                TargetType.browserOwnedMedia.rawValue
            ]
            guard let targetType = snapshot.targetType, sourceTargetTypes.contains(targetType) else { return false }
            if let currentChapterId = engine?.currentSession?.position.chapterId,
               selectedItem.chapters.contains(where: { $0.id == currentChapterId }) {
                return currentChapterId == chapter.id
            }
            if let currentTitle = snapshot.chapterTitle,
               selectedItem.chapters.contains(where: { $0.title.caseInsensitiveCompare(currentTitle) == .orderedSame }) {
                return currentTitle.caseInsensitiveCompare(chapter.title) == .orderedSame
            }
            return currentChapter?.id == chapter.id
        }

        let expectedTargetType = selectedItem.turns.first(where: { $0.id == turnId })?.turnType == "interjection_summary"
            ? TargetType.summaryTurnTTS.rawValue
            : TargetType.assistantTurnTTS.rawValue
        guard snapshot.targetType == expectedTargetType else { return false }
        if let turnId, snapshot.targetId != turnId { return false }
        if let currentChapterId = engine?.currentSession?.position.chapterId {
            return currentChapterId == chapter.id
        }
        return snapshot.chapterTitle?.caseInsensitiveCompare(chapter.title) == .orderedSame
    }

    func isCurrentTimelineMediaChapter(_ chapter: MediaTimelineChapter) -> Bool {
        guard snapshot.targetType == TargetType.transcriptBackedMedia.rawValue
                || snapshot.targetType == TargetType.browserOwnedMedia.rawValue else {
            return false
        }
        if let currentChapterId = engine?.currentSession?.position.chapterId,
           selectedItem.mediaChapters.contains(where: { $0.id == currentChapterId }) {
            return currentChapterId == chapter.id
        }
        return snapshot.chapterTitle?.caseInsensitiveCompare(chapter.title) == .orderedSame
    }

    func isCurrentTimelineListeningMapScene(_ scene: MediaTimelineChapter) -> Bool {
        guard snapshot.targetType == TargetType.transcriptBackedMedia.rawValue
                || snapshot.targetType == TargetType.browserOwnedMedia.rawValue,
              let currentTimeMs = snapshot.currentMediaTimeMs else {
            return false
        }
        let scenes = selectedItem.listeningMapScenes.sorted { $0.startMs < $1.startMs }
        guard let index = scenes.firstIndex(where: { $0.id == scene.id }) else { return false }
        let endMs = scenes.indices.contains(index + 1) ? scenes[index + 1].startMs : Int.max
        return currentTimeMs >= scene.startMs && currentTimeMs < endMs
    }

    private var playbackChapterTitles: [String] {
        switch snapshot.targetType {
        case TargetType.itemTextTTS.rawValue:
            return selectedItem.chapters.map(\.title)
        case TargetType.summaryTurnTTS.rawValue, TargetType.assistantTurnTTS.rawValue:
            return selectedItem.turns
                .first(where: { $0.id == snapshot.targetId })?
                .chapters?
                .map(\.title) ?? []
        case TargetType.transcriptBackedMedia.rawValue, TargetType.browserOwnedMedia.rawValue:
            let authoredTitles = selectedItem.mediaChapters
                .filter { !$0.id.hasPrefix("ch-transcript-") && !$0.id.contains("-ch-transcript-") }
                .sorted { $0.startMs < $1.startMs }
                .map(\.title)
            if !authoredTitles.isEmpty { return authoredTitles }
            return selectedItem.listeningMapScenes
                .sorted { $0.startMs < $1.startMs }
                .map(\.title)
        default:
            return []
        }
    }

    var preparedTextAudioStatusDescription: String {
        humanReadableStatus(preparedTextAudioStatus)
    }

    var shouldShowOnDeviceSpeechGenerationStatus: Bool {
        Self.supportsOnDeviceSpeechGenerationStatus(targetType: snapshot.targetType)
            && ttsVoiceSelection.supertonicVoice != nil
            && onDeviceSpeechGenerationStatus != RenderedSpeechGenerationState.inactive.rawValue
    }

    static func supportsOnDeviceSpeechGenerationStatus(targetType: String?) -> Bool {
        switch targetType {
        case TargetType.itemTextTTS.rawValue,
             TargetType.summaryTurnTTS.rawValue,
             TargetType.assistantTurnTTS.rawValue:
            return true
        default:
            return false
        }
    }

    var canStopOnDeviceSpeechGeneration: Bool {
        onDeviceSpeechGenerationStatus == RenderedSpeechGenerationState.rendering.rawValue
    }

    var isOnDeviceSpeechGenerating: Bool {
        onDeviceSpeechGenerationStatus == RenderedSpeechGenerationState.rendering.rawValue
    }

    var canRetryOnDeviceSpeechGeneration: Bool {
        guard speechPlaybackClient is SupertonicSpeechPlaybackClient, snapshot.targetId != nil, snapshot.sessionId != nil else { return false }
        return onDeviceSpeechGenerationStatus == RenderedSpeechGenerationState.stopped.rawValue
            || preparedTextAudioStatus == "failed"
    }

    func retryOnDeviceSpeechGeneration() {
        guard let client = speechPlaybackClient as? SupertonicSpeechPlaybackClient,
              let targetId = snapshot.targetId,
              let sessionId = snapshot.sessionId else {
            reportFailure("There is no current Supertonic response to retry.")
            return
        }
        let itemId = snapshot.itemId
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let coordinator = self.preparedAudioCoordinator,
                   let signature = self.currentSupertonicRenderSignature {
                    try await coordinator.retry(itemId: targetId, signature: signature)
                }
                guard self.snapshot.sessionId == sessionId, self.snapshot.targetId == targetId else { return }
                if let itemId { self.allowAudioPreparation(itemId: itemId) }
                guard try client.retryOnDeviceRendering() else { return }
                self.speechFallbackReason = nil
                self.preparedTextAudioStatus = "preparing"
                self.diagnostics["onDeviceSpeechGeneration"] = "retry_current_target"
                self.reportConfirmation("Retrying Supertonic at the current position.")
            } catch {
                self.reportFailure(error, context: "Prepared audio retry failed", itemId: itemId)
            }
        }
    }

    var onDeviceSpeechGenerationStatusDescription: String {
        (RenderedSpeechGenerationState(rawValue: onDeviceSpeechGenerationStatus) ?? .inactive).listenerDescription(
            progress: onDeviceSpeechGenerationProgress, isDelayed: isOnDeviceSpeechGenerationDelayed,
            stopReason: onDeviceSpeechGenerationStopReason, fallbackReason: speechFallbackReason
        )
    }

    func updateOnDeviceSpeechGenerationState(_ state: RenderedSpeechGenerationState, stopReason: String?) {
        if onDeviceSpeechGenerationStatus != state.rawValue { onDeviceSpeechGenerationStatus = state.rawValue }
        if onDeviceSpeechGenerationStopReason != stopReason { onDeviceSpeechGenerationStopReason = stopReason }
        // Rendering, ready or idle: the iOS voice isn't standing in, so an old reason is stale (#314).
        if state != .stopped, speechFallbackReason != nil { speechFallbackReason = nil }
        if canPrepareLibraryAudio { startForegroundAudioPreparationIfNeeded() }
        diagnostics["onDeviceSpeechGeneration"] = state.rawValue
        diagnostics["onDeviceSpeechGenerationStopReason"] = stopReason
        guard state != .rendering else { return }
        onDeviceSpeechGenerationDelayTask?.cancel()
        onDeviceSpeechGenerationDelayTask = nil
        isOnDeviceSpeechGenerationDelayed = false
        if state == .inactive {
            onDeviceSpeechGenerationProgress = RenderedSpeechGenerationProgress(
                completedChunks: 0,
                totalChunks: 0
            )
        }
    }

    private func updateOnDeviceSpeechGenerationProgress(_ progress: RenderedSpeechGenerationProgress) {
        guard onDeviceSpeechGenerationProgress != progress else { return }
        onDeviceSpeechGenerationProgress = progress
        if canPrepareLibraryAudio { startForegroundAudioPreparationIfNeeded() }
        isOnDeviceSpeechGenerationDelayed = false
        diagnostics["onDeviceSpeechGenerationProgress"] = "\(progress.completedChunks)/\(progress.totalChunks)"
        onDeviceSpeechGenerationDelayTask?.cancel()
        onDeviceSpeechGenerationDelayTask = nil
        guard progress.completedChunks < progress.totalChunks else { return }
        onDeviceSpeechGenerationDelayTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self,
                  self.onDeviceSpeechGenerationStatus == RenderedSpeechGenerationState.rendering.rawValue,
                  self.onDeviceSpeechGenerationProgress == progress else { return }
            self.isOnDeviceSpeechGenerationDelayed = true
            self.diagnostics["onDeviceSpeechGenerationDelay"] = "chunk_\(progress.completedChunks + 1)_over_45s"
        }
    }

    var sourceTranscriptStatusDescription: String {
        humanReadableStatus(sourceTranscriptStatus)
    }

    private func humanReadableStatus(_ status: String) -> String {
        switch status {
        case "not_started":
            return "not started"
        case "rendering":
            return "rendering"
        case "starter_ready":
            return "starter ready"
        case "ready", "complete":
            return "ready"
        case "failed":
            return "failed"
        case "live_fallback":
            return "live fallback"
        case "queued":
            return "queued"
        case "downloading":
            return "downloading"
        case "transcribing":
            return "transcribing"
        case "unavailable":
            return "unavailable"
        default:
            return status.replacingOccurrences(of: "_", with: " ")
        }
    }

    var currentChapter: Chapter? {
        // Multiple short chapters can share one rounded percentage. Prefer
        // the exact source position so the label cannot jump ahead of audio.
        if snapshot.targetType == TargetType.itemTextTTS.rawValue,
           let offset = snapshot.currentTextStart {
            return selectedItem.chapters.last { $0.startChar <= offset } ?? selectedItem.chapters.first
        }
        if let session = engine?.currentSession, session.itemId == selectedItem.id,
           let chapter = selectedItem.chapters.first(where: { $0.id == session.position.chapterId }) {
            return chapter
        }
        if let title = snapshot.chapterTitle,
           let chapter = selectedItem.chapters.first(where: { $0.title == title }) {
            return chapter
        }
        return selectedItem.chapters.last { $0.percent <= snapshot.sourceProgressPercent } ?? selectedItem.chapters.first
    }

    func installEngine(_ engine: SessionEngine) {
        self.engine = engine
        for record in podcastDownloadRecords.values where record.state == .availableOffline {
            guard let path = record.localRelativePath,
                  let url = try? applicationSupportDirectory()
                    .appending(path: "PodcastAudio", directoryHint: .isDirectory)
                    .appending(path: path) else { continue }
            _ = try? engine.updatePlaybackTransport(itemId: record.itemId, playbackURL: url.absoluteString)
        }
        configureGate2CompactControls(for: engine)
    }

    private func configureGate2CompactControls(for engine: SessionEngine) {
        do {
            let surfaceProfile = try loadProfile(id: "lock-screen-widget")
            gate2CompactControls.configure(
                canonicalRuntime: engine,
                surfaceProfile: surfaceProfile,
                skipUnit: mediaSkipUnit(seconds: mediaSkipForwardSeconds)
            ) { [weak self] command, origin, chapterId, mediaTimeMs, playbackRate in
                self?.dispatchGate2CompactCommand(
                    command,
                    chapterId: chapterId,
                    mediaTimeMs: mediaTimeMs,
                    playbackRate: playbackRate,
                    origin: origin
                )
            } applicationCommandHandler: { [weak self] command, targetID in
                self?.handleGate2CompactApplicationCommand(command, targetID: targetID) ?? false
            }
            gate2CompactControls.setNowPlayingEnabled(!mixesWithOtherAudio)
            updateGate2CompactState()
            diagnostics.merge(gate2CompactControls.diagnostics(), uniquingKeysWith: { _, new in new })
        } catch {
            diagnostics["gate2CompactSurface"] = "configuration_failed"
            diagnostics["gate2CompactError"] = String(describing: error)
        }
    }

    func updateGate2CompactState() {
        // The source Live Activity cannot describe the separate Margin player.
        // Its native Now Playing owner supplies transport until source restoration.
        guard playingImportedCommentary == nil else { return }
        let sharedMarginPrompt = pendingImportedCommentary.map {
            Gate2SharedMarginActivityPrompt(
                senderLabel: $0.senderLabel
            )
        }
        gate2CompactControls.update(
            snapshot: snapshot,
            sharedMarginPrompt: sharedMarginPrompt,
            upcomingSharedMargins: liveActivitySharedMarginNavigationEntries()
        )
        let compactSnapshot = gate2CompactControls.snapshot
        if gate2CompactSnapshot != compactSnapshot {
            gate2CompactSnapshot = compactSnapshot
        }
        let compactDiagnostics = gate2CompactControls.diagnostics()
        if compactDiagnostics.contains(where: { diagnostics[$0.key] != $0.value }) {
            diagnostics.merge(compactDiagnostics, uniquingKeysWith: { _, new in new })
        }
    }

    private func liveActivitySharedMarginNavigationEntries() -> [Gate2LiveActivityNavigationEntry] {
        let currentPercent = snapshot.sourceProgressPercent
        let mediaDurationMs = snapshot.currentPlaybackDurationMs ?? selectedItem.mediaDurationMs
        let textLength = selectedItem.text.count
        return importedCommentaryPrompts(includeAnnounced: false).compactMap { prompt in
            let positionPercent: Int?
            if let mediaTimeMs = prompt.interjection.resolution.localMediaTimeMs,
               let mediaDurationMs,
               mediaDurationMs > 0 {
                positionPercent = Int((Double(mediaTimeMs) / Double(mediaDurationMs) * 100).rounded())
            } else if let charOffset = prompt.interjection.resolution.localStartChar,
                      textLength > 0 {
                positionPercent = Int((Double(charOffset) / Double(textLength) * 100).rounded())
            } else {
                positionPercent = nil
            }
            guard let positionPercent,
                  positionPercent > currentPercent else { return nil }
            return Gate2LiveActivityNavigationEntry(
                kind: .sharedMargin,
                title: "Shared Margin",
                targetID: prompt.interjection.id,
                positionPercent: min(100, max(0, positionPercent))
            )
        }
    }

    #if SPOKEN_MARGINS_WATCH
    private func configureGate3WatchControls(for engine: SessionEngine) {
        do {
            let surfaceProfile = try loadProfile(id: "watch-tethered")
            gate3WatchDispatcher = CompactControlDispatcher(
                surfaceProfile: surfaceProfile,
                canonicalRuntime: engine,
                defaultSkipUnit: skipUnit
            )
            updateGate3WatchState()
        } catch {
            diagnostics["gate3WatchSurface"] = "configuration_failed"
            diagnostics["gate3WatchError"] = String(describing: error)
        }
    }

    private func gate3WatchSnapshot() -> CompactControlSnapshot? {
        gate3WatchDispatcher?.snapshot()
    }

    private func updateGate3WatchState() {
        gate3WatchConnectivity.publish(snapshot: gate3WatchSnapshot())
        diagnostics.merge(gate3WatchConnectivity.diagnostics(), uniquingKeysWith: { _, new in new })
    }

    private func gate4WatchPackageLibraryRows() -> [WatchPackageLibraryRow] {
        do {
            let store = try requireStore()
            try seedGate4WatchPackageFixture(store: store)
            let items = try store.listItems()
            return try items.flatMap { item -> [WatchPackageLibraryRow] in
                let packages = try store.loadWatchAudioPackages(itemId: item.id)
                let requests = try store.loadWatchPackageRequests(itemId: item.id)
                if let package = packages.sorted(by: { $0.createdAt > $1.createdAt }).first {
                    let hasTransferRequest = requests.contains { $0.packageId == package.id && $0.requestType == .watchTransferRequested }
                    return [
                        WatchPackageLibraryRow(
                            itemId: item.id,
                            title: package.item.title.isEmpty ? item.title : package.item.title,
                            status: hasTransferRequest ? .queuedForTransfer : .availableForTransfer,
                            packageId: package.id,
                            progressPercent: hasTransferRequest ? 0 : nil
                        )
                    ]
                }
                let hasPrerenderRequest = requests.contains { $0.requestType == .prerenderRequested }
                let status: WatchPackageLibraryStatus
                if activeWatchPackageRenderItemIds.contains(item.id) {
                    status = .rendering
                } else if failedWatchPackageRenderItemIds.contains(item.id) {
                    status = .failed
                } else if hasPrerenderRequest {
                    status = .rendering
                } else {
                    status = .needsPrerender
                }
                return [
                    WatchPackageLibraryRow(
                        itemId: item.id,
                        title: item.title,
                        status: status,
                        packageId: nil,
                        progressPercent: status == .rendering ? 0 : nil
                    )
                ]
            }
        } catch {
            diagnostics["gate4WatchPackageLibraryError"] = String(describing: error)
            return []
        }
    }

    private func gate4WatchPackage(packageId: String) throws -> WatchAudioPackage? {
        let store = try requireStore()
        try seedGate4WatchPackageFixture(store: store)
        return try store.loadWatchAudioPackage(id: packageId)
    }

    private func handleGate4WatchPackageRequest(_ request: WatchPackageRequestEvent) {
        do {
            let store = try requireStore()
            try store.saveWatchPackageRequest(request)
            diagnostics["gate4WatchLastPackageRequest"] = "\(request.requestType.rawValue):\(request.itemId)"
            if request.requestType == .prerenderRequested {
                renderWatchPackage(itemId: request.itemId, transferAfterRender: true)
            } else if request.requestType == .watchTransferRequested, let packageId = request.packageId {
                gate3WatchConnectivity.transferWatchPackage(packageId: packageId)
            }
            gate3WatchConnectivity.publishPackageLibrary()
        } catch {
            diagnostics["gate4WatchPackageRequestError"] = String(describing: error)
            reportFailure(error, context: "Watch package request failed")
        }
    }

    private func handleGate4WatchSyncEvent(_ event: WatchSyncEvent) {
        do {
            let store = try requireStore()
            try seedGate4WatchPackageFixture(store: store)
            try store.saveWatchSyncEvent(event)
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            _ = try engine?.importWatchSyncEvent(eventId: event.id)
            if let engine {
                snapshot = engine.snapshot
            }
            libraryItems = try loadLibraryRows(store: store)
            let importedItemId: String?
            if let itemId = event.itemId {
                importedItemId = itemId
            } else {
                importedItemId = try store.loadWatchAudioPackage(id: event.watchPackageId)?.itemId
            }
            if let itemId = importedItemId {
                selectedItem = try loadItemDetail(id: itemId, store: store)
            }
            diagnostics["gate4WatchLastImportedEvent"] = event.id
            reportSuccess("Imported Watch event \(event.id).")
        } catch {
            diagnostics["gate4WatchSyncEventError"] = String(describing: error)
            reportFailure(error, context: "Watch sync import failed")
        }
    }

    private func renderWatchPackage(itemId: String, transferAfterRender: Bool) {
        guard !itemId.isEmpty else {
            reportFailure("Choose an item before rendering Watch audio.")
            return
        }
        guard !activeWatchPackageRenderItemIds.contains(itemId) else {
            reportFailure("Watch audio is already rendering for this item.")
            return
        }
        activeWatchPackageRenderItemIds.insert(itemId)
        failedWatchPackageRenderItemIds.remove(itemId)
        isRenderingWatchPackage = true
        watchPackageRenderStatus = "Rendering"
        diagnostics["gate4WatchRenderItem"] = itemId
        gate3WatchConnectivity.publishPackageLibrary()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let store = try self.requireStore()
                let item = try store.loadItem(id: itemId)
                let map = try store.loadListeningMap(itemId: itemId)
                let coordinator = WatchPackageRenderCoordinator(
                    applicationSupportDirectory: try self.applicationSupportDirectory()
                )
                let output = try await coordinator.renderSystemSpeechPackage(
                    item: item,
                    map: map,
                    voiceIdentifier: self.speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self.speechVoiceIdentifier,
                    rate: Float(self.speechRate)
                )
                try store.saveWatchAudioPackage(output.package)
                self.activeWatchPackageRenderItemIds.remove(itemId)
                self.failedWatchPackageRenderItemIds.remove(itemId)
                self.isRenderingWatchPackage = !self.activeWatchPackageRenderItemIds.isEmpty
                self.libraryItems = try self.loadLibraryRows(store: store)
                if itemId == self.selectedItem.id || itemId == self.activeItemId {
                    self.selectedItem = try self.loadItemDetail(id: itemId, store: store)
                }
                self.diagnostics["gate4WatchLastRenderedPackage"] = output.package.id
                self.diagnostics["gate4WatchLastRenderedAudio"] = output.audioURL.lastPathComponent
                self.watchPackageRenderStatus = "Available"
                self.reportSuccess("Rendered Watch package \(output.package.item.title).")
                self.gate3WatchConnectivity.publishPackageLibrary()
                if transferAfterRender {
                    self.gate3WatchConnectivity.transferWatchPackage(packageId: output.package.id)
                }
            } catch {
                self.activeWatchPackageRenderItemIds.remove(itemId)
                self.failedWatchPackageRenderItemIds.insert(itemId)
                self.isRenderingWatchPackage = !self.activeWatchPackageRenderItemIds.isEmpty
                self.watchPackageRenderStatus = "Failed"
                self.diagnostics["gate4WatchRenderError"] = String(describing: error)
                self.reportFailure(error, context: "Watch package render failed")
                self.gate3WatchConnectivity.publishPackageLibrary()
            }
        }
    }

    private func dispatchGate3WatchCommand(_ request: Gate3WatchCommandRequest) {
        diagnostics["gate2LastCommandOrigin"] = "watch_connectivity_legacy"
        if request.command == .beginInterjection {
            diagnostics["gate3WatchLastCommand"] = request.command.rawValue
            diagnostics["gate3WatchLastResult"] = "disabled_until_watch_recording"
            updateGate3WatchState()
            reportFailure("Recording a Margin from Watch is disabled until Watch-owned or background-safe recording is available.")
            return
        }
        guard gate3WatchSnapshot()?.availableCommands.contains(request.command) == true else {
            diagnostics["gate3WatchLastCommand"] = request.command.rawValue
            diagnostics["gate3WatchLastResult"] = "unavailable"
            updateGate3WatchState()
            reportFailure("Watch command \(request.command.rawValue) is unavailable for the current session state.")
            return
        }
        if request.command == .generateInterjectionSummary {
            summarize()
            updateGate3WatchState()
            return
        }
        if request.command == .submitFollowup {
            discuss(followUp: request.followUpText ?? "Can you respond to my interjection?")
            updateGate3WatchState()
            return
        }
        if request.command == .beginInterjection {
            Task {
                let granted = await SystemRecordingClient.requestRecordPermission()
                guard granted else {
                    reportFailure("Microphone access is required to record Margins from Watch.")
                    updateGate3WatchState()
                    return
                }
                performGate3WatchCommand(request)
            }
            return
        }
        performGate3WatchCommand(request)
    }

    private func performGate3WatchCommand(_ request: Gate3WatchCommandRequest) {
        do {
            if engine == nil {
                let store = try requireStore()
                installEngine(try makeEngine(store: store))
            }
            guard let dispatcher = gate3WatchDispatcher else {
                throw SessionKitError.invalidCommandForState("watch_tethered_unconfigured")
            }
            let result = try dispatcher.dispatch(
                request.command,
                chapterId: request.chapterId,
                unit: request.unit,
                followUpText: request.followUpText
            )
            if let engine {
                snapshot = engine.snapshot
            } else {
                updateGate3WatchState()
            }
            refreshSelectedItem()
            if request.command == .finishInterjection, let interjection = latestInterjectionNeedingTranscription() {
                scheduleTranscription(for: interjection)
            }
            diagnostics["gate3WatchLastCommand"] = request.command.rawValue
            diagnostics["gate3WatchLastResult"] = result.delegatedToCanonicalRuntime ? "delegated" : (result.rejectedReason ?? "rejected")
            updateGate3WatchState()
            reportSuccess("Watch control \(request.command.rawValue) delegated.")
        } catch {
            diagnostics["gate3WatchLastCommand"] = request.command.rawValue
            diagnostics["gate3WatchLastResult"] = "failed"
            updateGate3WatchState()
            reportFailure(error, context: "Watch control failed")
        }
    }
    #endif

    private func performGate2CompactCommand(
        _ command: CompactControlCommand,
        chapterId: String? = nil,
        mediaTimeMs: Int? = nil,
        playbackRate: Double? = nil,
        origin: String = "app_ui"
    ) {
        recordDeveloperDiagnostic("transport.request", [
            "command": command.rawValue, "origin": origin,
            "mediaTimeMs": String(snapshot.currentMediaTimeMs ?? -1),
            "requestedMediaTimeMs": String(mediaTimeMs ?? -1)
        ])
        if playingImportedCommentary != nil {
            switch command {
            case .play: resumePlayback()
            case .pause: pause()
            case .togglePlayPause: playPause()
            default:
                reportWarning("Return to Source before using source controls.")
            }
            return
        }
        if command == .skimForward {
            skimForward()
            diagnostics["gate2LastCommand"] = command.rawValue
            return
        }
        if command == .skimBackward {
            skimBackward()
            diagnostics["gate2LastCommand"] = command.rawValue
            return
        }
        if snapshot.skimBridgeState != nil {
            switch command {
            case .play:
                setSkimBridgePaused(false)
                return
            case .pause:
                setSkimBridgePaused(true)
                return
            case .togglePlayPause:
                playPause()
                return
            case .skipBack, .skipForward, .seekToMediaTime, .jumpToChapter:
                restoreSkimOriginBeforeCanonicalTransport()
            case .beginInterjection:
                reportWarning("Margins are unavailable while a scene summary is playing.")
                return
            case .setPlaybackRate:
                if let playbackRate { setMediaPlaybackRate(playbackRate) }
                return
            case .finishInterjection, .cancelInterjection,
                 .generateInterjectionSummary, .submitFollowup, .skimBackward, .skimForward:
                break
            }
        }
        if (snapshot.isRecording && command != .finishInterjection && command != .cancelInterjection)
            || (isRequestingRecordingPermission && command != .beginInterjection) {
            diagnostics["recordingNavigationGuard"] = "blocked_compact_\(command.rawValue)"
            return
        }
        let canonicalTransportCommands: Set<CompactControlCommand> = [
            .play, .pause, .togglePlayPause, .skipBack, .skipForward, .jumpToChapter
        ]
        let normalizedPlaybackRate = command == .setPlaybackRate
            ? playbackRate.map { max(0.5, min(2.0, ($0 * 4).rounded() / 4)) }
            : playbackRate
        if command == .beginInterjection || canonicalTransportCommands.contains(command) {
            synchronizeStreamingSpeechAnchorIfNeeded()
        }
        if command == .beginInterjection {
            streamingSpeechQueue.pauseForInterjection()
        }
        do {
            let result = try gate2CompactControls.dispatch(
                command,
                chapterId: chapterId,
                unit: compactSkipUnit(for: command),
                mediaTimeMs: mediaTimeMs,
                playbackRate: normalizedPlaybackRate,
                origin: origin
            )
            if let engine {
                snapshot = engine.snapshot
            } else {
                updateGate2CompactState()
            }
            if command == .beginInterjection, snapshot.isRecording {
                recordingPresentationContext = RecordingPresentationContext(
                    itemTitle: selectedItem.title,
                    locationTitle: snapshot.chapterTitle ?? "Current listening position",
                    progressPercent: snapshot.currentPlaybackProgressPercent,
                    startedAt: Date()
                )
            }
            if command == .setPlaybackRate,
               let playbackRate = normalizedPlaybackRate {
                if isMediaPlaybackSnapshot {
                    mediaPlaybackRate = playbackRate
                    UserDefaults.standard.set(mediaPlaybackRate, forKey: "mediaPlaybackRate")
                    diagnostics["mediaPlaybackRate"] = String(format: "%.2f", mediaPlaybackRate)
                } else {
                    speechRate = playbackRate * 0.5
                    UserDefaults.standard.set(speechRate, forKey: "speechRate")
                }
            }
            refreshSelectedItem()
            if command == .finishInterjection {
                recordSavedInterjectionForOnboarding()
            }
            if command == .finishInterjection, let interjection = latestInterjectionNeedingTranscription() {
                scheduleTranscription(for: interjection)
            }
            if command == .finishInterjection || command == .cancelInterjection {
                streamingSpeechQueue.resumeAfterInterjection()
                if !snapshot.isRecording {
                    recordingPresentationContext = nil
                    refreshMarginRows()
                }
            }
            if canonicalTransportCommands.contains(command) {
                streamingSpeechQueue.relinquishToCanonicalPlayback()
            }
            reportSuccess("Compact control \(command.rawValue) \(result.delegatedToCanonicalRuntime ? "delegated" : "handled").")
        } catch {
            if command == .beginInterjection || command == .finishInterjection || command == .cancelInterjection {
                streamingSpeechQueue.resumeAfterInterjection()
            }
            reportFailure(error, context: "Compact control failed")
        }
    }

    private func compactSkipUnit(for command: CompactControlCommand) -> String? {
        guard isMediaPlaybackSnapshot else { return nil }
        switch command {
        case .skipBack:
            return mediaSkipUnit(seconds: mediaSkipBackSeconds)
        case .skipForward:
            return mediaSkipUnit(seconds: mediaSkipForwardSeconds)
        default:
            return nil
        }
    }

    func synchronizeStreamingSpeechAnchorIfNeeded() {
        guard let engine,
              let turnId = streamingSpeechQueue.currentTurnId,
              let presentationOffset = streamingSpeechQueue.currentPresentationOffset else {
            return
        }
        do {
            snapshot = try engine.updateStreamingTurnPosition(turnId: turnId, charOffset: presentationOffset)
            diagnostics["streamingInterjectionTurnId"] = turnId
            diagnostics["streamingPresentationOffset"] = "\(presentationOffset)"
            diagnostics["streamingRecoveryOffset"] = "\(streamingSpeechQueue.currentRecoveryOffset ?? presentationOffset)"
        } catch {
            diagnostics["streamingAnchorSyncError"] = String(describing: error)
        }
    }

    func applyStreamingSpeechObservation(_ observation: StreamingSpeechQueue.PlaybackObservation) {
        guard let engine, snapshot.targetId == observation.turnId else { return }
        do {
            switch observation.event {
            case .started:
                snapshot = try engine.streamingTurnPlaybackStarted(
                    turnId: observation.turnId,
                    charOffset: observation.charOffset
                )
            case .progressed:
                snapshot = try engine.updateStreamingTurnPosition(
                    turnId: observation.turnId,
                    charOffset: observation.charOffset
                )
            case .failed:
                diagnostics["streamingSpeechFailure:\(observation.turnId)"] = "offset:\(observation.charOffset)"
            }
        } catch {
            diagnostics["streamingSpeechObservationError"] = String(describing: error)
        }
    }

    var renderedFractionForPlayback: Double? {
        guard frontierPublicationKey == renderFrontierKey else { return nil }
        if ttsVoiceSelection.supertonicVoice != nil,
           snapshot.targetType == TargetType.itemTextTTS.rawValue,
           onDeviceSpeechGenerationProgress.totalChunks > 0 {
            return Double(onDeviceSpeechGenerationProgress.percent) / 100
        }
        return renderedSourceFraction
    }

    var renderFrontierKey: String { "\(snapshot.itemId ?? "")|\(snapshot.targetType ?? "")|\(ttsVoiceSelection.rawValue)" }

    /// Runs only while the playback surface is present; publication never reads disk in body.
    func observeRenderedFrontier() async {
        let key = renderFrontierKey
        renderedSourceFraction = nil
        frontierPublicationKey = key
        guard let itemID = snapshot.itemId, let voice = ttsVoiceSelection.supertonicVoice,
              [TargetType.itemTextTTS.rawValue, TargetType.transcriptBackedMedia.rawValue].contains(snapshot.targetType ?? ""),
              let store, let resources = Bundle.main.resourceURL else { return }
        do {
            let signature: TTSRenderSignature
            if let cached = frontierSignatures[voice.rawValue] { signature = cached }
            else {
                let assets = SupertonicAssetLocation(rootURL: resources.appendingPathComponent("Supertonic"))
                let existing = currentSupertonicRenderSignature
                signature = try await Task.detached(priority: .utility) {
                    if let existing,
                       existing.voiceStyleHash == SupertonicRenderIdentity.sha256(try Data(contentsOf: assets.voiceStyleURL(for: voice))) { return existing }
                    return try SupertonicRenderIdentity.make(assets: assets, voice: voice)
                }.value
                frontierSignatures[voice.rawValue] = signature
            }
            let root = try applicationSupportDirectory().appendingPathComponent("PreparedAudio")
            while !Task.isCancelled, renderFrontierKey == key {
                let item = try store.loadItem(id: itemID)
                guard let text = item.text, !text.isEmpty else { return }
                let source = try store.loadCanonicalSource(itemId: itemID)
                let manifest = try store.loadPreparedAudioManifests(itemId: itemID).first { $0.signature == signature }
                let canonical = source?.segments.map(\.text).joined(separator: "\n\n") ?? ""
                let fraction = await Task.detached(priority: .utility) {
                    PreparedRenderFrontier.fraction(manifest: manifest, signature: signature, sourceText: text, canonicalSourceText: canonical, root: root)
                }.value
                guard !Task.isCancelled, renderFrontierKey == key else { return }
                if renderedSourceFraction != fraction { renderedSourceFraction = fraction }
                try await Task.sleep(for: .seconds(2))
            }
        } catch {
            if renderFrontierKey == key, !Task.isCancelled { renderedSourceFraction = nil }
        }
    }

    func run(_ operation: (SessionEngine) throws -> Void) {
        if engine == nil {
            do {
                let store = try requireStore()
                installEngine(try makeEngine(store: store))
            } catch {
                reportFailure(error, context: "Playback setup failed")
            }
        }
        guard let engine else { return }
        do {
            try operation(engine)
        } catch {
            reportFailure(error)
        }
    }

    var currentPlaybackTargetType: String {
        (engine?.currentSession?.currentTargetType).map(\.rawValue) ?? snapshot.targetType ?? TargetType.itemTextTTS.rawValue
    }

    var currentPlaybackTargetId: String? {
        engine?.currentSession?.currentTargetId ?? snapshot.itemId
    }

    func makeTextAudioPreparationClient() throws -> TextAudioPreparationClient? {
        guard audioPlaybackClientOverride == nil else { return nil }
        guard ttsVoiceSelection == .system else { return nil }
        guard ttsMode != "piper" else { return nil }
        #if canImport(AVFoundation)
        diagnostics["sessionTextAudio"] = "System generated audio"
        return SystemTextAudioPreparationClient(
            outputDirectory: try generatedTextAudioDirectory(),
            voiceIdentifier: speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : speechVoiceIdentifier,
            speechRate: Float(speechRate),
            allowsSynchronousRendering: false
        )
        #else
        return nil
        #endif
    }

    func scheduleTextAudioPrewarmIfNeeded(itemId: String) {
        if ttsVoiceSelection.supertonicVoice != nil {
            scheduleStartupAudioPreparationIfNeeded(itemId: itemId)
            return
        }
        // AVSpeechSynthesizer serializes or competes with live utterances on real
        // devices. Only an explicitly injected preparation job may pre-render in
        // the background; production playback must stay on the immediate path.
        guard ttsVoiceSelection == .system else { return }
        guard let prewarmHandler = preparedTextAudioPrewarmHandler else { return }
        guard ttsMode != "piper" else { return }
        guard textAudioPrewarmTasks[itemId] == nil else { return }
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: itemId)
            let shouldSkipPreparation = Self.shouldSkipTextAudioPreparation(
                try store.loadSessions(itemId: itemId)
            )
            guard !shouldSkipPreparation else {
                diagnostics["textAudioPrewarm:\(itemId)"] = "skipped_existing_progress"
                return
            }
            guard shouldPrewarmTextAudio(for: item), let text = item.text else { return }
            let outputDirectory = try generatedTextAudioDirectory()
            let voiceIdentifier = speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : speechVoiceIdentifier
            let rate = Float(speechRate)
            diagnostics["textAudioPrewarm:\(itemId)"] = "scheduled"
            preparedTextAudioStatus = "rendering"
            snapshot.preparedTextAudioStatus = preparedTextAudioStatus
            textAudioPrewarmTasks[itemId] = Task { [weak self, itemId, title = item.title, text, outputDirectory, voiceIdentifier, rate] in
                guard let self else { return }
                self.diagnostics["textAudioPrewarm:\(itemId)"] = "rendering_full"
                let fullResult = await prewarmHandler(itemId, title, text, outputDirectory, voiceIdentifier, rate)
                guard !Task.isCancelled else { return }
                self.textAudioPrewarmTasks[itemId] = nil
                switch fullResult {
                case .success(let prepared):
                    guard let prepared else {
                        self.finishTextAudioPrewarm(itemId: itemId, status: "failed", diagnostic: "full_unavailable")
                        return
                    }
                    self.attachPreparedTextAudio(prepared, itemId: itemId, preparedStatus: "ready", diagnosticStatus: "ready")
                case .failure(let error):
                    self.finishTextAudioPrewarm(itemId: itemId, status: "failed", diagnostic: "full_failed:\(error.localizedDescription)")
                }
            }
        } catch {
            diagnostics["textAudioPrewarm:\(itemId)"] = "failed:\(error.localizedDescription)"
            preparedTextAudioStatus = "failed"
            snapshot.preparedTextAudioStatus = "failed"
        }
    }

    static func startupPreparationCandidates(_ rows: [LibraryItemRow]) -> [String] {
        rows.filter { !$0.isCompleted && $0.startupAudioState != .ready }
            .sorted {
                let lhsDate = $0.addedAt ?? .distantPast
                let rhsDate = $1.addedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                if $0.storageRecencyRank != $1.storageRecencyRank { return $0.storageRecencyRank < $1.storageRecencyRank }
                return $0.id < $1.id
            }
            .map(\.id)
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
            let item = try store.loadItem(id: itemId)
            guard item.sourceCompletedAt == nil,
                  !Self.itemIsCompleted(try store.loadSessions(itemId: itemId)),
                  shouldPrewarmTextAudio(for: item),
                  item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return
            }
            pendingStartupAudioPreparationItemIds.insert(itemId)
            failedStartupAudioPreparationItemIds.remove(itemId)
            updateLibraryStartupAudioState(itemId: itemId, state: .preparing)
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
                  !Self.itemIsCompleted(try store.loadSessions(itemId: itemId)),
                  let sourceText = item.text,
                  shouldPrewarmTextAudio(for: item),
                  let voice = ttsVoiceSelection.supertonicVoice,
                  let resourceRoot = Bundle.main.resourceURL?.appending(path: "Supertonic", directoryHint: .isDirectory) else {
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
            let assets = SupertonicAssetLocation(rootURL: resourceRoot)
            let signature = try await Task.detached(priority: .utility) {
                try SupertonicRenderIdentity.make(assets: assets, voice: voice)
            }.value
            try Task.checkCancellation()
            let support = try applicationSupportDirectory()
            let coordinator = preparedAudioCoordinator ?? PreparedAudioCoordinator(
                repository: store,
                rootDirectory: support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
            )
            preparedAudioCoordinator = coordinator
            currentSupertonicRenderSignature = signature
            let manifest = try await coordinator.begin(
                itemId: item.id,
                sourceText: sourceText,
                signature: signature,
                plan: plan
            )
            let targetChunkCount = min(Self.startupAudioChunkCount, plan.count)
            if manifest.chunks.count < targetChunkCount {
                var job = (try store.loadAudioPreparationJobs()).first(where: { $0.manifestId == manifest.id })
                    ?? AudioPreparationJob(
                        id: "job-\(manifest.id)",
                        itemId: item.id,
                        manifestId: manifest.id,
                        policy: .demandWindow
                    )
                if job.policy == .demandWindow {
                    job.requestedAt = item.createdAt ?? job.requestedAt
                    job.maximumChunkCount = targetChunkCount
                }
                job.isCancelled = false
                job.lastFailureCode = nil
                try store.saveAudioPreparationJob(job)
                diagnostics["startupAudioPreparation:\(itemId)"] = "preparing_0_of_\(targetChunkCount)"
            } else if let job = try store.loadAudioPreparationJobs().first(where: {
                $0.manifestId == manifest.id && $0.policy == .demandWindow && $0.maximumChunkCount != nil
            }) {
                try store.deleteAudioPreparationJob(id: job.id)
                diagnostics["startupAudioPreparation:\(itemId)"] = "ready_from_cache"
            }
            try refreshLibraryRows(store: store)
            startForegroundAudioPreparationIfNeeded()
        } catch is CancellationError {
            diagnostics["startupAudioPreparation:\(itemId)"] = "cancelled"
        } catch {
            failedStartupAudioPreparationItemIds.insert(itemId)
            updateLibraryStartupAudioState(itemId: itemId, state: .failed)
            diagnostics["startupAudioPreparation:\(itemId)"] = "failed:\(error.localizedDescription)"
        }
    }

    private func updateLibraryStartupAudioState(itemId: String, state: NativeTextStartupAudioState) {
        guard let index = libraryItems.firstIndex(where: { $0.id == itemId }),
              libraryItems[index].startupAudioState != state else { return }
        libraryItems[index].startupAudioState = state
    }

    private nonisolated static func prepareTextAudioInBackground(
        itemId: String,
        title: String,
        text: String,
        outputDirectory: URL,
        voiceIdentifier: String?,
        speechRate: Float,
        renderScope: TextAudioPrewarmRenderScope
    ) async -> Result<PreparedTextAudio?, Error> {
        await Task.detached(priority: renderScope.priority) {
            do {
                let renderer = SystemTextAudioPreparationClient(
                    outputDirectory: outputDirectory,
                    voiceIdentifier: voiceIdentifier,
                    speechRate: speechRate,
                    allowsSynchronousRendering: true
                )
                switch renderScope {
                case .starter(let targetDurationMs):
                    return .success(try renderer.prepareStarterTextAudio(itemId: itemId, title: title, text: text, targetDurationMs: targetDurationMs))
                case .complete:
                    return .success(try renderer.prepareTextAudio(itemId: itemId, title: title, text: text))
                }
            } catch {
                return .failure(error)
            }
        }.value
    }

    @discardableResult
    private func attachPreparedTextAudio(
        _ prepared: PreparedTextAudio,
        itemId: String,
        preparedStatus: String = "ready",
        diagnosticStatus: String = "ready",
        replaceActivePlayback: Bool = false
    ) -> Bool {
        do {
            let shouldAutoStart = pendingPreparedTextStartItemId == itemId
            if engine == nil, let store {
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return false }
            snapshot = try engine.attachPreparedTextAudio(
                itemId: itemId,
                prepared: prepared,
                replaceActivePlayback: replaceActivePlayback
            )
            if let store {
                libraryItems = try loadLibraryRows(store: store)
                if activeItemId == itemId || selectedItem.id == itemId {
                    selectedItem = try loadItemDetail(id: itemId, store: store)
                }
            }
            activateListeningEditionAudio(itemId: itemId, timeline: prepared.timeline)
            diagnostics["textAudioPrewarm:\(itemId)"] = diagnosticStatus
            preparedTextAudioStatus = preparedStatus
            snapshot.preparedTextAudioStatus = preparedStatus
            if shouldAutoStart {
                pendingPreparedTextStartItemId = nil
                startItem(id: itemId)
            }
            return true
        } catch {
            diagnostics["textAudioPrewarm:\(itemId)"] = "attach_failed:\(error.localizedDescription)"
            if pendingPreparedTextStartItemId == itemId {
                pendingPreparedTextStartItemId = nil
            }
            preparedTextAudioStatus = "failed"
            snapshot.preparedTextAudioStatus = "failed"
            return false
        }
    }

    private func finishTextAudioPrewarm(itemId: String, status: String, diagnostic: String) {
        textAudioPrewarmTasks[itemId] = nil
        diagnostics["textAudioPrewarm:\(itemId)"] = diagnostic
        if pendingPreparedTextStartItemId == itemId {
            pendingPreparedTextStartItemId = nil
        }
        preparedTextAudioStatus = status
        snapshot.preparedTextAudioStatus = status
    }

    private nonisolated static func preparedTextAudioCoversCompleteText(_ prepared: PreparedTextAudio) -> Bool {
        guard let endChar = prepared.timeline.segments.compactMap(\.endChar).max() else {
            return false
        }
        return endChar >= prepared.normalizedText.count
    }

    /// A PDF imported with extraction v2 (C1 M3) is spoken through SessionEngine's
    /// I14 projection. Prepared (pre-rendered) text audio is rendered from Item.text,
    /// which would read its references and tables aloud, so it isn't prepared for
    /// these items yet; they play with live speech.
    private func usesStructuredSpeech(_ item: Item) -> Bool {
        item.mediaType == "pdf" && (try? store?.loadStructuredDocument(itemId: item.id)) != nil
    }

    func shouldPrewarmTextAudio(for item: Item) -> Bool {
        guard item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
        guard !usesStructuredSpeech(item) else { return false }
        if item.mediaType == TargetType.browserOwnedMedia.rawValue {
            return false
        }
        switch item.media?.sourceType {
        case .none, .some(.generatedTTSRealtime):
            return true
        case .some(.generatedTTSPrerendered):
            return !isPreparedTextMediaAvailable(item.media) || isStarterPreparedTextMedia(item.media)
        case .some(.nativeMediaFile), .some(.browserOwnedMedia), .some(.remoteStream):
            return false
        }
    }

    func isStarterPreparedTextMedia(_ media: ItemMedia?) -> Bool {
        guard media?.sourceType == .generatedTTSPrerendered else { return false }
        let identifier = media?.nativeMediaId ?? media?.url ?? ""
        return identifier.contains("-starter.caf") || identifier.contains("-starter.")
    }

    func isPreparedTextMediaAvailable(_ media: ItemMedia?) -> Bool {
        guard media?.sourceType == .generatedTTSPrerendered else { return false }
        let identifier = [media?.url, media?.nativeMediaId]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard let url = URL(string: identifier), url.isFileURL else { return true }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func cancelTextAudioPrewarmTasks() {
        textAudioPrewarmTasks.values.forEach { $0.cancel() }
        textAudioPrewarmTasks.removeAll()
    }

    private func generatedTextAudioDirectory() throws -> URL {
        let cachesDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return cachesDirectory.appending(path: "GeneratedTextAudio", directoryHint: .isDirectory)
    }

    func removeDurableGeneratedAudio(for item: Item) {
        guard item.media?.sourceType == .generatedTTSPrerendered,
              let identifier = item.media?.nativeMediaId ?? item.media?.url,
              let url = URL(string: identifier),
              url.isFileURL,
              let supportDirectory = try? applicationSupportDirectory() else { return }
        let generatedDirectory = supportDirectory
            .appending(path: "PreparedSupertonicAudio", directoryHint: .isDirectory)
            .standardizedFileURL
        let file = url.standardizedFileURL
        guard file.deletingLastPathComponent() == generatedDirectory else { return }
        try? FileManager.default.removeItem(at: file)
    }

    func removeEpisodeMapArtifacts(itemId: String) {
        if snapshot.itemId == itemId, snapshot.skimBridgeState != nil {
            cancelSkimBridge(restoringOrigin: true, resumeSource: false)
        }
        if episodeMapPreparationItemId == itemId {
            episodeMapPreparationTask?.cancel()
        }
        if let directory = try? episodeMapDirectory(itemId: itemId),
           FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        }
        try? purgeTransientEpisodeTranscriptionCaches(itemId: itemId)
        for job in (try? store?.loadEpisodeMapPreparationJobs()) ?? [] where job.itemId == itemId {
            try? store?.deleteEpisodeMapPreparationJob(id: job.id)
        }
    }

    func purgeExpiredEpisodeMapPreparationJobs(store: SQLiteSessionStore, now: Date = Date()) {
        let expiration = now.addingTimeInterval(-7 * 24 * 60 * 60)
        for job in (try? store.loadEpisodeMapPreparationJobs()) ?? [] where
            job.isCancelled || job.requestedAt < expiration {
            try? purgeTransientEpisodeTranscriptionCaches(itemId: job.itemId)
            if (try? store.loadEditionFingerprintSpine(itemId: job.itemId)) == nil,
               let directory = try? episodeMapDirectory(itemId: job.itemId),
               FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
            try? store.deleteEpisodeMapPreparationJob(id: job.id)
        }
    }

    private func prepareTextPlaybackBeforeStarting(itemId: String) -> Bool {
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: itemId)
            guard shouldGatePreparedTextPlayback(for: item) else {
                return false
            }
            pendingPreparedTextStartItemId = itemId
            diagnostics["textAudioStartGate:\(itemId)"] = "waiting_for_prepared_media"
            if preparedTextAudioStatus != "failed" {
                preparedTextAudioStatus = "rendering"
                snapshot.preparedTextAudioStatus = "rendering"
            }
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            selectedItem = try loadItemDetail(id: itemId, store: store)
            screen = .playback
            reportSuccess("Preparing generated audio for \(item.title).")
            return true
        } catch {
            reportFailure(error, context: "Prepare text playback failed", itemId: itemId)
            return true
        }
    }

    private func shouldGatePreparedTextPlayback(for item: Item) -> Bool {
        guard (audioPlaybackClientOverride == nil || forcePreparedTextGate),
              ttsVoiceSelection == .system,
              !liveSpeechFallbackItemIds.contains(item.id),
              shouldPrewarmTextAudio(for: item) else {
            return false
        }
        if item.media?.sourceType == .generatedTTSPrerendered {
            return false
        }
        return true
    }

    private enum TextAudioPrewarmRenderScope: Sendable {
        case starter(targetDurationMs: Int)
        case complete

        var priority: TaskPriority {
            switch self {
            case .starter:
                return .userInitiated
            case .complete:
                return .utility
            }
        }
    }

    func makeAudioPlaybackClient() throws -> AudioPlaybackClient {
        if let audioPlaybackClientOverride {
            diagnostics["sessionTTS"] = "Test audio override"
            try configureAudioPlaybackPolicy(audioPlaybackClientOverride)
            sessionAudioPlaybackClient = audioPlaybackClientOverride
            return audioPlaybackClientOverride
        }
        sanitizeTTSMode()
        let speech = try makeSpeechPlaybackClient()
        speechPlaybackClient = speech
        let routed = RoutedAudioPlaybackClient(
            speech: speech,
            media: makeMediaPlaybackClient()
        )
        try configureAudioPlaybackPolicy(routed)
        sessionAudioPlaybackClient = routed
        streamingSpeechQueue.configureSpeechClient(routed)
        return routed
    }

    private func configureAudioPlaybackPolicy(_ audio: AudioPlaybackClient) throws {
        try audio.setMixesWithOtherAudio(mixesWithOtherAudio)
        try audio.setLowersBackgroundAudio(mixesWithOtherAudio && lowersBackgroundAudio)
        try audio.setPlaybackVolume(mixesWithOtherAudio ? Float(mixedPlaybackVolume) : 1)
        audio.setRemoteCommandHandlingEnabled(!mixesWithOtherAudio)
    }

    private func makeSpeechPlaybackClient() throws -> AudioPlaybackClient {
        let selectedVoice = speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let appleVoiceIsAvailable = !Self.supportsSpeechVoiceEnumeration
            || selectedVoice.isEmpty
            || Self.availableSpeechVoiceOptions().contains(where: { $0.id == selectedVoice })
        if ttsVoiceSelection == .system, !appleVoiceIsAvailable {
            diagnostics["speechVoiceAvailability"] = "unavailable"
            throw SessionKitError.persistenceFailed("selected_speech_voice_unavailable")
        }
        if let voice = ttsVoiceSelection.supertonicVoice {
            let renderer = try makeSupertonicRenderer()
            let supportDirectory = try applicationSupportDirectory()
            guard let store else { throw SessionKitError.persistenceFailed("prepared_audio_store_unavailable") }
            guard let resourceRoot = Bundle.main.resourceURL?.appending(path: "Supertonic", directoryHint: .isDirectory) else {
                throw SupertonicNarrationError.missingAsset("Supertonic")
            }
            let assets = SupertonicAssetLocation(rootURL: resourceRoot)
            let signatureTask = Task.detached(priority: .userInitiated) {
                try SupertonicRenderIdentity.make(assets: assets, voice: voice)
            }
            let coordinator = PreparedAudioCoordinator(
                repository: store,
                rootDirectory: supportDirectory.appending(path: "PreparedAudio", directoryHint: .isDirectory)
            )
            preparedAudioCoordinator = coordinator
            Task { [weak self] in
                guard let signature = try? await signatureTask.value,
                      let self, self.ttsVoiceSelection.supertonicVoice == voice else { return }
                self.currentSupertonicRenderSignature = signature
            }
            let diskCache: RenderedSpeechDiskCache
            if let renderedSpeechDiskCache {
                renderedSpeechDiskCache.setLimitBytes(renderedSpeechCacheLimitMB * 1024 * 1024)
                diskCache = renderedSpeechDiskCache
            } else {
                let created = try RenderedSpeechDiskCache(
                    directory: supportDirectory.appending(path: "RenderedSpeechCache", directoryHint: .isDirectory),
                    limitBytes: renderedSpeechCacheLimitMB * 1024 * 1024
                )
                renderedSpeechDiskCache = created
                diskCache = created
            }
            diagnostics["sessionTTS"] = "Supertonic 3 INT8 \(voice.rawValue)"
            diagnostics["renderedSpeechCacheLimitMB"] = "\(renderedSpeechCacheLimitMB)"
            diagnostics["renderedSpeechCacheBytes"] = "\(diskCache.sizeBytes)"
            return SupertonicSpeechPlaybackClient(
                renderer: supertonicOutputGuard(wrapping: renderer, systemVoice: selectedVoice),
                voice: voice,
                speed: Float(speechRate / 0.5),
                fallbackVoiceIdentifier: selectedVoice.isEmpty ? nil : selectedVoice,
                fallbackRate: Float(speechRate),
                diskCache: diskCache,
                preparedAudioDirectory: supportDirectory.appending(
                    path: "PreparedSupertonicAudio",
                    directoryHint: .isDirectory
                ),
                interruptionHandler: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleSpeechPlaybackInterruption(event)
                    }
                },
                onGenerationStateChange: { [weak self] state, stopReason in
                    Task { @MainActor [weak self] in
                        self?.updateOnDeviceSpeechGenerationState(state, stopReason: stopReason)
                    }
                },
                onGenerationProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateOnDeviceSpeechGenerationProgress(progress)
                    }
                },
                onPreparationPlan: { itemId, articleIdentity, plan in
                    // A turn is not a Library item. The player's article chunks
                    // share the article plan's identity with background
                    // preparation (#312); a changed article matches nothing.
                    guard let signature = try? await signatureTask.value,
                          let item = try? store.loadItem(id: itemId), let sourceText = item.text,
                          NarrationChunkPlanner.identity(ofArticle: sourceText) == articleIdentity else { return }
                    _ = try? await coordinator.begin(itemId: itemId, sourceText: sourceText, signature: signature, plan: plan, schedulesJob: false)
                },
                onPreparedChunk: { itemId, articleIdentity, plan, audioURL, durationMs, engine in
                    guard let signature = try? await signatureTask.value,
                          let item = try? store.loadItem(id: itemId), let sourceText = item.text,
                          NarrationChunkPlanner.identity(ofArticle: sourceText) == articleIdentity else { return }
                    try? await coordinator.commit(itemId: itemId, signature: signature, plan: plan, sourceText: sourceText, audioURL: audioURL, durationMs: durationMs, engine: engine)
                },
                articleText: { itemId in try? store.loadItem(id: itemId).text },
                preparedChunkLookup: { itemId, articleIdentity, plan in
                    guard let signature = try? await signatureTask.value,
                          let item = try? store.loadItem(id: itemId), let sourceText = item.text,
                          NarrationChunkPlanner.identity(ofArticle: sourceText) == articleIdentity else { return nil }
                    return try? await coordinator.committedChunk(itemId: itemId, signature: signature, plan: plan, sourceText: sourceText)
                },
                onPreparedAudio: { [weak self] itemId, prepared in
                    Task { @MainActor [weak self] in
                        guard let signature = try? await signatureTask.value, let self else { return }
                        guard let store = self.store,
                              let item = try? store.loadItem(id: itemId),
                              let canonical = Self.canonicalSupertonicPreparedAudio(
                                prepared,
                                itemText: item.text
                              ) else {
                            self.diagnostics["supertonicPreparedCanonicalization:\(itemId)"] = "source_mismatch"
                            return
                        }
                        let attached = self.attachPreparedTextAudio(
                            canonical,
                            itemId: itemId,
                            preparedStatus: "ready",
                            diagnosticStatus: "supertonic_full_ready",
                            replaceActivePlayback: false
                        )
                        if attached {
                            try? await coordinator.complete(itemId: itemId, signature: signature, prepared: canonical)
                        }
                        if attached, let renderer = self.supertonicRenderer {
                            Task { [weak self] in
                                await renderer.unload(removingGeneratedAudio: false)
                                await MainActor.run { [weak self] in
                                    self?.diagnostics["supertonicRuntimeAfterFullAudio"] = "unloaded"
                                }
                            }
                        }
                    }
                },
                onFallback: { [weak self] reason, offset, itemId in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.suppressAudioPreparation(itemId: itemId)
                        if let coordinator = self.preparedAudioCoordinator,
                           let signature = self.currentSupertonicRenderSignature {
                            try? await coordinator.stop(itemId: itemId, signature: signature)
                        }
                        // I14: the reason is shown and logged with the power state beside it,
                        // so a device report shows whether charging or Low Power Mode coincided.
                        let conditions = SupertonicResourcePolicy.currentConditions(
                            isOnExternalPower: SupertonicResourcePolicy.isOnExternalPower()
                        )
                        let fallbackReason = SpeechFallbackReason(
                            supertonicCode: reason,
                            resourceBlock: SpeechEnginePolicy.onDeviceRenderingBlock(conditions)
                        )
                        self.speechFallbackReason = fallbackReason
                        self.diagnostics["supertonicFallback"] = reason
                        self.diagnostics["supertonicFallbackReason"] = fallbackReason.rawValue
                        self.diagnostics["supertonicFallbackConditions"] = conditions.logDescription
                        self.diagnostics["supertonicFallbackOffset"] = "\(offset)"
                        let message = fallbackReason.listenerExplanation
                        self.statusMessage = message
                        self.presentFeedback(UserFeedbackEvent(kind: .warning, message: message))
                    }
                },
                onRestore: { [weak self] itemId in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.speechFallbackReason = nil
                        self.allowAudioPreparation(itemId: itemId)
                        self.diagnostics["supertonicFallbackRestored"] = itemId
                    }
                },
                onStall: { [weak self] kind, fields in
                    Task { @MainActor [weak self] in self?.recordDeveloperDiagnostic(kind, fields) }
                },
                onResumeDecision: { [weak self] fields in
                    Task { @MainActor [weak self] in self?.recordDeveloperDiagnostic("supertonic.resume", fields) }
                }
            )
        }
        diagnostics["sessionTTS"] = "System speech"
        return SystemSpeechPlaybackClient(
            voiceIdentifier: selectedVoice.isEmpty ? nil : selectedVoice,
            speechRate: Float(speechRate)
        )
    }

    static func canonicalSupertonicPreparedAudio(
        _ prepared: PreparedTextAudio,
        itemText: String?
    ) -> PreparedTextAudio? {
        guard let itemText, !itemText.isEmpty,
              prepared.normalizedText.hasSuffix(itemText) else {
            return nil
        }
        let prefixLength = prepared.normalizedText.count - itemText.count
        guard prefixLength > 0 else { return prepared }
        let itemCharacters = Array(itemText)
        let segments = prepared.timeline.segments.map { segment -> MediaTimelineSegment in
            let originalStart = segment.startChar ?? 0
            let originalEnd = segment.endChar ?? originalStart
            let start = max(0, min(itemCharacters.count, originalStart - prefixLength))
            let end = max(start, min(itemCharacters.count, originalEnd - prefixLength))
            let canonicalText = end > start
                ? String(itemCharacters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                : segment.text
            return MediaTimelineSegment(
                id: segment.id,
                startMs: segment.startMs,
                endMs: segment.endMs,
                startChar: start,
                endChar: end,
                text: canonicalText
            )
        }
        let segmentByID = segments.reduce(into: [String: MediaTimelineSegment]()) {
            $0[$1.id] = $1
        }
        let chapters = prepared.timeline.chapters.compactMap { chapter -> MediaTimelineChapter? in
            guard let segment = segmentByID[chapter.transcriptSegmentId],
                  (segment.endChar ?? 0) > 0 else { return nil }
            let titleWords = segment.text.split(separator: " ").prefix(7).joined(separator: " ")
            return MediaTimelineChapter(
                id: chapter.id,
                title: titleWords.isEmpty ? chapter.title : titleWords,
                description: chapter.description,
                startMs: chapter.startMs,
                transcriptSegmentId: chapter.transcriptSegmentId
            )
        }
        return PreparedTextAudio(
            normalizedText: itemText,
            media: prepared.media,
            timeline: TranscriptTimeline(
                segments: segments,
                chapters: chapters,
                durationMs: prepared.timeline.durationMs
            ),
            createdAt: prepared.createdAt
        )
    }

    func makeSupertonicRenderer() throws -> SupertonicNarrationRenderer {
        try verifyCurrentTermsForOnDeviceVoice()
        if let supertonicRenderer { return supertonicRenderer }
        guard let resourceRoot = Bundle.main.resourceURL?.appending(
            path: "Supertonic",
            directoryHint: .isDirectory
        ) else {
            throw SupertonicNarrationError.missingAsset("Supertonic")
        }
        let cachesDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let renderer = try SupertonicNarrationRenderer(
            assets: SupertonicAssetLocation(rootURL: resourceRoot),
            outputDirectory: cachesDirectory.appending(path: "SupertonicPlayback", directoryHint: .isDirectory)
        )
        supertonicRenderer = renderer
        return renderer
    }

    /// #240: chunks that fail the output check are read by the iOS voice; diagnostics say so.
    private func supertonicOutputGuard(wrapping renderer: SupertonicRendering, systemVoice: String) -> SupertonicOutputGuard {
        let voice = systemVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        return SupertonicOutputGuard(wrapping: renderer, systemVoiceIdentifier: voice.isEmpty ? nil : voice) { [weak self] summary in
            Task { @MainActor [weak self] in self?.diagnostics["supertonicOutputCheck"] = summary }
        }
    }

    private func makeMediaPlaybackClient() -> AudioPlaybackClient {
        let client = AVPlayerStreamPlaybackClient(
            preferredSkipBackSeconds: mediaSkipBackSeconds,
            preferredSkipForwardSeconds: mediaSkipForwardSeconds,
            interruptionHandler: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleMediaPlaybackInterruption(event)
                }
            }
        ) { [weak self] command, mediaTimeMs, playbackRate in
            Task { @MainActor [weak self] in
                self?.syncPlaybackProgressForLifecycle()
                self?.performGate2CompactCommand(
                    command,
                    mediaTimeMs: mediaTimeMs,
                    playbackRate: playbackRate,
                    origin: "now_playing"
                )
            }
        }
        client.playbackStartTraceHandler = { [weak self] fields in
            Task { @MainActor [weak self] in
                // #160: resume after a spoken Margin on a stream took 2.6-9.3 s; this shows where the time goes.
                self?.recordDeveloperDiagnostic("media.start", fields)
            }
        }
        client.heardSourceWindowHandler = { [weak self] window in
            Task { @MainActor [weak self] in self?.handleHeardSourceWindow(window) }
        }
        client.playbackStallTraceHandler = { [weak self] fields in
            Task { @MainActor [weak self] in
                // #166: the clock froze on a stream while the app showed "playing"; this records the player's state.
                self?.recordDeveloperDiagnostic("media.stall", fields)
            }
        }
        #if canImport(AVFoundation) && canImport(ShazamKit)
        client.postResumePodcastEvidenceHandler = { [weak self] result in
            Task { @MainActor [weak self] in
                self?.handlePostResumePodcastEvidence(result)
            }
        }
        #endif
        mediaPlaybackClient = client
        return client
    }

    private func handleMediaPlaybackInterruption(_ event: AudioPlaybackInterruptionEvent) {
        switch event {
        case .began:
            guard snapshot.status.isPlaybackActive, let engine else {
                diagnostics["mediaPlaybackInterruption"] = "pause_skipped"
                return
            }
            do {
                snapshot = try engine.reconcileSystemInitiatedPause()
                refreshSelectedItem()
                diagnostics["mediaPlaybackInterruption"] = "paused"
            } catch {
                diagnostics["mediaPlaybackInterruption"] = "pause_failed:\(error.localizedDescription)"
                reportWarning("Playback could not be paused cleanly after the audio route changed.")
            }
        case .endedShouldResume:
            guard snapshot.status == .paused, let engine else {
                diagnostics["mediaPlaybackInterruption"] = "resume_skipped"
                return
            }
            do {
                snapshot = try engine.resumePlayback()
                refreshSelectedItem()
                diagnostics["mediaPlaybackInterruption"] = "resumed"
            } catch {
                diagnostics["mediaPlaybackInterruption"] = "resume_failed:\(error.localizedDescription)"
                reportWarning("Playback paused after the interruption. Tap Play to resume.")
            }
        }
    }

    private func handleSpeechPlaybackInterruption(_ event: AudioPlaybackInterruptionEvent) {
        switch event {
        case .began:
            // Counted so a device report can show whether chunk-boundary pauses (#183) come
            // from audio interruptions.
            diagnostics["speechPlaybackInterruptionCount"] = "\(Int(diagnostics["speechPlaybackInterruptionCount"] ?? "0").map { $0 + 1 } ?? 1)"
            guard snapshot.status.isPlaybackActive, let engine else {
                diagnostics["speechPlaybackInterruption"] = "pause_skipped"
                return
            }
            do {
                snapshot = try engine.reconcileSystemInitiatedPause()
                refreshSelectedItem()
                diagnostics["speechPlaybackInterruption"] = "paused"
            } catch {
                diagnostics["speechPlaybackInterruption"] = "pause_failed:\(error.localizedDescription)"
                reportWarning("Playback could not be paused cleanly after the audio route changed.")
            }
        case .endedShouldResume:
            guard snapshot.status == .paused, let engine else {
                diagnostics["speechPlaybackInterruption"] = "resume_skipped"
                return
            }
            do {
                snapshot = try engine.resumePlayback()
                refreshSelectedItem()
                diagnostics["speechPlaybackInterruption"] = "resumed"
            } catch {
                diagnostics["speechPlaybackInterruption"] = "resume_failed:\(error.localizedDescription)"
                reportWarning("Playback paused after the interruption. Tap Play to resume.")
            }
        }
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
            row.offlineState = Self.libraryOfflineState(
                preparedState: manifest.state == .preparing && job == nil ? .notPrepared : manifest.state,
                mediaSourceType: item.media?.sourceType, podcastDownloadState: nil)
            if row != libraryItems[index] { libraryItems[index] = row }
        }
        let jobsByID = Dictionary(uniqueKeysWithValues: remainingJobs.filter { !$0.isCancelled }.map { ($0.id, $0) })
        let retained = audioPreparationQueue.filter { jobsByID[$0.id] != nil }.sorted {
            Self.audioPreparationJobPrecedes(jobsByID[$0.id]!, jobsByID[$1.id]!, activeItemId: activePlaybackItemId)
        }
        let rows = retained.enumerated().map { index, row in
            let current = row.id == job?.id
            let previous = index > 0 ? retained[index - 1] : nil
            let next = index + 1 < retained.count ? retained[index + 1] : nil
            let rowJob = jobsByID[row.id]!
            let pinned = row.itemId == activePlaybackItemId
            let sharesTier: (AudioPreparationQueueRow?) -> Bool = { neighbor in
                guard let neighbor, let neighborJob = jobsByID[neighbor.id] else { return false }
                return neighborJob.policy == rowJob.policy
                    && (neighborJob.maximumChunkCount != nil) == (rowJob.maximumChunkCount != nil)
                    && neighbor.itemId != self.activePlaybackItemId
            }
            return AudioPreparationQueueRow(
                id: row.id, itemId: row.itemId, title: row.title,
                policy: rowJob.policy,
                state: current ? manifest.state : row.state,
                completedChunkCount: current ? min(manifest.chunks.count, job?.maximumChunkCount ?? .max) : row.completedChunkCount,
                plannedChunkCount: current ? min(manifest.plannedChunkCount, job?.maximumChunkCount ?? .max) : row.plannedChunkCount,
                requestedAt: row.requestedAt, updatedAt: current ? manifest.updatedAt : row.updatedAt,
                failureCode: current ? job?.lastFailureCode : row.failureCode,
                isActivePlaybackItem: pinned,
                canMoveEarlier: !pinned && sharesTier(previous),
                canMoveLater: !pinned && sharesTier(next))
        }
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
        let itemsById = Dictionary(uniqueKeysWithValues: try store.listItems().map { ($0.id, $0) })
        let manifests = try store.loadPreparedAudioManifests()
        let manifestsById = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, $0) })
        let activeItemId = activePlaybackItemId
        let completedItemIds = Set(itemsById.values.filter { $0.sourceCompletedAt != nil }.map(\.id)).union(Set(
            Dictionary(grouping: try store.loadSessions(), by: \.itemId)
                .filter { Self.itemIsCompleted($0.value) }
                .keys
        ))
        let storedJobs = try store.loadAudioPreparationJobs()
        try store.deleteAudioPreparationJobs(
            ids: storedJobs.filter { $0.policy != .explicit && completedItemIds.contains($0.itemId) }.map(\.id)
        )
        let jobs = storedJobs
            .filter { !$0.isCancelled && ($0.policy == .explicit || !completedItemIds.contains($0.itemId)) }
            .sorted { lhs, rhs in
                Self.audioPreparationJobPrecedes(lhs, rhs, activeItemId: activeItemId)
            }

        audioPreparationQueue = jobs.enumerated().map { index, job in
            let manifest = manifestsById[job.manifestId]
            let previous = index > 0 ? jobs[index - 1] : nil
            let next = jobs.indices.contains(index + 1) ? jobs[index + 1] : nil
            let isPinnedActive = job.itemId == activeItemId
            let sharesTier: (AudioPreparationJob?) -> Bool = { neighbor in
                guard let neighbor else { return false }
                return neighbor.policy == job.policy
                    && (neighbor.maximumChunkCount != nil) == (job.maximumChunkCount != nil)
            }
            return AudioPreparationQueueRow(
                id: job.id,
                itemId: job.itemId,
                title: itemsById[job.itemId]?.title ?? job.itemId,
                policy: job.policy,
                state: manifest?.state ?? .failed,
                completedChunkCount: min(
                    manifest?.committedChunkCount ?? job.nextChunkIndex,
                    job.maximumChunkCount ?? manifest?.plannedChunkCount ?? .max
                ),
                plannedChunkCount: min(
                    manifest?.plannedChunkCount ?? job.maximumChunkCount ?? 0,
                    job.maximumChunkCount ?? .max
                ),
                requestedAt: job.requestedAt,
                updatedAt: manifest?.updatedAt ?? job.requestedAt,
                failureCode: job.lastFailureCode ?? manifest?.failureCode,
                isActivePlaybackItem: isPinnedActive,
                canMoveEarlier: !isPinnedActive && sharesTier(previous) && previous?.itemId != activeItemId,
                canMoveLater: !isPinnedActive && sharesTier(next) && next?.itemId != activeItemId
            )
        }

        var seenItemIds = Set<String>()
        recentlyPreparedAudio = manifests
            .filter { $0.state == .readyOffline && $0.artifact != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { manifest -> RecentlyPreparedAudioRow? in
                guard seenItemIds.insert(manifest.itemId).inserted else { return nil }
                return RecentlyPreparedAudioRow(
                    id: manifest.id,
                    itemId: manifest.itemId,
                    title: itemsById[manifest.itemId]?.title ?? manifest.itemId,
                    completedAt: manifest.updatedAt,
                    durationMs: manifest.artifact?.durationMs ?? 0
                )
            }
            .prefix(10)
            .map { $0 }

        guard announceNewCompletions else { return }
        let defaults = UserDefaults.standard
        let storedTimestamp = defaults.object(forKey: Self.lastPreparedAudioNoticeDateKey) as? Double
        let noticeBoundary = storedTimestamp.map(Date.init(timeIntervalSince1970:))
            ?? now.addingTimeInterval(-24 * 60 * 60)
        let newlyCompleted = recentlyPreparedAudio.filter { $0.completedAt > noticeBoundary }
        guard let newest = newlyCompleted.first else { return }
        defaults.set(newest.completedAt.timeIntervalSince1970, forKey: Self.lastPreparedAudioNoticeDateKey)
        let message: String
        if newlyCompleted.count == 1 {
            message = "Ready offline: \(newest.title)."
        } else {
            message = "Ready offline: \(newest.title) and \(newlyCompleted.count - 1) more. Review them in Offline Rendering."
        }
        reportConfirmation(message)
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
            try refreshLibraryRows(store: store)
            diagnostics["audioPreparationSuppressed:\(selected.itemId)"] = "user"
            reportConfirmation("Removed \(itemsTitle(itemId: selected.itemId, store: store)) from offline rendering.")
        } catch {
            reportFailure(error, context: "Removing the item from offline rendering failed")
        }
    }

    func clearAudioPreparationQueue() {
        do {
            let store = try requireStore()
            let jobs = try store.loadAudioPreparationJobs().filter { !$0.isCancelled }
            let itemIds = Set(jobs.map(\.itemId))
            foregroundAudioPreparationTask?.cancel()
            foregroundAudioPreparationGeneration += 1
            foregroundAudioPreparationTask = nil
            suppressAudioPreparation(itemIds: itemIds)
            try store.deleteAudioPreparationJobs(ids: jobs.map(\.id))
            pendingStartupAudioPreparationItemIds.subtract(itemIds)
            failedStartupAudioPreparationItemIds.subtract(itemIds)
            try refreshLibraryRows(store: store)
            diagnostics["audioPreparationQueueCleared"] = "\(jobs.count)"
            reportConfirmation("Cleared \(jobs.count) offline rendering job\(jobs.count == 1 ? "" : "s"). Existing audio and Library items were kept.")
        } catch {
            reportFailure(error, context: "Clearing the offline rendering queue failed")
        }
    }

    private func suppressAudioPreparation(itemId: String) {
        suppressAudioPreparation(itemIds: Set([itemId]))
    }

    private func suppressAudioPreparation(itemIds: Set<String>) {
        suppressedAutomaticAudioPreparationItemIds.formUnion(itemIds)
        UserDefaults.standard.set(
            suppressedAutomaticAudioPreparationItemIds.sorted(),
            forKey: Self.suppressedAudioPreparationItemIdsKey
        )
    }

    private func allowAudioPreparation(itemId: String) {
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
            selected.userPriority = max(Int.min + 1, jobs.compactMap(\.userPriority).min() ?? 0) - 1
            try store.saveAudioPreparationJob(selected)
            try refreshAudioPreparationPresentation(store: store)
            startForegroundAudioPreparationIfNeeded()
        } catch {
            reportFailure(error, context: "Unable to prioritize rendering")
        }
    }

    private func moveAudioPreparationJob(id: String, offset: Int) {
        guard offset == -1 || offset == 1 else { return }
        do {
            let store = try requireStore()
            var allJobs = try store.loadAudioPreparationJobs().filter { !$0.isCancelled }
            guard let selected = allJobs.first(where: { $0.id == id }),
                  selected.itemId != activePlaybackItemId else { return }
            var tier = allJobs
                .filter {
                    $0.policy == selected.policy
                        && ($0.maximumChunkCount != nil) == (selected.maximumChunkCount != nil)
                        && $0.itemId != activePlaybackItemId
                }
                .sorted { Self.audioPreparationJobPrecedes($0, $1, activeItemId: nil) }
            guard let currentIndex = tier.firstIndex(where: { $0.id == id }) else { return }
            let destination = currentIndex + offset
            guard tier.indices.contains(destination) else { return }
            tier.swapAt(currentIndex, destination)
            for (priority, var job) in tier.enumerated() {
                job.userPriority = priority
                try store.saveAudioPreparationJob(job)
                if let allIndex = allJobs.firstIndex(where: { $0.id == job.id }) {
                    allJobs[allIndex] = job
                }
            }
            try refreshAudioPreparationPresentation(store: store)
            reportConfirmation("Updated the offline rendering order.")
        } catch {
            reportFailure(error, context: "Updating the rendering queue failed")
        }
    }

    func finishStreamingTurnIfReady(_ turnId: String) {
        guard completedStreamingTurnIds.contains(turnId),
              !streamingSpeechQueue.hasPendingSpeech(for: turnId),
              let engine else {
            return
        }
        do {
            snapshot = try engine.finishStreamingTurnPlayback(turnId: turnId)
            completedStreamingTurnIds.remove(turnId)
            diagnostics["streamingSpeechPending"] = "\(streamingSpeechQueue.pendingCount)"
            diagnostics["streamingTurnCompleted"] = turnId
            refreshSelectedItem()
        } catch {
            diagnostics["streamingTurnCompletionError"] = String(describing: error)
        }
    }

    func syncPlaybackProgressBeforeGeneratedTurnDecision(engine: SessionEngine) -> Bool {
        let previousStatus = snapshot.status
        let previousTargetId = snapshot.targetId
        do {
            let updated = try engine.syncPlaybackProgress()
            if updated != snapshot {
                snapshot = updated
            }
            return previousStatus.isPlaybackActive &&
                updated.status == .paused &&
                previousTargetId == updated.targetId &&
                updated.currentPlaybackProgressPercent >= 100
        } catch {
            diagnostics["playbackProgressSyncError"] = String(describing: error)
            return false
        }
    }

    private func parseListeningMapJSON(_ raw: String, item: Item) throws -> ListeningMap {
        let trimmed = repairedJSONObjectString(from: raw)
        guard !trimmed.isEmpty else {
            throw ManualListeningMapError.empty
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw ManualListeningMapError.invalidUTF8
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ManualListeningMapError.jsonParseFailed(String(describing: error))
        }
        guard let root = parsed as? [String: Any] else {
            throw ManualListeningMapError.rootMustBeObject
        }
        guard root["schemaVersion"] as? String == "listening-map.v1" else {
            throw ManualListeningMapError.invalidSchema
        }
        guard let overview = root["overview"] as? String,
              !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManualListeningMapError.missingOverview
        }
        guard let rawChapters = root["chapters"] as? [[String: Any]], !rawChapters.isEmpty else {
            throw ManualListeningMapError.missingChapters
        }
        guard let text = item.text, !text.isEmpty else {
            throw ManualListeningMapError.itemHasNoText
        }

        var ids = Set<String>()
        let chapters = try rawChapters.map { chapterObject in
            guard let id = chapterObject["id"] as? String,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManualListeningMapError.missingChapterId
            }
            guard ids.insert(id).inserted else {
                throw ManualListeningMapError.duplicateChapterId(id)
            }
            guard let title = chapterObject["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManualListeningMapError.missingChapterTitle(id)
            }
            guard let description = chapterObject["description"] as? String,
                  !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManualListeningMapError.missingChapterDescription(id)
            }
            if let start = chapterObject["startChar"] as? Int,
               let end = chapterObject["endChar"] as? Int {
                return try validatedChapter(id: id, title: title, start: start, end: end, text: text)
            }
            guard let anchor = (chapterObject["anchor"] as? String) ?? (chapterObject["anchorText"] as? String),
                  !anchor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManualListeningMapError.missingChapterAnchor(id)
            }
            let range = try resolveAnchor(anchor, in: text, chapterId: id)
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            return try validatedChapter(id: id, title: title, start: start, end: end, text: text)
        }
        .sorted { lhs, rhs in
            if lhs.startChar == rhs.startChar {
                return lhs.id < rhs.id
            }
            return lhs.startChar < rhs.startChar
        }

        return ListeningMap(
            id: "map-\(item.id)-manual",
            itemId: item.id,
            overview: overview.trimmingCharacters(in: .whitespacesAndNewlines),
            chapters: chapters
        )
    }

    private func repairedJSONObjectString(from raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first <= last {
            text = String(text[first...last])
        }
        text = normalizingJSONDelimitersOutsideStrings(in: text)
        text = removingJSONCommentsOutsideStrings(from: text)
        text = escapingControlCharactersInsideJSONStringLiterals(in: text)
        text = text
            .replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizingJSONDelimitersOutsideStrings(in text: String) -> String {
        var output = ""
        var inString = false
        var escaped = false

        for scalar in text.unicodeScalars {
            if inString {
                output.unicodeScalars.append(scalar)
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                continue
            }

            if scalar == "\"" || scalar == "“" || scalar == "”" {
                output += "\""
                inString = true
            } else {
                output.unicodeScalars.append(scalar)
            }
        }

        return output
    }

    private func removingJSONCommentsOutsideStrings(from text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = ""
        var index = 0
        var inString = false
        var escaped = false

        while index < scalars.count {
            let scalar = scalars[index]
            if inString {
                output.unicodeScalars.append(scalar)
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                index += 1
                continue
            }

            if scalar == "\"" {
                inString = true
                output.unicodeScalars.append(scalar)
                index += 1
            } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                index += 2
                while index < scalars.count, scalars[index] != "\n" {
                    index += 1
                }
            } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                index += 2
                while index + 1 < scalars.count, !(scalars[index] == "*" && scalars[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, scalars.count)
            } else {
                output.unicodeScalars.append(scalar)
                index += 1
            }
        }

        return output
    }

    private func escapingControlCharactersInsideJSONStringLiterals(in text: String) -> String {
        var output = ""
        var inString = false
        var escaped = false

        for scalar in text.unicodeScalars {
            if inString {
                if escaped {
                    output.unicodeScalars.append(scalar)
                    escaped = false
                } else if scalar == "\\" {
                    output.unicodeScalars.append(scalar)
                    escaped = true
                } else if scalar == "\"" {
                    output.unicodeScalars.append(scalar)
                    inString = false
                } else if scalar.value < 0x20 {
                    switch scalar {
                    case "\n":
                        output += "\\n"
                    case "\r":
                        output += "\\r"
                    case "\t":
                        output += "\\t"
                    default:
                        output += String(format: "\\u%04X", scalar.value)
                    }
                } else {
                    output.unicodeScalars.append(scalar)
                }
            } else {
                output.unicodeScalars.append(scalar)
                if scalar == "\"" {
                    inString = true
                }
            }
        }

        return output
    }

    private func validatedChapter(id: String, title: String, start: Int, end: Int, text: String) throws -> Chapter {
        guard start >= 0, end > start, end <= text.count else {
            throw ManualListeningMapError.invalidChapterRange(id)
        }
        let percent = text.isEmpty ? 0 : Int((Double(start) / Double(text.count)) * 100)
        return Chapter(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            startChar: start,
            endChar: end,
            percent: min(100, max(0, percent))
        )
    }

    private func resolveAnchor(_ anchor: String, in text: String, chapterId: String) throws -> Range<String.Index> {
        let trimmedAnchor = anchor.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = text.range(of: trimmedAnchor) {
            return exact
        }
        if let folded = text.range(of: trimmedAnchor, options: [.caseInsensitive, .diacriticInsensitive]) {
            return folded
        }
        if let normalized = normalizedAnchorRange(trimmedAnchor, in: text) {
            return normalized
        }
        if let ngram = ngramAnchorRange(trimmedAnchor, in: text) {
            return ngram
        }
        throw ManualListeningMapError.anchorNotFound(chapterId)
    }

    private func ngramAnchorRange(_ anchor: String, in text: String) -> Range<String.Index>? {
        let words = anchor
            .replacingOccurrences(of: #"[^A-Za-z0-9']+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
        guard words.count >= 5 else { return nil }
        let maxWindow = min(12, words.count)
        for size in stride(from: maxWindow, through: 5, by: -1) {
            guard words.count >= size else { continue }
            for start in 0...(words.count - size) {
                let phrase = words[start..<(start + size)].joined(separator: " ")
                if let range = normalizedAnchorRange(phrase, in: text) {
                    return range
                }
            }
        }
        return nil
    }

    private func normalizedAnchorRange(_ anchor: String, in text: String) -> Range<String.Index>? {
        let source = normalizedSearchIndex(for: text)
        let target = normalizedSearchIndex(for: anchor).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, let range = source.text.range(of: target) else { return nil }
        let lowerOffset = source.text.distance(from: source.text.startIndex, to: range.lowerBound)
        let upperOffset = source.text.distance(from: source.text.startIndex, to: range.upperBound)
        guard lowerOffset < source.indices.count, upperOffset > 0 else { return nil }
        let lower = source.indices[lowerOffset]
        let last = source.indices[min(source.indices.count - 1, upperOffset - 1)]
        let upper = text.index(after: last)
        return lower..<upper
    }

    private func normalizedSearchIndex(for text: String) -> (text: String, indices: [String.Index]) {
        var normalized = ""
        var indices: [String.Index] = []
        var lastWasSpace = true
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            let folded = String(char).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if folded.range(of: #"^[A-Za-z0-9']+$"#, options: .regularExpression) != nil {
                normalized.append(folded.lowercased())
                indices.append(index)
                lastWasSpace = false
            } else if !lastWasSpace {
                normalized.append(" ")
                indices.append(index)
                lastWasSpace = true
            }
            index = text.index(after: index)
        }
        if normalized.last == " " {
            normalized.removeLast()
            indices.removeLast()
        }
        return (normalized, indices)
    }

    func configurePodcastDownloads(store: SQLiteSessionStore) throws {
        try configureOfflineServices(store: store)
        podcastDownloadCoordinator?.shutdown()
        let limit = PodcastCacheLimitGB(rawValue: podcastCacheLimitGB) ?? .defaultValue
        let coordinator = try PodcastDownloadCoordinator(
            store: store,
            ledger: offlineStorageLedger ?? OfflineStorageLedger(
                repository: store,
                rootDirectory: try applicationSupportDirectory()
            ),
            applicationSupportDirectory: try applicationSupportDirectory(),
            cacheLimit: limit,
            monitorsNetwork: !Self.isRunningUnitTests,
            usesBackgroundSession: !Self.isRunningUnitTests
        )
        coordinator.onRecordChanged = { [weak self] record in
            guard let self else { return }
            podcastDownloadRecords[record.itemId] = record
            if let index = libraryItems.firstIndex(where: { $0.id == record.itemId }) {
                let state = Self.libraryOfflineState(
                    preparedState: nil,
                    mediaSourceType: nil,
                    podcastDownloadState: record.state
                )
                if libraryItems[index].offlineState != state {
                    libraryItems[index].offlineState = state
                }
            }
            if diagnostics["podcastDownload:\(record.itemId)"] != record.state.rawValue {
                recordDeveloperDiagnostic("download.state", ["item": DeveloperDiagnosticRecording.token(record.itemId),
                    "state": record.state.rawValue, "bytes": String(record.bytesWritten),
                    "failure": DeveloperDiagnosticRecording.token(record.failureReason)])
            }
            diagnostics["podcastDownload:\(record.itemId)"] = record.state.rawValue
        }
        coordinator.onLocalAssetReady = { [weak self] itemId, url in
            self?.podcastLocalAssetDidBecomeReady(itemId: itemId, url: url)
        }
        podcastDownloadCoordinator = coordinator
        podcastDownloadRecords = coordinator.recordsByItemId
        diagnostics["podcastCacheLimitGB"] = "\(limit.rawValue)"
    }

    func enqueueExplicitAudioPreparation(item: Item) async {
        guard let sourceText = item.text,
              !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let voice = ttsVoiceSelection.supertonicVoice else { return }
        guard !usesStructuredSpeech(item) else {
            diagnostics["explicitAudioPreparation:\(item.id)"] = "skipped_structured_pdf"
            statusMessage = "This PDF plays with live speech; preparing its audio ahead isn't available yet."
            return
        }
        do {
            allowAudioPreparation(itemId: item.id)
            failedStartupAudioPreparationItemIds.remove(item.id)
            let store = try requireStore()
            let support = try applicationSupportDirectory()
            guard let resourceRoot = Bundle.main.resourceURL?.appending(path: "Supertonic", directoryHint: .isDirectory) else {
                reportFailure("The bundled speech assets are unavailable.")
                return
            }
            let assets = SupertonicAssetLocation(rootURL: resourceRoot)
            let signature = try await Task.detached(priority: .utility) {
                try SupertonicRenderIdentity.make(assets: assets, voice: voice)
            }.value
            let coordinator = preparedAudioCoordinator ?? PreparedAudioCoordinator(
                repository: store,
                rootDirectory: support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
            )
            preparedAudioCoordinator = coordinator
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
                try refreshLibraryRows(store: store)
                reportConfirmation("\(item.title) is already available offline.")
                return
            }
            var job = (try store.loadAudioPreparationJobs()).first(where: { $0.manifestId == manifest.id })
                ?? AudioPreparationJob(
                    id: "job-\(manifest.id)",
                    itemId: item.id,
                    manifestId: manifest.id,
                    policy: .explicit
                )
            job.policy = .explicit
            job.userPriority = 0
            job.maximumChunkCount = nil
            job.requestedAt = Date()
            job.isCancelled = false
            try store.saveAudioPreparationJob(job)
            try refreshLibraryRows(store: store)
            diagnostics["explicitAudioPreparation:\(item.id)"] = "queued"
            reportConfirmation("Prioritized \(item.title) for offline rendering.")
            startForegroundAudioPreparationIfNeeded()
        } catch {
            diagnostics["explicitAudioPreparation:\(item.id)"] = "failed:\(error.localizedDescription)"
            reportFailure(error, context: "Offline rendering request failed")
        }
    }

    func startForegroundAudioPreparationIfNeeded() {
        guard foregroundAudioPreparationTask == nil else { return }
        foregroundAudioPreparationGeneration += 1
        let generation = foregroundAudioPreparationGeneration
        foregroundAudioPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, await self.performBackgroundAudioPreparationPass(foregroundDemandOnly: true) {
                await Task.yield()
            }
            if self.foregroundAudioPreparationGeneration == generation {
                self.foregroundAudioPreparationTask = nil
                if Task.isCancelled, self.canPrepareLibraryAudio {
                    self.startForegroundAudioPreparationIfNeeded()
                }
                if let store = self.store {
                    try? self.refreshLibraryRows(store: store)
                }
            }
        }
    }

    private func enqueueAutomaticAudioPreparationJobs() async {
        guard automaticAudioPreparationPolicy == .whileCharging,
              hasAcceptedCurrentTerms,
              let voice = ttsVoiceSelection.supertonicVoice else { return }
        do {
            let store = try requireStore()
            let support = try applicationSupportDirectory()
            guard let resourceRoot = Bundle.main.resourceURL?.appending(path: "Supertonic", directoryHint: .isDirectory) else { return }
            let assets = SupertonicAssetLocation(rootURL: resourceRoot)
            let signature = try await Task.detached(priority: .utility) {
                try SupertonicRenderIdentity.make(assets: assets, voice: voice)
            }.value
            let coordinator = preparedAudioCoordinator ?? PreparedAudioCoordinator(
                repository: store,
                rootDirectory: support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
            )
            preparedAudioCoordinator = coordinator
            currentSupertonicRenderSignature = signature
            let sessionsByItemId = Dictionary(grouping: try store.loadSessions(), by: \.itemId)
            for row in libraryItems {
                guard let item = try? store.loadItem(id: row.id),
                      let text = item.text,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !suppressedAutomaticAudioPreparationItemIds.contains(item.id),
                      !usesStructuredSpeech(item) else { continue }
                guard item.sourceCompletedAt == nil, !Self.shouldSkipTextAudioPreparation(sessionsByItemId[item.id] ?? []) else {
                    diagnostics["automaticAudioPreparation:\(item.id)"] = "skipped_existing_progress"
                    continue
                }
                let plan = await Task.detached(priority: .utility) {
                    Self.preparedChunkPlan(for: text)
                }.value
                guard !plan.isEmpty else { continue }
                let manifest = try await coordinator.begin(
                    itemId: item.id,
                    sourceText: text,
                    signature: signature,
                    plan: plan
                )
                guard manifest.state != .readyOffline else { continue }
                var job = (try store.loadAudioPreparationJobs()).first(where: { $0.manifestId == manifest.id })
                    ?? AudioPreparationJob(id: "job-\(manifest.id)", itemId: item.id, manifestId: manifest.id, policy: .whileCharging, requestedAt: item.createdAt ?? Date())
                let unfinishedStartupHorizon = job.policy == .demandWindow
                    && job.maximumChunkCount.map { manifest.chunks.count < $0 } == true
                if !unfinishedStartupHorizon {
                    job.policy = .whileCharging
                    job.maximumChunkCount = nil
                }
                job.isCancelled = false
                try store.saveAudioPreparationJob(job)
            }
            try refreshAudioPreparationPresentation(store: store)
            diagnostics["automaticAudioPreparationQueue"] = "queued"
        } catch {
            diagnostics["automaticAudioPreparationQueue"] = "failed:\(error.localizedDescription)"
        }
    }

    var canPrepareLibraryAudio: Bool {
        !SupertonicResourcePolicy.memoryBackoff.isActive()
            && (!snapshot.status.isPlaybackActive || isMediaPlaybackSnapshot
                || snapshot.preparedTextAudioStatus == "ready"
                || (speechPlaybackClient as? SupertonicSpeechPlaybackClient)?.canYieldRendererToLibrary == true)
    }

    private func performBackgroundAudioPreparationPass(foregroundDemandOnly: Bool = false) async -> Bool {
        var attemptedJob: AudioPreparationJob?
        // Live speech owns the serial renderer while the listener has active
        // demand. A stale/background job must not queue ahead of its next chunk.
        guard canPrepareLibraryAudio else { return false }
        guard (foregroundDemandOnly || automaticAudioPreparationPolicy == .whileCharging),
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical,
              hasAcceptedCurrentTerms,
              let voice = ttsVoiceSelection.supertonicVoice else { return false }
        do {
            try Task.checkCancellation()
            let store = try requireStore()
            var queuedJobs = try store.loadAudioPreparationJobs()
                .filter({ !$0.isCancelled })
            if foregroundDemandOnly {
                queuedJobs = queuedJobs.filter {
                    $0.policy == .explicit || ($0.policy == .demandWindow && $0.maximumChunkCount != nil)
                }
            }
            queuedJobs.sort {
                Self.audioPreparationJobPrecedes($0, $1, activeItemId: activePlaybackItemId)
            }
            if queuedJobs.isEmpty, !foregroundDemandOnly {
                await enqueueAutomaticAudioPreparationJobs()
                queuedJobs = try store.loadAudioPreparationJobs()
                    .filter { !$0.isCancelled }
                    .sorted {
                        Self.audioPreparationJobPrecedes($0, $1, activeItemId: activePlaybackItemId)
                    }
            }
            let hasMoreMatchingJobs = {
                let remaining = try store.loadAudioPreparationJobs().filter { !$0.isCancelled }
                return foregroundDemandOnly
                    ? remaining.contains(where: { $0.policy == .explicit || ($0.policy == .demandWindow && $0.maximumChunkCount != nil) })
                    : !remaining.isEmpty
            }
            guard var job = queuedJobs.first else { return false }
            guard var manifest = try store.loadPreparedAudioManifest(id: job.manifestId),
                  let item = try? store.loadItem(id: job.itemId),
                  let sourceText = item.text else {
                try store.deleteAudioPreparationJob(id: job.id)
                diagnostics["backgroundAudioPreparation"] = "discarded_missing_source_job"
                return try hasMoreMatchingJobs()
            }
            attemptedJob = job
            recordDeveloperDiagnostic("preparation.selected", ["item": DeveloperDiagnosticRecording.token(job.itemId), "policy": String(describing: job.policy), "nextChunk": String(job.nextChunkIndex)])
            let sourceSessions = try store.loadSessions(itemId: item.id)
            if job.policy != .explicit, item.sourceCompletedAt != nil || Self.shouldSkipTextAudioPreparation(sourceSessions) {
                // Removing speculative work must never invalidate committed audio.
                try store.deleteAudioPreparationJob(id: job.id)
                diagnostics["automaticAudioPreparation:\(item.id)"] = "cancelled_existing_progress"
                return try hasMoreMatchingJobs()
            }
            let support = try applicationSupportDirectory()
            guard let resourceRoot = Bundle.main.resourceURL?.appending(path: "Supertonic", directoryHint: .isDirectory) else {
                return !foregroundDemandOnly
            }
            let assets = SupertonicAssetLocation(rootURL: resourceRoot)
            let signature = try await Task.detached(priority: .utility) {
                try SupertonicRenderIdentity.make(assets: assets, voice: voice)
            }.value
            guard manifest.signature == signature else {
                manifest.state = .needsRepreparation
                manifest.updatedAt = Date()
                try store.savePreparedAudioManifest(manifest)
                try store.deleteAudioPreparationJob(id: job.id)
                return try hasMoreMatchingJobs()
            }
            let plan = await Task.detached(priority: .utility) {
                Self.preparedChunkPlan(for: sourceText)
            }.value
            let eligiblePlan = Self.preparationHorizon(
                plan: plan,
                maximumChunkCount: job.maximumChunkCount
            )
            let completedIndexes = PreparedAudioCoordinator.completedIndexes(manifest, plan: plan, sourceText: sourceText, retryingStandInsFor: job)
            let ledger = offlineStorageLedger ?? OfflineStorageLedger(repository: store, rootDirectory: support)
            offlineStorageLedger = ledger
            let coordinator = preparedAudioCoordinator ?? PreparedAudioCoordinator(
                repository: store,
                rootDirectory: support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
            )
            preparedAudioCoordinator = coordinator
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
                byteCount: 64 * 1_024 * 1_024
            )
            let renderer = try makeSupertonicRenderer()
            // Paced per render, not through the shared lifecycle flag (#377).
            let pacedRenderer = BackgroundPreparationRenderer(base: renderer)
            do {
                try Task.checkCancellation()
                recordDeveloperDiagnostic("preparation.render.begin", ["item": DeveloperDiagnosticRecording.token(item.id), "chunk": String(next.index)])
                // The render is discarded once committed (copied), or on any failure.
                try await supertonicOutputGuard(wrapping: pacedRenderer, systemVoice: speechVoiceIdentifier).render(
                    text: next.text, voice: voice, language: "en", speed: 1, synthesisSteps: 8
                ) { rendered in
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
                return !foregroundDemandOnly
            }
            try await ledger.commit(
                reservationId: reservation.id,
                asset: OwnedOfflineAsset(
                    id: committed.id,
                    itemId: item.id,
                    category: .preparedChunk,
                    relativePath: "PreparedAudio/\(committed.relativePath)",
                    byteCount: committed.byteCount,
                    checksumSHA256: committed.checksumSHA256,
                    isReproducible: true
                )
            )
            job = (try store.loadAudioPreparationJobs()).first(where: { $0.id == job.id }) ?? job
            recordDeveloperDiagnostic("preparation.committed", ["item": DeveloperDiagnosticRecording.token(item.id), "chunks": String(updated.chunks.count)])
            job.nextChunkIndex = updated.chunks.count
            job.lastFailureCode = PreparedAudioCoordinator.hasStandIns(updated) ? PreparedAudioCoordinator.standInRetried : nil
            if PreparedAudioCoordinator.matchingChunks(in: updated, plan: plan, sourceText: sourceText).count == plan.count {
                try store.saveAudioPreparationJob(job)
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
            applyPreparedChunkProgress(item: item, manifest: updated,
                                       remainingJobs: try store.loadAudioPreparationJobs())
            let hasMore = try hasMoreMatchingJobs()
            diagnostics["backgroundAudioPreparation"] = hasMore ? "chunk_committed" : "complete"
            return hasMore
        } catch is CancellationError {
            if var job = attemptedJob,
               !suppressedAutomaticAudioPreparationItemIds.contains(job.itemId),
               let store {
                job.lastFailureCode = "background_time_expired"
                try? store.saveAudioPreparationJob(job)
                try? refreshAudioPreparationPresentation(store: store)
            }
            diagnostics["backgroundAudioPreparation"] = "expired"
            return !foregroundDemandOnly
        } catch {
            if var job = attemptedJob, let store {
                job.lastFailureCode = String(describing: type(of: error))
                try? store.saveAudioPreparationJob(job)
                if job.maximumChunkCount != nil {
                    failedStartupAudioPreparationItemIds.insert(job.itemId)
                }
                try? refreshLibraryRows(store: store)
            }
            diagnostics["backgroundAudioPreparation"] = "paused:\(error.localizedDescription)"
            if attemptedJob?.policy == .explicit {
                reportWarning("Offline rendering paused: \(error.localizedDescription)")
            }
            return false
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
        if lhs.userPriority != rhs.userPriority {
            return (lhs.userPriority ?? .max) < (rhs.userPriority ?? .max)
        }
        if let activeItemId, (lhs.itemId == activeItemId) != (rhs.itemId == activeItemId) {
            return lhs.itemId == activeItemId
        }
        let lhsIsOpeningBuffer = lhs.policy == .demandWindow && lhs.maximumChunkCount != nil
        let rhsIsOpeningBuffer = rhs.policy == .demandWindow && rhs.maximumChunkCount != nil
        if lhsIsOpeningBuffer != rhsIsOpeningBuffer {
            return lhsIsOpeningBuffer
        }
        if (lhs.policy == .explicit) != (rhs.policy == .explicit) {
            return lhs.policy == .explicit
        }
        if lhs.policy != rhs.policy {
            if lhs.policy == .demandWindow { return true }
            if rhs.policy == .demandWindow { return false }
        }
        if lhs.requestedAt != rhs.requestedAt {
            return lhs.requestedAt > rhs.requestedAt
        }
        return lhs.id < rhs.id
    }

    private func finishBackgroundPreparedAudio(
        item: Item,
        sourceText: String,
        voice: SupertonicVoiceID,
        signature: TTSRenderSignature,
        manifest: PreparedAudioManifest,
        plan: [PreparedChunkPlan],
        store: SQLiteSessionStore,
        ledger: OfflineStorageLedger,
        coordinator: PreparedAudioCoordinator,
        support: URL
    ) async throws {
        // A stand-in (iOS voice) chunk waits for a play to retry Supertonic; don't bake it in (#363).
        guard !PreparedAudioCoordinator.hasStandIns(manifest) else { return }
        let chunks = try PreparedAudioCoordinator.assemblyChunks(
            plan: plan, manifest: manifest, sourceText: sourceText,
            preparedRoot: support.appending(path: "PreparedAudio", directoryHint: .isDirectory)
        )
        let assemblyReservation = try await ledger.reserve(
            ownerId: "prepared-artifact-\(manifest.id)",
            byteCount: max(1, manifest.chunks.reduce(0) { $0 + $1.byteCount })
        )
        do {
            let prepared = try await SupertonicPreparedAudioAssembler.assemble(
                itemId: item.id,
                sourceText: sourceText,
                projection: SpeechTextNormalizer.normalizeWithSourceOffsets(sourceText),
                voice: voice,
                chunks: chunks,
                outputDirectory: support.appending(path: "PreparedSupertonicAudio", directoryHint: .isDirectory)
            )
            guard attachPreparedTextAudio(prepared, itemId: item.id, replaceActivePlayback: false),
                  let rawURL = prepared.media.url,
                  let url = URL(string: rawURL) else {
                throw SessionKitError.persistenceFailed("prepared_audio_attach_failed")
            }
            try await coordinator.complete(itemId: item.id, signature: signature, prepared: prepared)
            try refreshLibraryRows(store: store)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            let relative = String(url.standardizedFileURL.path.dropFirst(support.standardizedFileURL.path.count + 1))
            try await ledger.commit(
                reservationId: assemblyReservation.id,
                asset: OwnedOfflineAsset(
                    id: "prepared-artifact-\(manifest.id)",
                    itemId: item.id,
                    category: .preparedAudio,
                    relativePath: relative,
                    byteCount: Int64(values.fileSize ?? 0),
                    isReproducible: true
                )
            )
            for asset in try store.loadOwnedOfflineAssets() where asset.itemId == item.id && asset.category == .preparedChunk {
                try store.updateOwnedOfflineAsset(id: asset.id) { $0.isRedundant = true }
            }
        } catch {
            try? await ledger.release(reservationId: assemblyReservation.id)
            throw error
        }
    }

    private nonisolated static func preparedChunkPlan(for sourceText: String) -> [PreparedChunkPlan] {
        preparationPlanCache.value(for: sourceText) { PreparedChunkPlan.articlePlan(sourceText) }
    }

    nonisolated static func preparationHorizon(
        plan: [PreparedChunkPlan],
        maximumChunkCount: Int?
    ) -> [PreparedChunkPlan] {
        Array(plan.prefix(min(maximumChunkCount ?? plan.count, plan.count)))
    }

    func resolvedOwnedAudiobookURL(for item: Item) -> URL? {
        // iOS can relocate the data container during an update. The ledger path
        // is relative to today's Application Support directory; item URLs are not.
        if let assets = try? store?.loadOwnedOfflineAssets(),
           let asset = assets.first(where: { $0.itemId == item.id && $0.category == .audiobook && $0.integrity == .valid }),
           let url = resolvedApplicationSupportAssetURL(for: asset.relativePath) {
            return url
        }
        guard let savedURL = item.media?.url.flatMap(URL.init(string:)), savedURL.isFileURL else { return nil }
        return resolvedApplicationSupportAssetURL(for: savedURL.path)
    }

    func prepareSourceMediaPlayback(itemId: String) throws {
        if let item = try store?.loadItem(id: itemId), item.mediaType == "audiobook" {
            guard let url = resolvedOwnedAudiobookURL(for: item) else {
                throw SessionKitError.invalidCommandForState("The imported audio file is unavailable. Restore the source audio to continue listening.")
            }
            _ = try engine?.updatePlaybackTransport(itemId: itemId, playbackURL: url.absoluteString, replaceActivePlayback: false)
            return
        }
        guard let coordinator = podcastDownloadCoordinator else { return }
        coordinator.configureActiveItem(itemId)
        if let record = podcastDownloadRecords[itemId], record.state == .evicted,
           coordinator.networkTransport == .wifi,
           let remoteURL = URL(string: record.remoteURL) {
            coordinator.register(itemId: itemId, remoteURL: remoteURL)
        }
        guard let localURL = coordinator.validatedLocalURL(for: itemId) else {
            // Clear a cached local override when its file has disappeared.
            _ = try engine?.updatePlaybackTransport(itemId: itemId, playbackURL: nil, replaceActivePlayback: false)
            return
        }
        _ = try? engine?.updatePlaybackTransport(itemId: itemId, playbackURL: localURL.absoluteString, replaceActivePlayback: false)
        resolveImportedPodcastCommentary(itemId: itemId, localURL: localURL)
    }
}
