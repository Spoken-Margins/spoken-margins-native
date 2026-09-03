import Foundation

public struct PostResumeAudioSampleRequest: Equatable, Sendable {
    public let interjectionId: String
    public let sessionId: String
    public let itemId: String
    public let anchorMediaTimeMs: Int
    public let targetDurationMs: Int
    public let captureDelayMs: Int

    public init(
        interjectionId: String,
        sessionId: String,
        itemId: String,
        anchorMediaTimeMs: Int,
        targetDurationMs: Int,
        captureDelayMs: Int = 0
    ) {
        self.interjectionId = interjectionId
        self.sessionId = sessionId
        self.itemId = itemId
        self.anchorMediaTimeMs = anchorMediaTimeMs
        self.targetDurationMs = targetDurationMs
        self.captureDelayMs = max(0, captureDelayMs)
    }
}

public protocol ItemRepository {
    func loadItem(id: String) throws -> Item
    func saveItem(_ item: Item) throws
    func loadListeningMap(itemId: String) throws -> ListeningMap?
    func saveListeningMap(_ map: ListeningMap) throws
}

public protocol ListeningSessionRepository {
    func saveSession(_ session: Session) throws
    func loadSession(id: String) throws -> Session?
    func saveInterjection(_ interjection: Interjection) throws
    func loadInterjections(sessionId: String) throws -> [Interjection]
    func saveInterjectionShareRevision(_ revision: InterjectionShareRevision) throws
    func loadInterjectionShareRevisions(interjectionId: String) throws -> [InterjectionShareRevision]
    func importCommentaryLayer(
        _ layer: ImportedCommentaryLayer,
        interjections: [ImportedCommentaryInterjection]
    ) throws -> ImportedCommentaryImportDisposition
    func loadImportedCommentaryLayer(id: String) throws -> ImportedCommentaryLayer?
    func loadImportedCommentaryLayer(packageDigest: String) throws -> ImportedCommentaryLayer?
    func loadImportedCommentaryLayers(itemId: String) throws -> [ImportedCommentaryLayer]
    func loadImportedCommentaryInterjections(layerId: String) throws -> [ImportedCommentaryInterjection]
    func saveImportedCommentaryLayer(_ layer: ImportedCommentaryLayer) throws
    func saveImportedCommentaryInterjection(_ interjection: ImportedCommentaryInterjection) throws
    func saveTurn(_ turn: ConversationTurn) throws
    func loadTurns(sessionId: String) throws -> [ConversationTurn]
    func saveAIJob(_ job: AIJob) throws
    func loadAIJobs(sessionId: String) throws -> [AIJob]
    func updateAIJob(_ job: AIJob) throws
}

public protocol WatchRepository {
    func saveWatchAudioPackage(_ package: WatchAudioPackage) throws
    func loadWatchAudioPackage(id: String) throws -> WatchAudioPackage?
    func loadWatchAudioPackages(itemId: String) throws -> [WatchAudioPackage]
    func saveWatchSyncEvent(_ event: WatchSyncEvent) throws
    func loadWatchSyncEvents(sessionId: String) throws -> [WatchSyncEvent]
    func loadWatchSyncEvent(id: String) throws -> WatchSyncEvent?
    func markWatchSyncEventImported(id: String) throws
    func hasImportedWatchSyncEvent(id: String) throws -> Bool
    func saveWatchPackageRequest(_ request: WatchPackageRequestEvent) throws
    func loadWatchPackageRequests(itemId: String) throws -> [WatchPackageRequestEvent]
}

public protocol MediaRepository {
    func saveTranscriptTimeline(_ transcript: SourceTranscriptTimeline) throws
    func loadTranscriptTimeline(id: String) throws -> SourceTranscriptTimeline?
    func loadTranscriptTimeline(itemId: String) throws -> SourceTranscriptTimeline?
    func saveAudioAsset(_ asset: AudioAsset) throws
    func loadAudioAssets(itemId: String) throws -> [AudioAsset]
    func deleteAudioAsset(id: String) throws
    func savePodcastDownload(_ record: PodcastDownloadRecord) throws
    func loadPodcastDownload(itemId: String) throws -> PodcastDownloadRecord?
    func loadPodcastDownloads() throws -> [PodcastDownloadRecord]
    func deletePodcastDownload(id: String) throws
}

