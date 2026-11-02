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

/// The model's face to `EpisodeMapPreparer` (#957), the host it asks for, and the summary bridge assets.
extension Gate1AppModel {
    var episodeMapPreparationStatus: String { episodeMapPreparer.status }

    var episodeMapPreparationTask: Task<Void, Never>? { episodeMapPreparer.task }

    var episodeMapPreparationItemId: String? { episodeMapPreparer.itemId }

    /// The one item whose private map waits on a download or a transcript.
    var pendingMapGenerationItemId: String? {
        get { episodeMapPreparer.pendingRequestItemId }
        set { episodeMapPreparer.pendingRequestItemId = newValue }
    }

    func prepareEpisodeMap(
        itemId: String? = nil,
        policy: PreparationJobPolicy = .explicit,
        trigger: EpisodeMapPreparationTrigger = .listenerRequest
    ) {
        episodeMapPreparer.prepare(itemId: itemId ?? activeItemId, policy: policy, trigger: trigger)
    }

    func episodeMapDirectory(itemId: String) throws -> URL {
        try applicationSupportDirectory()
            .appending(path: "SpokenMargins/EpisodeMaps", directoryHint: .isDirectory)
            .appending(path: safePodcastEvidenceComponent(itemId), directoryHint: .isDirectory)
    }

    /// James or Lily is chosen but Supertonic isn't downloaded (#1820): the bundled Kitten voice speaks the summary,
    /// as it does the narration. The asset ID names the voice that rendered it, so once the listener downloads
    /// Supertonic the summary is prepared again in their chosen voice instead of reusing Kitten's.
    private var summaryBridgeUsesKitten: Bool {
        ttsVoiceSelection.supertonicVoice != nil && !supertonicModel.isModelPresent
    }

    private func currentSummaryBridgeVoiceKey(usesKitten: Bool) -> String {
        if usesKitten {
            return safePodcastEvidenceComponent("\(KittenNarrationRenderer.engine)--\(SummaryBridgeRatePolicy.cacheVersion)")
        }
        let systemIdentifier = ttsVoiceSelection == .system ? speechVoiceIdentifier : ""
        return safePodcastEvidenceComponent("\(ttsVoiceSelection.rawValue)-\(systemIdentifier)-\(SummaryBridgeRatePolicy.cacheVersion)")
    }

    func summaryBridgeAssetID(itemId: String, proposalId: String, sceneId: String, suppliedAssetId: String? = nil) -> String {
        summaryBridgeAssetID(itemId: itemId, proposalId: proposalId, sceneId: sceneId, suppliedAssetId: suppliedAssetId,
                             usesKitten: summaryBridgeUsesKitten)
    }

    /// `usesKitten` is read once by the caller, so an ID and the voice that renders under it can't disagree if the
    /// Supertonic download lands or is removed in between.
    private func summaryBridgeAssetID(itemId: String, proposalId: String, sceneId: String, suppliedAssetId: String?, usesKitten: Bool) -> String {
        Self.summaryBridgeAssetID(itemId: itemId, proposalId: proposalId, sceneId: sceneId, suppliedAssetId: suppliedAssetId,
                                  voiceKey: currentSummaryBridgeVoiceKey(usesKitten: usesKitten))
    }

    /// The asset ID of each scene's summary for one item, with the voice read once, so a pass can name a long map's
    /// summaries off the main thread (#2255).
    func summaryBridgeAssetIDs(itemId: String) -> @Sendable (_ proposalId: String, _ scene: PortableListeningMapScene) -> String {
        let voiceKey = currentSummaryBridgeVoiceKey(usesKitten: summaryBridgeUsesKitten)
        return { proposalId, scene in
            Gate1AppModel.summaryBridgeAssetID(itemId: itemId, proposalId: proposalId, sceneId: scene.id,
                                               suppliedAssetId: scene.summaryAssetId, voiceKey: voiceKey)
        }
    }

