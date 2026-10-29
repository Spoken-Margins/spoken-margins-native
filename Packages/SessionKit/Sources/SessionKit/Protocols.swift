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
    func listItems(includeDeleted: Bool) throws -> [Item]
    func loadListeningMap(itemId: String) throws -> ListeningMap?
    func saveListeningMap(_ map: ListeningMap) throws
}

/// A repository that can say, without reading the item, whether an item was saved or deleted
/// through it since the last time you asked. The number means nothing on its own: only a change
/// between two reads does. Callers that watch an item's fields (the listening-signal collector)
/// re-read the item only when it moves, instead of decoding its text on every playback tick.
/// A repository without it is simply read each time.
public protocol ItemRevisionReading: AnyObject {
    func itemRevision(id: String) -> Int
}

/// A repository that can count a session's active Margins and unfinished AI jobs without decoding them (#2509).
/// The engine publishes both counts on every playback tick (about twice a second); without this it decodes every
/// Margin and every job of the session each time. A repository without it is simply read each time.
public protocol SessionRecordCounting: AnyObject {
    func activeInterjectionCount(sessionId: String) throws -> Int
    func unfinishedAIJobCount(sessionId: String) throws -> Int
}

/// A repository that can read one Margin of a session by its id (#2509). A transcription or source-window result
/// updates one Margin; without this the engine decodes every Margin of the session, transcripts included, to find it.
public protocol InterjectionByIdReading: AnyObject {
    func loadInterjection(id: String, sessionId: String) throws -> Interjection?
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
    /// Keeps a stored `firstHeardAt` when `interjection` has none, so a copy loaded before
    /// the listener heard it can't make it new again (#469).
    func saveImportedCommentaryInterjection(_ interjection: ImportedCommentaryInterjection) throws
    /// Records the first time the listener heard this shared Margin's voice (#469). A later
    /// call keeps the first time. Returns the stored record, or nil when there is none.
    func markImportedCommentaryInterjectionHeard(id: String, at date: Date) throws -> ImportedCommentaryInterjection?
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
    /// A cheap fingerprint of the record `loadTranscriptTimeline(itemId:)` would return, without reading it (#1696):
    /// equal fingerprints mean the same record, unchanged. nil when there is none, or when the store can't tell,
    /// and then a reader has to read the timeline every time.
    func transcriptTimelineStamp(itemId: String) throws -> String?
    func saveAudioAsset(_ asset: AudioAsset) throws
    func loadAudioAssets(itemId: String) throws -> [AudioAsset]
    func deleteAudioAsset(id: String) throws
    func savePodcastDownload(_ record: PodcastDownloadRecord) throws
    func loadPodcastDownload(itemId: String) throws -> PodcastDownloadRecord?
    func loadPodcastDownloads() throws -> [PodcastDownloadRecord]
    func deletePodcastDownload(id: String) throws
}