public protocol CanonicalSourceRepository {
    func saveCanonicalSource(_ source: CanonicalSourcePackage) throws
    func loadCanonicalSource(itemId: String) throws -> CanonicalSourcePackage?
}

public protocol LocalImportRepository {
    func publishImportedSource(item: Item, canonicalSource: CanonicalSourcePackage?, listeningMap: ListeningMap?, audioAsset: AudioAsset?, ownedAsset: OwnedOfflineAsset) throws
}

public protocol PreparedAudioRepository {
    func savePreparedAudioManifest(_ manifest: PreparedAudioManifest) throws
    func loadPreparedAudioManifest(id: String) throws -> PreparedAudioManifest?
    func loadPreparedAudioManifests(itemId: String) throws -> [PreparedAudioManifest]
    func deletePreparedAudioManifest(id: String) throws
    func saveAudioPreparationJob(_ job: AudioPreparationJob) throws
    func loadAudioPreparationJobs() throws -> [AudioPreparationJob]
    func deleteAudioPreparationJob(id: String) throws
}

public protocol EpisodeMapRepository {
    func saveEditionFingerprintSpine(_ spine: EditionFingerprintSpineArtifact) throws
    func loadEditionFingerprintSpine(itemId: String) throws -> EditionFingerprintSpineArtifact?
    func saveTranscriptPhraseSketch(_ sketch: TranscriptPhraseSketchArtifact) throws
    func loadTranscriptPhraseSketch(itemId: String) throws -> TranscriptPhraseSketchArtifact?
    func savePortableListeningMapProposal(_ proposal: PortableListeningMapProposalArtifact, itemId: String) throws
    func loadPortableListeningMapProposals(itemId: String) throws -> [PortableListeningMapProposalArtifact]
    func saveResolvedListeningMapProjection(_ projection: ResolvedListeningMapProjection) throws
    func loadResolvedListeningMapProjection(itemId: String) throws -> ResolvedListeningMapProjection?
    func saveEpisodeMapPreparationJob(_ job: EpisodeMapPreparationJob) throws
    func loadEpisodeMapPreparationJobs() throws -> [EpisodeMapPreparationJob]
    func deleteEpisodeMapPreparationJob(id: String) throws
}

public protocol OfflineStorageRepository {
    func saveOfflineStorageBudget(_ budget: OfflineStorageBudget) throws
    func loadOfflineStorageBudget() throws -> OfflineStorageBudget
    func saveOwnedOfflineAsset(_ asset: OwnedOfflineAsset) throws
    func loadOwnedOfflineAssets() throws -> [OwnedOfflineAsset]
    func deleteOwnedOfflineAsset(id: String) throws
    func saveOfflineStorageReservation(_ reservation: OfflineStorageReservation) throws
    func loadOfflineStorageReservations() throws -> [OfflineStorageReservation]
    func deleteOfflineStorageReservation(id: String) throws
}

public protocol FollowedSourceRepository {
    func saveFeedSubscription(_ subscription: FeedSubscription) throws
    func loadFeedSubscriptions() throws -> [FeedSubscription]
    func deleteFeedSubscription(id: String) throws
    func saveFeedEntry(_ entry: FeedEntry) throws
    func loadFeedEntries(subscriptionId: String?) throws -> [FeedEntry]
    func deleteFeedEntry(id: String) throws
    func saveFeedRefreshState(_ state: FeedRefreshState) throws
    func loadFeedRefreshState(subscriptionId: String) throws -> FeedRefreshState?
    func saveSourceSuggestionDecision(_ decision: SourceSuggestionDecision) throws
    func loadSourceSuggestionDecision(sourceId: String) throws -> SourceSuggestionDecision?
}