    private nonisolated static func summaryBridgeAssetID(
        itemId: String, proposalId: String, sceneId: String, suppliedAssetId: String?, voiceKey: String
    ) -> String {
        // An id the name cut would change carries a hash of the whole id, so two ids can't share a file (#1120).
        SummaryBridgeAssetNaming.assetID(
            itemId: itemId, proposalId: proposalId, sceneId: sceneId, suppliedAssetId: suppliedAssetId,
            generatedVoiceKey: suppliedAssetId == nil ? voiceKey : ""
        )
    }

    func prepareSummaryBridgeAsset(
        itemId: String,
        proposalId: String,
        scene: PortableListeningMapScene,
        store: SQLiteSessionStore
    ) async throws -> OwnedOfflineAsset? {
        guard let summary = scene.summaryText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else { return nil }
        let usesKitten = summaryBridgeUsesKitten
        let assetID = summaryBridgeAssetID(itemId: itemId, proposalId: proposalId, sceneId: scene.id,
                                           suppliedAssetId: scene.summaryAssetId, usesKitten: usesKitten)
        // A supplied voice imported before #1120 sits under the old cut name; it still counts as prepared.
        let legacyID = scene.summaryAssetId.flatMap {
            SummaryBridgeAssetNaming.legacyAssetID(itemId: itemId, proposalId: proposalId, sceneId: scene.id, suppliedAssetId: $0)
        }
        // The whole asset table, read off the main thread (#2255).
        let saved = try await Task.detached(priority: .userInitiated) { () throws -> OwnedOfflineAsset? in
            let assets = try store.loadOwnedOfflineAssets()
            for id in [assetID] + (legacyID.map { [$0] } ?? []) {
                if let found = assets.first(where: { $0.id == id && $0.integrity == .valid }) { return found }
            }
            return nil
        }.value
        if let existing = saved, resolvedApplicationSupportAssetURL(for: existing.relativePath) != nil { return existing }
        // An authored voice is part of the imported experience, not a request
        // to silently synthesize replacement speech in the current system voice.
        guard scene.summaryAssetId == nil else { return nil }
        let directory = try episodeMapDirectory(itemId: itemId)
            .appending(path: "SummaryBridges", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = try requireOfflineLedger(store: store, rootDirectory: try applicationSupportDirectory())
        let reservation = try await ledger.reserve(
            ownerId: "summary-bridge-\(assetID)",
            byteCount: 64 * 1_024 * 1_024
        )
        do {
            let sourceURL: URL
            if usesKitten {
                // The asset ID above was built from this same reading, so it names the voice that gets saved.
                guard let kitten = makeKittenRenderer() else { throw KittenNarrationError.missingAsset("Kitten") }
                sourceURL = try await kitten.render(text: summary).audioURL
            } else if let voice = ttsVoiceSelection.supertonicVoice {
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
                    // Off the main thread: the render waits on the speech synthesizer once per scene (#2100).
                    prepared = try await SystemTextAudioPreparationClient(
                        outputDirectory: directory,
                        voiceIdentifier: speechVoiceIdentifier,
                        speechRate: SummaryBridgeRatePolicy.systemSynthesisRate,
                        allowsSynchronousRendering: true
                    ).prepareTextAudioOffMainThread(itemId: assetID, title: title, text: summary)
                }
                guard let prepared, let value = prepared.media.url, let url = URL(string: value) else {
                    try? await ledger.release(reservationId: reservation.id)
                    return nil
                }
                sourceURL = url
            }
            let destination = directory.appending(path: "\(assetID).\(sourceURL.pathExtension.isEmpty ? "caf" : sourceURL.pathExtension)")
            // The copy of a rendered scene summary goes off the main actor (#2510); only its size comes back.
            let bytes: Int64 = try await Task.detached(priority: .userInitiated) {
                if sourceURL.standardizedFileURL != destination.standardizedFileURL {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: destination)
                }
                return (try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            }.value
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

    /// The file half of a purge: the exported audio chunks of the whole episode, then each folder in `directories`.
    /// It is a plain function so a caller picks the thread: the awaited purge below and the background removal both
    /// run it off the main thread (#2510).
    nonisolated static func removeEpisodeTranscriptionFiles(itemId: String, directories: [URL]) throws {
        try SourceTranscriptionCaches.purge(itemId: itemId)
        for directory in directories where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// For the callers that cannot wait: deletes a trashed item and the launch clean-up of old jobs. Each folder goes
    /// on its own, so one failure leaves the rest to be removed, as the `try?` calls before it did (#2510).
    nonisolated static func removeEpisodeTranscriptionFilesInBackground(itemId: String, directories: [URL]) {
        Task.detached(priority: .utility) {
            try? SourceTranscriptionCaches.purge(itemId: itemId)
            for directory in directories where FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// The transcript rows the run recorded for the item; the files they name are removed with the folders.
    func deleteTransientTranscriptAssets(itemId: String) throws {
        guard let store else { return }
        for asset in try store.loadOwnedOfflineAssets(itemId: itemId) where asset.category == .transientEpisodeTranscript {
            try store.deleteOwnedOfflineAsset(id: asset.id)
        }
    }

    /// Deletes the item's episode-map jobs on a background task, in line with the automatic queueing's saves (#2509).
    func deleteEpisodeMapPreparationJobsInBackground(itemId: String) {
        guard let store else { return }
        Task {
            _ = try? await StoreReader(store).readInOrder(AutomaticEpisodeMapJobs.orderKey) {
                EpisodeMapJobCleanup.deleteJobs(itemId: itemId, store: $0)
            }
        }
    }

    /// Launch clean-up of cancelled and week-old episode-map jobs. The job reads and deletes run on a background task,
    /// in line with the automatic queueing's saves (#2509); the files go first and the rows after, so a crash in
    /// between leaves a job to try again.
    func purgeExpiredEpisodeMapPreparationJobs(store: SQLiteSessionStore, now: Date = Date()) {
        Task { [weak self] in
            // Read, then confirm just before the files go, so a job asked for again meanwhile keeps its folder.
            let found = (try? await StoreReader(store).readInOrder(AutomaticEpisodeMapJobs.orderKey) {
                EpisodeMapJobCleanup.expiredJobs(now: now, store: $0)
            }) ?? []
            guard !found.isEmpty else { return }
            guard let self else { return }
            // `prepare` keeps a live job's old `requestedAt`, so the row can't show a re-request. The items being
            // prepared, or waiting on a download or transcript, are read here on the main actor and kept.
            let busy = self.busyEpisodeMapItemIds
            let expired = (try? await StoreReader(store).readInOrder(AutomaticEpisodeMapJobs.orderKey) {
                EpisodeMapJobCleanup.stillExpired(found, now: now, excluding: busy, store: $0)
            }) ?? []
            // Another hop passed; ask again, then remove the files in the same turn with no await in between.
            let busyNow = self.busyEpisodeMapItemIds
            let doomed = expired.filter { !busyNow.contains($0.itemId) }
            guard !doomed.isEmpty else { return }
            for job in doomed {
                // Without a saved map the whole folder goes; with one, only the transient folder (#2510: off the main thread).
                let directory = try? self.episodeMapDirectory(itemId: job.itemId)
                let target = job.hasMap ? directory?.appending(path: "Transient", directoryHint: .isDirectory) : directory
                Self.removeEpisodeTranscriptionFilesInBackground(itemId: job.itemId, directories: [target].compactMap { $0 })
            }
            _ = try? await StoreReader(store).readInOrder(AutomaticEpisodeMapJobs.orderKey) {
                EpisodeMapJobCleanup.deleteExpired(doomed, now: now, excluding: busyNow, store: $0)
            }
        }
    }

    /// Items whose episode map is being prepared, or is waiting on a download or a transcript.
    var busyEpisodeMapItemIds: Set<String> {
        Set([episodeMapPreparationItemId, pendingMapGenerationItemId].compactMap { $0 })
    }

    func purgeTransientEpisodeTranscriptionCaches(itemId: String) async throws {
        let transientDirectory = try episodeMapDirectory(itemId: itemId)
            .appending(path: "Transient", directoryHint: .isDirectory)
        try await Gate1AppModel.offMain {
            try Gate1AppModel.removeEpisodeTranscriptionFiles(itemId: itemId, directories: [transientDirectory])
        }
        try deleteTransientTranscriptAssets(itemId: itemId)
    }

    func purgeSourceTranscriptionAudioCaches(itemId: String) async throws {
        try await Gate1AppModel.offMain { try SourceTranscriptionCaches.purge(itemId: itemId) }
    }

    /// Queues an episode-map job for every downloaded episode that has none. The spine, summary and job reads and the
    /// job save run off the main actor, one row after another in line with any earlier call (#2509); only the check
    /// that a downloaded file is still there comes back, because the download coordinator answers it on the main actor.
    func submitAutomaticEpisodeMapPreparationIfNeeded() {
        guard automaticEpisodeMapPreparationPolicy == .whileCharging,
              let store else { return }
        let rowIds = libraryItems.map(\.id)
        Task { [weak self] in
            let candidates = (try? await StoreReader(store).read {
                AutomaticEpisodeMapJobs.candidates(itemIds: rowIds, store: $0)
            }) ?? []
            guard let self else { return }
            let downloaded = candidates.filter { self.podcastDownloadCoordinator?.validatedLocalURL(for: $0) != nil }
            // The listener may have turned the setting off while the reads ran.
            if !downloaded.isEmpty, self.automaticEpisodeMapPreparationPolicy == .whileCharging {
                _ = try? await StoreReader(store).readInOrder(AutomaticEpisodeMapJobs.orderKey) {
                    AutomaticEpisodeMapJobs.enqueue(itemIds: downloaded, policy: .whileCharging, store: $0)
                }
            }
            #if canImport(BackgroundTasks) && canImport(UIKit)
            self.scheduleAudioPreparationBackgroundTask()
            #endif
        }
    }
}

extension Gate1AppModel: EpisodeMapPreparerHost {
    func episodeMapPreparationStatusWillChange() {
        objectWillChange.send()
    }

    func recordEpisodeMapDiagnostic(_ key: String, _ value: String) {
        diagnostics[key] = value
    }

    func episodeMapDeviceConditions() -> SpeechEngineConditions {
        preparationSeams.deviceConditions()
    }

    func episodeMapTranscribed(itemId: String, timeline: TranscriptTimeline, store: SQLiteSessionStore) {
        CommunityMapUploadService.shared.episodeTranscribed(itemId: itemId, timeline: timeline, store: store, localAudio: { [weak self] in self?.importedPodcastRecipientLocalURLs[$0] ?? self?.podcastDownloadCoordinator?.validatedLocalURL(for: $0) }) { [weak self] in self?.diagnostics["communityMapUpload"] = $0 }
    }

    func episodeMapWarn(_ message: String) {
        reportWarning(message)
    }

    func episodeMapSucceeded(_ message: String) {
        reportSuccess(message)
    }

    func episodeMapFailedToStart(_ error: Error) {
        reportFailure(error, context: "Episode map preparation failed")
    }

    func episodeMapPreparationDidComplete(itemId: String, status: String) {
        if itemId == activeItemId {
            refreshSelectedItemInBackground()
            updateSkimAvailability()
            reportConfirmation(status)
        }
    }

    func episodeMapPreparationDidFail(itemId: String, error: Error) {
        if itemId == activeItemId { reportFailure(error, context: "Episode map preparation failed", itemId: itemId) }
    }
}
