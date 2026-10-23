import Foundation
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitSharing
import SessionKitPersistence

/// Places a shared podcast Margin on the recipient's own copy of the episode, and decides when a transcript of that
/// copy may be made to help (#1015). The model used to hold this state as loose collections beside its code; this type
/// owns it, and the model passes in the few things the work needs from it.
///
/// Three kinds of state, each with one owner:
/// - Matching generations stay in SessionKit's `PodcastPlacementPassCoordinator` (`matching`): which pass is current.
/// - `admission` is the one slot for transcribing an item's audio on behalf of placement. A transient alignment
///   transcript and the model's full-source transcription take turns in it, and `lastTransientStart` is the cooldown
///   only the first kind obeys. Nothing else that transcribes (publisher narration, episode maps) goes through it.
/// - `passes` is what the Margin rows read to say "placing". It is display only and says nothing about what may run.
///
/// Matching and transcription can overlap, so this is deliberately not one idle/scheduled/transcribing/done state.
@MainActor
final class ImportedPodcastPlacementCoordinator {
    /// What the coordinator needs from the model that owns it. Every closure is `@MainActor`, and the off-main matching
    /// operation reaches them only inside `MainActor.run`. The model builds them with a weak reference to itself.
    struct Dependencies {
        /// The model's current store. Initial invalidation uses the store taken at request; publication asks again.
        var store: @MainActor () -> SQLiteSessionStore?
        /// The clock behind the transient transcript's 60 second cooldown.
        var now: @MainActor () -> Date = { Date() }
        /// The transcriber the transient and full-source passes use.
        var transcriber: any SourceTranscriptionClient
        /// True when placement must wait because the session keeps another edition (#914). Writes the deferral itself.
        var deferPlacement: @MainActor (Item, URL) -> Bool
        /// A request that failed its preflight forgets any earlier deferral for the item.
        var clearDeferredPlacement: @MainActor (String) -> Void
        var localAudiobookDigest: @MainActor (Item) -> String?
        var applicationSupportDirectory: @MainActor () -> URL?
        var listenerHasListeningMap: @MainActor (String, SQLiteSessionStore) throws -> Bool
        var purgeTransientCaches: @MainActor (String) throws -> Void
        var prepareSummaryBridgeAsset: @MainActor (String, String, PortableListeningMapScene, SQLiteSessionStore) async -> Void
        var updateSkimAvailability: @MainActor () -> Void
        /// After the placements were invalidated for a new file: refresh the selected item if it shows `itemId`, and the rows.
        var refreshAfterInvalidation: @MainActor (String) -> Void
        var refreshSelectedItemIfShowing: @MainActor (String) -> Void
        var recordDiagnostic: @MainActor (String, String) -> Void
        /// Called synchronously, with the old and the new value, every time `passes` changes.
        var passesDidChange: @MainActor (SharedMarginPlacementPasses, SharedMarginPlacementPasses) -> Void
        /// A strong reference to the model, taken by a transcription that has to keep the model alive until it finishes.
        var retainHost: @MainActor () -> AnyObject?
    }

    /// What `resolve` did with a request. A rejected preflight and an evaluated empty piece of work are different:
    /// the first leaves any running pass and the Margins' display alone, the second cancels them.
    enum ResolveOutcome: Equatable {
        /// No store, unreadable file, missing item, no loaded layers: only the item's earlier deferral was cleared.
        case rejected
        /// The session keeps its own edition; placement waits for it.
        case deferred
        /// The item has layers, but none with podcast work to place: the running pass was cancelled and its display ended.
        case noPodcastWork
        /// A pass runs for this file and layers. `joined` means an identical one was already running and was kept.
        case scheduled(joined: Bool)
    }

    /// Who holds the item's transcription slot. A missing key is idle.
    enum Admission: Equatable {
        case fullSource
        /// Carries the file as it was admitted, so a transcript of a file that was since replaced is discarded.
        case transient(PodcastPlacementFile)
    }

    /// The transient transcript may start again this long after the last one started.
    static let transientCooldown = ImportedPodcastPlacementPolicy.transientCooldown

    let matching = PodcastPlacementPassCoordinator()
    private(set) var requestedURL: [String: URL] = [:]
    private(set) var admission: [String: Admission] = [:]
    private(set) var lastTransientStart: [String: Date] = [:]
    /// Placement work in flight, so its shared Margins read "placing", not "unresolved" (#872).
    private(set) var passes = SharedMarginPlacementPasses() {
        didSet { deps.passesDidChange(oldValue, passes) }
    }

    private let deps: Dependencies

    init(dependencies: Dependencies) {
        deps = dependencies
    }

    // MARK: Transcription slot