public protocol SessionRepository: AnyObject, Sendable,
    ItemRepository,
    ListeningSessionRepository,
    WatchRepository,
    MediaRepository,
    CanonicalSourceRepository,
    LocalImportRepository,
    PreparedAudioRepository,
    EpisodeMapRepository,
    OfflineStorageRepository,
    FollowedSourceRepository {}

public protocol AudioPlaybackClient {
    func configureMediaContext(_ context: PlaybackMediaContext?) throws
    func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws
    func prepareSpeechText(_ text: String) throws -> String
    func play(targetId: String) throws
    func play(targetId: String, from charOffset: Int) throws
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws
    func seek(toMediaTimeMs mediaTimeMs: Int) throws
    func requestMediaSeek(toMediaTimeMs mediaTimeMs: Int) throws -> MediaSeekRequest
    func mediaSeekResolution(for request: MediaSeekRequest) -> MediaSeekResolution
    func setPlaybackRate(_ rate: Double) throws
    func currentPlaybackPosition() -> PlaybackPosition?
    func currentCharOffset() -> Int?
    func currentRecoveryCharOffset() -> Int?
    func currentMediaTimeMs() -> Int?
    func currentPlaybackDurationMs() -> Int?
    func isPlaybackComplete(targetId: String) -> Bool
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus
    func playbackTransportState(targetId: String) -> PlaybackTransportState?
    func setRemoteCommandHandlingEnabled(_ enabled: Bool)
    @discardableResult
    func armPostResumeAudioSample(_ request: PostResumeAudioSampleRequest) -> Bool
    @discardableResult
    func captureBufferedPreInterjectionAudioSample(_ request: PostResumeAudioSampleRequest) -> Bool
    func pause() throws
    func stop() throws
}

public protocol LinkResolutionClient {
    func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult
}

public protocol SourceTranscriptionClient: Sendable {
    func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline
    func transcribeSourceAudioWindow(
        url: URL,
        itemId: String,
        anchorMediaTimeMs: Int,
        durationMs: Int?,
        windowBeforeMs: Int,
        windowAfterMs: Int
    ) async throws -> TranscriptTimeline
    func transcribeSourceAudioWindowWithEvidence(
        url: URL,
        itemId: String,
        anchorMediaTimeMs: Int,
        durationMs: Int?,
        windowBeforeMs: Int,
        windowAfterMs: Int
    ) async throws -> SourceAudioWindowTranscription
}

public struct SourceAudioWindowTranscription: Sendable {
    public let timeline: TranscriptTimeline
    public let localAudioURL: URL?
    public let sourceStartMs: Int
    public let sourceEndMs: Int
    public let provenance: EpisodeFingerprintProvenance

    public init(
        timeline: TranscriptTimeline,
        localAudioURL: URL?,
        sourceStartMs: Int,
        sourceEndMs: Int,
        provenance: EpisodeFingerprintProvenance
    ) {
        self.timeline = timeline
        self.localAudioURL = localAudioURL
        self.sourceStartMs = max(0, sourceStartMs)
        self.sourceEndMs = max(sourceStartMs, sourceEndMs)
        self.provenance = provenance
    }
}

public extension SourceTranscriptionClient {
    func transcribeSourceAudioWindow(
        url: URL,
        itemId: String,
        anchorMediaTimeMs: Int,
        durationMs: Int?,
        windowBeforeMs: Int = 60_000,
        windowAfterMs: Int = 60_000
    ) async throws -> TranscriptTimeline {
        throw SessionKitError.persistenceFailed("source_audio_window_transcription_unavailable")
    }

