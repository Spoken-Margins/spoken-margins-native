import Foundation

public final class InMemorySessionRepository: SessionRepository, @unchecked Sendable {
    public var items: [String: Item]
    public var mapsByItemId: [String: ListeningMap]
    public var sessions: [String: Session]
    public var interjections: [String: Interjection]
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
    public var offlineStorageBudget: OfflineStorageBudget
    public var ownedOfflineAssets: [String: OwnedOfflineAsset]
    public var offlineStorageReservations: [String: OfflineStorageReservation]
    public var feedSubscriptions: [String: FeedSubscription]
    public var feedEntries: [String: FeedEntry]
    public var feedRefreshStates: [String: FeedRefreshState]
    public var sourceSuggestionDecisions: [String: SourceSuggestionDecision]

    public init(
        items: [String: Item] = [:],
        mapsByItemId: [String: ListeningMap] = [:],
        sessions: [String: Session] = [:],
        interjections: [String: Interjection] = [:],
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
        interjections.values.filter { $0.sessionId == sessionId }.sorted { $0.createdAt < $1.createdAt }
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

    public func publishImportedSource(item: Item, canonicalSource: CanonicalSourcePackage?, audioAsset: AudioAsset?, ownedAsset: OwnedOfflineAsset) throws {
        items[item.id] = item
        if let canonicalSource { canonicalSources[item.id] = canonicalSource }
        if let audioAsset { audioAssets[audioAsset.id] = audioAsset }
        ownedOfflineAssets[ownedAsset.id] = ownedAsset
    }

    public func savePreparedAudioManifest(_ manifest: PreparedAudioManifest) throws { preparedAudioManifests[manifest.id] = manifest }
    public func loadPreparedAudioManifest(id: String) throws -> PreparedAudioManifest? { preparedAudioManifests[id] }
    public func loadPreparedAudioManifests(itemId: String) throws -> [PreparedAudioManifest] {
        preparedAudioManifests.values.filter { $0.itemId == itemId }.sorted { $0.updatedAt < $1.updatedAt }
    }
    public func deletePreparedAudioManifest(id: String) throws { preparedAudioManifests[id] = nil }
    public func saveAudioPreparationJob(_ job: AudioPreparationJob) throws { audioPreparationJobs[job.id] = job }
    public func loadAudioPreparationJobs() throws -> [AudioPreparationJob] {
        audioPreparationJobs.values.sorted { $0.requestedAt < $1.requestedAt }
    }
    public func deleteAudioPreparationJob(id: String) throws { audioPreparationJobs[id] = nil }

    public func saveOfflineStorageBudget(_ budget: OfflineStorageBudget) throws { offlineStorageBudget = budget }
    public func loadOfflineStorageBudget() throws -> OfflineStorageBudget { offlineStorageBudget }
    public func saveOwnedOfflineAsset(_ asset: OwnedOfflineAsset) throws { ownedOfflineAssets[asset.id] = asset }
    public func loadOwnedOfflineAssets() throws -> [OwnedOfflineAsset] { ownedOfflineAssets.values.sorted { $0.id < $1.id } }
    public func deleteOwnedOfflineAsset(id: String) throws { ownedOfflineAssets[id] = nil }
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
