import Foundation

public class InMemorySessionRepository: SessionRepository, @unchecked Sendable {
    /// Any change to the items moves `itemRevision(id:)` for every item: tests change this directly.
    public var items: [String: Item] { didSet { itemWrites &+= 1 } }
    private var itemWrites = 0
    public var mapsByItemId: [String: ListeningMap]
    public var sessions: [String: Session]
    public var interjections: [String: Interjection]
    public private(set) var interjectionShareRevisions: [String: InterjectionShareRevision]
    public var importedCommentaryLayers: [String: ImportedCommentaryLayer]
    public var importedCommentaryInterjections: [String: ImportedCommentaryInterjection]
    public var turns: [String: ConversationTurn]
    public var aiJobs: [String: AIJob]
    public var watchPackages: [String: WatchAudioPackage]
    public var watchSyncEvents: [String: WatchSyncEvent]
    public var importedWatchSyncEventIds: Set<String>
    public var watchPackageRequests: [String: WatchPackageRequestEvent]
    public var transcriptTimelines: [String: SourceTranscriptTimeline]
    public var audioAssets: [String: AudioAsset]
    public var podcastDownloads: [String: PodcastDownloadRecord]
    public var canonicalSources: [String: CanonicalSourcePackage]
    public var preparedAudioManifests: [String: PreparedAudioManifest]
    public var audioPreparationJobs: [String: AudioPreparationJob]
    public var editionFingerprintSpines: [String: EditionFingerprintSpineArtifact]
    public var transcriptPhraseSketches: [String: TranscriptPhraseSketchArtifact]
    public var portableListeningMapProposals: [String: (itemId: String, proposal: PortableListeningMapProposalArtifact)]
    public var resolvedListeningMapProjections: [String: ResolvedListeningMapProjection]
    public var episodeMapPreparationJobs: [String: EpisodeMapPreparationJob]
    public var offlineStorageBudget: OfflineStorageBudget
    public var ownedOfflineAssets: [String: OwnedOfflineAsset]
    /// The ledger actor and the app's main actor both write these rows (#287).
    private let ownedOfflineAssetsLock = NSLock()
    public var offlineStorageReservations: [String: OfflineStorageReservation]
    public var feedSubscriptions: [String: FeedSubscription]
    public var feedEntries: [String: FeedEntry]
    public var feedRefreshStates: [String: FeedRefreshState]
    public var sourceSuggestionDecisions: [String: SourceSuggestionDecision]
    /// I13 documents by item id, then extraction version.
    public var structuredDocuments: [String: [Int: StructuredDocument]] = [:]
    public var sourceElements: [String: SourceElementsRecord] = [:]
    /// Publisher audio by item id (#545).
    public var publisherAudio: [String: PublisherAudio] = [:]
    public var communityMapUploads: [String: CommunityMapUploadRecord] = [:]

