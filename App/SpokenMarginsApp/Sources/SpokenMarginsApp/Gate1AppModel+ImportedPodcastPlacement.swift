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

/// Places a shared podcast Margin on the recipient's own copy of the episode (#1012), moved unchanged out of the central model.
extension Gate1AppModel {
    func scheduleTransientRecipientAlignmentTranscript(for item: Item, localSourceURL: URL) {
        guard let sourceFile = try? PodcastPlacementFile(url: localSourceURL),
              importedTranscriptRetryDates[item.id].map({ Date().timeIntervalSince($0) >= 60 }) ?? true,
              pendingFullSourceTranscriptionItemIds.insert(item.id).inserted else { return }
        importedTranscriptRetryDates[item.id] = Date()
        diagnostics["recipientAlignmentTranscript:\(item.id)"] = "transcribing_transiently"
        sharedMarginPlacementPasses.begin(.transcript, itemId: item.id)
        Task { [weak self] in
            guard let self else { return }
            defer { self.sharedMarginPlacementPasses.end(.transcript, itemId: item.id) }
            do {
                let timeline = try await self.sourceTranscriptionClient.transcribeSourceAudio(
                    url: localSourceURL,
                    itemId: item.id,
                    durationMs: item.media?.durationMs
                )
                self.pendingFullSourceTranscriptionItemIds.remove(item.id)
                if self.importedPodcastResolutionURLs[item.id] == localSourceURL,
                   (try? PodcastPlacementFile(url: localSourceURL)) == sourceFile {
                    self.resolveImportedPodcastCommentary(
                        itemId: item.id, localURL: localSourceURL, recipientTranscriptOverride: timeline)
                }
                try? self.purgeTransientEpisodeTranscriptionCaches(itemId: item.id)
                self.diagnostics["recipientAlignmentTranscript:\(item.id)"] = "consumed_and_deleted"
            } catch {
                self.pendingFullSourceTranscriptionItemIds.remove(item.id)
                try? self.purgeTransientEpisodeTranscriptionCaches(itemId: item.id)
                self.diagnostics["recipientAlignmentTranscript:\(item.id)"] = "failed_and_deleted:\(error.localizedDescription)"
            }
        }
    }

