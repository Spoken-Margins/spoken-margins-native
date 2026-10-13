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

/// Private episode map preparation and summary bridge assets (#1016), moved unchanged out of the central model.
extension Gate1AppModel {
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
                    let ledger = try self.requireOfflineLedger(store: store, rootDirectory: try self.applicationSupportDirectory())
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
                    try FileManager.default.createDirectory(at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let ledger = self.requireOfflineLedger(store: store, rootDirectory: supportDirectory)
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
                CommunityMapUploadService.shared.episodeTranscribed(itemId: item.id, timeline: timeline, store: store, localAudio: { [weak self] in self?.importedPodcastRecipientLocalURLs[$0] ?? self?.podcastDownloadCoordinator?.validatedLocalURL(for: $0) }) { [weak self] in self?.diagnostics["communityMapUpload"] = $0 }

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
        let ledger = try requireOfflineLedger(store: store, rootDirectory: try applicationSupportDirectory())
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
        try SourceTranscriptionCaches.purge(itemId: itemId)
    }

    func submitAutomaticEpisodeMapPreparationIfNeeded() {
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
}