    public init(
        items: [String: Item] = [:],
        mapsByItemId: [String: ListeningMap] = [:],
        sessions: [String: Session] = [:],
        interjections: [String: Interjection] = [:],
        interjectionShareRevisions: [String: InterjectionShareRevision] = [:],
        importedCommentaryLayers: [String: ImportedCommentaryLayer] = [:],
        importedCommentaryInterjections: [String: ImportedCommentaryInterjection] = [:],
        turns: [String: ConversationTurn] = [:],
        aiJobs: [String: AIJob] = [:],
        watchPackages: [String: WatchAudioPackage] = [:],
        watchSyncEvents: [String: WatchSyncEvent] = [:],
        importedWatchSyncEventIds: Set<String> = [],
        watchPackageRequests: [String: WatchPackageRequestEvent] = [:],
        transcriptTimelines: [String: SourceTranscriptTimeline] = [:],
        audioAssets: [String: AudioAsset] = [:],
        podcastDownloads: [String: PodcastDownloadRecord] = [:],
        canonicalSources: [String: CanonicalSourcePackage] = [:],
        preparedAudioManifests: [String: PreparedAudioManifest] = [:],
        audioPreparationJobs: [String: AudioPreparationJob] = [:],
        editionFingerprintSpines: [String: EditionFingerprintSpineArtifact] = [:],
        transcriptPhraseSketches: [String: TranscriptPhraseSketchArtifact] = [:],
        portableListeningMapProposals: [String: (itemId: String, proposal: PortableListeningMapProposalArtifact)] = [:],
        resolvedListeningMapProjections: [String: ResolvedListeningMapProjection] = [:],
        episodeMapPreparationJobs: [String: EpisodeMapPreparationJob] = [:],
        offlineStorageBudget: OfflineStorageBudget = OfflineStorageBudget(),
        ownedOfflineAssets: [String: OwnedOfflineAsset] = [:],
        offlineStorageReservations: [String: OfflineStorageReservation] = [:],
        feedSubscriptions: [String: FeedSubscription] = [:],
        feedEntries: [String: FeedEntry] = [:],
        feedRefreshStates: [String: FeedRefreshState] = [:],
        sourceSuggestionDecisions: [String: SourceSuggestionDecision] = [:]
    ) {
        self.items = items
        self.mapsByItemId = mapsByItemId
        self.sessions = sessions
        self.interjections = interjections
        self.interjectionShareRevisions = interjectionShareRevisions
        self.importedCommentaryLayers = importedCommentaryLayers
        self.importedCommentaryInterjections = importedCommentaryInterjections
        self.turns = turns
        self.aiJobs = aiJobs
        self.watchPackages = watchPackages
        self.watchSyncEvents = watchSyncEvents
        self.importedWatchSyncEventIds = importedWatchSyncEventIds
        self.watchPackageRequests = watchPackageRequests
        self.transcriptTimelines = transcriptTimelines
        self.audioAssets = audioAssets
        self.podcastDownloads = podcastDownloads
        self.canonicalSources = canonicalSources
        self.preparedAudioManifests = preparedAudioManifests
        self.audioPreparationJobs = audioPreparationJobs
        self.editionFingerprintSpines = editionFingerprintSpines
        self.transcriptPhraseSketches = transcriptPhraseSketches
        self.portableListeningMapProposals = portableListeningMapProposals
        self.resolvedListeningMapProjections = resolvedListeningMapProjections
        self.episodeMapPreparationJobs = episodeMapPreparationJobs
        self.offlineStorageBudget = offlineStorageBudget
        self.ownedOfflineAssets = ownedOfflineAssets
        self.offlineStorageReservations = offlineStorageReservations
        self.feedSubscriptions = feedSubscriptions
        self.feedEntries = feedEntries
        self.feedRefreshStates = feedRefreshStates
        self.sourceSuggestionDecisions = sourceSuggestionDecisions
    }

    public func loadItem(id: String) throws -> Item {
        guard let item = items[id] else { throw SessionKitError.missingFixture(id) }
        return item
    }

    public func saveItem(_ item: Item) throws {
        items[item.id] = item
    }

    public func listItems(includeDeleted: Bool = false) throws -> [Item] {
        items.values.filter { includeDeleted || $0.deletedAt == nil }.sorted { $0.id < $1.id }
    }

    public func loadListeningMap(itemId: String) throws -> ListeningMap? {
        mapsByItemId[itemId]
    }

    public func saveListeningMap(_ map: ListeningMap) throws {
        mapsByItemId[map.itemId] = map
    }

    public func saveSession(_ session: Session) throws {
        sessions[session.id] = session
    }

    public func loadSession(id: String) throws -> Session? {
        sessions[id]
    }

    public func saveInterjection(_ interjection: Interjection) throws {
        interjections[interjection.id] = interjection
    }