extension MediaRepository {
    public func transcriptTimelineStamp(itemId: String) throws -> String? { nil }
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
    /// Removes every stored proposal of the item and the projection that points at one, so a map that replaces
    /// another is the only one left and nothing is left pointing at a proposal that is gone (#1471).
    func removePortableListeningMapProposals(itemId: String) throws
    func saveResolvedListeningMapProjection(_ projection: ResolvedListeningMapProjection) throws
    func loadResolvedListeningMapProjection(itemId: String) throws -> ResolvedListeningMapProjection?
    /// Removes a community map's proposal and projection (#553), found by their ids; nothing else.
    /// Called when the publisher's own chapters arrive, which a community map never outlives.
    func removeCommunityMap(itemId: String) throws
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
    /// Reads one row, applies `change` and saves it, with no other write in between (#287): a
    /// protection another caller saved after this caller's earlier read survives. Returns the saved
    /// row, or nil when there is no row with that id. `change` must not call the repository: it runs
    /// inside the store's transaction, which can't be nested.
    @discardableResult
    func updateOwnedOfflineAsset(id: String, _ change: (inout OwnedOfflineAsset) -> Void) throws -> OwnedOfflineAsset?
    /// Deletes the row only if `shouldDelete` accepts it as it is now, with no other write in between
    /// (#530): a protection saved after the caller's earlier read keeps the row. Returns whether a row
    /// was deleted. `shouldDelete` must not call the repository, for the same reason as `change` above;
    /// it may remove the row's file, so no reader sees the row gone while the file is still there.
    @discardableResult
    func deleteOwnedOfflineAsset(id: String, if shouldDelete: (OwnedOfflineAsset) -> Bool) throws -> Bool
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

/// I13 structured documents (C1 M3), stored beside their item as their own
/// record kind, one per extraction version, never inside `Item`. A build that
/// predates them never reads that kind, so it still opens the database (I13
/// rule 1c). Stores that don't adopt this simply keep no documents.
public protocol StructuredDocumentRepository {
    func saveStructuredDocument(_ document: StructuredDocument, itemId: String) throws
    /// The newest extraction version stored for the item, if any.
    func loadStructuredDocument(itemId: String) throws -> StructuredDocument?
    func loadSessions(itemId: String) throws -> [Session]
    /// Moves an item to a new extraction: its text, chapters, Margin anchors,
    /// session positions and document, all or nothing.
    func applyStructuredDocumentUpgrade(_ upgrade: StructuredDocumentUpgrade) throws
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
    /// A listener's explicit move to `charOffset` while speaking: unlike a repeated play or a
    /// restart, it must move even when it's close to the live position (#303).
    func play(targetId: String, seekingTo charOffset: Int) throws
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws
    func seek(toMediaTimeMs mediaTimeMs: Int) throws
    func requestMediaSeek(toMediaTimeMs mediaTimeMs: Int) throws -> MediaSeekRequest
    func mediaSeekResolution(for request: MediaSeekRequest) -> MediaSeekResolution
    func setPlaybackRate(_ rate: Double) throws
    /// The rate the player is actually using, read back from it rather than from what was asked for (#1670); nil
    /// when the client can't tell. A paused player reports the rate it will resume at.
    func currentPlayerRate() -> Double?
    func setMixesWithOtherAudio(_ enabled: Bool) throws
    /// Opt-in attenuation of other apps, effective only during mixed playback.
    func setLowersBackgroundAudio(_ enabled: Bool) throws
    func setPlaybackVolume(_ volume: Float) throws
    func currentPlaybackPosition() -> PlaybackPosition?
    func currentCharOffset() -> Int?
    func currentRecoveryCharOffset() -> Int?
    func currentMediaTimeMs() -> Int?
    func currentPlaybackDurationMs() -> Int?
    func isPlaybackComplete(targetId: String) -> Bool
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus
    /// True while a pending start is waiting for audio that is still being rendered, under the
    /// client's own deadline and fallback. The engine's start watchdog then keeps waiting (#235).
    func isAwaitingRenderedAudio(targetId: String) -> Bool
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
    func currentPlayerRate() -> Double? { nil }

    func configureMediaContext(_ context: PlaybackMediaContext?) throws {}

    func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {}

    func play(targetId: String, from charOffset: Int) throws {
        try play(targetId: targetId)
    }

    func play(targetId: String, seekingTo charOffset: Int) throws {
        try play(targetId: targetId, from: charOffset)
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

    func setMixesWithOtherAudio(_ enabled: Bool) throws {}

    func setLowersBackgroundAudio(_ enabled: Bool) throws {}

    func setPlaybackVolume(_ volume: Float) throws {}

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

    func isAwaitingRenderedAudio(targetId: String) -> Bool {
        false
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
    /// What the recorder has actually taken in so far, or nil when it can't tell (#937).
    func captureReading() -> RecordingCaptureReading?
    /// Starts a new recorder on a new file after one that never got audio. Throws when it can't.
    func restartCapture() throws
    /// Privacy-safe fields about the capture in progress (route, restarts, level), for the diagnostics log.
    func captureDiagnostics() -> [String: String]
    /// Where the file being recorded will be, named the way the saved Margin names it. Nil when nothing is recording
    /// or the recorder can't say. The draft journal keeps it so a kill before Save still points at the file (#951).
    func recordingInProgressRef() -> String?
    /// Evidence from the closed recording, retained through save retries; nil when unsupported.
    func finalizedRecordingIntegrity() -> FinalizedRecordingIntegrity?
    /// The ready cue (#1594) is about to play: stop taking audio in, so the cue is not in the saved file.
    func pauseForReadyCue()
    /// The cue has started, or did not play (0 seconds): listen again after `seconds`.
    func resumeAfterReadyCue(after seconds: TimeInterval)
    /// The last recording to end turned the audio session off, handing it back to other apps. Playing anything
    /// now would turn it on again and interrupt them, so the outcome cue (#1977) stays silent.
    func releasedAudioSessionAtEnd() -> Bool
}

extension RecordingClient {
    public func releasedAudioSessionAtEnd() -> Bool { false }
    public func recordingInProgressRef() -> String? { nil }
    public func finalizedRecordingIntegrity() -> FinalizedRecordingIntegrity? { nil }
    public func captureReading() -> RecordingCaptureReading? { nil }
    public func pauseForReadyCue() {}
    public func resumeAfterReadyCue(after seconds: TimeInterval) {}
    public func restartCapture() throws {
        throw SessionKitError.persistenceFailed("recording_restart_unsupported")
    }
    public func captureDiagnostics() -> [String: String] { [:] }
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

extension EpisodeMapRepository {
    /// Stores that never hold community maps have nothing to remove.
    public func removeCommunityMap(itemId: String) throws {}
}