    /// Takes the slot for a full-source transcription. No cooldown, no display. False when anything holds the slot.
    func beginFullSourceTranscription(itemId: String) -> Bool {
        guard admission[itemId] == nil else { return false }
        admission[itemId] = .fullSource
        return true
    }

    /// Frees the slot. The caller does this before it attaches the transcript or reports the failure, so work started
    /// by those callbacks finds the slot free.
    func releaseFullSourceTranscription(itemId: String) {
        admission[itemId] = nil
    }

    /// Transcribes the listener's copy once, for a stronger placement pass, and deletes the transcript afterwards.
    /// Admitted only for a readable file, outside the cooldown (measured from the last attempt's start), with the slot free.
    /// A refused request changes nothing, including the cooldown clock.
    @discardableResult
    func scheduleTransientTranscript(for item: Item, localSourceURL: URL) -> Bool {
        guard let sourceFile = try? PodcastPlacementFile(url: localSourceURL) else { return false }
        let now = deps.now()
        guard ImportedPodcastPlacementPolicy.transientTranscriptMayStart(
            lastStart: lastTransientStart[item.id], now: now, slotIsFree: admission[item.id] == nil) else { return false }
        admission[item.id] = .transient(sourceFile)
        lastTransientStart[item.id] = now
        deps.recordDiagnostic("recipientAlignmentTranscript:\(item.id)", "transcribing_transiently")
        passes.begin(.transcript, itemId: item.id)
        Task { [weak self] in
            guard let self else { return }
            // The model stays alive until the transcript is in, as it did when this task belonged to the model.
            let host = self.deps.retainHost()
            defer {
                self.passes.end(.transcript, itemId: item.id)
                withExtendedLifetime(host) {}
            }
            do {
                let timeline = try await self.deps.transcriber.transcribeSourceAudio(
                    url: localSourceURL,
                    itemId: item.id,
                    durationMs: item.media?.durationMs
                )
                MainThreadOperationLabels.shared.scoped("transientTranscriptResolve") {
                    self.admission[item.id] = nil
                    if self.requestedURL[item.id] == localSourceURL,
                       (try? PodcastPlacementFile(url: localSourceURL)) == sourceFile {
                        self.resolve(itemId: item.id, localURL: localSourceURL, recipientTranscriptOverride: timeline)
                    }
                    try? self.deps.purgeTransientCaches(item.id)
                    self.deps.recordDiagnostic("recipientAlignmentTranscript:\(item.id)", "consumed_and_deleted")
                }
            } catch {
                MainThreadOperationLabels.shared.scoped("transientTranscriptResolve") {
                    self.admission[item.id] = nil
                    try? self.deps.purgeTransientCaches(item.id)
                    self.deps.recordDiagnostic(
                        "recipientAlignmentTranscript:\(item.id)", "failed_and_deleted:\(error.localizedDescription)")
                }
            }
        }
        return true
    }

    // MARK: Placement