    public func loadInterjections(sessionId: String) throws -> [Interjection] {
        interjections.values.filter { $0.sessionId == sessionId }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public func saveInterjectionShareRevision(_ revision: InterjectionShareRevision) throws {
        if let existing = interjectionShareRevisions[revision.id] {
            guard existing == revision else {
                throw SessionKitError.persistenceFailed("interjection_share_revision_immutable_conflict")
            }
            return
        }
        interjectionShareRevisions[revision.id] = revision
    }

    public func loadInterjectionShareRevisions(interjectionId: String) throws -> [InterjectionShareRevision] {
        interjectionShareRevisions.values
            .filter { $0.interjectionId == interjectionId }
            .sorted { lhs, rhs in
                lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
            }
    }

    public func importCommentaryLayer(
        _ layer: ImportedCommentaryLayer,
        interjections newInterjections: [ImportedCommentaryInterjection]
    ) throws -> ImportedCommentaryImportDisposition {
        if let existing = importedCommentaryLayers.values.first(where: { $0.packageDigest == layer.packageDigest }) {
            return .duplicate(existingLayerId: existing.id)
        }
        guard importedCommentaryLayers[layer.id] == nil,
              newInterjections.allSatisfy({ importedCommentaryInterjections[$0.id] == nil }) else {
            throw SessionKitError.persistenceFailed("imported_commentary_local_id_conflict")
        }
        importedCommentaryLayers[layer.id] = layer
        for interjection in newInterjections {
            importedCommentaryInterjections[interjection.id] = interjection
        }
        return .imported(layerId: layer.id, interjectionIds: newInterjections.map(\.id))
    }

    public func loadImportedCommentaryLayer(id: String) throws -> ImportedCommentaryLayer? {
        importedCommentaryLayers[id]
    }

    public func loadImportedCommentaryLayer(packageDigest: String) throws -> ImportedCommentaryLayer? {
        importedCommentaryLayers.values.first { $0.packageDigest == packageDigest }
    }

    public func loadImportedCommentaryLayers(itemId: String) throws -> [ImportedCommentaryLayer] {
        importedCommentaryLayers.values
            .filter { $0.itemId == itemId }
            .sorted { lhs, rhs in
                lhs.importedAt == rhs.importedAt ? lhs.id < rhs.id : lhs.importedAt < rhs.importedAt
            }
    }

    public func loadImportedCommentaryInterjections(layerId: String) throws -> [ImportedCommentaryInterjection] {
        importedCommentaryInterjections.values
            .filter { $0.layerId == layerId }
            .sorted { lhs, rhs in
                lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
            }
    }

    public func saveImportedCommentaryLayer(_ layer: ImportedCommentaryLayer) throws {
        importedCommentaryLayers[layer.id] = layer
    }

    public func saveImportedCommentaryInterjection(_ interjection: ImportedCommentaryInterjection) throws {
        var interjection = interjection
        // Once heard, a stale copy can't make it new again (#469).
        if interjection.firstHeardAt == nil { interjection.firstHeardAt = importedCommentaryInterjections[interjection.id]?.firstHeardAt }
        var aliases = importedCommentaryInterjections[interjection.id]?.alsoSharedAs ?? []
        for identity in interjection.alsoSharedAs ?? [] where !aliases.contains(identity) { aliases.append(identity) }
        interjection.alsoSharedAs = aliases.isEmpty ? nil : aliases
        importedCommentaryInterjections[interjection.id] = interjection
    }

    public func markImportedCommentaryInterjectionHeard(id: String, at date: Date) throws -> ImportedCommentaryInterjection? {
        guard var interjection = importedCommentaryInterjections[id] else { return nil }
        guard interjection.firstHeardAt == nil else { return interjection }
        interjection.firstHeardAt = date
        importedCommentaryInterjections[id] = interjection
        return interjection
    }

    public func saveTurn(_ turn: ConversationTurn) throws {
        turns[turn.id] = turn
    }

    public func loadTurns(sessionId: String) throws -> [ConversationTurn] {
        turns.values.filter { $0.sessionId == sessionId }.sorted { $0.id < $1.id }
    }

    public func saveAIJob(_ job: AIJob) throws {
        aiJobs[job.id] = job
    }

    public func loadAIJobs(sessionId: String) throws -> [AIJob] {
        aiJobs.values.filter { $0.sessionId == sessionId }.sorted { $0.id < $1.id }
    }

    public func updateAIJob(_ job: AIJob) throws {
        aiJobs[job.id] = job
    }

    public func saveWatchAudioPackage(_ package: WatchAudioPackage) throws {
        watchPackages[package.id] = package
    }

    public func loadWatchAudioPackage(id: String) throws -> WatchAudioPackage? {
        watchPackages[id]
    }

    public func loadWatchAudioPackages(itemId: String) throws -> [WatchAudioPackage] {
        watchPackages.values.filter { $0.itemId == itemId }.sorted { $0.createdAt < $1.createdAt }
    }

    public func saveWatchSyncEvent(_ event: WatchSyncEvent) throws {
        watchSyncEvents[event.id] = event
    }

    public func loadWatchSyncEvents(sessionId: String) throws -> [WatchSyncEvent] {
        watchSyncEvents.values.filter { $0.sessionId == sessionId }.sorted { $0.createdAt < $1.createdAt }
    }

    public func loadWatchSyncEvent(id: String) throws -> WatchSyncEvent? {
        watchSyncEvents[id]
    }

    public func markWatchSyncEventImported(id: String) throws {
        importedWatchSyncEventIds.insert(id)
    }

    public func hasImportedWatchSyncEvent(id: String) throws -> Bool {
        importedWatchSyncEventIds.contains(id)
    }

    public func saveWatchPackageRequest(_ request: WatchPackageRequestEvent) throws {
        watchPackageRequests[request.id] = request
    }

    public func loadWatchPackageRequests(itemId: String) throws -> [WatchPackageRequestEvent] {
        watchPackageRequests.values.filter { $0.itemId == itemId }.sorted { $0.createdAt < $1.createdAt }
    }

    public func saveTranscriptTimeline(_ transcript: SourceTranscriptTimeline) throws {
        transcriptTimelines[transcript.id] = transcript
    }

    public func loadTranscriptTimeline(id: String) throws -> SourceTranscriptTimeline? {
        transcriptTimelines[id]
    }

    /// No stamp: tests change `transcriptTimelines` in place, so every read here is a fresh one (#1696).
    /// A test of the engine's timeline cache overrides this.
    public func transcriptTimelineStamp(itemId: String) throws -> String? { nil }

    public func loadTranscriptTimeline(itemId: String) throws -> SourceTranscriptTimeline? {
        transcriptTimelines.values
            .filter { $0.itemId == itemId }
            .sorted { $0.createdAt < $1.createdAt }
            .last
    }

    public func saveAudioAsset(_ asset: AudioAsset) throws { audioAssets[asset.id] = asset }

    public func loadAudioAssets(itemId: String) throws -> [AudioAsset] {
        audioAssets.values.filter { $0.itemId == itemId }.sorted { $0.createdAt < $1.createdAt }
    }

    public func deleteAudioAsset(id: String) throws { audioAssets[id] = nil }

    public func savePodcastDownload(_ record: PodcastDownloadRecord) throws { podcastDownloads[record.id] = record }

    public func loadPodcastDownload(itemId: String) throws -> PodcastDownloadRecord? {
        podcastDownloads.values.first { $0.itemId == itemId }
    }

    public func loadPodcastDownloads() throws -> [PodcastDownloadRecord] {
        podcastDownloads.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func deletePodcastDownload(id: String) throws { podcastDownloads[id] = nil }

    public func saveCanonicalSource(_ source: CanonicalSourcePackage) throws { canonicalSources[source.itemId] = source }
    public func loadCanonicalSource(itemId: String) throws -> CanonicalSourcePackage? { canonicalSources[itemId] }

    public func publishImportedSource(item: Item, canonicalSource: CanonicalSourcePackage?, listeningMap: ListeningMap?, audioAsset: AudioAsset?, ownedAsset: OwnedOfflineAsset) throws {
        items[item.id] = item
        if let canonicalSource { canonicalSources[item.id] = canonicalSource }
        if let listeningMap { mapsByItemId[item.id] = listeningMap }
        if let audioAsset { audioAssets[audioAsset.id] = audioAsset }
        ownedOfflineAssetsLock.withLock { ownedOfflineAssets[ownedAsset.id] = ownedAsset }
    }

    public func savePreparedAudioManifest(_ manifest: PreparedAudioManifest) throws { preparedAudioManifests[manifest.id] = manifest; PreparedAudioChangeSignal.shared.bump() }
    public func loadPreparedAudioManifest(id: String) throws -> PreparedAudioManifest? { preparedAudioManifests[id] }
    public func loadPreparedAudioManifests(itemId: String) throws -> [PreparedAudioManifest] {
        preparedAudioManifests.values.filter { $0.itemId == itemId }.sorted { $0.updatedAt < $1.updatedAt }
    }
    public func deletePreparedAudioManifest(id: String) throws { preparedAudioManifests[id] = nil; PreparedAudioChangeSignal.shared.bump() }
    public func saveAudioPreparationJob(_ job: AudioPreparationJob) throws { audioPreparationJobs[job.id] = job }
    public func loadAudioPreparationJobs() throws -> [AudioPreparationJob] {
        audioPreparationJobs.values.sorted { $0.requestedAt < $1.requestedAt }
    }
    public func deleteAudioPreparationJob(id: String) throws { audioPreparationJobs[id] = nil }

    public func saveEditionFingerprintSpine(_ spine: EditionFingerprintSpineArtifact) throws {
        editionFingerprintSpines[spine.itemId] = spine
    }
    public func loadEditionFingerprintSpine(itemId: String) throws -> EditionFingerprintSpineArtifact? {
        editionFingerprintSpines[itemId]
    }
    public func saveTranscriptPhraseSketch(_ sketch: TranscriptPhraseSketchArtifact) throws {
        transcriptPhraseSketches[sketch.itemId] = sketch
    }
    public func loadTranscriptPhraseSketch(itemId: String) throws -> TranscriptPhraseSketchArtifact? {
        transcriptPhraseSketches[itemId]
    }
    public func savePortableListeningMapProposal(_ proposal: PortableListeningMapProposalArtifact, itemId: String) throws {
        portableListeningMapProposals = portableListeningMapProposals.filter {
            $0.value.itemId != itemId || !ListeningEditionMap.supersedes(proposal.id, $0.key)
        }
        portableListeningMapProposals[proposal.id] = (itemId, proposal)
    }
    public func removePortableListeningMapProposals(itemId: String) throws {
        portableListeningMapProposals = portableListeningMapProposals.filter { $0.value.itemId != itemId }
        resolvedListeningMapProjections[itemId] = nil
    }
    public func loadPortableListeningMapProposals(itemId: String) throws -> [PortableListeningMapProposalArtifact] {
        portableListeningMapProposals.values.filter { $0.itemId == itemId }.map(\.proposal).sorted { $0.createdAt < $1.createdAt }
    }
    public func saveResolvedListeningMapProjection(_ projection: ResolvedListeningMapProjection) throws {
        resolvedListeningMapProjections[projection.itemId] = projection
    }
    public func loadResolvedListeningMapProjection(itemId: String) throws -> ResolvedListeningMapProjection? {
        resolvedListeningMapProjections[itemId]
    }
    public func removeCommunityMap(itemId: String) throws {
        portableListeningMapProposals = portableListeningMapProposals.filter {
            !($0.value.itemId == itemId && CommunityMapConverter.isCommunityProposal(id: $0.key))
        }
        if let projection = resolvedListeningMapProjections[itemId], CommunityMapConverter.isCommunityProjection(projection) {
            resolvedListeningMapProjections[itemId] = nil
        }
    }
    public func saveEpisodeMapPreparationJob(_ job: EpisodeMapPreparationJob) throws {
        episodeMapPreparationJobs[job.id] = job
    }
    public func loadEpisodeMapPreparationJobs() throws -> [EpisodeMapPreparationJob] {
        episodeMapPreparationJobs.values.sorted { $0.requestedAt < $1.requestedAt }
    }
    public func deleteEpisodeMapPreparationJob(id: String) throws { episodeMapPreparationJobs[id] = nil }

    public func saveOfflineStorageBudget(_ budget: OfflineStorageBudget) throws { offlineStorageBudget = budget }
    public func loadOfflineStorageBudget() throws -> OfflineStorageBudget { offlineStorageBudget }
    public func saveOwnedOfflineAsset(_ asset: OwnedOfflineAsset) throws {
        ownedOfflineAssetsLock.withLock { ownedOfflineAssets[asset.id] = asset }
    }
    public func loadOwnedOfflineAssets() throws -> [OwnedOfflineAsset] {
        ownedOfflineAssetsLock.withLock { ownedOfflineAssets.values.sorted { $0.id < $1.id } }
    }
    public func deleteOwnedOfflineAsset(id: String) throws {
        ownedOfflineAssetsLock.withLock { ownedOfflineAssets[id] = nil }
    }
    @discardableResult
    public func updateOwnedOfflineAsset(id: String, _ change: (inout OwnedOfflineAsset) -> Void) throws -> OwnedOfflineAsset? {
        ownedOfflineAssetsLock.withLock {
            guard var asset = ownedOfflineAssets[id] else { return nil }
            change(&asset)
            ownedOfflineAssets[id] = asset
            return asset
        }
    }
    @discardableResult
    public func deleteOwnedOfflineAsset(id: String, if shouldDelete: (OwnedOfflineAsset) -> Bool) throws -> Bool {
        ownedOfflineAssetsLock.withLock {
            guard let asset = ownedOfflineAssets[id], shouldDelete(asset) else { return false }
            ownedOfflineAssets[id] = nil
            return true
        }
    }
    public func saveOfflineStorageReservation(_ reservation: OfflineStorageReservation) throws { offlineStorageReservations[reservation.id] = reservation }
    public func loadOfflineStorageReservations() throws -> [OfflineStorageReservation] { offlineStorageReservations.values.sorted { $0.id < $1.id } }
    public func deleteOfflineStorageReservation(id: String) throws { offlineStorageReservations[id] = nil }

    public func saveFeedSubscription(_ subscription: FeedSubscription) throws { feedSubscriptions[subscription.id] = subscription }
    public func loadFeedSubscriptions() throws -> [FeedSubscription] { feedSubscriptions.values.sorted { $0.id < $1.id } }
    public func deleteFeedSubscription(id: String) throws {
        feedSubscriptions[id] = nil
        feedEntries = feedEntries.filter { $0.value.subscriptionId != id || $0.value.state == .imported }
    }
    public func saveFeedEntry(_ entry: FeedEntry) throws { feedEntries[entry.id] = entry }
    public func loadFeedEntries(subscriptionId: String?) throws -> [FeedEntry] {
        feedEntries.values.filter { subscriptionId == nil || $0.subscriptionId == subscriptionId }.sorted { $0.id < $1.id }
    }
    public func deleteFeedEntry(id: String) throws { feedEntries[id] = nil }
    public func saveFeedRefreshState(_ state: FeedRefreshState) throws { feedRefreshStates[state.subscriptionId] = state }
    public func loadFeedRefreshState(subscriptionId: String) throws -> FeedRefreshState? { feedRefreshStates[subscriptionId] }
    public func saveSourceSuggestionDecision(_ decision: SourceSuggestionDecision) throws { sourceSuggestionDecisions[decision.sourceId] = decision }
    public func loadSourceSuggestionDecision(sourceId: String) throws -> SourceSuggestionDecision? { sourceSuggestionDecisions[sourceId] }
}

extension InMemorySessionRepository: SourceElementsRepository {
    public func saveSourceElements(_ record: SourceElementsRecord, itemId: String) throws {
        sourceElements[itemId] = record
    }

    public func loadSourceElements(itemId: String) throws -> SourceElementsRecord? {
        sourceElements[itemId]
    }
}

extension InMemorySessionRepository: StructuredDocumentRepository {
    public func saveStructuredDocument(_ document: StructuredDocument, itemId: String) throws {
        structuredDocuments[itemId, default: [:]][document.extraction.version] = document
    }

    public func loadStructuredDocument(itemId: String) throws -> StructuredDocument? {
        structuredDocuments[itemId]?.max { $0.key < $1.key }?.value
    }

    public func loadSessions(itemId: String) throws -> [Session] {
        sessions.values.filter { $0.itemId == itemId }.sorted { $0.id < $1.id }
    }

    public func applyStructuredDocumentUpgrade(_ upgrade: StructuredDocumentUpgrade) throws {
        try StructuredDocumentUpgrader.requireUnchangedSincePlanned(upgrade, repository: self)
        items[upgrade.item.id] = upgrade.item
        mapsByItemId[upgrade.item.id] = upgrade.listeningMap
        upgrade.interjections.forEach { interjections[$0.id] = $0 }
        upgrade.sessions.forEach { sessions[$0.id] = $0 }
        for manifest in try loadPreparedAudioManifests(itemId: upgrade.item.id) { try deletePreparedAudioManifest(id: manifest.id) }
        for job in try loadAudioPreparationJobs() where job.itemId == upgrade.item.id { try deleteAudioPreparationJob(id: job.id) }
        try saveStructuredDocument(upgrade.document, itemId: upgrade.item.id)
    }
}

extension InMemorySessionRepository: CommunityMapUploadRepository {
    public func saveCommunityMapUpload(_ record: CommunityMapUploadRecord) throws { communityMapUploads[record.id] = record }
    public func loadCommunityMapUpload(episodeKey: String) throws -> CommunityMapUploadRecord? { communityMapUploads[episodeKey] }
    public func loadCommunityMapUploads() throws -> [CommunityMapUploadRecord] { Array(communityMapUploads.values) }
}

extension InMemorySessionRepository: PublisherAudioRepository {
    public func savePublisherAudio(_ audio: PublisherAudio) throws { publisherAudio[audio.itemId] = audio }
    public func loadPublisherAudio(itemId: String) throws -> PublisherAudio? { publisherAudio[itemId] }
}

extension InMemorySessionRepository: SessionRecordCounting {
    public func activeInterjectionCount(sessionId: String) throws -> Int {
        interjections.values.filter { $0.sessionId == sessionId && $0.status == "active" }.count
    }

    public func unfinishedAIJobCount(sessionId: String) throws -> Int {
        aiJobs.values.filter { $0.sessionId == sessionId && $0.status != "complete" }.count
    }
}

extension InMemorySessionRepository: ItemRevisionReading {
    public func itemRevision(id: String) -> Int { itemWrites }
}