    func resolveImportedPodcastCommentary(
        itemId: String,
        localURL: URL,
        recipientTranscriptOverride: TranscriptTimeline? = nil
    ) {
        guard let store,
              let file = try? PodcastPlacementFile(url: localURL),
              let item = try? store.loadItem(id: itemId),
              let layers = try? store.loadImportedCommentaryLayers(itemId: itemId),
              !layers.isEmpty else { deferredPodcastPlacementURLs[itemId] = nil; return }
        guard !deferPlacementWhileSessionKeepsItsEdition(item: item, localURL: localURL) else { return }
        importedPodcastResolutionURLs[itemId] = localURL
        let localItem = SharedPacketItemMatcher.localIdentity(for: item, ownedAudiobookDigest: localAudiobookDigest(for: item))
        // Persisted transcripts have no byte-edition binding. Only this pass's
        // transient transcript is evidence for the supplied recipient file.
        let work = ImportedPodcastPlacement.podcastLayerRecords(layers: layers) { layer in
            try? store.loadImportedCommentaryInterjections(layerId: layer.id)
        }
        guard !work.isEmpty else { podcastPlacementPassCoordinator.cancel(itemId: itemId); sharedMarginPlacementPasses.end(.matching, itemId: itemId); return }
        if recipientTranscriptOverride == nil, importedPodcastCommentaryNeedsTranscript(itemId: itemId, store: store) {
            scheduleTransientRecipientAlignmentTranscript(for: item, localSourceURL: localURL)
        }
        let applicationSupportDirectory = try? applicationSupportDirectory()
        let submission = podcastPlacementPassCoordinator.schedule(.init(itemId: itemId, file: file,
            layers: work.map { .init(layer: $0.0, records: $0.1) }, transcript: recipientTranscriptOverride)) { [weak self] context in
            let recipientTranscript = context.request.transcript
            do {
                try Task.checkCancellation()
                let recipientDigest = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: localURL)
                let isCurrent = try await MainActor.run { [weak self] in
                    guard !Task.isCancelled, let self, self.podcastPlacementPassCoordinator.isCurrent(context) else { return false }
                    try store.invalidateImportedPodcastPlacements(itemId: itemId, editionSHA256: recipientDigest)
                    if self.selectedItem.id == itemId { self.refreshSelectedItem() }; self.refreshMarginRows()
                    return true
                }
                guard isCurrent else { return }
                var resolvedWork: [(ImportedCommentaryLayer, [ImportedCommentaryInterjection], SharedListeningMapPlacement.Outcome?)] = []
                for (var layer, records) in work {
                    try Task.checkCancellation()
                    let queries = records.map { record in
                        let evidence = (record.podcastAnchorEvidence ?? []).compactMap { asset -> PodcastAcousticEvidenceQuery? in
                            guard let assetURL = Self.resolvedApplicationSupportAssetURL(
                                for: asset.localPath,
                                applicationSupportDirectory: applicationSupportDirectory
                            ), let data = try? Data(contentsOf: assetURL) else { return nil }
                            return PodcastAcousticEvidenceQuery(
                                id: asset.id,
                                signatureData: data,
                                anchorOffsetMs: asset.anchorOffsetMs
                            )
                        }
                        return PodcastPortableAnchorQuery(
                            packageScopedId: record.packageScopedId,
                            senderMediaTimeMs: record.anchorEvidence.mediaTimeMs,
                            evidence: evidence,
                            evidenceWasDeclared: !record.anchorEvidence.machineEvidenceAssetIds.isEmpty
                        )
                    }
                    let resolutions = (try? await PodcastAcousticAnchorResolver.resolve(
                        queries: queries,
                        recipientAudioURL: localURL,
                        senderExactEditionSHA256: layer.itemIdentity.exactEditionSHA256,
                        senderDurationMs: layer.itemIdentity.durationMs,
                        strongSourceIdentity: ImportedItemResolver.canRepresentSameWork(
                            layer.itemIdentity,
                            localItem
                        )
                    )) ?? [:]
                    try Task.checkCancellation()
                    let fusedResolutions = ImportedPodcastPlacement.fuse(
                        queries: queries, records: records, acoustic: resolutions,
                        recipientTranscript: recipientTranscript)
                    let updated = ImportedPodcastPlacement.apply(
                        fusedResolutions, to: records, layer: &layer,
                        recipientDigest: recipientDigest, hasTranscript: recipientTranscript != nil)
                    var mapOutcome: SharedListeningMapPlacement.Outcome?
                    if layer.listeningMapProposals?.first != nil, layer.editionFingerprintSpines?.first == nil {
                        mapOutcome = .notPlaced(.init(sceneId: nil, sceneLabel: nil, reason: .noEvidence))
                    } else if let spine = layer.editionFingerprintSpines?.first, let proposal = layer.listeningMapProposals?.first {
                        let evidencePaths = layer.episodeMapEvidencePaths ?? [:]
                        mapOutcome = try await SharedListeningMapResolver.resolve(
                            proposal: proposal, spine: spine,
                            signatureData: { id in evidencePaths[id].flatMap {
                                Self.resolvedApplicationSupportAssetURL(for: $0, applicationSupportDirectory: applicationSupportDirectory)
                            }.flatMap { try? Data(contentsOf: $0) } },
                            recipientAudioURL: localURL, recipientEditionSHA256: recipientDigest,
                            itemId: itemId, projectionId: SharedListeningMapPlacement.projectionId(layerId: layer.id),
                            strongSourceIdentity: ImportedItemResolver.canRepresentSameWork(layer.itemIdentity, localItem)
                        )
                    }
                    resolvedWork.append((layer, updated, mapOutcome))
                }
                await MainActor.run {
                    guard !Task.isCancelled, let self, self.podcastPlacementPassCoordinator.isCurrent(context) else { return }
                    defer { self.sharedMarginPlacementPasses.end(.matching, itemId: itemId) }
                    guard let store = self.store else { return }
                    do {
                        let livingWork = try resolvedWork.filter { try store.isLiveImportedCommentaryLayer(id: $0.0.id) } // #915
                        let outcomes = livingWork.sorted { $0.0.importedAt < $1.0.importedAt }.compactMap(\.2)
                        let current = try store.loadResolvedListeningMapProjection(itemId: itemId)
                        let activation = SharedListeningMapPlacement.activation(
                            outcomes, listenerHasMap: try Self.listenerHasListeningMap(itemId: itemId, store: store),
                            activeProjectionId: current?.id)
                        for (var layer, records, outcome) in livingWork {
                            layer.sharedMapRefusalReason = activation.refusal == nil ? nil : outcome?.refusal?.listenerReason
                            try store.savePlacementResult(of: layer, records: records)
                        }
                        let sharedProposals = Dictionary(livingWork.compactMap { work in
                            work.0.listeningMapProposals?.first.map { (SharedListeningMapPlacement.projectionId(layerId: work.0.id), $0) }
                        }, uniquingKeysWith: { first, _ in first })
                        if activation.refusal != nil, let stale = current, sharedProposals[stale.id] != nil {
                            try store.saveResolvedListeningMapProjection(ResolvedListeningMapProjection(
                                id: stale.id, itemId: itemId, proposalId: stale.proposalId,
                                recipientEditionSHA256: stale.recipientEditionSHA256, points: [], intervals: []))
                        }
                        if let projection = activation.projection {
                            try store.saveResolvedListeningMapProjection(projection)
                            if let proposal = sharedProposals[projection.id] {
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    for scene in proposal.scenes where
                                        scene.eligibility == .eligible && scene.summaryText?.isEmpty == false {
                                        _ = try? await self.prepareSummaryBridgeAsset(
                                            itemId: itemId,
                                            proposalId: projection.id,
                                            scene: scene,
                                            store: store
                                        )
                                    }
                                    self.updateSkimAvailability()
                                }
                            }
                        }
                        if self.selectedItem.id == itemId { self.refreshSelectedItem() }
                        let resolvedCount = livingWork.filter { $0.0.sourceResolutionStatus == .resolved }.count
                        self.diagnostics["importedPodcastAnchorResolution:\(itemId)"] = "complete:\(resolvedCount)/\(livingWork.count) \(SharedMarginPlacementSummary(livingWork.map { ($0.0, $0.1) }).diagnosticValue)"
                        if recipientTranscript == nil, self.importedPodcastCommentaryNeedsTranscript(itemId: itemId, store: store) {
                            self.scheduleTransientRecipientAlignmentTranscript(for: item, localSourceURL: localURL)
                        }
                    } catch {
                        self.diagnostics["importedPodcastAnchorResolution:\(itemId)"] = "persistence_failed:\(error.localizedDescription)"
                    }
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled, self?.podcastPlacementPassCoordinator.isCurrent(context) == true else { return }
                    self?.sharedMarginPlacementPasses.end(.matching, itemId: itemId)
                    self?.diagnostics["importedPodcastAnchorResolution:\(itemId)"] = "failed:\(error.localizedDescription)"
                }
            }
        }
        if !submission.joined {
            diagnostics["importedPodcastAnchorResolution:\(itemId)"] = "scheduled:\(work.count)"
            // Only a request that starts a pass records "placing"; a joined one could set it after its pass ended it.
            sharedMarginPlacementPasses.begin(.matching, itemId: itemId, previous: Dictionary(work.flatMap(\.1).map { ($0.id, $0.resolution) }, uniquingKeysWith: { first, _ in first }))
        }
    }

    func importedPodcastCommentaryNeedsTranscript(
        itemId: String,
        store: SQLiteSessionStore
    ) -> Bool {
        guard let layers = try? store.loadImportedCommentaryLayers(itemId: itemId) else { return false }
        return ImportedPodcastPlacement.podcastLayerRecords(layers: layers) { layer in
            try? store.loadImportedCommentaryInterjections(layerId: layer.id)
        }.contains { $0.1.contains(where: ImportedPodcastPlacement.recordNeedsTranscript) }
    }
}