    @discardableResult
    func resolve(
        itemId: String,
        localURL: URL,
        recipientTranscriptOverride: TranscriptTimeline? = nil
    ) -> ResolveOutcome {
        guard let store = deps.store(),
              let file = try? PodcastPlacementFile(url: localURL),
              let item = try? store.loadItem(id: itemId),
              let layers = try? store.loadImportedCommentaryLayers(itemId: itemId),
              !layers.isEmpty else { deps.clearDeferredPlacement(itemId); return .rejected }
        guard !deps.deferPlacement(item, localURL) else { return .deferred }
        requestedURL[itemId] = localURL
        let localItem = SharedPacketItemMatcher.localIdentity(for: item, ownedAudiobookDigest: deps.localAudiobookDigest(item))
        // Persisted transcripts have no byte-edition binding. Only this pass's
        // transient transcript is evidence for the supplied recipient file.
        let work = ImportedPodcastPlacement.podcastLayerRecords(layers: layers) { layer in
            try? store.loadImportedCommentaryInterjections(layerId: layer.id)
        }
        guard !work.isEmpty else { matching.cancel(itemId: itemId); passes.end(.matching, itemId: itemId); return .noPodcastWork }
        if recipientTranscriptOverride == nil, commentaryNeedsTranscript(itemId: itemId, store: store) {
            scheduleTransientTranscript(for: item, localSourceURL: localURL)
        }
        let applicationSupportDirectory = deps.applicationSupportDirectory()
        let submission = matching.schedule(.init(itemId: itemId, file: file,
            layers: work.map { .init(layer: $0.0, records: $0.1) }, transcript: recipientTranscriptOverride)) { [weak self] context in
            let recipientTranscript = context.request.transcript
            do {
                try Task.checkCancellation()
                let recipientDigest = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: localURL)
                let isCurrent = try await MainActor.run { [weak self] in
                    guard !Task.isCancelled, let self, self.matching.isCurrent(context) else { return false }
                    try store.invalidateImportedPodcastPlacements(itemId: itemId, editionSHA256: recipientDigest)
                    self.deps.refreshAfterInvalidation(itemId)
                    return true
                }
                guard isCurrent else { return }
                var resolvedWork: [(ImportedCommentaryLayer, [ImportedCommentaryInterjection], SharedListeningMapPlacement.Outcome?)] = []
                for (var layer, records) in work {
                    try Task.checkCancellation()
                    let queries = records.map { record in
                        let evidence = (record.podcastAnchorEvidence ?? []).compactMap { asset -> PodcastAcousticEvidenceQuery? in
                            guard let assetURL = Gate1AppModel.resolvedApplicationSupportAssetURL(
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
                                Gate1AppModel.resolvedApplicationSupportAssetURL(for: $0, applicationSupportDirectory: applicationSupportDirectory)
                            }.flatMap { try? Data(contentsOf: $0) } },
                            recipientAudioURL: localURL, recipientEditionSHA256: recipientDigest,
                            itemId: itemId, projectionId: SharedListeningMapPlacement.projectionId(layerId: layer.id),
                            strongSourceIdentity: ImportedItemResolver.canRepresentSameWork(layer.itemIdentity, localItem)
                        )
                    }
                    resolvedWork.append((layer, updated, mapOutcome))
                }
                await MainActor.run {
                    guard !Task.isCancelled, let self, self.matching.isCurrent(context) else { return }
                    defer { self.passes.end(.matching, itemId: itemId) }
                    guard let store = self.deps.store() else { return }
                    do {
                        let livingWork = try resolvedWork.filter { try store.isLiveImportedCommentaryLayer(id: $0.0.id) } // #915
                        let outcomes = livingWork.sorted { $0.0.importedAt < $1.0.importedAt }.compactMap(\.2)
                        let current = try store.loadResolvedListeningMapProjection(itemId: itemId)
                        let activation = SharedListeningMapPlacement.activation(
                            outcomes, listenerHasMap: try self.deps.listenerHasListeningMap(itemId, store),
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
                                // Independent of the pass once published: not fenced by a generation, not cancelled.
                                Task { @MainActor [weak self] in
                                    guard let self else { return }
                                    let host = self.deps.retainHost()
                                    defer { withExtendedLifetime(host) {} }
                                    for scene in proposal.scenes where
                                        scene.eligibility == .eligible && scene.summaryText?.isEmpty == false {
                                        await self.deps.prepareSummaryBridgeAsset(itemId, projection.id, scene, store)
                                    }
                                    self.deps.updateSkimAvailability()
                                }
                            }
                        }
                        self.deps.refreshSelectedItemIfShowing(itemId)
                        let resolvedCount = livingWork.filter { $0.0.sourceResolutionStatus == .resolved }.count
                        self.deps.recordDiagnostic("importedPodcastAnchorResolution:\(itemId)", "complete:\(resolvedCount)/\(livingWork.count) \(SharedMarginPlacementSummary(livingWork.map { ($0.0, $0.1) }).diagnosticValue)")
                        if recipientTranscript == nil, self.commentaryNeedsTranscript(itemId: itemId, store: store) {
                            self.scheduleTransientTranscript(for: item, localSourceURL: localURL)
                        }
                    } catch {
                        self.deps.recordDiagnostic("importedPodcastAnchorResolution:\(itemId)", "persistence_failed:\(error.localizedDescription)")
                    }
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled, self?.matching.isCurrent(context) == true else { return }
                    self?.passes.end(.matching, itemId: itemId)
                    self?.deps.recordDiagnostic("importedPodcastAnchorResolution:\(itemId)", "failed:\(error.localizedDescription)")
                }
            }
        }
        if !submission.joined {
            deps.recordDiagnostic("importedPodcastAnchorResolution:\(itemId)", "scheduled:\(work.count)")
            // Only a request that starts a pass records "placing"; a joined one could set it after its pass ended it.
            passes.begin(.matching, itemId: itemId, previous: Dictionary(work.flatMap(\.1).map { ($0.id, $0.resolution) }, uniquingKeysWith: { first, _ in first }))
        }
        return .scheduled(joined: submission.joined)
    }

    func commentaryNeedsTranscript(itemId: String, store: SQLiteSessionStore) -> Bool {
        guard let layers = try? store.loadImportedCommentaryLayers(itemId: itemId) else { return false }
        return ImportedPodcastPlacementPolicy.commentaryNeedsTranscript(
            layers: layers,
            loadRecords: { try? store.loadImportedCommentaryInterjections(layerId: $0.id) },
            recordNeedsTranscript: ImportedPodcastPlacement.recordNeedsTranscript)
    }
}