    func transcribeSourceAudioWindowWithEvidence(
        url: URL,
        itemId: String,
        anchorMediaTimeMs: Int,
        durationMs: Int?,
        windowBeforeMs: Int = 60_000,
        windowAfterMs: Int = 60_000
    ) async throws -> SourceAudioWindowTranscription {
        let timeline = try await transcribeSourceAudioWindow(
            url: url,
            itemId: itemId,
            anchorMediaTimeMs: anchorMediaTimeMs,
            durationMs: durationMs,
            windowBeforeMs: windowBeforeMs,
            windowAfterMs: windowAfterMs
        )
        return SourceAudioWindowTranscription(
            timeline: timeline,
            localAudioURL: nil,
            sourceStartMs: max(0, anchorMediaTimeMs - windowBeforeMs),
            sourceEndMs: anchorMediaTimeMs + windowAfterMs,
            provenance: .sourceWindowReference
        )
    }
}

public protocol TextAudioPreparationClient: Sendable {
    func prepareTextAudio(itemId: String, title: String, text: String) throws -> PreparedTextAudio?
}

public extension AudioPlaybackClient {
    func configureMediaContext(_ context: PlaybackMediaContext?) throws {}

    func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {}

    func play(targetId: String, from charOffset: Int) throws {
        try play(targetId: targetId)
    }

    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        try play(targetId: targetId, from: mediaTimeMs)
    }

    func seek(toMediaTimeMs mediaTimeMs: Int) throws {}

    func requestMediaSeek(toMediaTimeMs mediaTimeMs: Int) throws -> MediaSeekRequest {
        let targetId = currentPlaybackPosition()?.targetId
        try seek(toMediaTimeMs: mediaTimeMs)
        return MediaSeekRequest(id: 0, targetId: targetId, requestedMediaTimeMs: mediaTimeMs)
    }

    func mediaSeekResolution(for request: MediaSeekRequest) -> MediaSeekResolution {
        .accepted(mediaTimeMs: currentMediaTimeMs() ?? request.requestedMediaTimeMs)
    }

    func setPlaybackRate(_ rate: Double) throws {}

    @discardableResult
    func armPostResumeAudioSample(_ request: PostResumeAudioSampleRequest) -> Bool {
        false
    }

    @discardableResult
    func captureBufferedPreInterjectionAudioSample(_ request: PostResumeAudioSampleRequest) -> Bool {
        false
    }

    func stop() throws {
        try pause()
    }

    func currentCharOffset() -> Int? {
        currentPlaybackPosition()?.textStart
    }

    /// A conservative source offset that is safe to use after the active audio
    /// asset is lost. Rendered speech may return the beginning of the current
    /// chunk here while exposing a more precise interpolated presentation offset
    /// through `currentCharOffset()`.
    func currentRecoveryCharOffset() -> Int? {
        currentCharOffset()
    }

    func currentMediaTimeMs() -> Int? {
        currentPlaybackPosition()?.mediaTimeMs
    }

    func currentPlaybackDurationMs() -> Int? {
        currentPlaybackPosition()?.durationMs
    }

    func currentPlaybackPosition() -> PlaybackPosition? {
        nil
    }

    func isPlaybackComplete(targetId: String) -> Bool {
        false
    }

    func playbackStartStatus(targetId: String) -> PlaybackStartStatus {
        .confirmed
    }

    func playbackTransportState(targetId: String) -> PlaybackTransportState? {
        nil
    }

    func setRemoteCommandHandlingEnabled(_ enabled: Bool) {}
}

public protocol RecordingClient {
    func beginRecording() throws
    func finishRecording(audioRef: String?) throws -> String
    func cancelRecording() throws
}

public protocol TranscriptionClient {
    func scheduleTranscription(interjection: Interjection) throws
}

public protocol AIProviderClient {
    var providerType: String { get }
    var model: String { get }
    func shouldStartProviderCall(profile: RuntimeCapabilityProfile, kind: String) -> Bool
}

public extension AIProviderClient {
    func shouldStartProviderCall(profile: RuntimeCapabilityProfile, kind: String) -> Bool {
        switch kind {
        case "interjection_summary":
            return profile.has("ai", "summarize_interjections")
        case "assistant_response":
            return profile.has("ai", "continue_discussion")
        default:
            return false
        }
    }
}
