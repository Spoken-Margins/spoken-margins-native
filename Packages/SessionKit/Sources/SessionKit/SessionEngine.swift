#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public final class SessionEngine {
    private static let textAnchorShoulderSentenceCount = 4
    private static let mediaClockBackwardToleranceMs = 2_000
    private static let storedDurationTruncationMs = 999
    public private(set) var profile: RuntimeCapabilityProfile
    public private(set) var snapshot = SessionSnapshot()
    public private(set) var currentSession: Session? {
        // A coalesced progress tick (#2509) leaves the newest place only in memory. Whatever replaces the session,
        // the place is written first.
        didSet {
            guard let unsaved = unsavedProgressSessionId, let old = oldValue, old.id == unsaved,
                  currentSession?.id != unsaved else { return }
            try? persistSession(old)
        }
    }
    public private(set) var currentItem: Item? {
        // An article that plays its publisher's recording is always the playing copy in memory, however
        // the item was loaded (#547).
        didSet {
            if let item = currentItem, let plan = publisherPlayback[item.id], item.media != plan.playingMedia {
                currentItem = plan.playing(item)
            }
        }
    }
    public private(set) var currentMap: ListeningMap?
    public private(set) var lastExport: SessionExport?
    public private(set) var lastSummaryCandidates: [Interjection] = []
    public private(set) var lastSpokenText: String?
    public private(set) var lastScheduledTranscriptionInterjectionId: String?
    public private(set) var currentWatchPackage: WatchAudioPackage?
    public private(set) var lastResolvedMediaAnchor: MediaResolvedAnchor?
    public private(set) var lastQueuedWatchSyncEvent: WatchSyncEvent?
    public private(set) var lastImportedWatchSyncEvent: WatchSyncEvent?
    public private(set) var lastLinkResolutionResult: LinkResolutionResult?
    public private(set) var pendingWatchEventCount = 0
    public private(set) var lastMediaSeekRequest: MediaSeekRequest?
    public private(set) var lastMediaSeekResolution: MediaSeekResolution?

    private let repository: SessionRepository
    /// Articles playing their publisher's recording right now, by item id (#547). The Library keeps
    /// the plain article; the engine plays a copy whose audio is the recording.
    private var publisherPlayback: [String: PublisherAudioPlayback] = [:]
    /// Recordings that failed to play, by item id: the address and when. The article keeps its on-device
    /// voice for a while instead of waiting out the same failure at every start, and tries again after
    /// `publisherAudioRetryInterval` (the network may be back) or when the record names another recording.
    private var publisherAudioUnavailable: [String: (audioURL: String, failedAt: Date)] = [:]
    private static let publisherAudioRetryInterval: TimeInterval = 10 * 60
    private let audio: AudioPlaybackClient
    private let recorder: RecordingClient
    private var marginCaptureTiming: MarginCaptureTiming?
    private let transcriber: TranscriptionClient
    private let aiProvider: AIProviderClient
    private let linkResolver: LinkResolutionClient
    private let textAudio: TextAudioPreparationClient?
    /// However long rendered audio takes, a start ends by then (#235).
    private var startAttempt: PlaybackStartAttempt
    private let now: () -> Date
    /// Set when a listener's start command arrives; the next published start carries it (#357).
    private var playbackRequestedAt: Date?
    private(set) var recordingAnchor: Anchor?
    /// The words just before the place the recording being made is anchored to, for the recording screen's cue (#1491).
    public var recordingContextBefore: String? { recordingAnchor?.anchorBefore }
    private var recordingTargetType: InterjectionTargetType?
    /// The shared Margin the recording being made answers, carried from the begin request to the saved Margin (#473).
    private var recordingReplyTo: MarginReplyLink?
    /// The file the recorder closed for a Margin that isn't saved yet. The recorder forgets it once finished and
    /// Save passes no path, so a Save that failed once could never be tried again (#911).
    private var closedRecordingRef: String?
    /// Where unsaved recordings are noted so a launch after a kill can find them (#951). Nil keeps no notes.
    public var recordingDraftJournal: RecordingDraftJournal?
    /// Why the last note could not be written or removed. A failed note never stops a recording.
    public private(set) var recordingDraftFailure: String?
    private var activeRecordingDraft: RecordingDraft?
    /// A Margin that is stored but whose finishing steps (evidence capture, transcription, rejoining the source) did
    /// not all run. The next Save picks up from here instead of asking the recorder for a recording it already
    /// gave up, so the recording screen can't get stuck behind a Margin that is saved (#1121).
    private var storedMarginFinish: StoredMarginFinish?
    private struct StoredMarginFinish {
        var interjection: Interjection
        var capturesPostResumeEvidence: Bool
        var evidenceHandled = false
        var transcriptionScheduled = false
    }
    private var recordingTargetId: String?
    /// Whether the source resumes after a Margin capture, and in which phase, is `MarginCaptureResume`'s to say (#3144).
    /// It holds the playing podcast that Add a Margin paused on the tap (#1696), the phase the recording began in,
    /// whether the source had finished (#142) and whether the step back over the saved Margin ran (#776).
    private var captureResume = MarginCaptureResume()
    /// The newest decoded transcript timeline of the item being played and the stamp of the stored record it was
    /// read from (#1696). A long episode's timeline is several MB of JSON, and the progress tick, `publish` and
    /// Add a Margin each read it a handful of times; decoding it every time kept the main actor busy.
    private var transcriptTimelineCache: (itemId: String, stamp: String, timeline: TranscriptTimeline)?
    private var streamingBuffers: [String: String] = [:]
    private var spokenPrefixes: [String: Int] = [:]
    private var externallyStreamedTurnId: String?
    private var playbackStartRecoveryAttemptId: Int?
    private var playbackURLOverrides: [String: String] = [:]
    private var pinnedMediaTransport: (sessionId: String, targetId: String, playbackURL: String?)?
    private var lastMediaPercentageRepair: (sessionId: String, durationMs: Int)?
    /// Margins whose transcript the listener deleted since transcription was last asked for. Work that was already
    /// running when they deleted it must not write the words back (#942); a new request (Retry) clears the entry.
    private var transcriptsDeletedSinceRequest: Set<String> = []
    /// How the last saved Margin chose where its source resumes (#806), for diagnostics.
    private var lastMarginRejoin: String?
    /// Where the system paused a podcast or recording, until it is resumed or the listener moves it (#1975).
    private var interruptionResumePoint = InterruptionResumePoint()
    /// Where the last Back tap in text landed, so the next one can tell it is a repeat (#1102). Only listening on
    /// from there keeps it: every other change of position calls `forgetBackTapLanding()` (#1122).
    private var lastBackTapLanding: (targetKey: String, charOffset: Int)?
    private var protectedPosition = ProtectedResumePosition()
    private var pendingWrittenInterjection: WrittenInterjectionCapture?

    private struct PlaybackPlan {
        var text: String
        var audioOffset: Int
    }

    /// The I14 projection of the current item's I13 document, cached by item.
    private var listenableCache: (itemId: String, textLength: Int, projection: NormalizedSpeechText?)?
    /// The structured document a paper's Margin pages come from (#206), cached by item, so
    /// the notes-folder gatherer decodes it once per paper rather than once per Margin.
    private var exportPageDocumentCache: (itemId: String, text: String?, document: StructuredDocument?)?

    /// Test seam (#1452): runs on the main actor once a re-imported PDF's off-main upgrade plan is back and before
    /// the "is the listener in this item?" check, so a test can open the item at exactly the point the check
    /// guards, with no dependence on how the scheduler orders main-actor tasks. Nil in the app.
    var afterStructuredUpgradePlannedForTesting: (() throws -> Void)?
    /// Test seam (#2384): runs in the same task as a re-imported PDF's upgrade plan, just before it, so a test can
    /// prove the plan is off the main actor by waiting there for something only the main actor can do. Nil in the app.
    var whileStructuredUpgradeIsPlannedForTesting: (@Sendable () -> Void)?

    private struct PlaybackProgress {
        var sourcePercent: Int
        var currentPercent: Int
        var chapterTitle: String?
    }

    public init(
        profile: RuntimeCapabilityProfile,
        repository: SessionRepository,
        audio: AudioPlaybackClient = NoopAudioPlaybackClient(),
        recorder: RecordingClient = NoopRecordingClient(),
        transcriber: TranscriptionClient = DeferredTranscriptionClient(),
        aiProvider: AIProviderClient = DeterministicAIProvider(),
        linkResolver: LinkResolutionClient = UnsupportedLinkResolutionClient(),
        textAudio: TextAudioPreparationClient? = nil,
        playbackStartTimeout: TimeInterval = 10,
        now: @escaping () -> Date = Date.init
    ) {
        self.profile = profile
        self.repository = repository
        self.audio = audio
        self.recorder = recorder
        self.transcriber = transcriber
        self.aiProvider = aiProvider
        self.linkResolver = linkResolver
        self.textAudio = textAudio
        self.startAttempt = PlaybackStartAttempt(timeout: playbackStartTimeout)
        self.now = now
    }

    @discardableResult
    public func startSession(itemId: String) throws -> SessionSnapshot {
        playbackRequestedAt = now(); defer { playbackRequestedAt = nil } // time to first audio counts from here (#357)
        try require("startSession", category: "sync", capabilities: ["canonical_persistence", "receive_prepared_packages", "browser_session_handoff"])
        forgetFailure(unlessItemIs: itemId)
        var item = try repository.loadItem(id: itemId)
        item = try discardUnavailableGeneratedTextAudio(from: item)
        item = adoptingPublisherAudio(for: item)
        currentItem = item
        currentMap = try repository.loadListeningMap(itemId: itemId)
        item = try prepareGeneratedTextAudioIfAvailable(for: item)
        currentItem = item
        let targetType = playbackTargetType(for: item)
        let startedAt = now()
        let session = Session(
            id: nextSessionId(itemId: itemId),
            itemId: itemId,
            createdAt: startedAt,
            updatedAt: startedAt,
            completedAt: nil,
            status: "in_progress",
            phase: .itemPlayback,
            currentTargetType: targetType,
            currentTargetId: itemPlaybackTargetId(for: item, targetType: targetType),
            position: targetType == .itemTextTTS ? Position(charOffset: 0, chapterId: nil) : Position(charOffset: 0, mediaTimeMs: 0, chapterId: nil),
            completionPercent: 0,
            playbackRate: 1
        )
        currentSession = session
        try persistSession(session)
        try playCurrentTarget(session)
        publishPlaybackStart(for: session, phase: .itemPlayback)
        return snapshot
    }

    @discardableResult
    public func importSourceLink(_ request: LinkResolutionRequest, startSessionWhenPlayable: Bool = false) throws -> SessionSnapshot {
        try require("importSourceLink", category: "sync", capabilities: ["canonical_persistence"])
        snapshot.linkResolutionStatus = LinkResolutionStatus.resolving.rawValue
        snapshot.linkResolutionFailureReason = nil

        let result = try linkResolver.resolve(request)
        return try importResolvedSourceLink(request, result: result, startSessionWhenPlayable: startSessionWhenPlayable)
    }

    @discardableResult
    public func importResolvedSourceLink(
        _ request: LinkResolutionRequest,
        result: LinkResolutionResult,
        startSessionWhenPlayable: Bool = false
    ) throws -> SessionSnapshot {
        try require("importSourceLink", category: "sync", capabilities: ["canonical_persistence"])
        lastLinkResolutionResult = result
        snapshot.linkResolutionStatus = result.status.rawValue
        snapshot.linkResolutionFailureReason = result.failureReason
        snapshot.sourceTranscriptStatus = nil

        guard result.status == .playable,
              let candidate = result.selectedCandidate,
              let audioURL = candidate.audioURL,
              !audioURL.isEmpty else {
            return snapshot
        }

        let item = try sourceImportItem(from: candidate, result: result, request: request)
        try saveItem(item)
        forgetFailure(unlessItemIs: item.id)
        currentItem = item
        currentMap = nil
        snapshot.itemId = item.id
        snapshot.targetType = TargetType.transcriptBackedMedia.rawValue
        snapshot.targetId = itemPlaybackTargetId(for: item, targetType: .transcriptBackedMedia)
        snapshot.title = item.title
        snapshot.chapterTitle = item.title
        snapshot.status = .idle
        snapshot.phase = .idle
        snapshot.sourceTranscriptStatus = item.transcriptId == nil ? "not_started" : "ready"
        snapshot.progressPercent = 0
        snapshot.sourceProgressPercent = 0
        snapshot.currentPlaybackProgressPercent = 0
        snapshot.currentMediaTimeMs = 0
        snapshot.currentPlaybackDurationMs = item.media?.durationMs
        snapshot.currentTextStart = nil
        snapshot.currentTextEnd = nil
        snapshot.currentTranscriptSegmentId = item.transcriptId
        snapshot.currentAnchorConfidence = .providerMetadata

        if item.media?.url == candidate.audioURL,
           try repository.listeningMapId(itemId: item.id) == nil, // whether there is one, not the map (#2506)
           let publisherChapters = preferredPublisherChapterCollection(in: candidate) {
            _ = try attachPublisherChapters(itemId: item.id, collection: publisherChapters)
        }

        if startSessionWhenPlayable {
            return try startSession(itemId: item.id)
        }
        return snapshot
    }

    /// Persists a resolved source without replacing the item or session the user is
    /// currently listening to. Background share intake must use this path.
    @discardableResult
    public func importResolvedSourceLinkInBackground(
        _ request: LinkResolutionRequest,
        result: LinkResolutionResult,
        sourceIdentity: String? = nil
    ) throws -> Item? {
        try require("importSourceLink", category: "sync", capabilities: ["canonical_persistence"])
        guard result.status == .playable,
              let candidate = result.selectedCandidate,
              let audioURL = candidate.audioURL,
              !audioURL.isEmpty else {
            return nil
        }
        let item = try sourceImportItem(from: candidate, result: result, request: request, sourceIdentity: sourceIdentity)
        try saveItem(item)
        if item.media?.url == candidate.audioURL,
           try repository.listeningMapId(itemId: item.id) == nil, // whether there is one, not the map (#2506)
           let publisherChapters = preferredPublisherChapterCollection(in: candidate) {
            _ = try attachPublisherChapters(itemId: item.id, collection: publisherChapters)
        }
        return item
    }

    @discardableResult
    public func togglePlayPause() throws -> SessionSnapshot {
        try requireNavigationAllowed("togglePlayPause")
        if snapshot.status.isPlaybackActive {
            return try pause()
        }
        return try resumePlayback()
    }

    @discardableResult
    public func pause() throws -> SessionSnapshot {
        try requireNavigationAllowed("pause")
        try requirePlayback("pause")
        guard var session = currentSession else {
            throw SessionKitError.invalidCommandForState("pause")
        }
        interruptionResumePoint.forget()
        session = try syncCurrentPositionFromAudio(session)
        currentSession = session
        try persistSession(session)
        try audio.pause()
        publish(status: .paused, phase: session.phase)
        return snapshot
    }

    /// Reconciles a pause that the active audio client has already applied in
    /// response to an interruption or route loss. Unlike `pause()`, this does
    /// not send a second pause command to the client, so interruption-specific
    /// resume intent remains intact until the system reports how it ended.
    @discardableResult
    public func reconcileSystemInitiatedPause() throws -> SessionSnapshot {
        try requirePlayback("reconcileSystemInitiatedPause")
        guard var session = currentSession else {
            throw SessionKitError.invalidCommandForState("reconcileSystemInitiatedPause")
        }
        session = try syncCurrentPositionFromAudio(session)
        currentSession = session
        try persistSession(session)
        interruptionResumePoint.paused(
            sessionId: session.id,
            mediaTimeMs: Self.isTimeBased(session) ? session.position.mediaTimeMs : nil,
            at: now()
        )
        publish(status: .paused, phase: session.phase)
        return snapshot
    }

    /// Resumes after the system ended an interruption. A podcast or recording first steps back by
    /// `InterruptionRewind` for how long it was paused, so the listener picks up the thread; anything else
    /// resumes as `resumePlayback()` does. The step happens once: a retry of a refused resume starts from the
    /// stepped-back place (#1975).
    @discardableResult
    public func resumePlaybackAfterInterruption() throws -> SessionSnapshot {
        defer { interruptionResumePoint.forget() }
        guard var session = currentSession, snapshot.status == .paused,
              let pause = interruptionResumePoint.rewindMs(sessionId: session.id, mediaTimeMs: session.position.mediaTimeMs, now: now) else {
            return try resumePlayback()
        }
        let rewindMs = pause.rewindMs
        // An episode that ended as the call came in is finished, not replayed from its tail (#2097).
        if rewindMs > 0, !startsInTheLastInstantOfMedia(session) {
            forgetBackTapLanding()
            // Never into a chapter the listener skipped: a tap on chapter 3 followed by a call must not resume in chapter 2.
            let timeline = currentWatchPackage?.timeline ?? sourceTranscriptTimeline(for: session)
            let chapterStartMs = timeline.flatMap { mediaChapter(at: pause.pausedAtMs, timeline: $0)?.startMs } ?? 0
            session = mediaSession(session, movedTo: max(chapterStartMs, pause.pausedAtMs - rewindMs))
            currentSession = session
            try persistSession(session)
            protectPlaybackPosition(for: session)
        }
        return try resumePlayback()
    }

    /// Podcasts and recordings are heard on a clock; text is read from a character, and resumes at its sentence.
    private static func isTimeBased(_ session: Session) -> Bool {
        session.currentTargetType == .transcriptBackedMedia || session.currentTargetType == .browserOwnedMedia
    }

    @discardableResult
    public func resumePlayback() throws -> SessionSnapshot {
        playbackRequestedAt = now(); defer { playbackRequestedAt = nil } // time to first audio counts from here (#357)
        interruptionResumePoint.forget()
        try requireNavigationAllowed("resumePlayback")
        try requirePlayback("resumePlayback")
        guard var session = currentSession else {
            throw SessionKitError.invalidCommandForState("resumePlayback")
        }
        session = try readingTextIfNarrationFileIsMissing(session)
        if startsInTheLastInstantOfMedia(session) {
            // Nothing is left to play, and a stream's seek into its last instant took 28 s on the owner's phone
            // while the start sat pending and the X on the pill did nothing (#2097). It is the end: finish here,
            // as a natural end would, so the next Play starts the item again from the top (#643).
            let finished = markPlaybackComplete(session, item: currentItem)
            currentSession = finished
            try persistSession(finished)
            publish(status: .paused, phase: finished.phase)
            return snapshot
        }
        try playCurrentTarget(session)
        publishPlaybackStart(for: session, phase: session.phase)
        return snapshot
    }

    /// A podcast or recording saved within `endOfMediaStartToleranceMs` of its end, with a known length. A saved
    /// position at 0 is a fresh start, whatever the length.
    private func startsInTheLastInstantOfMedia(_ session: Session) -> Bool {
        guard session.currentTargetType == .transcriptBackedMedia || session.currentTargetType == .browserOwnedMedia,
              !isPartialGeneratedTextPlayback(session),
              let mediaTimeMs = session.position.mediaTimeMs, mediaTimeMs > 0,
              let durationMs = durableMediaDurationMs(for: session), durationMs > 0 else { return false }
        // A place past the stored length means the stored length is short of the real file (corrections under 1 s
        // are skipped; a feed length can miss dynamic ads), so it says nothing about the end (#2189).
        return (0...Self.endOfMediaStartToleranceMs).contains(durationMs - mediaTimeMs)
    }

    /// Half a second: inside the player's own seek tolerance (0.25 s either side) of the end there is nothing
    /// worth seeking to. Wider would take a deliberate place from the listener: a scrub to 1 s from the end, or a
    /// Margin recorded at the last second (0.8 s), still plays from there (#643, #588).
    static let endOfMediaStartToleranceMs = 500

    @discardableResult
    public func restartPlaybackFromCurrentPosition() throws -> SessionSnapshot {
        try requireNavigationAllowed("restartPlaybackFromCurrentPosition")
        try requirePlayback("restartPlaybackFromCurrentPosition")
        guard var session = currentSession else {
            throw SessionKitError.invalidCommandForState("restartPlaybackFromCurrentPosition")
        }
        session = try syncCurrentPositionFromAudio(session)
        currentSession = session
        try persistSession(session)
        if snapshot.status.isPlaybackActive {
            try playCurrentTarget(session)
        }
        publishPlaybackContinuation(for: session)
        return snapshot
    }

    /// Applies native-speech settings without replacing the playback client. When speech is
    /// active, restart from the last position reported by the audio client so an unconfirmed
    /// utterance can never advance the source cursor.
    @discardableResult
    public func updateSpeechPlaybackSettings(voiceIdentifier: String?, rate: Float) throws -> SessionSnapshot {
        try requirePlayback("updateSpeechPlaybackSettings")
        try audio.configureSpeechSettings(voiceIdentifier: voiceIdentifier, rate: rate)
        guard var session = currentSession,
              snapshot.targetType == TargetType.itemTextTTS.rawValue
                || snapshot.targetType == TargetType.assistantTurnTTS.rawValue
                || snapshot.targetType == TargetType.summaryTurnTTS.rawValue else {
            return snapshot
        }
        // Rate is one number (I14). `rate` is the listener's speed stored as multiplier × 0.5.
        // The restart below re-applies the session's rate, so it has to be that same speed, or
        // the old rate (often 1×) overwrites the new one and Now Playing reports it.
        session.playbackRate = SpeechRateRule.multiplier(forStoredRate: rate)
        currentSession = session
        try persistSession(session)
        return try restartPlaybackFromCurrentPosition()
    }

    /// Changes only the transport asset for an item. Canonical target ids, source URLs,
    /// playback rate, source time, and interjection anchors remain unchanged.
    @discardableResult
    /// The player's own state behind the current target. It can be waiting (a network stall)
    /// while the session still reads as playing.
    public func currentPlaybackTransportState() -> PlaybackTransportState? {
        currentSession.flatMap { audio.playbackTransportState(targetId: $0.currentTargetId) }
    }

    public func updatePlaybackTransport(
        itemId: String,
        playbackURL: String?,
        replaceActivePlayback: Bool = true
    ) throws -> SessionSnapshot {
        if let playbackURL {
            playbackURLOverrides[itemId] = playbackURL
        } else {
            playbackURLOverrides[itemId] = nil
        }
        guard var session = currentSession,
              session.itemId == itemId,
              session.currentTargetType == .transcriptBackedMedia || session.currentTargetType == .browserOwnedMedia else {
            return snapshot
        }
        guard replaceActivePlayback else {
            // A second request can contain different dynamically inserted ads.
            // Keep this session on its original edition across skips, pauses and
            // interjections; a new session may select the completed download.
            return snapshot
        }
        pinnedMediaTransport = nil
        session = try syncCurrentPositionFromAudio(session)
        currentSession = session
        try persistSession(session)
        if snapshot.status.isPlaybackActive {
            try playCurrentTarget(session)
            publishPlaybackContinuation(for: session)
        } else {
            try audio.configureMediaContext(playbackMediaContext(for: session))
        }
        return snapshot
    }

    /// Whether the media session on `itemId` is playing `playbackURL`. A session keeps the edition it started on
    /// (see `updatePlaybackTransport`), so a download that finishes mid-session is not what the listener hears (#914).
    /// Nil when no media session on the item has chosen its edition yet.
    public func mediaSessionPlays(itemId: String, playbackURL: String) -> Bool? {
        guard let session = currentSession, session.itemId == itemId,
              let pinned = pinnedMediaTransport,
              pinned.sessionId == session.id, pinned.targetId == session.currentTargetId else { return nil }
        guard let playing = pinned.playbackURL else { return false }
        if playing == playbackURL { return true }
        // The same file can be spelled two ways (a symlinked /private/var, a trailing slash).
        guard let playingFile = URL(string: playing), playingFile.isFileURL,
              let candidate = URL(string: playbackURL), candidate.isFileURL else { return false }
        return playingFile.resolvingSymlinksInPath().standardizedFileURL == candidate.resolvingSymlinksInPath().standardizedFileURL
    }

    @discardableResult
    public func stopPlayback() throws -> SessionSnapshot {
        try requireNavigationAllowed("stopPlayback")
        guard var session = currentSession else {
            throw SessionKitError.invalidCommandForState("stopPlayback")
        }
        session = try syncCurrentPositionFromAudio(session)
        currentSession = session
        try persistSession(session)
        try audio.stop()
        publish(status: .paused, phase: session.phase)
        return snapshot
    }

    /// How long a steady playback tick may keep its place in memory before it is saved (#2509). A kill loses at
    /// most this much; pause, stop, a lifecycle sync, a status change and a change of session save at once.
    static let progressWriteInterval: TimeInterval = 5

    /// The session whose newest place is in memory but not yet saved.
    private var unsavedProgressSessionId: String?
    private var lastProgressWriteAt: [String: Date] = [:]

    /// - Parameter coalescingWrites: the foreground ticker (about twice a second) passes true so a steady advance
    ///   writes the Session row at most every `progressWriteInterval` seconds instead of on every tick. Every other
    ///   caller leaves it false and saves a moved place at once.
    @discardableResult
    public func syncPlaybackProgress(coalescingWrites: Bool = false) throws -> SessionSnapshot {
        guard var session = currentSession else {
            return snapshot
        }
        guard snapshot.status != .recording else {
            return snapshot
        }
        if externallyStreamedTurnId == session.currentTargetId {
            // Streaming speech uses chunk-scoped audio target IDs. Its queue
            // publishes confirmed start and position observations explicitly,
            // so reconciling against the turn-scoped target would promote or
            // demote the UI from an unrelated transport sample.
            publish(status: snapshot.status, phase: session.phase)
            return snapshot
        }
        let mediaSeekFailure = try reconcilePendingMediaSeek(for: &session)
        let positionIsPending = protectedPosition.holdsPosition(for: session)
        var playbackCompleted = positionIsPending ? false : audio.isPlaybackComplete(targetId: session.currentTargetId)
        let transportState = audio.playbackTransportState(targetId: session.currentTargetId)
        var updated = try syncCurrentPositionFromAudio(session)
        // A start from the very end (resuming after a Margin at the last second) finds the episode
        // already over, so it never confirms. It ended: pause there. This is checked before the
        // start's own status, whose watchdog would otherwise call it a timeout once the deadline
        // passes (#588). The media client clears its completion when a start begins, so this
        // completion is the new start's own.
        let endedBeforeStartConfirmed = snapshot.status == .starting
            && (session.currentTargetType == .transcriptBackedMedia || session.currentTargetType == .browserOwnedMedia)
            && audio.isPlaybackComplete(targetId: session.currentTargetId)
        if endedBeforeStartConfirmed {
            startAttempt.clear()
            protectedPosition.release()
            playbackCompleted = true
            updated = try syncCurrentPositionFromAudio(session)
            // The client still counts itself as playing (Lock Screen included) until told.
            try audio.pause()
            snapshot.status = .paused
        } else if snapshot.status == .starting {
            let startStatus = playbackStartStatus(for: session.currentTargetId, attemptId: startAttempt.currentAttemptId)
            if let recovered = currentSession, recovered.currentTargetId != session.currentTargetId {
                // Start recovery moved playback to another target (#237); don't persist the old one.
                session = recovered
                updated = recovered
            }
            switch startStatus {
            case .confirmed:
                // A confirmed start is the first point at which the newly
                // requested transport position is authoritative.
                updated = try syncCurrentPositionFromAudio(session)
                snapshot.status = .playing
                forgetStartFailure()
            case .pending:
                // Startup can remain pending while a buffered speech client is
                // already advancing or after the user seeks. Preserve that
                // canonical position instead of repeatedly publishing the
                // pre-start session offset (usually zero).
                if updated.position != session.position
                    || updated.completionPercent != session.completionPercent
                    || updated.phase != session.phase
                    || updated.status != session.status {
                    session = updated
                    currentSession = session
                    try persistSession(session)
                }
                publish(status: .starting, phase: session.phase)
                return snapshot
            case .failed(let message):
                if updated.position != session.position
                    || updated.completionPercent != session.completionPercent
                    || updated.phase != session.phase
                    || updated.status != session.status {
                    session = updated
                    currentSession = session
                    try persistSession(session)
                }
                snapshot.lastFailure = "playback_start_failed:\(message)"
                publish(status: .failed, phase: session.phase)
                return snapshot
            }
        } else if snapshot.status == .playing {
            if case .failed(let message) = audio.playbackStartStatus(targetId: session.currentTargetId) {
                if updated.position != session.position
                    || updated.completionPercent != session.completionPercent
                    || updated.phase != session.phase
                    || updated.status != session.status {
                    session = updated
                    currentSession = session
                    try persistSession(session)
                }
                snapshot.lastFailure = "playback_failed:\(message)"
                publish(status: .failed, phase: session.phase)
                return snapshot
            }
        }
        if playbackCompleted {
            updated = markPlaybackComplete(updated, item: currentItem)
        }
        if updated.position != session.position
            || updated.completionPercent != session.completionPercent
            || updated.phase != session.phase
            || updated.status != session.status {
            let steadyAdvance = updated.phase == session.phase && updated.status == session.status && !playbackCompleted
            let savedRecently = lastProgressWriteAt[session.id].map { now().timeIntervalSince($0) < Self.progressWriteInterval } ?? false
            let deferWrite = coalescingWrites && steadyAdvance && savedRecently
            session = updated
            if deferWrite {
                unsavedProgressSessionId = session.id
                currentSession = session
            } else {
                currentSession = session
                try persistSession(session)
            }
        }
        if !coalescingWrites, unsavedProgressSessionId == session.id, let held = currentSession {
            try persistSession(held) // a lifecycle sync saves the place the ticker has been holding
        }
        let reconciledStatus: PlaybackStatus
        if playbackCompleted || (snapshot.status == .playing && transportState == .paused) {
            reconciledStatus = .paused
        } else {
            reconciledStatus = snapshot.status
        }
        publish(status: reconciledStatus, phase: session.phase)
        if let mediaSeekFailure {
            snapshot.lastFailure = "media_seek_failed:\(mediaSeekFailure)"
        } else if case .accepted = lastMediaSeekResolution,
                  snapshot.lastFailure?.hasPrefix("media_seek_failed:") == true {
            snapshot.lastFailure = nil
        }
        return snapshot
    }

    @discardableResult
    public func attachTranscriptTimeline(itemId: String, timeline: TranscriptTimeline) throws -> SessionSnapshot {
        try require("attachTranscriptTimeline", category: "sync", capabilities: ["canonical_persistence"])
        var item = try repository.loadItem(id: itemId)
        var timelineWithPreferredChapters = timeline
        if let map = try repository.loadListeningMap(itemId: itemId),
           publisherChapterSource(from: map.id) != nil,
           let existingChapters = try repository.loadTranscriptTimeline(itemId: itemId)?.timeline.chapters,
           !existingChapters.isEmpty {
            timelineWithPreferredChapters.chapters = existingChapters
        }
        let normalized = normalizedSourceTranscriptTimeline(timelineWithPreferredChapters)
        let transcriptId = item.transcriptId ?? "transcript-\(item.id)"
        let stored = SourceTranscriptTimeline(
            id: transcriptId,
            itemId: item.id,
            createdAt: Date(),
            timeline: normalized.timeline
        )
        try repository.saveTranscriptTimeline(stored)
        item.transcriptId = transcriptId
        item.text = normalized.text
        if item.status == "ready" || item.status == "needs_transcript" || item.status == "audio_ready" {
            item.status = "needs_listening_map"
        }
        try saveItem(item)
        if currentItem?.id == item.id || currentSession?.itemId == item.id {
            currentItem = item
            if let session = currentSession, session.itemId == item.id {
                currentSession = try syncMediaPositionFromAudio(session)
                if let currentSession {
                    try persistSession(currentSession)
                }
                publish(status: snapshot.status, phase: currentSession?.phase ?? snapshot.phase)
            } else {
                snapshot.itemId = item.id
                snapshot.title = item.title
                snapshot.currentTranscriptSegmentId = item.transcriptId
            }
        }
        return snapshot
    }

    @discardableResult
    public func attachPreparedTextAudio(
        itemId: String,
        prepared: PreparedTextAudio,
        replaceActivePlayback: Bool = false
    ) throws -> SessionSnapshot {
        try require("attachPreparedTextAudio", category: "sync", capabilities: ["canonical_persistence"])
        let item = try repository.loadItem(id: itemId)
        guard shouldPrepareGeneratedTextAudio(for: item) else {
            return snapshot
        }
        let updated = try applyPreparedTextAudio(prepared, to: item)
        if currentItem?.id == updated.id || currentSession?.itemId == updated.id {
            currentItem = updated
            if let session = currentSession, session.itemId == updated.id {
                if session.currentTargetType == .itemTextTTS, session.phase == .itemPlayback {
                    let synchronized = syncSessionPositionFromAudio(session, item: updated)
                    if replaceActivePlayback {
                        var migrated = synchronized
                        let mediaTimeMs = mediaTimeMs(
                            forTextOffset: synchronized.position.charOffset,
                            timeline: prepared.timeline
                        )
                        migrated.currentTargetType = .transcriptBackedMedia
                        migrated.currentTargetId = itemPlaybackTargetId(
                            for: updated,
                            targetType: .transcriptBackedMedia
                        )
                        migrated = mediaSession(migrated, movedTo: mediaTimeMs)
                        currentSession = migrated
                        try persistSession(migrated)
                        protectPlaybackPosition(for: migrated)
                        if snapshot.status.isPlaybackActive {
                            try playCurrentTarget(migrated)
                        }
                        publishPlaybackContinuation(for: migrated)
                    } else {
                        // System speech preparation can use a different voice and
                        // cadence, so its generic attachment remains next-session
                        // only unless the caller explicitly guarantees continuity.
                        currentSession = synchronized
                        try persistSession(synchronized)
                        publish(status: snapshot.status, phase: synchronized.phase)
                    }
                } else if session.currentTargetType == .transcriptBackedMedia,
                          publisherPlayback[session.itemId] == nil,
                          item.media?.sourceType == .generatedTTSPrerendered,
                          updated.media?.sourceType == .generatedTTSPrerendered {
                    let replacementTargetId = itemPlaybackTargetId(for: updated, targetType: .transcriptBackedMedia)
                    guard session.currentTargetId != replacementTargetId else {
                        publish(status: snapshot.status, phase: session.phase)
                        return snapshot
                    }
                    var migrated = try syncMediaPositionFromAudio(session)
                    let sourceOffset = migrated.position.charOffset
                    let mediaTimeMs = mediaTimeMs(forTextOffset: sourceOffset, timeline: prepared.timeline)
                    migrated.currentTargetId = replacementTargetId
                    migrated = mediaSession(migrated, movedTo: mediaTimeMs)
                    currentSession = migrated
                    try persistSession(migrated)
                    protectPlaybackPosition(for: migrated)
                    if snapshot.status.isPlaybackActive {
                        try playCurrentTarget(migrated)
                    }
                    publishPlaybackContinuation(for: migrated)
                } else {
                    publish(status: snapshot.status, phase: session.phase)
                }
            } else {
                snapshot.itemId = updated.id
                snapshot.title = updated.title
                snapshot.targetType = TargetType.transcriptBackedMedia.rawValue
                snapshot.targetId = itemPlaybackTargetId(for: updated, targetType: .transcriptBackedMedia)
            }
        }
        return snapshot
    }

    @discardableResult
    public func seekMedia(toMediaTimeMs mediaTimeMs: Int) throws -> SessionSnapshot {
        try requireNavigationAllowed("seekMedia")
        try requirePlayback("seekMedia")
        forgetBackTapLanding()
        guard let session = currentSession,
              session.currentTargetType == .transcriptBackedMedia || session.currentTargetType == .browserOwnedMedia else {
            throw SessionKitError.invalidCommandForState("seekMedia")
        }
        // An episode that played to its end is stopped, even if its last start never confirmed:
        // a seek leaves it paused at the new place rather than waiting on that start (#588).
        // This holds when progress sync already showed it paused, too: an end inferred from a
        // player that stopped short was never a listener's pause, so the client must be told,
        // or a seek near the end is read as the end again.
        let endedBeforeSeek = (snapshot.status.isPlaybackActive || snapshot.status == .paused)
            && audio.isPlaybackComplete(targetId: session.currentTargetId)
        let updated = reopeningIfMovedBeforeTheEnd(mediaSession(session, movedTo: mediaTimeMs))
        currentSession = updated
        try persistSession(updated)
        do {
            let request = try audio.requestMediaSeek(toMediaTimeMs: updated.position.mediaTimeMs ?? 0)
            protectPlaybackPosition(for: updated, mediaSeekRequest: request)
            lastMediaSeekRequest = request
            lastMediaSeekResolution = .pending
        } catch {
            currentSession = session
            try persistSession(session)
            throw error
        }
        // Seeking within the active target is navigation, not a new playback
        // start. Preserve the current transport status while the matching seek
        // transaction is acknowledged by the audio client.
        if endedBeforeSeek {
            try audio.pause()
        }
        publish(status: endedBeforeSeek ? .paused : snapshot.status, phase: updated.phase)
        return snapshot
    }

    /// Records a media destination while paused when no player exists yet (for example,
    /// after restoring a session). The next playback start opens the source at this position.
    /// Active playback must use seekMedia so a real player seek is acknowledged.
    @discardableResult
    public func stagePausedMediaPosition(toMediaTimeMs mediaTimeMs: Int) throws -> SessionSnapshot {
        try requireNavigationAllowed("stagePausedMediaPosition")
        try requirePlayback("stagePausedMediaPosition")
        forgetBackTapLanding()
        guard snapshot.status == .paused,
              let session = currentSession,
              session.currentTargetType == .transcriptBackedMedia || session.currentTargetType == .browserOwnedMedia else {
            throw SessionKitError.invalidCommandForState("stagePausedMediaPosition")
        }
        let updated = reopeningIfMovedBeforeTheEnd(mediaSession(session, movedTo: mediaTimeMs))
        currentSession = updated
        try persistSession(updated)
        protectPlaybackPosition(for: updated)
        lastMediaSeekRequest = nil
        lastMediaSeekResolution = nil
        publish(status: .paused, phase: updated.phase)
        return snapshot
    }

    @discardableResult
    public func seekText(toCharOffset charOffset: Int) throws -> SessionSnapshot {
        try requireNavigationAllowed("seekText")
        try requirePlayback("seekText")
        forgetBackTapLanding()
        if var turnSession = currentSession,
           turnSession.currentTargetType == .assistantTurnTTS || turnSession.currentTargetType == .summaryTurnTTS {
            guard let turn = try repository.loadTurns(sessionId: turnSession.id).first(where: { $0.id == turnSession.currentTargetId }) else {
                throw SessionKitError.invalidCommandForState("seekText")
            }
            let text = generatedTurnNavigationText(for: turn)
            guard !text.isEmpty else { throw SessionKitError.invalidCommandForState("seekText") }
            let wasPlaying = snapshot.status.isPlaybackActive
            externallyStreamedTurnId = nil
            turnSession.position = Position(charOffset: max(0, min(charOffset, text.count)))
            turnSession.position.chapterId = turn.chapters?.last(where: { $0.startChar <= turnSession.position.charOffset })?.id
            currentSession = turnSession
            try persistSession(turnSession)
            protectPlaybackPosition(for: turnSession)
            if wasPlaying, turnSession.position.charOffset < text.count {
                try playCurrentTarget(turnSession, seeking: true)
                publishPlaybackContinuation(for: turnSession)
            } else {
                try audio.pause()
                publish(status: .paused, phase: turnSession.phase)
            }
            return snapshot
        }
        // An article's prepared narration plays as media, so a text place (a shared Margin's, or where a Margin
        // was recorded) is found on its narration timeline (#866). A place the audio doesn't reach still throws.
        if let session = currentSession, session.currentTargetType == .transcriptBackedMedia,
           let item = currentItem ?? (try? repository.loadItem(id: session.itemId)),
           isTextBackedMedia(item),
           let timeline = sourceTranscriptTimeline(itemId: item.id),
           let mediaTimeMs = publisherPlayback[item.id]?.mediaTimeMs(textOffset: charOffset)
               ?? PreparedNarrationFallback.mediaTimeMs(textOffset: charOffset, timeline: timeline) {
            do {
                return try seekMedia(toMediaTimeMs: mediaTimeMs)
            } catch SessionKitError.invalidCommandForState(let reason)
                where reason == "media_seek_player_unavailable" && snapshot.status == .paused {
                // A restored, paused session has no player yet: the next start opens the narration there.
                return try stagePausedMediaPosition(toMediaTimeMs: mediaTimeMs)
            }
        }
        // The recording doesn't reach this place (a sentence the map couldn't place), so the article reads on
        // from here with on-device speech, as it did before the recording (#547).
        if let session = currentSession, isPlayingPublisherAudio(session),
           let item = try? repository.loadItem(id: session.itemId) {
            try audio.stop()
            publisherPlayback[item.id] = nil
            currentItem = item
            let reading = PreparedNarrationFallback.liveSpeechSession(from: session, item: item, timeline: nil)
            currentSession = reading
        }
        guard var session = currentSession,
              session.currentTargetType == .itemTextTTS,
              let item = currentItem ?? (try? repository.loadItem(id: session.itemId)),
              let text = item.text,
              !text.isEmpty else {
            throw SessionKitError.invalidCommandForState("seekText")
        }
        currentItem = item
        session.position.charOffset = max(0, min(charOffset, text.count))
        session.position.mediaTimeMs = nil
        session.position.chapterId = chapterId(for: session.position.charOffset)
        session.completionPercent = percent(for: session.position.charOffset, text: text)
        session.phase = .itemPlayback
        session.status = "in_progress"
        currentSession = session
        try persistSession(session)
        protectPlaybackPosition(for: session)
        if session.position.charOffset >= text.count {
            try audio.stop()
            publish(status: .paused, phase: .itemPlayback)
        } else if snapshot.status.isPlaybackActive {
            try playCurrentTarget(session, seeking: true)
            publishPlaybackContinuation(for: session)
        } else {
            publish(status: snapshot.status, phase: session.phase)
        }
        return snapshot
    }

    @discardableResult
    public func setPlaybackRate(_ rate: Double) throws -> SessionSnapshot {
        try requirePlayback("setPlaybackRate")
        guard var session = currentSession else {
            throw SessionKitError.invalidCommandForState("setPlaybackRate")
        }
        let clamped = max(0.25, min(3.0, rate))
        session.playbackRate = clamped
        currentSession = session
        try persistSession(session)
        try audio.setPlaybackRate(clamped)
        publish(status: snapshot.status, phase: session.phase)
        return snapshot
    }

    @discardableResult
    public func prepareSpeechText(itemId: String, targetType: TargetType) throws -> SessionSnapshot {
        let item = try repository.loadItem(id: itemId)
        lastSpokenText = SpeechTextNormalizer.normalize(item.text ?? "")
        currentItem = item
        snapshot.title = item.title
        return snapshot
    }

    /// `structuredDocument` is a PDF's extraction v2 (C1 M3, I13): its text becomes
    /// `Item.text`, its headings the chapters, and it is stored beside the item so
    /// the speech path can apply I14.
    @discardableResult
    public func importBrowserText(_ handoff: BrowserTextHandoff, structuredDocument: StructuredDocument? = nil) throws -> SessionSnapshot {
        try require("importBrowserText", category: "sync", capabilities: ["browser_session_handoff", "canonical_persistence"])
        let (item, deterministicMap, document, persisted) = try browserTextImportRecords(handoff, structuredDocument: structuredDocument)
        if !persisted {
            try saveItem(item)
            if let deterministicMap { try repository.saveListeningMap(deterministicMap) }
            try saveStructuredDocument(document, itemId: item.id)
        } else { forgetDocumentCaches(itemId: item.id) }
        browserTextImporter().saveSourceElements(for: handoff, item: item)
        forgetFailure(unlessItemIs: item.id)
        currentItem = item
        currentMap = deterministicMap
        snapshot.itemId = item.id
        snapshot.targetType = TargetType.itemTextTTS.rawValue
        snapshot.targetId = item.id
        snapshot.title = item.title
        snapshot.chapterTitle = item.title
        snapshot.status = .idle
        snapshot.phase = .idle
        snapshot.progressPercent = 0
        snapshot.sourceProgressPercent = 0
        snapshot.currentPlaybackProgressPercent = 0
        if handoff.requestedContinuation.startSession {
            return try startSession(itemId: item.id)
        }
        return snapshot
    }

    /// Persists a browser or file share without disturbing active playback state.
    @discardableResult
    public func importBrowserTextInBackground(_ handoff: BrowserTextHandoff, structuredDocument: StructuredDocument? = nil) throws -> Item {
        try require("importBrowserText", category: "sync", capabilities: ["browser_session_handoff", "canonical_persistence"])
        let (item, deterministicMap, document, persisted) = try browserTextImportRecords(handoff, structuredDocument: structuredDocument)
        if !persisted {
            try saveItem(item)
            if let deterministicMap { try repository.saveListeningMap(deterministicMap) }
            try saveStructuredDocument(document, itemId: item.id)
        } else { forgetDocumentCaches(itemId: item.id) }
        browserTextImporter().saveSourceElements(for: handoff, item: item)
        return item
    }

    /// The same import, except it never reads or writes the store on the main actor, so a long page, a long PDF or
    /// a Library of many Margins never freezes the app (#556, #2509). Reading what is already there, working out the
    /// item and its map, and writing the item, map and document run together in one detached step that holds the
    /// store and values, never the engine; the engine's state (which items are open, whether playback runs) is read
    /// once on the main actor just before it. A re-imported PDF's move to the new extraction is planned the same
    /// way, and its one short write stays on the main actor, together with the "is the listener in this item?" check:
    /// a write off the main actor could not be made atomic with the engine's state (a paused item opened, or
    /// played, between the plan and the write would keep the old text and write its old position over the moved
    /// one). If the item was opened or anything the plan read changed (the store re-checks inside the transaction),
    /// nothing is written and the new text becomes its own edition, as it does for a PDF that can't move.
    ///
    /// The one window left is the milliseconds between reading the open items and the detached step's own write; an
    /// item opened in it is rewritten with the same text and a new document, which the reader does not notice.
    /// Imports run one at a time (`importGate`), so two shares of one address cannot both find nothing and write
    /// over each other.
    @MainActor
    @discardableResult
    public func importBrowserTextInBackgroundOffMain(_ handoff: BrowserTextHandoff, structuredDocument: StructuredDocument? = nil) async throws -> Item {
        try require("importBrowserText", category: "sync", capabilities: ["browser_session_handoff", "canonical_persistence"])
        await enterImportGate()
        defer { leaveImportGate() }
        let firstImporter = browserTextImporter()
        var outcome = try await Task.detached(priority: .userInitiated) {
            try firstImporter.outcomeAndPersist(handoff, structuredDocument: structuredDocument, upgrade: .deferred)
        }.value
        if case .upgradeCandidate(let job) = outcome {
            let whilePlanned = whileStructuredUpgradeIsPlannedForTesting
            let planned = await Task.detached(priority: .userInitiated) {
                whilePlanned?()
                return try? job.plan()
            }.value
            try afterStructuredUpgradePlannedForTesting?()
            if case .success(let upgrade)? = planned, currentSession?.itemId != job.existing.id, currentItem?.id != job.existing.id {
                do {
                    try job.apply(upgrade)
                    forgetDocumentCaches(itemId: upgrade.item.id)
                    return upgrade.item
                } catch StructuredDocumentUpgradeError.changedSincePlanned {}
            }
            let skipImporter = browserTextImporter()
            outcome = try await Task.detached(priority: .userInitiated) {
                try skipImporter.outcomeAndPersist(handoff, structuredDocument: structuredDocument, upgrade: .skip)
            }.value
        }
        guard case .records(let item, _, _, _) = outcome else {
            throw SessionKitError.invalidCommandForState("importBrowserText")
        }
        forgetDocumentCaches(itemId: item.id)
        return item
    }

    private var importGateBusy = false
    private var importGateWaiters: [CheckedContinuation<Void, Never>] = []

    /// Waits for any earlier off-main import to finish, in the order they asked.
    @MainActor
    private func enterImportGate() async {
        if importGateBusy {
            await withCheckedContinuation { importGateWaiters.append($0) }
        } else {
            importGateBusy = true
        }
    }

    @MainActor
    private func leaveImportGate() {
        if importGateWaiters.isEmpty { importGateBusy = false } else { importGateWaiters.removeFirst().resume() }
    }

    private func saveStructuredDocument(_ document: StructuredDocument?, itemId: String) throws {
        guard let document, let store = repository as? StructuredDocumentRepository else { return }
        if let store = store as? any (SessionRepository & StructuredDocumentRepository) {
            try PreparedAudioEnqueue.saveStructuredDocument(document, itemId: itemId, repository: store)
        } else { try store.saveStructuredDocument(document, itemId: itemId) }
        forgetDocumentCaches(itemId: itemId)
    }

    private func forgetDocumentCaches(itemId: String) {
        // The cache may hold "no document" for this item's text (#220 audit 5).
        if listenableCache?.itemId == itemId { listenableCache = nil }
        if exportPageDocumentCache?.itemId == itemId { exportPageDocumentCache = nil }
    }

    @discardableResult
    public func loadWatchPackage(watchPackageId: String) throws -> SessionSnapshot {
        try require("loadWatchPackage", category: "sync", capabilities: ["receive_prepared_packages"])
        try require("loadWatchPackage", category: "playback", capabilities: ["prerendered_audio", "native_media"])
        guard let package = try repository.loadWatchAudioPackage(id: watchPackageId) else {
            throw SessionKitError.missingFixture("watch_package:\(watchPackageId)")
        }
        try ensureWatchPackageRecords(package)
        forgetFailure(unlessItemIs: package.itemId)
        currentWatchPackage = package
        currentItem = try repository.loadItem(id: package.itemId)
        currentMap = nil
        let firstChapter = package.chapters.sorted { $0.startMs < $1.startMs }.first
        let session = Session(
            id: package.sessionId,
            itemId: package.itemId,
            status: "in_progress",
            phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia,
            currentTargetId: package.primaryAudioAsset?.audioAssetId ?? package.id,
            position: Position(
                charOffset: package.transcript.segments.first?.startChar ?? 0,
                mediaTimeMs: firstChapter?.startMs ?? 0,
                segmentIndex: 0,
                chapterId: firstChapter?.id
            ),
            completionPercent: mediaPercent(firstChapter?.startMs ?? 0, package: package),
            playbackRate: package.settings.defaultPlaybackRate
        )
        currentSession = session
        try persistSession(session)
        lastResolvedMediaAnchor = resolveMediaAnchor(for: session)
        publish(status: .paused, phase: session.phase)
        return snapshot
    }

    @discardableResult
    public func importWatchSyncEvent(eventId: String) throws -> SessionSnapshot {
        try require("importWatchSyncEvent", category: "sync", capabilities: ["import_offline_events", "canonical_persistence"])
        guard let event = try repository.loadWatchSyncEvent(id: eventId) else {
            throw SessionKitError.missingFixture("watch_sync_event:\(eventId)")
        }
        if try repository.hasImportedWatchSyncEvent(id: event.id) {
            lastImportedWatchSyncEvent = event
            publish(status: snapshot.status, phase: currentSession?.phase ?? snapshot.phase)
            return snapshot
        }
        guard let package = try repository.loadWatchAudioPackage(id: event.watchPackageId) else {
            throw SessionKitError.missingFixture("watch_package:\(event.watchPackageId)")
        }
        try ensureWatchPackageRecords(package)
        currentWatchPackage = package
        currentItem = try repository.loadItem(id: package.itemId)
        switch event.eventType {
        case "interjection_recorded":
            try importWatchInterjection(event, package: package)
        case "playback_position":
            try importWatchPlaybackPosition(event, package: package)
        case "session_finished":
            if var session = try repository.loadSession(id: event.sessionId) {
                session.status = "finished"
                session.phase = .finished
                currentSession = session
                try persistSession(session)
            }
        default:
            break
        }
        try repository.markWatchSyncEventImported(id: event.id)
        lastImportedWatchSyncEvent = event
        pendingWatchEventCount = try unimportedWatchEventCount(sessionId: event.sessionId)
        publish(status: snapshot.status, phase: currentSession?.phase ?? snapshot.phase)
        return snapshot
    }

    @discardableResult
    public func generateListeningMap(itemId: String) throws -> SessionSnapshot {
        try require("generateListeningMap", category: "ai", capabilities: ["generate_listening_map"])
        if let existing = try repository.loadListeningMap(itemId: itemId) {
            if currentItem?.id == itemId || currentSession?.itemId == itemId {
                currentMap = existing
            }
            return snapshot
        }
        var item = try repository.loadItem(id: itemId)
        let map = generatedListeningMap(for: item)
        try repository.saveListeningMap(map)
        if item.status == "needs_listening_map" {
            item.status = "ready"
            try saveItem(item)
        }
        if currentItem?.id == itemId || currentSession?.itemId == itemId {
            currentItem = item
            currentMap = map
            if var session = currentSession, session.itemId == itemId {
                session.position.chapterId = chapterId(for: session.position.charOffset)
                currentSession = session
                try persistSession(session)
                publish(status: snapshot.status, phase: session.phase)
            } else {
                snapshot.title = item.title
            }
        }
        return snapshot
    }

    @discardableResult
    public func attachListeningMap(_ map: ListeningMap) throws -> SessionSnapshot {
        try require("attachListeningMap", category: "sync", capabilities: ["canonical_persistence"])
        var item = try repository.loadItem(id: map.itemId)
        try repository.saveListeningMap(map)
        if item.status == "needs_listening_map" {
            item.status = "ready"
            try saveItem(item)
        }
        guard currentItem?.id == map.itemId || currentSession?.itemId == map.itemId else {
            return snapshot
        }
        currentItem = item
        currentMap = map
        if var session = currentSession, session.itemId == map.itemId {
            if session.currentTargetType == .itemTextTTS {
                session.position.chapterId = chapterId(for: session.position.charOffset)
                currentSession = session
                try persistSession(session)
            }
            publish(status: snapshot.status, phase: session.phase)
        } else {
            snapshot.itemId = item.id
            snapshot.title = item.title
        }
        return snapshot
    }

    @discardableResult
    public func attachPublisherChapters(
        itemId: String,
        collection: PublisherChapterCollection
    ) throws -> SessionSnapshot {
        try require("attachPublisherChapters", category: "sync", capabilities: ["canonical_persistence"])
        var item = try repository.loadItem(id: itemId)
        if let existingMap = try repository.loadListeningMap(itemId: itemId),
           let existingSource = publisherChapterSource(from: existingMap.id),
           existingSource.precedence > collection.source.precedence {
            return snapshot
        }

        let existingTimeline = try repository.loadTranscriptTimeline(itemId: itemId)
        let durationMs = item.media?.durationMs ?? existingTimeline?.timeline.durationMs
        let normalized = normalizedPublisherChapters(collection.chapters, durationMs: durationMs)
        guard !normalized.isEmpty else { return snapshot }

        let segments = existingTimeline?.timeline.segments ?? []
        let mediaChapters = normalized.enumerated().map { index, chapter in
            let id = publisherChapterId(source: collection.source, index: index)
            let segmentId = segments.last(where: { $0.startMs <= chapter.startMs })?.id
                ?? segments.first?.id
                ?? "publisher-anchor-\(index + 1)"
            return MediaTimelineChapter(
                id: id,
                title: chapter.title,
                description: chapter.description,
                startMs: chapter.startMs,
                transcriptSegmentId: segmentId
            )
        }
        let timeline = TranscriptTimeline(
            segments: segments,
            chapters: mediaChapters,
            durationMs: durationMs ?? normalized.compactMap(\.endMs).max() ?? normalized.last?.startMs
        )
        try repository.saveTranscriptTimeline(SourceTranscriptTimeline(
            id: existingTimeline?.id ?? "media-chapters-\(itemId)",
            itemId: itemId,
            createdAt: existingTimeline?.createdAt ?? Date(),
            timeline: timeline
        ))

        let percentDuration = max(1, timeline.durationMs ?? normalized.last?.startMs ?? 1)
        let chapters = normalized.enumerated().map { index, chapter in
            Chapter(
                id: mediaChapters[index].id,
                title: chapter.title,
                startChar: index,
                endChar: index + 1,
                percent: max(0, min(100, Int((Double(chapter.startMs) / Double(percentDuration) * 100).rounded())))
            )
        }
        let map = ListeningMap(
            id: "map-\(itemId)-publisher-\(collection.source.rawValue)",
            itemId: itemId,
            overview: ListeningMapOverviewText.appGenerated(title: item.title, chapterCount: chapters.count),
            chapters: chapters
        )
        try repository.saveListeningMap(map)
        // A community map never outlives the publisher's chapters (#553): the episode may have
        // asked for one while its audio, and so its embedded chapters, was not yet readable.
        try repository.removeCommunityMap(itemId: itemId)
        if item.status == "needs_listening_map" {
            item.status = "ready"
            try saveItem(item)
        }

        guard currentItem?.id == itemId || currentSession?.itemId == itemId else { return snapshot }
        currentItem = item
        currentMap = map
        if let session = currentSession, session.itemId == itemId {
            publish(status: snapshot.status, phase: session.phase)
        } else {
            snapshot.itemId = item.id
            snapshot.title = item.title
        }
        return snapshot
    }

    @discardableResult
    public func skipForward(unit: String) throws -> SessionSnapshot {
        return try skipForward(unit: unit, minimumDistance: 0)
    }

    @discardableResult
    public func skipForward(unit: String, minimumDistance: Int) throws -> SessionSnapshot {
        try requireNavigationAllowed("skipForward")
        try requirePlayback("skipForward")
        forgetBackTapLanding()
        guard var session = currentSession else {
            throw SessionKitError.invalidCommandForState("skipForward")
        }
        if session.currentTargetType == .transcriptBackedMedia || session.currentTargetType == .browserOwnedMedia {
            return try skipMediaForward(session: session, unit: unit)
        }
        guard session.currentTargetType == .itemTextTTS else {
            return try skipGeneratedTurnForward(session: session, unit: unit)
        }
        guard let item = currentItem else {
            throw SessionKitError.invalidCommandForState("skipForward")
        }
        session = syncSessionPositionFromAudio(session, item: item)
        let text = item.text ?? ""
        if unit == "chapter" {
            session.position.charOffset = nextChapterBoundary(after: session.position.charOffset, text: text)
        } else {
            let baseline = session.position.charOffset
            let firstBoundary = nextBoundary(after: baseline, unit: unit, text: text)
            if minimumDistance > 0, firstBoundary < min(text.count, baseline + minimumDistance) {
                session.position.charOffset = nextBoundary(after: min(text.count, baseline + minimumDistance), unit: unit, text: text)
            } else {
                session.position.charOffset = firstBoundary
            }
        }
        session.completionPercent = percent(for: session.position.charOffset, text: text)
        session.position.chapterId = chapterId(for: session.position.charOffset)
        session.phase = .itemPlayback
        session.status = "in_progress"
        currentSession = session
        try persistSession(session)
        protectPlaybackPosition(for: session)
        if snapshot.status.isPlaybackActive, session.position.charOffset < text.count {
            try playCurrentTarget(session, seeking: true)
            publishPlaybackContinuation(for: session)
            return snapshot
        } else if session.position.charOffset >= text.count {
            try audio.stop()
        }
        publish(status: session.position.charOffset >= text.count ? .paused : snapshot.status, phase: session.phase)
        return snapshot
    }

    @discardableResult
    public func skipBack(unit: String) throws -> SessionSnapshot {
        try requireNavigationAllowed("skipBack")
        try requirePlayback("skipBack")
        guard var session = currentSession else {
            throw SessionKitError.invalidCommandForState("skipBack")
        }
        if session.currentTargetType == .transcriptBackedMedia || session.currentTargetType == .browserOwnedMedia {
            forgetBackTapLanding()
            return try skipMediaBack(session: session, unit: unit)
        }
        guard session.currentTargetType == .itemTextTTS else {
            return try skipGeneratedTurnBack(session: session, unit: unit)
        }
        guard let item = currentItem else {
            throw SessionKitError.invalidCommandForState("skipBack")
        }
        session = syncSessionPositionFromAudio(session, item: item)
        let text = item.text ?? ""
        if unit == "chapter" {
            forgetBackTapLanding()
            session.position.charOffset = previousChapterBoundary(before: session.position.charOffset)
        } else {
            session.position.charOffset = backTapBoundary(from: session.position.charOffset, unit: unit, text: text, session: session)
        }
        session.completionPercent = percent(for: session.position.charOffset, text: text)
        session.position.chapterId = chapterId(for: session.position.charOffset)
        if session.phase == .finished {
            session.phase = .itemPlayback
        }
        currentSession = session
        try persistSession(session)
        protectPlaybackPosition(for: session)
        if snapshot.status.isPlaybackActive {
            try playCurrentTarget(session, seeking: true)
            publishPlaybackContinuation(for: session)
            return snapshot
        }
        publish(status: snapshot.status, phase: session.phase)
        return snapshot
    }

    private func skipGeneratedTurnForward(session: Session, unit: String) throws -> SessionSnapshot {
        var updated = try syncGeneratedTurnPositionFromAudio(session)
        guard let turn = try repository.loadTurns(sessionId: updated.id).first(where: { $0.id == updated.currentTargetId }) else {
            throw SessionKitError.invalidCommandForState("skipForward")
        }
        let text = generatedTurnNavigationText(for: turn)
        guard !text.isEmpty else {
            throw SessionKitError.invalidCommandForState("skipForward")
        }
        updated.position.charOffset = nextBoundary(after: updated.position.charOffset, unit: unit, text: text)
        updated.position.charOffset = max(0, min(updated.position.charOffset, text.count))
        updated.position.chapterId = turn.chapters?.last(where: { $0.startChar <= updated.position.charOffset })?.id
        currentSession = updated
        try persistSession(updated)
        protectPlaybackPosition(for: updated)
        if snapshot.status.isPlaybackActive, updated.position.charOffset < text.count {
            try playCurrentTarget(updated, seeking: true)
            publishPlaybackContinuation(for: updated)
            return snapshot
        } else if updated.position.charOffset >= text.count {
            try audio.stop()
        }
        publish(status: updated.position.charOffset >= text.count ? .paused : snapshot.status, phase: updated.phase)
        return snapshot
    }

    private func skipGeneratedTurnBack(session: Session, unit: String) throws -> SessionSnapshot {
        var updated = try syncGeneratedTurnPositionFromAudio(session)
        guard let turn = try repository.loadTurns(sessionId: updated.id).first(where: { $0.id == updated.currentTargetId }) else {
            throw SessionKitError.invalidCommandForState("skipBack")
        }
        let text = generatedTurnNavigationText(for: turn)
        guard !text.isEmpty else {
            throw SessionKitError.invalidCommandForState("skipBack")
        }
        updated.position.charOffset = backTapBoundary(from: updated.position.charOffset, unit: unit, text: text, session: updated)
        updated.position.charOffset = max(0, min(updated.position.charOffset, text.count))
        updated.position.chapterId = turn.chapters?.last(where: { $0.startChar <= updated.position.charOffset })?.id
        currentSession = updated
        try persistSession(updated)
        protectPlaybackPosition(for: updated)
        if snapshot.status.isPlaybackActive {
            try playCurrentTarget(updated, seeking: true)
            publishPlaybackContinuation(for: updated)
            return snapshot
        }
        publish(status: snapshot.status, phase: updated.phase)
        return snapshot
    }

    @discardableResult
    public func jumpToChapter(chapterId: String) throws -> SessionSnapshot {
        defer { playbackRequestedAt = nil }
        try requireNavigationAllowed("jumpToChapter")
        try require("jumpToChapter", category: "timeline", capabilities: ["chapter_timing"])
        try requirePlayback("jumpToChapter")
        forgetBackTapLanding()
        if let session = currentSession,
           session.currentTargetType == .transcriptBackedMedia || session.currentTargetType == .browserOwnedMedia {
            stampRequestIfStarting(target: session.currentTargetId)
            return try jumpToMediaChapter(chapterId: chapterId, session: session)
        }
        guard var session = currentSession, let chapter = currentMap?.chapters.first(where: { $0.id == chapterId }) else {
            throw SessionKitError.invalidCommandForState("jumpToChapter")
        }
        stampRequestIfStarting(target: session.itemId)
        session.currentTargetType = .itemTextTTS
        session.currentTargetId = session.itemId
        session.phase = .itemPlayback
        session.position.charOffset = chapter.startChar
        session.position.chapterId = chapter.id
        session.completionPercent = chapter.percent
        currentSession = session
        try persistSession(session)
        protectPlaybackPosition(for: session)
        try playCurrentTarget(session, seeking: true)
        publishPlaybackStart(for: session, phase: session.phase)
        return snapshot
    }

    @discardableResult
    public func playSourceFromBeginning() throws -> SessionSnapshot {
        playbackRequestedAt = now(); defer { playbackRequestedAt = nil } // time to first audio counts from here (#357)
        try requireNavigationAllowed("playSourceFromBeginning")
        try requirePlayback("playSourceFromBeginning")
        forgetBackTapLanding()
        guard var session = currentSession else {
            throw SessionKitError.invalidCommandForState("playSourceFromBeginning")
        }
        if currentItem?.id != session.itemId {
            currentItem = try repository.loadItem(id: session.itemId)
        }
        currentMap = try repository.loadListeningMap(itemId: session.itemId)
        if let item = currentItem {
            currentItem = try prepareGeneratedTextAudioIfAvailable(for: item)
        }
        let targetType = currentItem.map(playbackTargetType(for:)) ?? .itemTextTTS
        session.currentTargetType = targetType
        session.currentTargetId = currentItem.map { itemPlaybackTargetId(for: $0, targetType: targetType) } ?? session.itemId
        session.phase = .itemPlayback
        session.position = targetType == .itemTextTTS ? Position(charOffset: 0, chapterId: nil) : Position(charOffset: 0, mediaTimeMs: 0, chapterId: nil)
        session.completionPercent = 0
        currentSession = session
        try persistSession(session)
        protectPlaybackPosition(for: session)
        try playCurrentTarget(session, seeking: true)
        publishPlaybackStart(for: session, phase: .itemPlayback)
        return snapshot
    }

    @discardableResult
    public func inspectSession(sessionId: String) throws -> SessionSnapshot {
        guard var session = try repository.loadSession(id: sessionId) else {
            throw SessionKitError.invalidCommandForState("inspectSession")
        }
        forgetFailure(unlessItemIs: session.itemId)
        protectedPosition.release()
        if (session.phase == .finished || session.status == "finished"), session.completionPercent < 100 {
            if session.phase == .finished {
                session.phase = .itemPlayback
            }
            session.status = "in_progress"
            try persistSession(session)
        }
        var item = try repository.loadItem(id: session.itemId)
        item = try discardUnavailableGeneratedTextAudio(from: item)
        (item, session) = resumingPublisherAudio(item: item, session: session)
        currentItem = item
        currentMap = try repository.loadListeningMap(itemId: session.itemId)
        session = try readingTextIfNarrationFileIsMissing(session)
        if session.currentTargetType == .itemTextTTS,
           isGeneratedTextMedia(item.media),
           let timeline = sourceTranscriptTimeline(itemId: item.id),
           !timeline.segments.isEmpty,
           !isPartialGeneratedTextMedia(item: item, timeline: timeline) {
            let mediaTimeMs = mediaTimeMs(forTextOffset: session.position.charOffset, timeline: timeline)
            session.currentTargetType = .transcriptBackedMedia
            session.currentTargetId = itemPlaybackTargetId(for: item, targetType: .transcriptBackedMedia)
            session = mediaSession(session, movedTo: mediaTimeMs)
            try persistSession(session)
        }
        if let durationMs = durableMediaDurationMs(for: session) {
            session = try repairMediaPercentages(session, durationMs: durationMs, forceNotes: true)
        }
        currentSession = session
        publish(status: .paused, phase: session.phase)
        return snapshot
    }

    @discardableResult
    public func beginInterjection(request: MarginCaptureRequest = MarginCaptureRequest()) throws -> SessionSnapshot {
        try require("beginInterjection", category: "interjection", capabilities: ["record_audio", "delegate_interjection_to_canonical_runtime"])
        guard pendingWrittenInterjection == nil else {
            throw SessionKitError.invalidCommandForState("beginInterjection")
        }
        guard var session = currentSession else { throw SessionKitError.invalidCommandForState("beginInterjection") }
        // Left in place until the steps that can throw have passed, so a failure here still leaves the app
        // something to put back (`isSourcePausedOnTap`).
        let pendingPause = captureResume.tapPause
        marginCaptureTiming = pendingPause ?? MarginCaptureTiming(request: request)
        marginCaptureTiming?.engineEntered(at: ProcessInfo.processInfo.systemUptime)
        // The tap already paused it (#1696), so the snapshot no longer says it was playing.
        let wasPlaying = pendingPause != nil || snapshot.status.isPlaybackActive
        let usesNativeMediaClock = session.currentTargetType == .transcriptBackedMedia
            || session.currentTargetType == .browserOwnedMedia
        captureResume.captureStarting(finishedAtEnd: isFinishedAtEnd(session))
        if captureResume.startedOnFinishedSource {
            // A recap Margin on a finished item (#142). The saved end position is
            // authoritative: a stopped speech player reports a reset offset, so
            // neither the session nor the anchor may sample it.
            protectPlaybackPosition(for: session)
            try audio.pause()
        } else if usesNativeMediaClock {
            // Freeze native transport before sampling its clock. Sampling first
            // lets media advance before the interruption and accumulates drift.
            try audio.pause()
            session = try syncCurrentPositionFromAudio(session)
        } else {
            // Speech pause callbacks can report terminal state synchronously.
            // Capture text position before pausing so that callback cannot turn an
            // in-progress interjection anchor into end-of-source completion.
            session = try syncCurrentPositionFromAudio(session)
            try audio.pause()
        }
        marginCaptureTiming?.sourcePaused(at: ProcessInfo.processInfo.systemUptime)
        currentSession = session
        try persistSession(session)
        captureResume.sourcePaused(in: session.phase)
        let target = currentInterjectionTarget(for: session)
        recordingTargetType = target.type
        recordingTargetId = target.id
        recordingReplyTo = request.replyTo
        recordingAnchor = buildAnchor(for: session, targetType: target.type, targetId: target.id)
        closedRecordingRef = nil
        storedMarginFinish = nil
        marginCaptureTiming?.anchorReady(at: ProcessInfo.processInfo.systemUptime)
        captureResume.takeOverTapPause() // from here a failure puts the source back itself, below
        do {
            marginCaptureTiming?.recorderRequested(at: ProcessInfo.processInfo.systemUptime)
            try recorder.beginRecording()
            marginCaptureTiming?.recorderStarted(at: ProcessInfo.processInfo.systemUptime,
                                                inputRoute: recorder.captureDiagnostics()["inputs"])
            noteRecordingDraft(session: session, targetType: target.type, targetId: target.id)
        } catch {
            try? recorder.cancelRecording() // let go of whatever the failed start grabbed, such as the audio session
            abandonInterjectionStart(session, wasPlaying: wasPlaying)
            throw error
        }
        session.phase = .recordingInterjection
        currentSession = session
        snapshot.recordingTargetId = target.id
        publish(status: .recording, phase: .recordingInterjection)
        return snapshot
    }

    /// The recorder wouldn't start after the source was paused for it (#1034), so nothing is recording. Forget the
    /// recording target and put the transport back as the listener left it, the way `cancelInterjection` does:
    /// a source that was playing plays on, anything else stays stopped, and the snapshot says which.
    private func abandonInterjectionStart(_ session: Session, wasPlaying: Bool) {
        let resumes = captureResume.resumesAfterFailedStart(sourceWasPlaying: wasPlaying)
        recordingAnchor = nil
        recordingTargetType = nil
        recordingTargetId = nil
        recordingReplyTo = nil
        captureResume.captureAbandoned()
        guard resumes else {
            publish(status: .paused, phase: session.phase)
            return
        }
        playbackRequestedAt = now(); defer { playbackRequestedAt = nil } // the resume's first audio counts from here (#357)
        if externallyStreamedTurnId == session.currentTargetId {
            publish(status: .starting, phase: session.phase)
            return
        }
        do {
            try playCurrentTarget(session)
            publishPlaybackStart(for: session, phase: session.phase)
        } catch {
            // The player wouldn't restart either; say so rather than claim it plays.
            publish(status: .paused, phase: session.phase)
        }
    }

    /// Add a Margin on a playing podcast: pause it now, on the tap, before the permission check, the deferred start
    /// and the anchor work (#1696). On a phone that took 16 s to get to the pause, the listener talked over a
    /// podcast that kept playing. Only the pause happens here: the position is read, and the anchor made, by
    /// `beginInterjection` once the source is quiet, as before. Does nothing for a source that isn't playing, text
    /// that is read aloud (its position has to be read before it is paused), or one that has already ended.
    /// `abandonPendingInterjection` puts the podcast back; `beginInterjection` and `beginWrittenInterjection` take it over.
    @discardableResult
    public func pauseSourceForInterjection(request: MarginCaptureRequest) -> SessionSnapshot {
        guard !captureResume.isSourcePausedOnTap, pendingWrittenInterjection == nil,
              snapshot.status.isPlaybackActive,
              let session = currentSession,
              session.currentTargetType == .transcriptBackedMedia || session.currentTargetType == .browserOwnedMedia,
              !isFinishedAtEnd(session),
              profile.hasAny("interjection", ["record_audio", "delegate_interjection_to_canonical_runtime"]) else {
            return snapshot
        }
        var timing = MarginCaptureTiming(request: request)
        do { try audio.pause() } catch { return snapshot } // `beginInterjection` pauses again and reports it
        timing.sourcePaused(at: ProcessInfo.processInfo.systemUptime)
        captureResume.tapPaused(timing)
        publish(status: .paused, phase: session.phase)
        return snapshot
    }

    /// True between `pauseSourceForInterjection` and the `beginInterjection` that takes it over.
    public var isSourcePausedOnTap: Bool { captureResume.isSourcePausedOnTap }

    /// The recorder, when it can switch the audio session for recording off the main thread before
    /// `beginInterjection` (#2511). Nil for recorders that can't (tests' fakes, the watch).
    public var recordingSessionPreparer: RecordingSessionPreparing? { recorder as? RecordingSessionPreparing }

    /// Cancel before the recorder was asked for: nothing is recording and there is no draft, so the podcast
    /// goes on from where it stopped (#1696). Does nothing when the tap did not pause anything.
    @discardableResult
    public func abandonPendingInterjection() throws -> SessionSnapshot {
        guard captureResume.takeOverTapPause() != nil else { return snapshot }
        marginCaptureTiming = nil
        // Play from the Lock Screen or Now Playing in the meantime already did the job; don't seek it again.
        guard !snapshot.status.isPlaybackActive else { return snapshot }
        guard var session = currentSession else { return snapshot }
        // The pause froze the clock, so this reads where the listener stopped. A failure here still resumes.
        if let synced = try? syncCurrentPositionFromAudio(session) { session = synced }
        currentSession = session
        try? persistSession(session)
        abandonInterjectionStart(session, wasPlaying: true)
        return snapshot
    }

    /// What the recorder has taken in so far while a Margin is recording (#937). Nil when it can't tell.
    public func recordingCaptureReading() -> RecordingCaptureReading? {
        let reading = recorder.captureReading()
        let observedAt = ProcessInfo.processInfo.systemUptime
        marginCaptureTiming?.observe(reading, at: observedAt, inputRoute: reading?.inputRoute)
        return reading
    }

    /// The ready cue is about to play (#1594): the recorder stops taking audio in, so the cue is not in the saved Margin.
    public func pauseRecordingForReadyCue() {
        guard currentSession?.phase == .recordingInterjection else { return }
        recorder.pauseForReadyCue()
    }

    /// The cue has started, or did not play (0 seconds): the recorder listens again after `seconds`.
    public func resumeRecordingAfterReadyCue(after seconds: TimeInterval) {
        recorder.resumeAfterReadyCue(after: seconds)
    }

    /// Starts a new recorder after one that never got audio; the session stays in `recordingInterjection`.
    public func restartRecordingCapture() throws {
        guard currentSession?.phase == .recordingInterjection else {
            throw SessionKitError.invalidCommandForState("restartRecordingCapture")
        }
        try recorder.restartCapture()
        updateRecordingDraft { $0.audioRef = recorder.recordingInProgressRef() }
    }

    /// Writes the note for the recording that just started: its source, place and file, before the app shows
    /// "Recording". A failure is remembered and the recording goes on (#951).
    private func noteRecordingDraft(session: Session, targetType: InterjectionTargetType, targetId: String) {
        guard let journal = recordingDraftJournal, let anchor = recordingAnchor else { return }
        let draft = RecordingDraft(
            sessionId: session.id,
            itemId: session.itemId,
            targetType: targetType,
            targetId: targetId,
            createdAt: now(),
            roughPercent: interjectionPercent(for: session, targetType: targetType, targetId: targetId, anchor: anchor),
            anchor: anchor,
            audioRef: recorder.recordingInProgressRef(),
            replyTo: recordingReplyTo
        )
        activeRecordingDraft = draft
        recordingDraftFailure = nil
        do { try journal.write(draft) } catch { recordingDraftFailure = "write:\(error.localizedDescription)" }
    }

    private func updateRecordingDraft(_ change: (inout RecordingDraft) -> Void) {
        guard let journal = recordingDraftJournal, var draft = activeRecordingDraft else { return }
        change(&draft)
        activeRecordingDraft = draft
        do { try journal.write(draft) } catch { recordingDraftFailure = "write:\(error.localizedDescription)" }
    }

    /// The Margin is stored, or the listener cancelled: the note has done its job.
    private func removeRecordingDraft() {
        guard let draft = activeRecordingDraft else { return }
        activeRecordingDraft = nil
        do { try recordingDraftJournal?.remove(id: draft.id) } catch { recordingDraftFailure = "remove:\(error.localizedDescription)" }
    }

    public func recordingCaptureDiagnostics() -> [String: String] {
        recorder.captureDiagnostics().merging(marginCaptureTiming?.fields ?? [:]) { _, timing in timing }
    }

    public func finalizedRecordingIntegrity() -> FinalizedRecordingIntegrity? {
        recorder.finalizedRecordingIntegrity()
    }

    /// Changes which shared Margin the Margin being recorded or written answers (#473): the listener switched it
    /// to independent, or back. Does nothing when no Margin is being captured.
    public func changeReplyOfCurrentCapture(to link: MarginReplyLink?) {
        if currentSession?.phase == .recordingInterjection {
            recordingReplyTo = link
            updateRecordingDraft { $0.replyTo = link }
        }
        if let capture = pendingWrittenInterjection {
            pendingWrittenInterjection = WrittenInterjectionCapture(
                id: capture.id, sessionId: capture.sessionId, itemId: capture.itemId, targetType: capture.targetType,
                targetId: capture.targetId, anchor: capture.anchor, roughPercent: capture.roughPercent,
                wasPlaying: capture.wasPlaying, replyTo: link
            )
        }
    }

    public func recordingReleasedAudioSession() -> Bool {
        recorder.releasedAudioSessionAtEnd()
    }

    @discardableResult
    public func beginWrittenInterjection(replyTo: MarginReplyLink? = nil) throws -> WrittenInterjectionCapture {
        try requireNavigationAllowed("beginWrittenInterjection")
        guard let originalSession = currentSession else {
            throw SessionKitError.invalidCommandForState("beginWrittenInterjection")
        }
        guard pendingWrittenInterjection == nil else {
            throw SessionKitError.invalidCommandForState("beginWrittenInterjection")
        }
        // Add a Margin may already have paused it on the tap (#1696), when the listener switched to writing.
        let wasPlaying = captureResume.takeOverTapPause() != nil || snapshot.status.isPlaybackActive
        // Resolve the immutable target before changing transport. The native
        // media clock still has to be sampled after pause, but every other
        // fallible part of the transaction happens before audio is stopped.
        let target = currentInterjectionTarget(for: originalSession)
        _ = buildAnchor(for: originalSession, targetType: target.type, targetId: target.id)

        do {
            var session = originalSession
            let usesNativeMediaClock = session.currentTargetType == .transcriptBackedMedia
                || session.currentTargetType == .browserOwnedMedia
            if usesNativeMediaClock {
                try audio.pause()
                session = try syncCurrentPositionFromAudio(session)
            } else {
                session = try syncCurrentPositionFromAudio(session)
                try audio.pause()
            }
            let anchor = buildAnchor(for: session, targetType: target.type, targetId: target.id)
            try persistSession(session)
            currentSession = session
            let capture = WrittenInterjectionCapture(
                id: UUID().uuidString,
                sessionId: session.id,
                itemId: session.itemId,
                targetType: target.type,
                targetId: target.id,
                anchor: anchor,
                roughPercent: interjectionPercent(
                    for: session,
                    targetType: target.type,
                    targetId: target.id,
                    anchor: anchor
                ),
                wasPlaying: wasPlaying,
                replyTo: replyTo
            )
            pendingWrittenInterjection = capture
            publish(status: .paused, phase: session.phase)
            return capture
        } catch {
            // A failed begin must leave no draft and must restore transport if
            // the source had been playing. The persisted session was only
            // written after the pause/synchronization transaction succeeded.
            currentSession = originalSession
            if wasPlaying {
                try? restoreWrittenInterjectionTransport(wasPlaying: true, session: originalSession)
            } else {
                try? audio.pause()
                publish(status: .paused, phase: originalSession.phase)
            }
            throw error
        }
    }

    @discardableResult
    public func saveWrittenInterjection(captureId: String, text: String) throws -> SessionSnapshot {
        playbackRequestedAt = now(); defer { playbackRequestedAt = nil } // the resume's first audio counts from here (#357)
        guard let capture = pendingWrittenInterjection, capture.id == captureId,
              let session = currentSession,
              session.id == capture.sessionId,
              session.itemId == capture.itemId else {
            throw SessionKitError.invalidCommandForState("saveWrittenInterjection")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionKitError.invalidCommandForState("saveWrittenInterjection")
        }
        let interjection = Interjection(
            id: "ij-written-\(capture.id)",
            itemId: capture.itemId,
            sessionId: capture.sessionId,
            targetType: capture.targetType,
            targetId: capture.targetId,
            createdAt: now(),
            roughPercent: capture.roughPercent,
            anchor: capture.anchor,
            audioPath: nil,
            audioStatus: "discarded",
            transcriptionStatus: "transcribed",
            transcript: text,
            cleanedTranscript: nil,
            displayText: text,
            status: "active",
            // Written capture does not schedule transcription. A missing
            // cached context is unavailable, never pending background work.
            anchorContextStatus: capture.anchor.mediaTimeMs == nil
                || !capture.anchor.anchorBefore.isEmpty
                || !capture.anchor.anchorAfter.isEmpty ? .ready : .unavailable,
            captureKind: .written,
            replyTo: capture.replyTo
        )
        try repository.saveInterjection(interjection)
        lastMediaPercentageRepair = nil
        pendingWrittenInterjection = nil
        do {
            // A written Margin rejoins like a spoken one (#776), but a source that was
            // already paused stays exactly where the listener left it.
            let resumed = capture.wasPlaying ? try rejoiningAfterSavedMargin(session) : session
            try restoreWrittenInterjectionTransport(wasPlaying: capture.wasPlaying, session: resumed)
        } catch {
            // The note is already durable. Do not report this as a save failure
            // or retain a retryable draft: doing either would allow a second
            // submit to create a duplicate. Leave transport safely paused.
            try? audio.pause()
            publish(status: .paused, phase: session.phase)
        }
        return snapshot
    }

    @discardableResult
    public func cancelWrittenInterjection(captureId: String) throws -> SessionSnapshot {
        playbackRequestedAt = now(); defer { playbackRequestedAt = nil } // the resume's first audio counts from here (#357)
        guard let capture = pendingWrittenInterjection, capture.id == captureId,
              let session = currentSession,
              session.id == capture.sessionId,
              session.itemId == capture.itemId else {
            throw SessionKitError.invalidCommandForState("cancelWrittenInterjection")
        }
        try restoreWrittenInterjectionTransport(wasPlaying: capture.wasPlaying, session: session)
        pendingWrittenInterjection = nil
        return snapshot
    }

    /// #1970: reopens the written Margin a closed app left unsaved. The capture comes from the draft journal; the
    /// session it names must be the one the engine has open, and nothing else may be mid-capture. The source is
    /// left paused, so saving or cancelling it never starts playback.
    @discardableResult
    public func restoreWrittenInterjection(_ capture: WrittenInterjectionCapture) throws -> WrittenInterjectionCapture {
        guard pendingWrittenInterjection == nil, snapshot.status != .recording,
              let session = currentSession,
              session.id == capture.sessionId,
              session.itemId == capture.itemId else {
            throw SessionKitError.invalidCommandForState("restoreWrittenInterjection")
        }
        let restored = WrittenInterjectionCapture(
            id: capture.id, sessionId: capture.sessionId, itemId: capture.itemId, targetType: capture.targetType,
            targetId: capture.targetId, anchor: capture.anchor, roughPercent: capture.roughPercent,
            wasPlaying: false, replyTo: capture.replyTo
        )
        pendingWrittenInterjection = restored
        publish(status: .paused, phase: session.phase)
        return restored
    }

    private func restoreWrittenInterjectionTransport(wasPlaying: Bool, session: Session) throws {
        if wasPlaying {
            if externallyStreamedTurnId == session.currentTargetId {
                publish(status: .starting, phase: session.phase)
            } else {
                try playCurrentTarget(session)
                publishPlaybackStart(for: session, phase: session.phase)
            }
        } else {
            try audio.pause()
            publish(status: .paused, phase: session.phase)
        }
    }

    private struct InterjectionAnchorPlaybackPlan {
        var originalSession: Session
        var session: Session
        var item: Item
        var map: ListeningMap?
    }

    private func interjectionAnchorPlaybackPlan(for requested: Interjection) throws -> InterjectionAnchorPlaybackPlan {
        guard let originalSession = try repository.loadSession(id: requested.sessionId),
              originalSession.itemId == requested.itemId,
              let stored = try repository.loadInterjections(sessionId: requested.sessionId).first(where: {
                  $0.id == requested.id
                      && $0.sessionId == requested.sessionId
                      && $0.itemId == requested.itemId
              }),
              stored.status == "active" else {
            throw SessionKitError.invalidCommandForState("playInterjectionAnchor")
        }

        // An article playing its publisher's recording hears the Margin there too (#547).
        let item = try repository.loadItem(id: originalSession.itemId)
        // A place the recording doesn't reach (a sentence the map couldn't place) is heard with on-device speech.
        let publisher = publisherPlayback[originalSession.itemId].flatMap {
            $0.mediaTimeMs(textOffset: stored.anchor.startChar) == nil ? nil : $0
        }
        let playingItem = publisher?.playing(item) ?? item
        let map = try repository.loadListeningMap(itemId: item.id)
        var session = originalSession
        switch stored.targetType {
        case .item:
            guard stored.targetId == item.id else {
                throw SessionKitError.invalidCommandForState("playInterjectionAnchor")
            }
            var targetType = playbackTargetType(for: playingItem)
            // An article's prepared narration finds a Margin's text place on its timeline; a place the render
            // doesn't reach is read with on-device speech, as a publisher recording's is (#1537).
            var narrationMediaTimeMs: Int?
            if targetType == .transcriptBackedMedia, publisher == nil, isGeneratedTextMedia(playingItem.media) {
                narrationMediaTimeMs = PreparedNarrationFallback.mediaTimeMs(
                    forMargin: stored.anchor,
                    timeline: sourceTranscriptTimeline(itemId: item.id)
                )
                if narrationMediaTimeMs == nil { targetType = .itemTextTTS }
            }
            session.currentTargetType = targetType
            session.currentTargetId = itemPlaybackTargetId(for: playingItem, targetType: targetType)
            session.phase = .itemPlayback
            if targetType == .transcriptBackedMedia || targetType == .browserOwnedMedia {
                let anchorMediaTimeMs = publisher.flatMap {
                    $0.mediaTimeMs(textOffset: stored.anchor.startChar)
                } ?? narrationMediaTimeMs ?? stored.anchor.mediaTimeMs
                guard let mediaTimeMs = anchorMediaTimeMs,
                      mediaTimeMs >= 0 else {
                    throw SessionKitError.invalidCommandForState("playInterjectionAnchor")
                }
                // The stamped copy, not a fresh decode of the whole transcript on every Margin play tap (#2508).
                let durableDurationMs = (publisher?.timeline ?? storedTranscriptTimeline(itemId: item.id))?.durationMs
                    ?? playingItem.media?.durationMs
                // A stored length is truncated to whole seconds (#2189), so it can sit up to 999 ms under the file's
                // real length; a Margin made in that last second is still the listener's place, not a bad anchor.
                guard durableDurationMs.map({ mediaTimeMs <= $0 + Self.storedDurationTruncationMs }) ?? true else {
                    throw SessionKitError.invalidCommandForState("playInterjectionAnchor")
                }
                // The plan is made while another item may still be current and its player
                // attached, so use this item's own stored duration, never theirs (#293).
                if let package = currentWatchPackage, package.itemId == item.id {
                    session = mediaSession(session, movedTo: mediaTimeMs, package: package)
                } else {
                    session = mediaSession(session, movedTo: mediaTimeMs, durationMs: durableDurationMs)
                }
            } else {
                guard let text = item.text,
                      stored.anchor.startChar >= 0,
                      stored.anchor.endChar >= stored.anchor.startChar,
                      stored.anchor.endChar <= text.count else {
                    throw SessionKitError.invalidCommandForState("playInterjectionAnchor")
                }
                session.position = Position(
                    charOffset: stored.anchor.startChar,
                    chapterId: map?.chapters.last(where: { $0.startChar <= stored.anchor.startChar })?.id
                )
                session.completionPercent = percent(for: stored.anchor.startChar, text: text)
            }
        case .assistantTurn, .summaryTurn:
            guard let turn = try repository.loadTurns(sessionId: originalSession.id).first(where: { $0.id == stored.targetId }),
                  turn.role == "assistant",
                  (turn.status == "complete" || turn.status == "streaming"),
                  (stored.targetType == .assistantTurn && turn.turnType == "assistant_response")
                      || (stored.targetType == .summaryTurn && turn.turnType == "interjection_summary") else {
                throw SessionKitError.invalidCommandForState("playInterjectionAnchor")
            }
            let text = generatedTurnNavigationText(for: turn)
            guard stored.anchor.startChar >= 0,
                  stored.anchor.endChar >= stored.anchor.startChar,
                  stored.anchor.endChar <= text.count else {
                throw SessionKitError.invalidCommandForState("playInterjectionAnchor")
            }
            session.currentTargetType = stored.targetType == .assistantTurn ? .assistantTurnTTS : .summaryTurnTTS
            session.currentTargetId = turn.id
            session.phase = stored.targetType == .assistantTurn ? .aiResponsePlayback : .summaryPlayback
            session.position = Position(charOffset: stored.anchor.startChar, chapterId: nil)
            session.completionPercent = percent(for: stored.anchor.startChar, text: text)
        }
        return InterjectionAnchorPlaybackPlan(originalSession: originalSession, session: session, item: playingItem, map: map)
    }

    @discardableResult
    public func playInterjectionAnchor(_ interjection: Interjection) throws -> SessionSnapshot {
        playbackRequestedAt = now(); defer { playbackRequestedAt = nil } // time to first audio counts from here (#357)
        try requireNavigationAllowed("playInterjectionAnchor")
        forgetBackTapLanding()
        let plan = try interjectionAnchorPlaybackPlan(for: interjection)
        let previousSession = currentSession
        let previousItem = currentItem
        let previousMap = currentMap
        let previousSnapshot = snapshot
        let previousProtectedPosition = protectedPosition
        let previousExternallyStreamedTurnId = externallyStreamedTurnId

        do {
            // Restored with the rest of the snapshot below if the jump fails.
            forgetFailure(unlessItemIs: plan.session.itemId)
            currentSession = plan.session
            currentItem = plan.item
            currentMap = plan.map
            externallyStreamedTurnId = nil
            try persistSession(plan.session)
            protectPlaybackPosition(for: plan.session)
            try playCurrentTarget(plan.session)
            publishPlaybackStart(for: plan.session, phase: plan.session.phase)
            return snapshot
        } catch {
            // The target session has not become the user's current source until
            // both its durable target and adapter setup succeed. Restore its
            // stored position before returning to the prior source.
            try? repository.saveSession(storedForm(of: plan.originalSession))
            lastSavedMediaTimeMs[plan.originalSession.id] = nil // the next write compares with the restored row
            currentSession = previousSession
            currentItem = previousItem
            currentMap = previousMap
            protectedPosition = previousProtectedPosition
            externallyStreamedTurnId = previousExternallyStreamedTurnId
            snapshot = previousSnapshot
            if let previousSession {
                do {
                    if previousSnapshot.status.isPlaybackActive {
                        try playCurrentTarget(previousSession)
                        publishPlaybackStart(for: previousSession, phase: previousSession.phase)
                    } else {
                        try audio.pause()
                        publish(status: .paused, phase: previousSession.phase)
                    }
                } catch {
                    // Identity is still truthful even when the adapter cannot
                    // restore the old transport.
                    snapshot.status = .paused
                    snapshot.phase = previousSession.phase
                    snapshot.lastFailure = "playback_anchor_rollback_failed"
                }
            }
            throw error
        }
    }

    @discardableResult
    /// - Parameter resumesSource: false leaves the source paused at the Margin's place, for a
    ///   Margin a call or lost headphones ended (#771); the listener's Save resumes it.
    public func finishInterjection(audioRef: String?, resumesSource: Bool = true) throws -> SessionSnapshot {
        playbackRequestedAt = now(); defer { playbackRequestedAt = nil } // the resume's first audio counts from here (#357)
        guard var session = currentSession,
              let anchor = recordingAnchor,
              let targetType = recordingTargetType,
              let targetId = recordingTargetId else {
            throw SessionKitError.invalidCommandForState("finishInterjection")
        }
        if let pending = storedMarginFinish, pending.interjection.sessionId == session.id {
            // The Margin was stored by an earlier Save whose later steps failed (#1121).
            return try finishStoredMargin(session, anchor: anchor, targetType: targetType, resumesSource: resumesSource)
        }
        storedMarginFinish = nil // left over from another session
        let savedAudioRef = try MainThreadOperationLabels.shared.scoped("finish.recorder") {
            try recorder.finishRecording(audioRef: audioRef ?? closedRecordingRef)
        }
        closedRecordingRef = savedAudioRef
        updateRecordingDraft { $0.audioRef = savedAudioRef; $0.state = .closed }
        if profile.has("sync", "queue_offline_events"), let package = currentWatchPackage {
            let event = try queueWatchInterjectionEvent(audioRef: savedAudioRef, session: session, package: package)
            closedRecordingRef = nil
            removeRecordingDraft()
            lastQueuedWatchSyncEvent = event
            snapshot.lastInterjectionAnchorType = anchor.anchorType
            snapshot.lastInterjectionTargetType = targetType
            session.phase = MarginCaptureResume.phase(afterSavingOn: targetType)
            session = applyMediaRollback(session, package: package)
            currentSession = session
            try persistSession(session)
            try playCurrentTarget(session)
            publishPlaybackStart(for: session, phase: session.phase)
            return snapshot
        }
        let count = try repository.loadInterjections(sessionId: session.id).count + 1
        let item = try? repository.loadItem(id: session.itemId)
        let shouldCapturePostResumePodcastEvidence = targetType == .item
            && anchor.mediaTimeMs != nil
            && item.map(Self.isNativeAudioSource) == true
        let interjection = Interjection(
            id: Interjection.makeId(number: count, targetType: targetType),
            itemId: session.itemId,
            sessionId: session.id,
            targetType: targetType,
            targetId: targetId,
            createdAt: now(),
            roughPercent: interjectionPercent(
                for: session,
                targetType: targetType,
                targetId: targetId,
                anchor: anchor
            ),
            anchor: anchor,
            audioPath: savedAudioRef,
            audioStatus: "saved",
            transcriptionStatus: "pending",
            transcript: nil,
            cleanedTranscript: nil,
            displayText: nil,
            status: "active",
            anchorContextStatus: Interjection.contextStatus(for: anchor),
            podcastAnchorEvidenceCaptureStatus: shouldCapturePostResumePodcastEvidence
                ? .pendingPostResumeSample
                : nil,
            replyTo: recordingReplyTo
        )
        try MainThreadOperationLabels.shared.scoped("finish.store") { try repository.saveInterjection(interjection) }
        removeRecordingDraft()
        closedRecordingRef = nil // owned by a Margin now; a later failure must not store it again
        lastMediaPercentageRepair = nil
        storedMarginFinish = StoredMarginFinish(
            interjection: interjection,
            capturesPostResumeEvidence: shouldCapturePostResumePodcastEvidence
        )
        return try MainThreadOperationLabels.shared.scoped("finish.resume") {
            try finishStoredMargin(session, anchor: anchor, targetType: targetType, resumesSource: resumesSource)
        }
    }

    /// Everything after the Margin is stored. Each step that has run is remembered, so a Save that failed part way
    /// can be tried again without storing the Margin, capturing evidence or scheduling transcription twice (#1121).
    private func finishStoredMargin(_ session: Session, anchor: Anchor, targetType: InterjectionTargetType, resumesSource: Bool) throws -> SessionSnapshot {
        guard var pending = storedMarginFinish else {
            throw SessionKitError.invalidCommandForState("finishInterjection")
        }
        var session = session
        if !pending.evidenceHandled {
            pending.evidenceHandled = true
            storedMarginFinish = pending
            if pending.capturesPostResumeEvidence,
               let anchorMediaTimeMs = anchor.mediaTimeMs {
                let evidenceRequest = PostResumeAudioSampleRequest(
                    interjectionId: pending.interjection.id,
                    sessionId: session.id,
                    itemId: session.itemId,
                    anchorMediaTimeMs: anchorMediaTimeMs,
                    targetDurationMs: SparseFingerprintSchedule.targetDurationMs,
                    captureDelayMs: SparseFingerprintSchedule.seekDebounceMs
                )
                let capturedPreWindow = audio.captureBufferedPreInterjectionAudioSample(evidenceRequest)
                // A paused source has no resume to sample: an armed window would time out over a long
                // call (#771), so only the window before the Margin runs.
                let armedPostWindow = resumesSource && audio.armPostResumeAudioSample(evidenceRequest)
                if !capturedPreWindow && !armedPostWindow {
                    pending.interjection.podcastAnchorEvidenceCaptureStatus = .unavailable
                    pending.interjection.podcastAnchorEvidenceFailureReason = "decoded_playback_sample_unavailable"
                    storedMarginFinish = pending
                    try repository.saveInterjection(pending.interjection)
                    lastMediaPercentageRepair = nil
                } else if !capturedPreWindow || !armedPostWindow {
                    // One window still runs; record the one that didn't so a later success can't hide it.
                    pending.interjection.podcastAnchorEvidenceFailureReason = PodcastAnchorCaptureDiagnostics.appendingFailureReason(
                        capturedPreWindow ? (resumesSource ? "post_window_not_armed" : "post_window_skipped_source_paused") : "pre_window_not_captured",
                        to: pending.interjection.podcastAnchorEvidenceFailureReason
                    )
                    storedMarginFinish = pending
                    try repository.saveInterjection(pending.interjection)
                    lastMediaPercentageRepair = nil
                }
            }
        }
        if !pending.transcriptionScheduled {
            try transcriber.scheduleTranscription(interjection: pending.interjection)
            pending.transcriptionScheduled = true
            storedMarginFinish = pending
        }
        lastScheduledTranscriptionInterjectionId = pending.interjection.id
        snapshot.lastInterjectionAnchorType = anchor.anchorType
        snapshot.lastInterjectionTargetType = targetType
        if captureResume.returnsToFinishedSource(targetType: targetType) {
            let settled = try settleFinishedSourceAfterInterjection(session)
            storedMarginFinish = nil
            return settled
        }
        session.phase = MarginCaptureResume.phase(afterSavingOn: targetType)
        // beginInterjection already captured and persisted the authoritative
        // source position before pausing, and the anchor above was built from it.
        // The source rejoins a little earlier (#776); the step is idempotent at a
        // sentence start, so repeated Margins never drift into the sentence before.
        if captureResume.claimRejoin(forMargin: pending.interjection.id, inSession: session.id) {
            storedMarginFinish = pending
            session = try rejoiningAfterSavedMargin(session)
        }
        currentSession = session
        try persistSession(session)
        if !resumesSource {
            publish(status: .paused, phase: session.phase)
        } else if externallyStreamedTurnId == session.currentTargetId {
            publish(status: .starting, phase: session.phase)
        } else {
            try playCurrentTarget(session)
            publishPlaybackStart(for: session, phase: session.phase)
        }
        storedMarginFinish = nil
        return snapshot
    }

    /// What a Cancel or Write instead is told when a Save has already stored the Margin or closed its recording.
    static let marginAlreadyStored = "This Margin is already saved. Finish it with Save."

    /// - Parameter resumesSource: as for `finishInterjection`. A Cancel after a Save that stored the Margin and failed a
    ///   later step throws and changes nothing: the Margin is kept, and Save again finishes it (#1713).
    @discardableResult
    public func cancelInterjection(resumesSource: Bool = true) throws -> SessionSnapshot {
        playbackRequestedAt = now(); defer { playbackRequestedAt = nil } // the resume's first audio counts from here (#357)
        guard var session = currentSession else {
            throw SessionKitError.invalidCommandForState("cancelInterjection")
        }
        // The Margin is in the Library already (#1121). A Cancel now would tell the listener it was not saved.
        if let pending = storedMarginFinish, pending.interjection.sessionId == session.id { throw SessionKitError.invalidCommandForState(Self.marginAlreadyStored) }
        captureResume.takeOverTapPause() // a Cancel that finds the tap's pause still pending resumes below like any other
        removeRecordingDraft() // first: a kill between the two leaves a file nobody recovers, so a Cancel stays cancelled
        try recorder.cancelRecording()
        let returnsToFinished = captureResume.returnsToFinishedSource(targetType: recordingTargetType ?? .item)
        session.phase = captureResume.phase(afterCancellingOn: recordingTargetType ?? .item)
        // Cancellation follows the same exact-resume policy as completion.
        // The captured position is already present in the session.
        recordingAnchor = nil
        recordingTargetType = nil
        recordingTargetId = nil
        recordingReplyTo = nil
        closedRecordingRef = nil
        storedMarginFinish = nil
        if returnsToFinished {
            return try settleFinishedSourceAfterInterjection(session)
        }
        currentSession = session
        try persistSession(session)
        if !resumesSource {
            publish(status: .paused, phase: session.phase)
        } else if externallyStreamedTurnId == session.currentTargetId {
            publish(status: .starting, phase: session.phase)
        } else {
            try playCurrentTarget(session)
            publishPlaybackStart(for: session, phase: session.phase)
        }
        return snapshot
    }

    /// The listener chose to write the Margin they were recording (#1669). The recording is dropped, as Cancel
    /// does, and a written Margin opens at the place the recording was locked to, answering the same shared Margin.
    /// The source follows the written Margin the way it would have followed the spoken one: it plays on after
    /// Save or Cancel, except on a finished source, which stays finished.
    ///
    /// - Parameter resumesSource: false when something else is to play on instead (a Margin's voice the recording
    ///   held, as for `cancelInterjection`): the source stays paused after the written Margin.
    ///
    /// A call that finds no recording to switch changes nothing and the recording, if any, runs on. The same holds
    /// after a Save that closed the recording or stored the Margin and then failed: Save again finishes it (#1713). The recording's
    /// note is removed before the recorder is asked to cancel, as for `cancelInterjection`, so a recorder that won't
    /// cancel throws with the recording still running but no longer journaled.
    @discardableResult
    public func switchRecordingToWrittenInterjection(resumesSource: Bool = true) throws -> WrittenInterjectionCapture {
        guard var session = currentSession,
              session.phase == .recordingInterjection,
              pendingWrittenInterjection == nil,
              let anchor = recordingAnchor,
              let targetType = recordingTargetType,
              let targetId = recordingTargetId else {
            throw SessionKitError.invalidCommandForState("switchRecordingToWrittenInterjection")
        }
        // A Save that closed the recording or stored the Margin and failed a later step (#911, #1121) leaves the
        // recording screen up. Writing instead would drop the recording, or write a second Margin at the place of
        // the stored one, so the listener finishes with Save (#1713).
        if storedMarginFinish != nil || closedRecordingRef != nil {
            throw SessionKitError.invalidCommandForState(Self.marginAlreadyStored)
        }
        let outcome = captureResume.outcome(targetType: targetType, resumesSource: resumesSource)
        let returnsToFinished = outcome == .settleFinished
        let capture = WrittenInterjectionCapture(
            id: UUID().uuidString,
            sessionId: session.id,
            itemId: session.itemId,
            targetType: targetType,
            targetId: targetId,
            anchor: anchor,
            roughPercent: interjectionPercent(for: session, targetType: targetType, targetId: targetId, anchor: anchor),
            wasPlaying: outcome == .resumePlaying,
            replyTo: recordingReplyTo
        )
        removeRecordingDraft() // first, as for Cancel: a kill between the two leaves a file nobody recovers
        try recorder.cancelRecording()
        session.phase = returnsToFinished ? .finished : captureResume.phase(afterCancellingOn: targetType)
        recordingAnchor = nil
        recordingTargetType = nil
        recordingTargetId = nil
        recordingReplyTo = nil
        closedRecordingRef = nil
        storedMarginFinish = nil
        currentSession = session
        try persistSession(session)
        pendingWrittenInterjection = capture
        publish(status: .paused, phase: session.phase)
        return capture
    }

    @discardableResult
    public func generateInterjectionSummary(scope: SummaryScope) throws -> SessionSnapshot {
        try require("generateInterjectionSummary", category: "ai", capabilities: ["summarize_interjections", "defer_ai_jobs"])
        let session = try resolveSession(scope.sessionId)
        lastSummaryCandidates = try selectSummaryCandidates(scope: scope)
        let shouldCall = aiProvider.shouldStartProviderCall(profile: profile, kind: "interjection_summary")
        let status = shouldCall ? "pending" : "deferred"
        let turns = try repository.loadTurns(sessionId: session.id)
        let interjections = try repository.loadInterjections(sessionId: session.id)
        let existingTurn = replacementSummaryTurn(scope: scope, session: session, turns: turns, interjections: interjections)
        if let existingTurn,
           existingTurn.status != "failed",
           existingTurn.status != "failed_partial",
           Set(existingTurn.sourceInterjectionIds) == Set(lastSummaryCandidates.map(\.id)) {
            throw SessionKitError.invalidCommandForState("interjection_summary_already_current")
        }
        let summaryIndex = existingTurn.flatMap { ConversationTurnTitle.sequenceNumber($0.id) } ?? turns.filter { $0.turnType == "interjection_summary" }.count + 1
        let turnId = existingTurn?.id ?? "turn-summary-\(String(format: "%03d", summaryIndex))"
        let turn = ConversationTurn(
            id: turnId,
            sessionId: session.id,
            role: "assistant",
            turnType: "interjection_summary",
            status: status,
            summary: nil,
            text: nil,
            rawText: nil,
            chapters: nil,
            sourceInterjectionIds: lastSummaryCandidates.map(\.id)
        )
        try repository.saveTurn(turn)
        let job = aiJob(id: "job-interjection-summary-\(String(format: "%03d", summaryIndex))", kind: "interjection_summary", session: session, turnId: turn.id, status: status)
        try repository.saveAIJob(job)
        snapshot.pendingAiJobKind = job.kind
        snapshot.pendingAiJobStatus = job.status
        snapshot.providerCallStarted = shouldCall
        snapshot.pendingAiJobCount = try repository.loadAIJobs(sessionId: session.id).filter { $0.status != "complete" }.count
        return snapshot
    }

    private func replacementSummaryTurn(scope: SummaryScope, session: Session, turns: [ConversationTurn], interjections: [Interjection]) -> ConversationTurn? {
        let target = summaryTarget(scope: scope, session: session)
        return turns
            .filter { $0.turnType == "interjection_summary" && summaryTurn($0, matches: target, interjections: interjections) }
            .sorted { $0.id < $1.id }
            .last
    }

    private func summaryTarget(scope: SummaryScope, session: Session) -> (type: InterjectionTargetType, id: String) {
        if scope.targetType == "turn", let turnId = scope.turnId {
            return (.assistantTurn, turnId)
        }
        return (.item, session.itemId)
    }

    private func summaryTurn(
        _ turn: ConversationTurn,
        matches target: (type: InterjectionTargetType, id: String),
        interjections: [Interjection]
    ) -> Bool {
        guard !turn.sourceInterjectionIds.isEmpty else { return false }
        let byId = Dictionary(uniqueKeysWithValues: interjections.map { ($0.id, $0) })
        let sourceInterjections = turn.sourceInterjectionIds.compactMap { byId[$0] }
        guard sourceInterjections.count == turn.sourceInterjectionIds.count,
              sourceInterjections.allSatisfy({ $0.status == "active" }) else { return false }
        switch target.type {
        case .item:
            return sourceInterjections.allSatisfy { $0.targetType == .item && $0.targetId == target.id }
        case .assistantTurn, .summaryTurn:
            return sourceInterjections.allSatisfy { $0.targetType != .item && $0.targetId == target.id }
        }
    }

    @discardableResult
    public func playTurn(turnId: String) throws -> SessionSnapshot {
        playbackRequestedAt = now(); defer { playbackRequestedAt = nil } // time to first audio counts from here (#357)
        try requireNavigationAllowed("playTurn")
        forgetBackTapLanding()
        externallyStreamedTurnId = nil
        var session = try resolveSession(nil)
        let turns = try repository.loadTurns(sessionId: session.id)
        let targetType: TargetType
        let phase: SessionPhase
        if let turn = turns.first(where: { $0.id == turnId }), turn.turnType == "interjection_summary" {
            try require("playTurn", category: "playback", capabilities: ["summary_turn_tts"])
            targetType = .summaryTurnTTS
            phase = .summaryPlayback
        } else {
            try require("playTurn", category: "playback", capabilities: ["assistant_turn_tts"])
            targetType = .assistantTurnTTS
            phase = .aiResponsePlayback
        }
        session.currentTargetType = targetType
        session.currentTargetId = turnId
        session.phase = phase
        session.position = Position(charOffset: 0)
        currentSession = session
        try persistSession(session)
        try playCurrentTarget(session)
        publishPlaybackStart(for: session, phase: phase)
        return snapshot
    }

    /// Makes an incrementally generated turn the canonical interjection target. The
    /// app's streaming queue feeds audio chunks, while SessionEngine remains the
    /// canonical owner of user-visible playback state and position.
    @discardableResult
    public func activateStreamingTurn(turnId: String) throws -> SessionSnapshot {
        playbackRequestedAt = now(); defer { playbackRequestedAt = nil } // time to first audio counts from here (#357)
        var session = try resolveSession(nil)
        let turn = try repository.loadTurns(sessionId: session.id).first(where: { $0.id == turnId })
        let targetType: TargetType = turn?.turnType == "interjection_summary" ? .summaryTurnTTS : .assistantTurnTTS
        let phase: SessionPhase = targetType == .summaryTurnTTS ? .summaryPlayback : .aiResponsePlayback

        if session.currentTargetId != turnId, snapshot.status.isPlaybackActive {
            session = try syncCurrentPositionFromAudio(session)
            try audio.pause()
        }
        externallyStreamedTurnId = turnId
        if session.currentTargetId != turnId || session.currentTargetType != targetType {
            session.currentTargetType = targetType
            session.currentTargetId = turnId
            session.position = Position(charOffset: 0)
        }
        session.phase = phase
        currentSession = session
        try persistSession(session)
        // The streaming queue has only claimed the turn at this point. Its
        // speech client may still be rendering or buffering the first chunk.
        publish(status: .starting, phase: phase)
        return snapshot
    }

    @discardableResult
    public func finishStreamingTurnPlayback(turnId: String) throws -> SessionSnapshot {
        guard var session = currentSession,
              externallyStreamedTurnId == turnId,
              session.currentTargetId == turnId,
              session.currentTargetType == .summaryTurnTTS || session.currentTargetType == .assistantTurnTTS else {
            return snapshot
        }
        let turn = try repository.loadTurns(sessionId: session.id).first(where: { $0.id == turnId })
        let text = turn.map { generatedTurnNavigationText(for: $0) } ?? ""
        session.position.charOffset = text.count
        session.position.chapterId = turn?.chapters?.last?.id
        // The streaming queue uses chunk-scoped target IDs. Clear that completed
        // transport before publishing the turn-scoped terminal snapshot so a
        // final chunk offset cannot make a completed response appear 80–90% done.
        try audio.stop()
        externallyStreamedTurnId = nil
        currentSession = session
        try persistSession(session)
        publish(status: .paused, phase: session.phase)
        return snapshot
    }

    /// Updates the conservative sentence-level cursor supplied by the streaming
    /// speech queue. The canonical audio client must not overwrite this position.
    @discardableResult
    public func updateStreamingTurnPosition(turnId: String, charOffset: Int) throws -> SessionSnapshot {
        guard var session = currentSession,
              externallyStreamedTurnId == turnId,
              session.currentTargetId == turnId,
              session.currentTargetType == .summaryTurnTTS || session.currentTargetType == .assistantTurnTTS else {
            return snapshot
        }
        let turn = try repository.loadTurns(sessionId: session.id).first(where: { $0.id == turnId })
        let turnText = turn.map { generatedTurnNavigationText(for: $0) } ?? ""
        session.position.charOffset = max(0, min(charOffset, turnText.count))
        session.position.chapterId = turn?
            .chapters?
            .last(where: { $0.startChar <= session.position.charOffset })?
            .id
        currentSession = session
        try persistSession(session)
        publish(status: snapshot.status, phase: session.phase)
        return snapshot
    }

    /// Reconciles the observed start of an externally fed speech chunk with the
    /// canonical generated-turn state used by every playback surface.
    @discardableResult
    public func streamingTurnPlaybackStarted(turnId: String, charOffset: Int) throws -> SessionSnapshot {
        _ = try updateStreamingTurnPosition(turnId: turnId, charOffset: charOffset)
        guard let session = currentSession,
              externallyStreamedTurnId == turnId,
              session.currentTargetId == turnId else {
            return snapshot
        }
        publish(status: .playing, phase: session.phase)
        return snapshot
    }

    @discardableResult
    public func jumpToTurnChapter(turnId: String, chapterId: String) throws -> SessionSnapshot {
        stampRequestIfStarting(target: turnId); defer { playbackRequestedAt = nil }
        try requireNavigationAllowed("jumpToTurnChapter")
        forgetBackTapLanding()
        var session = try resolveSession(nil)
        let turns = try repository.loadTurns(sessionId: session.id)
        guard let turn = turns.first(where: { $0.id == turnId }),
              let chapter = turn.chapters?.first(where: { $0.id == chapterId }) else {
            throw SessionKitError.invalidCommandForState("jumpToTurnChapter")
        }
        if turn.turnType == "interjection_summary" {
            try require("jumpToTurnChapter", category: "playback", capabilities: ["summary_turn_tts"])
            session.currentTargetType = .summaryTurnTTS
            session.phase = .summaryPlayback
        } else {
            try require("jumpToTurnChapter", category: "playback", capabilities: ["assistant_turn_tts"])
            session.currentTargetType = .assistantTurnTTS
            session.phase = .aiResponsePlayback
        }
        session.currentTargetId = turnId
        session.position = Position(charOffset: chapter.startChar, chapterId: chapter.id)
        currentSession = session
        try persistSession(session)
        try playCurrentTarget(session)
        publishPlaybackStart(for: session, phase: session.phase)
        return snapshot
    }

    @discardableResult
    public func submitFollowup(text: String) throws -> SessionSnapshot {
        try require("submitFollowup", category: "ai", capabilities: ["continue_discussion", "defer_ai_jobs"])
        var session = try resolveSession(nil)
        session.phase = .conversation
        currentSession = session
        let userTurn = ConversationTurn(
            id: "turn-addendum-\(UUID().uuidString.prefix(8))",
            sessionId: session.id,
            role: "user",
            turnType: "user_response",
            status: "complete",
            summary: nil,
            text: text,
            rawText: text,
            chapters: nil,
            sourceInterjectionIds: []
        )
        try repository.saveTurn(userTurn)
        let shouldCall = aiProvider.shouldStartProviderCall(profile: profile, kind: "assistant_response")
        let status = shouldCall ? "pending" : "deferred"
        let responseIndex = try repository.loadTurns(sessionId: session.id).filter { $0.turnType == "assistant_response" }.count + 1
        let responseTurnId = "turn-response-\(String(format: "%03d", responseIndex))"
        let responseTurn = ConversationTurn(
            id: responseTurnId,
            sessionId: session.id,
            role: "assistant",
            turnType: "assistant_response",
            status: status,
            summary: nil,
            text: nil,
            rawText: nil,
            chapters: nil,
            sourceInterjectionIds: []
        )
        try repository.saveTurn(responseTurn)
        let job = aiJob(id: "job-assistant-response-\(String(format: "%03d", responseIndex))", kind: "assistant_response", session: session, turnId: responseTurn.id, status: status, messages: [text])
        try repository.saveAIJob(job)
        snapshot.lastUserTurnType = userTurn.turnType
        snapshot.pendingAiJobKind = job.kind
        snapshot.pendingAiJobStatus = job.status
        snapshot.providerCallStarted = shouldCall
        publish(status: snapshot.status, phase: .conversation)
        return snapshot
    }

    @discardableResult
    public func importAssistantResponse(text rawText: String, autoPlay: Bool = true) throws -> SessionSnapshot {
        try require("importAssistantResponse", category: "sync", capabilities: ["canonical_persistence"])
        var session = try resolveSession(nil)
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SessionKitError.invalidCommandForState("importAssistantResponse")
        }
        let parsed = parseSectionedResponse(from: trimmed)
        let turns = try repository.loadTurns(sessionId: session.id)
        let responseIndex = turns.filter { $0.turnType == "assistant_response" }.count + 1
        let turn = ConversationTurn(
            id: "turn-response-\(String(format: "%03d", responseIndex))",
            sessionId: session.id,
            role: "assistant",
            turnType: "assistant_response",
            status: "complete",
            summary: parsed.summary,
            text: parsed.response.isEmpty ? trimmed : parsed.response,
            rawText: trimmed,
            chapters: parsed.chapters,
            sourceInterjectionIds: []
        )
        try repository.saveTurn(turn)
        session.phase = .conversation
        currentSession = session
        try persistSession(session)
        snapshot.turnStatus = "complete"
        if autoPlay {
            return try playTurn(turnId: turn.id)
        }
        publish(status: snapshot.status, phase: .conversation)
        return snapshot
    }

    @discardableResult
    /// Settles a provider failure. Without ids it settles the active session's last open job.
    /// A late failure names the `sessionId` and `turnId` it was started for, so it settles
    /// that job and turn even after another session became active (#1469). A turn id that
    /// matches no open job falls back to that session's last open job.
    public func aiProviderFailed(error: String, sessionId: String? = nil, turnId: String? = nil) throws -> SessionSnapshot {
        // A session that was named but is gone is an error, not "the active session".
        if let sessionId, try repository.loadSession(id: sessionId) == nil {
            throw SessionKitError.invalidCommandForState("aiProviderFailed")
        }
        let session = try resolveSession(sessionId)
        var jobs = try repository.loadAIJobs(sessionId: session.id)
        let open = jobs.filter { $0.status == "pending" || $0.status == "deferred" }
        // The job for the named turn; if the caller's turn id is stale, the session's last open job.
        guard var job = open.last(where: { turnId != nil && $0.turnId == turnId }) ?? open.last else {
            throw SessionKitError.invalidCommandForState("aiProviderFailed")
        }
        job.status = "retryable"
        job.lastError = error
        job.attempts = max(1, job.attempts)
        try repository.updateAIJob(job)
        if let turnId = job.turnId,
           var turn = try repository.loadTurns(sessionId: session.id).first(where: { $0.id == turnId }) {
            let hasPartialContent = turn.rawText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || turn.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            turn.status = hasPartialContent ? "failed_partial" : "failed"
            try repository.saveTurn(turn)
        }
        // The snapshot describes the active session; another session's failure leaves it alone.
        guard session.id == currentSession?.id else { return snapshot }
        snapshot.pendingAiJobKind = job.kind
        snapshot.pendingAiJobStatus = job.status
        snapshot.lastFailure = "ai_provider_unreachable"
        snapshot.turnStatus = "failed"
        jobs = try repository.loadAIJobs(sessionId: session.id)
        snapshot.pendingAiJobCount = jobs.filter { $0.status != "complete" }.count
        return snapshot
    }

    @discardableResult
    public func retryAIJob(jobId: String) throws -> SessionSnapshot {
        let session = try resolveSession(nil)
        guard var job = try repository.loadAIJobs(sessionId: session.id).first(where: { $0.id == jobId }) else {
            throw SessionKitError.invalidCommandForState("retryAiJob")
        }
        job.status = "pending"
        job.attempts += 1
        try repository.updateAIJob(job)
        if let turnId = job.turnId {
            streamingBuffers[turnId] = ""
            spokenPrefixes[turnId] = 0
            var turns = try repository.loadTurns(sessionId: session.id)
            if let idx = turns.firstIndex(where: { $0.id == turnId }) {
                turns[idx].status = "streaming"
                try repository.saveTurn(turns[idx])
            }
        }
        snapshot.pendingAiJobKind = job.kind
        snapshot.pendingAiJobStatus = job.status
        snapshot.turnStatus = "streaming"
        return snapshot
    }

    public func localSummaryRequestOrigin(itemId: String, turnId: String) throws -> LocalSummaryRequestOrigin {
        try LocalSummaryRequestOrigin(repository: repository, snapshot: snapshot, itemId: itemId, turnId: turnId)
    }

    /// Local summaries arrive as one complete response, not a stream belonging to whichever session is now open.
    @discardableResult
    public func completeLocalSummary(origin: LocalSummaryRequestOrigin, content: String) throws -> SessionSnapshot {
        let parsed = parseSectionedResponse(from: content)
        try origin.save(repository: repository, rawText: content, text: parsed.response,
                        summary: parsed.summary, chapters: parsed.chapters)
        guard origin.matchesPlayback(snapshot) else { return snapshot }
        snapshot.turnStatus = "complete"
        snapshot.pendingAiJobCount = try repository.loadAIJobs(sessionId: origin.sessionId).filter { $0.status != "complete" }.count
        snapshot.spokenUnits = sentenceUnits(in: parsed.response, includeTrailingFragment: true)
        let phase = snapshot.status.isPlaybackActive && rawAudioTextOffset() != nil
            ? currentSession?.phase ?? snapshot.phase : .interjectionSummary
        publish(status: snapshot.status, phase: phase)
        return snapshot
    }

    @discardableResult
    public func aiStreamDelta(turnId: String, content: String) throws -> SessionSnapshot {
        let session = try resolveSession(nil)
        let previous = streamingBuffers[turnId] ?? ""
        let combined = previous + content
        streamingBuffers[turnId] = combined
        let parsed = parseSectionedResponse(from: combined)
        let text = parsed.response
        let alreadySpoken = spokenPrefixes[turnId] ?? 0
        let completeUnits = completeSentenceUnits(in: text)
        let unitsToSpeak = completeUnits.dropFirst(alreadySpoken)
        spokenPrefixes[turnId] = completeUnits.count
        var turn = try repository.loadTurns(sessionId: session.id).first(where: { $0.id == turnId }) ?? ConversationTurn(
            id: turnId,
            sessionId: session.id,
            role: "assistant",
            turnType: "assistant_response",
            status: "streaming",
            summary: nil,
            text: nil,
            rawText: nil,
            chapters: nil,
            sourceInterjectionIds: []
        )
        turn.status = "streaming"
        turn.summary = parsed.summary
        turn.text = text
        turn.rawText = combined
        try repository.saveTurn(turn)
        snapshot.turnStatus = "streaming"
        snapshot.spokenUnits = Array(unitsToSpeak)
        return snapshot
    }

    @discardableResult
    public func aiJobCompleted(turnId: String) throws -> SessionSnapshot {
        let session = try resolveSession(nil)
        var turns = try repository.loadTurns(sessionId: session.id)
        var turn = turns.first(where: { $0.id == turnId }) ?? ConversationTurn(
            id: turnId,
            sessionId: session.id,
            role: "assistant",
            turnType: turnId.contains("summary") ? "interjection_summary" : "assistant_response",
            status: "complete",
            summary: nil,
            text: nil,
            rawText: nil,
            chapters: nil,
            sourceInterjectionIds: []
        )
        turn.status = "complete"
        let parsed = parseSectionedResponse(from: turn.rawText ?? "")
        if turn.summary == nil || turn.summary?.isEmpty == true {
            turn.summary = parsed.summary
        }
        if turn.text == nil {
            turn.text = parsed.response
            if turn.text?.isEmpty != false {
                turn.text = turn.turnType == "interjection_summary" ? "Summary ready." : "AI response ready."
            }
        }
        if turn.chapters == nil || turn.chapters?.isEmpty == true {
            turn.chapters = parsed.chapters
        }
        let allSpeechUnits = sentenceUnits(in: parsed.response, includeTrailingFragment: true)
        let alreadySpoken = spokenPrefixes[turnId] ?? 0
        snapshot.spokenUnits = Array(allSpeechUnits.dropFirst(alreadySpoken))
        spokenPrefixes[turnId] = allSpeechUnits.count
        streamingBuffers.removeValue(forKey: turnId)
        try repository.saveTurn(turn)
        for var job in try repository.loadAIJobs(sessionId: session.id) where job.turnId == turnId {
            job.status = "complete"
            try repository.updateAIJob(job)
        }
        turns = try repository.loadTurns(sessionId: session.id)
        let pendingJobs = try repository.loadAIJobs(sessionId: session.id).filter { $0.status != "complete" }
        snapshot.turnStatus = "complete"
        snapshot.pendingAiJobCount = pendingJobs.count
        let nextPhase: SessionPhase
        if snapshot.status.isPlaybackActive, rawAudioTextOffset() != nil {
            nextPhase = session.phase
        } else if turn.turnType == "interjection_summary" {
            nextPhase = .interjectionSummary
        } else {
            nextPhase = .conversation
        }
        publish(status: snapshot.status, phase: nextPhase)
        _ = turns
        return snapshot
    }

    @discardableResult
    public func aiChaptersCompleted(turnId: String, chapters: [Chapter]) throws -> SessionSnapshot {
        let session = try resolveSession(nil)
        guard var turn = try repository.loadTurns(sessionId: session.id).first(where: { $0.id == turnId }) else {
            throw SessionKitError.invalidCommandForState("aiChaptersCompleted")
        }
        turn.chapters = chapters.sorted { $0.startChar < $1.startChar }
        try repository.saveTurn(turn)
        return snapshot
    }

    @discardableResult
    public func transcriptionCompleted(interjectionId: String, sessionId: String? = nil, transcript: String) throws -> SessionSnapshot {
        guard !transcriptWasDeleted(interjectionId, sessionId) else { return snapshot }
        try updateInterjection(interjectionId, sessionId: sessionId) { interjection in
            interjection.transcript = transcript
            interjection.alignedTranscript = nil
            interjection.transcriptionStatus = "transcribed"
            interjection.cleanedTranscript = nil
            interjection.displayText = transcript
        }
        return snapshot
    }

    @discardableResult
    public func transcriptionCompleted(
        interjectionId: String,
        sessionId: String? = nil,
        alignedTranscript: AlignedInterjectionTranscript
    ) throws -> SessionSnapshot {
        guard !transcriptWasDeleted(interjectionId, sessionId) else { return snapshot }
        try updateInterjection(interjectionId, sessionId: sessionId) { interjection in
            interjection.transcript = alignedTranscript.text
            interjection.alignedTranscript = alignedTranscript
            interjection.transcriptionStatus = "transcribed"
            interjection.cleanedTranscript = nil
            interjection.displayText = alignedTranscript.text
        }
        return snapshot
    }

    @discardableResult
    public func podcastAnchorEvidenceCompleted(
        interjectionId: String,
        sessionId: String? = nil,
        evidence: [CapturedPodcastAnchorEvidence],
        sourceExactEditionSHA256: String?
    ) throws -> SessionSnapshot {
        try updateInterjection(interjectionId, sessionId: sessionId) { interjection in
            interjection.podcastAnchorEvidence = evidence
            interjection.sourceExactEditionSHA256 = sourceExactEditionSHA256
            interjection.podcastAnchorEvidenceCaptureStatus = .ready
        }
        return snapshot
    }

    @discardableResult
    public func podcastAnchorEvidenceFailed(
        interjectionId: String,
        sessionId: String? = nil,
        reason: String
    ) throws -> SessionSnapshot {
        try updateInterjection(interjectionId, sessionId: sessionId) { interjection in
            interjection.podcastAnchorEvidenceCaptureStatus = .unavailable
            interjection.podcastAnchorEvidenceFailureReason = PodcastAnchorCaptureDiagnostics.appendingFailureReason(
                reason,
                to: interjection.podcastAnchorEvidenceFailureReason
            )
        }
        return snapshot
    }

    @discardableResult
    public func transcriptionFailed(interjectionId: String, sessionId: String? = nil, error: String) throws -> SessionSnapshot {
        try updateInterjection(interjectionId, sessionId: sessionId) { interjection in
            // The status says the transcript failed. displayText is the listener's
            // own words, so it stays as it was: nil for a new Margin, or the text a
            // Margin already had when a retry fails (#304).
            interjection.transcriptionStatus = "failed"
        }
        snapshot.lastFailure = "transcription_failed:\(error)"
        return snapshot
    }

    /// Transcription of this Margin was asked for again (Retry), so a transcript the listener deleted earlier may be
    /// replaced by this new work (#942).
    public func transcriptionRequested(interjectionId: String, sessionId: String? = nil) {
        transcriptsDeletedSinceRequest.remove(Self.transcriptKey(interjectionId, sessionId))
    }

    private func transcriptWasDeleted(_ interjectionId: String, _ sessionId: String?) -> Bool {
        transcriptsDeletedSinceRequest.contains(Self.transcriptKey(interjectionId, sessionId))
    }

    private static func transcriptKey(_ interjectionId: String, _ sessionId: String?) -> String {
        "\(sessionId ?? "")|\(interjectionId)"
    }

    /// A retry of a Margin's transcription failed. A Margin that already has words keeps them and its status. One
    /// still "pending" (saved, never transcribed) is settled as failed, so it doesn't claim work that has ended (#942).
    @discardableResult
    public func transcriptionRetryFailed(interjectionId: String, sessionId: String? = nil, error: String) throws -> SessionSnapshot {
        if let sessionId,
           let stored = try loadInterjection(interjectionId, inSession: sessionId),
           stored.transcriptionStatus != "pending" {
            return snapshot
        }
        try updateInterjection(interjectionId, sessionId: sessionId) { interjection in
            if interjection.transcriptionStatus == "pending" { interjection.transcriptionStatus = "failed" }
        }
        return snapshot
    }

    @discardableResult
    public func sourceWindowContextCompleted(interjectionId: String, sessionId: String? = nil, timeline: TranscriptTimeline) throws -> SessionSnapshot {
        let normalized = normalizedSourceTranscriptTimeline(timeline).timeline
        guard !normalized.segments.isEmpty else {
            return try sourceWindowContextUnavailable(interjectionId: interjectionId, sessionId: sessionId)
        }
        try updateInterjection(interjectionId, sessionId: sessionId) { interjection in
            let mediaTimeMs = interjection.anchor.mediaTimeMs ?? 0
            let resolved = MediaTimelineAnchorResolver.resolve(
                mediaTimeMs: mediaTimeMs,
                timeline: normalized,
                playbackRateObserved: interjection.anchor.playbackRateObserved
            )
            let context = SourceAnchorContextResolver.resolve(mediaTimeMs: mediaTimeMs, timeline: normalized)
            interjection.anchor.mediaTimeMs = resolved.mediaTimeMs
            interjection.anchor.playbackRateObserved = resolved.playbackRateObserved
            if let context {
                interjection.anchor.anchorType = .transcript
                interjection.anchor.startChar = context.startChar
                interjection.anchor.endChar = context.endChar
                interjection.anchor.anchorBefore = context.anchorBefore
                interjection.anchor.anchorAfter = context.anchorAfter
                interjection.anchor.transcriptSegmentId = context.transcriptSegmentId
                interjection.anchorContextStatus = .ready
            } else {
                interjection.anchor.anchorType = .media
                interjection.anchor.startChar = resolved.startChar
                interjection.anchor.endChar = resolved.endChar
                interjection.anchor.anchorBefore = ""
                interjection.anchor.anchorAfter = ""
                interjection.anchor.transcriptSegmentId = nil
                interjection.anchorContextStatus = .unavailable
            }
        }
        return snapshot
    }

    @discardableResult
    public func sourceWindowContextUnavailable(interjectionId: String, sessionId: String? = nil) throws -> SessionSnapshot {
        try updateInterjection(interjectionId, sessionId: sessionId) { interjection in
            interjection.anchorContextStatus = .unavailable
        }
        return snapshot
    }

    @discardableResult
    public func sourceWindowContextPending(interjectionId: String, sessionId: String? = nil) throws -> SessionSnapshot {
        try updateInterjection(interjectionId, sessionId: sessionId) { interjection in
            interjection.anchorContextStatus = .pending
        }
        return snapshot
    }

    @discardableResult
    public func cleanupCompleted(interjectionId: String, sessionId: String? = nil, cleanedTranscript: String) throws -> SessionSnapshot {
        guard !transcriptWasDeleted(interjectionId, sessionId) else { return snapshot }
        try updateInterjection(interjectionId, sessionId: sessionId) { interjection in
            interjection.cleanedTranscript = cleanedTranscript
            interjection.displayText = cleanedTranscript
        }
        return snapshot
    }

    @discardableResult
    public func deleteRepresentation(interjectionId: String, sessionId: String? = nil, representation: String) throws -> SessionSnapshot {
        if representation == "transcript" { transcriptsDeletedSinceRequest.insert(Self.transcriptKey(interjectionId, sessionId)) }
        try updateInterjection(interjectionId, sessionId: sessionId) { interjection in
            if representation == "cleanedTranscript" {
                interjection.cleanedTranscript = nil
                interjection.displayText = interjection.transcript
            } else if representation == "transcript" {
                interjection.transcript = nil
                interjection.alignedTranscript = nil
                interjection.cleanedTranscript = nil
                interjection.displayText = nil
                // "pending" would promise a transcription no one is doing (#942). "failed" is stored so Build 29
                // still opens the row; the app words it as a retry and Retry stays available while audio exists.
                interjection.transcriptionStatus = "failed"
            }
        }
        return snapshot
    }

    @discardableResult
    public func deleteInterjection(interjectionId: String, sessionId: String? = nil) throws -> SessionSnapshot {
        try updateInterjection(interjectionId, sessionId: sessionId) { interjection in
            interjection.status = "deleted"
        }
        publish(status: snapshot.status, phase: snapshot.phase)
        return snapshot
    }

    /// Brings back a Margin `deleteInterjection` hid, for the Undo on the "Deleted Margin" banner (#1981). Deleting
    /// only sets the status, so the words, the recording, the place and the order were never touched. A Margin that
    /// isn't deleted is left as it is, so a second Undo does nothing.
    @discardableResult
    public func restoreInterjection(interjectionId: String, sessionId: String? = nil) throws -> SessionSnapshot {
        try updateInterjection(interjectionId, sessionId: sessionId) { interjection in
            if interjection.status == "deleted" { interjection.status = "active" }
        }
        publish(status: snapshot.status, phase: snapshot.phase)
        return snapshot
    }

    /// Stops caller-owned inline audio before closing the source, even if teardown fails.
    /// The callback must cancel playback without resuming the source (#651).
    @discardableResult
    public func endSession(stoppingInlinePlayback: () -> Void = {}) throws -> SessionSnapshot {
        stoppingInlinePlayback()
        guard var session = currentSession else {
            throw SessionKitError.invalidCommandForState("endSession")
        }
        let sourceWasComplete = session.completionPercent >= 100
        let targetWasComplete = audio.isPlaybackComplete(targetId: session.currentTargetId)
        // Inspecting completed history does not load that session into the audio
        // adapter. Its idle/stale position must not rewrite the completed record.
        if session.phase != .finished || !sourceWasComplete {
            session = try syncCurrentPositionFromAudio(session)
        }
        if targetWasComplete {
            switch session.currentTargetType {
            case .itemTextTTS, .transcriptBackedMedia, .browserOwnedMedia:
                session = markPlaybackComplete(session, item: currentItem)
            case .summaryTurnTTS, .assistantTurnTTS:
                if sourceWasComplete {
                    session.completionPercent = 100
                    session.phase = .finished
                    session.status = "finished"
                }
            }
        }
        try audio.stop()
        if session.phase == .finished, session.completionPercent >= 100 {
            session.status = "finished"
        } else {
            session.status = "in_progress"
        }
        if session.phase == .finished, session.completionPercent < 100 {
            session.phase = .itemPlayback
        }
        currentSession = session
        try persistSession(session)
        currentSession = nil
        publisherPlayback.removeAll()
        transcriptTimelineCache = nil
        currentItem = nil
        currentMap = nil
        recordingAnchor = nil
        recordingTargetType = nil
        recordingTargetId = nil
        recordingReplyTo = nil
        closedRecordingRef = nil
        storedMarginFinish = nil
        captureResume.sessionEnded()
        // A protected position belongs to the session that just ended. Left set, it would
        // pin a replay of the same target to this session's end until playback confirms.
        protectedPosition.release()
        externallyStreamedTurnId = nil
        streamingBuffers.removeAll()
        spokenPrefixes.removeAll()
        startAttempt.clear()
        snapshot = SessionSnapshot()
        return snapshot
    }

    @discardableResult
    public func selectSummaryCandidates(scope: SummaryScope) throws -> [Interjection] {
        let session = try resolveSession(scope.sessionId)
        let all = try repository.loadInterjections(sessionId: scope.sessionId ?? session.id)
            .filter { $0.status == "active" }
        if let explicit = scope.interjectionIds {
            lastSummaryCandidates = all.filter { explicit.contains($0.id) }
        } else if scope.targetType == "turn", let turnId = scope.turnId {
            lastSummaryCandidates = all.filter { $0.targetId == turnId && $0.targetType != .item }
        } else {
            lastSummaryCandidates = all.filter { $0.targetType == .item }
        }
        return lastSummaryCandidates
    }

    public func hasSummaryCandidates(scope: SummaryScope) -> Bool {
        guard let candidates = try? summaryCandidates(scope: scope),
              !candidates.isEmpty,
              let session = try? summarySession(scope.sessionId),
              let turns = try? repository.loadTurns(sessionId: session.id),
              let interjections = try? repository.loadInterjections(sessionId: session.id) else {
            return false
        }
        guard let existingTurn = replacementSummaryTurn(scope: scope, session: session, turns: turns, interjections: interjections) else {
            return true
        }
        if existingTurn.status == "failed" || existingTurn.status == "failed_partial" {
            return true
        }
        return Set(existingTurn.sourceInterjectionIds) != Set(candidates.map(\.id))
    }

    private func summaryCandidates(scope: SummaryScope) throws -> [Interjection] {
        let session = try summarySession(scope.sessionId)
        let all = try repository.loadInterjections(sessionId: scope.sessionId ?? session.id)
            .filter { $0.status == "active" }
        if let explicit = scope.interjectionIds {
            return all.filter { explicit.contains($0.id) }
        }
        if scope.targetType == "turn", let turnId = scope.turnId {
            return all.filter { $0.targetId == turnId && $0.targetType != .item }
        }
        return all.filter { $0.targetType == .item }
    }

    private func summarySession(_ sessionId: String?) throws -> Session {
        if let sessionId, let loaded = try repository.loadSession(id: sessionId) {
            return loaded
        }
        if let currentSession {
            return currentSession
        }
        throw SessionKitError.invalidCommandForState("selectSummaryCandidates")
    }

    /// The stored session, for dating its Margins as the notes folder does (`Interjection.recordedAt(in:)`, #624).
    public func loadSession(id: String) throws -> Session? {
        try repository.loadSession(id: id)
    }

    @discardableResult
    public func buildExport(options: ExportOptions) throws -> SessionExport {
        try buildExport(options: options, source: try loadExportSource(sessionId: options.sessionId))
    }

    /// What an export reads before it shapes anything: the session, its item (with the whole text), the item's
    /// transcript timeline (megabytes for a podcast), and the session's Margins and turns. Exporting N Margins of
    /// one session reads this once (#2508) instead of once per Margin. The timeline is read on first use (#2506):
    /// only a recording's context, the full source text or the Listening Map's length need it, so an article's
    /// export never decodes one.
    struct ExportSource {
        var session: Session
        var item: Item
        var sourceTimeline: LazyTimeline
        var allInterjections: [Interjection]
        var allTurns: [ConversationTurn]
        /// Read beforehand, off the main thread (#2505); nil means "read it when the export needs it".
        var listeningMap: ListeningMap?? = nil
        var pageDocument: StructuredDocument?? = nil
    }

    /// What `buildExportReadingOffMain` reads on a background thread: everything the export would otherwise read
    /// from the store while it shapes the document. `nil` fields were not needed by the options asked for.
    struct ExportInputs: Sendable {
        var session: Session
        var item: Item
        var allInterjections: [Interjection]
        var allTurns: [ConversationTurn]
        var timeline: TranscriptTimeline??
        var listeningMap: ListeningMap??
        var pageDocument: StructuredDocument??
    }

    /// The export the Export screen shows, with its store reads off the main thread (#2505): the item's whole text,
    /// the session's Margins and turns, and, when the options use them, the transcript timeline (megabytes for a
    /// podcast), the Listening Map and a paper's structured document. Only the shaping runs on the caller's thread,
    /// and its result is what `buildExport(options:)` gives. Without a stored session id it is `buildExport(options:)`.
    @MainActor
    public func buildExportReadingOffMain(options: ExportOptions) async throws -> SessionExport {
        guard let sessionId = options.sessionId else { return try buildExport(options: options) }
        let repository = repository
        let includeFullText = options.includeFullText, includeListeningMap = options.includeListeningMap
        // Named type, not `Self`: capturing the dynamic `Self` in a detached closure makes Swift 6.2.4 on Linux fail with
        // "pattern that the region based isolation checker does not understand"; macOS accepts both.
        let inputs = try await Task.detached(priority: .userInitiated) {
            try SessionEngine.readExportInputs(sessionId: sessionId, includeFullText: includeFullText,
                                               includeListeningMap: includeListeningMap, repository: repository)
        }.value
        guard let inputs else { return try buildExport(options: options) } // not stored: the engine's own session
        let itemId = inputs.item.id
        let sourceTimeline = inputs.timeline.map { timeline in LazyTimeline { timeline } }
            ?? LazyTimeline { [repository] in try repository.loadTranscriptTimeline(itemId: itemId)?.timeline }
        return try buildExport(options: options, source: ExportSource(
            session: inputs.session, item: inputs.item, sourceTimeline: sourceTimeline,
            allInterjections: inputs.allInterjections, allTurns: inputs.allTurns,
            listeningMap: inputs.listeningMap, pageDocument: inputs.pageDocument))
    }

    /// The reads `loadExportSource` and `buildExport(options:source:)` make, done ahead in one go. The timeline is
    /// read when any export these options could shape needs it: a superset of `buildExport`'s own test, since the
    /// Margins' scope isn't applied yet. nil when the session isn't stored.
    nonisolated static func readExportInputs(
        sessionId: String, includeFullText: Bool, includeListeningMap: Bool, repository: SessionRepository
    ) throws -> ExportInputs? {
        guard let session = try repository.loadSession(id: sessionId) else { return nil }
        let item = try repository.loadItem(id: session.itemId)
        let interjections = try activeExportInterjections(repository.loadInterjections(sessionId: session.id))
        let turns = try exportTurns(repository.loadTurns(sessionId: session.id), activeInterjections: interjections)
        let needsTimeline = includeFullText || includeListeningMap
            || (isNativeAudioSource(item) && interjections.contains { $0.targetType == .item && $0.anchor.mediaTimeMs != nil })
        let timeline: TranscriptTimeline?? = needsTimeline ? .some(try repository.loadTranscriptTimeline(itemId: item.id)?.timeline) : nil
        let map: ListeningMap?? = includeListeningMap
            ? .some(try ListeningMapExportResolver.resolve(item: item, repository: repository, durationMs: timeline??.durationMs))
            : nil
        let pageDocument: StructuredDocument?? = item.documentStructure?.bibliography != nil
            && interjections.contains { $0.targetType == .item }
            ? .some(pageDocument(for: item, repository: repository))
            : nil
        return ExportInputs(session: session, item: item, allInterjections: interjections, allTurns: turns,
                            timeline: timeline, listeningMap: map, pageDocument: pageDocument)
    }

    private nonisolated static func activeExportInterjections(_ all: [Interjection]) -> [Interjection] {
        all.filter { $0.status == "active" }
    }

    /// Turns minus summaries of Margins that are no longer active.
    private nonisolated static func exportTurns(_ all: [ConversationTurn], activeInterjections: [Interjection]) -> [ConversationTurn] {
        let activeInterjectionIDs = Set(activeInterjections.map(\.id))
        return all.filter { turn in
            guard turn.turnType == "interjection_summary", !turn.sourceInterjectionIds.isEmpty else { return true }
            return Set(turn.sourceInterjectionIds).isSubset(of: activeInterjectionIDs)
        }
    }

    private nonisolated static func pageDocument(for item: Item, repository: SessionRepository) -> StructuredDocument? {
        (repository as? StructuredDocumentRepository)
            .flatMap { try? $0.loadStructuredDocument(itemId: item.id) }
            .flatMap { $0.text == item.text ? $0 : nil }
    }

    /// A transcript timeline read at most once, and only when something asks for it.
    final class LazyTimeline {
        private let load: () throws -> TranscriptTimeline?
        private var loaded: TranscriptTimeline??
        /// How many times the store was asked, for a test to pin (#2506).
        private(set) var loads = 0

        init(_ load: @escaping () throws -> TranscriptTimeline?) { self.load = load }

        func value() throws -> TranscriptTimeline? {
            if let loaded { return loaded }
            loads += 1
            let timeline = try load()
            loaded = .some(timeline)
            return timeline
        }
    }

    func loadExportSource(sessionId: String?) throws -> ExportSource {
        let session = try resolveSession(sessionId)
        let item = try repository.loadItem(id: session.itemId)
        let itemId = item.id
        let sourceTimeline = LazyTimeline { [repository] in try repository.loadTranscriptTimeline(itemId: itemId)?.timeline }
        let allInterjections = Self.activeExportInterjections(try repository.loadInterjections(sessionId: session.id))
        let allTurns = Self.exportTurns(try repository.loadTurns(sessionId: session.id), activeInterjections: allInterjections)
        return ExportSource(session: session, item: item, sourceTimeline: sourceTimeline,
                            allInterjections: allInterjections, allTurns: allTurns)
    }

    func buildExport(options: ExportOptions, source: ExportSource) throws -> SessionExport {
        let session = source.session, item = source.item
        let allInterjections = source.allInterjections, allTurns = source.allTurns
        let exposesFullSourceText = options.includeFullText && !Self.isNativeAudioSource(item)
        let interjections = options.includeInterjections ? scopedExportInterjections(options: options, session: session, interjections: allInterjections) : []
        // Read only when this export uses it (#2506): the full text of a transcribed source, the words around a
        // recording's Margins, or the Listening Map's length. An article's Margin note needs none of them.
        let needsTimeline = exposesFullSourceText || options.includeListeningMap
            || (Self.isNativeAudioSource(item) && interjections.contains { $0.targetType == .item && $0.anchor.mediaTimeMs != nil })
        let sourceTimeline = try needsTimeline ? source.sourceTimeline.value() : nil
        let sourceTranscript = exposesFullSourceText
            ? sourceTimeline?.segments
                .sorted { $0.startMs < $1.startMs }
                .map(\.text)
                .joined(separator: " ")
            : nil
        let turns = options.includeTurns ? scopedExportTurns(options: options, turns: allTurns, interjections: interjections) : []
        // The page goes with a paper's citation (#206), so the structured document is only
        // read for an item that has one. Margins anchor into Item.text, so the page is only
        // known when the document's text is exactly that text.
        let pageDocument = interjections.contains { $0.targetType == .item } && item.documentStructure?.bibliography != nil
            ? source.pageDocument ?? exportPageDocument(for: item)
            : nil
        let export = SessionExport(
            item: ExportItem(
                id: item.id,
                title: item.title,
                externalReference: options.includeReference ? ShareableLinkPolicy.shareableLink(item.externalReference) : nil,
                sourceURL: options.includeReference ? ShareableLinkPolicy.shareableLink(item.media?.url) : nil,
                mediaSourceType: item.media?.sourceType.rawValue,
                includedFullText: exposesFullSourceText,
                text: exposesFullSourceText ? item.text : nil,
                sourceTranscript: sourceTranscript,
                author: item.author.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 },
                bibliography: options.includeReference ? item.documentStructure?.bibliography : nil
            ),
            session: ExportSession(id: session.id, status: session.status, completionPercent: session.completionPercent),
            listeningMap: options.includeListeningMap
                ? try source.listeningMap ?? ListeningMapExportResolver.resolve(item: item, repository: repository, durationMs: sourceTimeline?.durationMs)
                : nil,
            turns: turns,
            timeline: exportTimeline(interjections: interjections, turns: turns),
            interjections: interjections.map { interjection in
                let resolvedContext: SourceAnchorContext?
                let shouldResolveNativeContext = Self.isNativeAudioSource(item)
                    && interjection.targetType == .item
                    && interjection.anchor.mediaTimeMs != nil
                    && sourceTimeline != nil
                if shouldResolveNativeContext,
                   interjection.targetType == .item,
                   let mediaTimeMs = interjection.anchor.mediaTimeMs,
                   let sourceTimeline {
                    resolvedContext = SourceAnchorContextResolver.resolve(
                        mediaTimeMs: mediaTimeMs,
                        timeline: sourceTimeline
                    )
                } else {
                    resolvedContext = nil
                }
                let turn = interjection.targetType == .item
                    ? nil
                    : allTurns.first(where: { $0.id == interjection.targetId })
                let turnContext = turn.map {
                    exportTurnAnchorContext(for: interjection.anchor, turn: $0)
                }
                return ExportInterjection(
                    id: interjection.id,
                    sessionId: interjection.sessionId,
                    targetType: interjection.targetType.rawValue,
                    targetId: interjection.targetId,
                    roughPercent: turn.map {
                        percent(
                            for: max(0, min(interjection.anchor.startChar, generatedTurnNavigationText(for: $0).count)),
                            text: generatedTurnNavigationText(for: $0)
                        )
                    } ?? interjection.roughPercent,
                    anchorBefore: shouldResolveNativeContext
                        ? resolvedContext?.anchorBefore ?? ""
                        : turnContext?.before ?? interjection.anchor.anchorBefore,
                    anchorAfter: shouldResolveNativeContext
                        ? resolvedContext?.anchorAfter ?? ""
                        : turnContext?.after ?? interjection.anchor.anchorAfter,
                    mediaTimeMs: interjection.anchor.mediaTimeMs,
                    transcriptionStatus: interjection.transcriptionStatus,
                    transcript: interjection.captureKind == .written
                        ? interjection.transcript
                        : interjection.cleanedTranscript ?? interjection.transcript,
                    audioPath: nil,
                    captureKind: interjection.captureKind,
                    page: interjection.targetType == .item
                        ? pageDocument?.pageNumber(atCharacter: interjection.anchor.startChar)
                        : nil,
                    sourceCharOffset: interjection.targetType == .item ? interjection.anchor.startChar : nil
                )
            }
        )
        lastExport = export
        return export
    }

    private func exportPageDocument(for item: Item) -> StructuredDocument? {
        if let cache = exportPageDocumentCache, cache.itemId == item.id, cache.text == item.text {
            return cache.document
        }
        let document = Self.pageDocument(for: item, repository: repository)
        exportPageDocumentCache = (item.id, item.text, document)
        return document
    }

    private nonisolated static func isNativeAudioSource(_ item: Item) -> Bool {
        switch item.media?.sourceType {
        case .nativeMediaFile, .remoteStream:
            return true
        default:
            return false
        }
    }

    private func scopedExportInterjections(options: ExportOptions, session: Session, interjections: [Interjection]) -> [Interjection] {
        switch options.scope {
        case "original", "source_only":
            return []
        case "source_interjections", "original_with_interjections":
            return interjections.filter { $0.targetType == .item && $0.targetId == session.itemId }
        case "target":
            guard let targetType = options.targetType, let targetId = options.targetId else { return interjections }
            if targetType == InterjectionTargetType.item.rawValue || targetType == TargetType.itemTextTTS.rawValue {
                return interjections.filter { $0.targetType == .item && $0.targetId == targetId }
            }
            return interjections.filter { $0.targetId == targetId && $0.targetType != .item }
        case "selected_interjections":
            guard let ids = options.interjectionIds else { return [] }
            return interjections.filter { ids.contains($0.id) }
        default:
            return interjections
        }
    }

    private func scopedExportTurns(options: ExportOptions, turns: [ConversationTurn], interjections: [Interjection]) -> [ConversationTurn] {
        switch options.scope {
        case "original", "source_only", "source_interjections", "original_with_interjections":
            return []
        case "target":
            guard let targetId = options.targetId else { return turns }
            return turns.filter { $0.id == targetId }
        case "selected_interjections":
            let targetTurnIds = Set(interjections.filter { $0.targetType != .item }.map(\.targetId))
            return turns.filter { targetTurnIds.contains($0.id) }
        default:
            return turns
        }
    }

    public func compactTimelineEntries() -> [CompactTimelineEntry] {
        guard let session = currentSession else { return [] }
        let item = currentItem ?? (try? repository.loadItem(id: session.itemId))
        let map = currentMap ?? (try? repository.loadListeningMap(itemId: session.itemId))
        let sourceChapters = map?.chapters ?? []
        let interjections = ((try? repository.loadInterjections(sessionId: session.id)) ?? [])
            .filter { $0.status != "deleted" }
        let turns = (try? repository.loadTurns(sessionId: session.id)) ?? []

        var entries: [CompactTimelineEntry] = []
        if let overview = map?.overview, !overview.isEmpty {
            entries.append(
                CompactTimelineEntry(
                    id: "source-overview",
                    kind: "overview",
                    title: "Summary",
                    detail: overview,
                    percent: 0,
                    isCurrent: session.currentTargetType == .itemTextTTS && session.position.chapterId == nil
                )
            )
        } else if sourceChapters.isEmpty {
            entries.append(
                CompactTimelineEntry(
                    id: "source-\(session.itemId)",
                    kind: "source_item",
                    title: item?.title ?? "Source",
                    detail: "Source",
                    percent: 0,
                    isCurrent: session.currentTargetType == .itemTextTTS
                )
            )
        }

        let sourceTargetTypes: [TargetType] = [.itemTextTTS, .transcriptBackedMedia, .browserOwnedMedia]
        let sourceEntries = sourceChapters.map { chapter in
            CompactTimelineEntry(
                id: "source-\(chapter.id)",
                kind: "source_chapter",
                title: chapter.title,
                detail: "Source",
                chapterId: chapter.id,
                percent: chapter.percent,
                isCurrent: sourceTargetTypes.contains(session.currentTargetType) && session.position.chapterId == chapter.id
            )
        } + interjections
            .filter { $0.targetType == .item }
            .map { interjection in
                CompactTimelineEntry(
                    id: "interjection-\(interjection.id)",
                    kind: "interjection",
                    title: "Interjection",
                    detail: interjectionPreview(interjection),
                    percent: interjection.roughPercent
                )
            }
        entries.append(contentsOf: sourceEntries.sorted(by: compactTimelineSort))

        for turn in turns {
            let title = turnTitle(for: turn)
            entries.append(
                CompactTimelineEntry(
                    id: "turn-\(turn.id)",
                    kind: turn.turnType,
                    title: title,
                    detail: turn.summary ?? turn.text,
                    turnId: turn.id,
                    isCurrent: session.currentTargetId == turn.id
                )
            )
            entries.append(
                contentsOf: (turn.chapters ?? []).map { chapter in
                    CompactTimelineEntry(
                        id: "turn-\(turn.id)-\(chapter.id)",
                        kind: "turn_chapter",
                        title: chapter.title,
                        detail: title,
                        chapterId: chapter.id,
                        turnId: turn.id,
                        percent: chapter.percent,
                        isCurrent: session.currentTargetId == turn.id && session.position.chapterId == chapter.id
                    )
                }
            )
            entries.append(
                contentsOf: interjections
                    .filter { $0.targetId == turn.id && $0.targetType != .item }
                    .map { interjection in
                        CompactTimelineEntry(
                            id: "interjection-\(interjection.id)",
                            kind: "interjection",
                            title: "Interjection",
                            detail: interjectionPreview(interjection),
                            turnId: turn.id
                        )
                    }
            )
        }

        let turnIds = Set(turns.map(\.id))
        entries.append(
            contentsOf: interjections
                .filter { $0.targetType != .item && !turnIds.contains($0.targetId) }
                .map { interjection in
                    CompactTimelineEntry(
                        id: "interjection-\(interjection.id)",
                        kind: "interjection",
                        title: "Interjection",
                        detail: interjectionPreview(interjection)
                    )
                }
        )

        return entries
    }

    private func compactTimelineSort(_ lhs: CompactTimelineEntry, _ rhs: CompactTimelineEntry) -> Bool {
        let lhsPercent = lhs.percent ?? 101
        let rhsPercent = rhs.percent ?? 101
        if lhsPercent == rhsPercent {
            return compactTimelineSortRank(lhs.kind) < compactTimelineSortRank(rhs.kind)
        }
        return lhsPercent < rhsPercent
    }

    private func compactTimelineSortRank(_ kind: String) -> Int {
        switch kind {
        case "source_item": return -2
        case "overview": return -1
        case "source_chapter": return 0
        case "interjection": return 1
        case "user_response", "interjection_summary", "assistant_response": return 2
        case "turn_chapter": return 3
        default: return 4
        }
    }

    private func interjectionPreview(_ interjection: Interjection) -> String? {
        let text = (interjection.displayText ?? interjection.cleanedTranscript ?? interjection.transcript ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(80))
    }

    private func exportTimeline(interjections: [Interjection], turns: [ConversationTurn]) -> [ExportTimelineEntry] {
        let sourceInterjections = interjections.filter { $0.targetType == .item }.map {
            ExportTimelineEntry(type: "interjection", interjectionId: $0.id, turnId: nil, targetType: $0.targetType.rawValue, targetId: $0.targetId, percent: $0.roughPercent, chapterId: nil)
        }
        let exportedTurnIds = Set(turns.map(\.id))
        let turnEntries = turns.flatMap { turn -> [ExportTimelineEntry] in
            let base = ExportTimelineEntry(type: "ai_turn", interjectionId: nil, turnId: turn.id, targetType: nil, targetId: nil, percent: nil, chapterId: nil)
            let chapters = (turn.chapters ?? []).map {
                ExportTimelineEntry(type: "ai_turn_chapter", interjectionId: nil, turnId: turn.id, targetType: nil, targetId: nil, percent: $0.percent, chapterId: $0.id)
            }
            let turnInterjections = interjections.filter { $0.targetId == turn.id && $0.targetType != .item }.map {
                ExportTimelineEntry(type: "interjection", interjectionId: $0.id, turnId: nil, targetType: $0.targetType.rawValue, targetId: $0.targetId, percent: $0.roughPercent, chapterId: nil)
            }
            return [base] + chapters + turnInterjections
        }
        let orphanedTurnInterjections = interjections
            .filter { $0.targetType != .item && !exportedTurnIds.contains($0.targetId) }
            .map {
                ExportTimelineEntry(type: "interjection", interjectionId: $0.id, turnId: nil, targetType: $0.targetType.rawValue, targetId: $0.targetId, percent: $0.roughPercent, chapterId: nil)
            }
        return sourceInterjections + turnEntries + orphanedTurnInterjections
    }

    public func diagnostics() throws -> [String: String] {
        let sessionId = currentSession?.id ?? "none"
        return [
            "runtimeProfile": profile.id,
            "providerStatus": profile.has("ai", "provider_diagnostics") ? "available" : "unavailable",
            "pendingAiJobs": "\(try currentSession.map { try repository.loadAIJobs(sessionId: $0.id).filter { $0.status != "complete" }.count } ?? 0)",
            "recentFailure": snapshot.lastFailure ?? "none",
            "lastMarginRejoin": lastMarginRejoin ?? "none",
            "lastBackwardPositionWrite": lastBackwardPositionWrite ?? "none",
            "sessionId": sessionId
        ]
    }

    private func playbackTargetType(for item: Item) -> TargetType {
        if item.mediaType == TargetType.transcriptBackedMedia.rawValue || item.media?.url != nil {
            return .transcriptBackedMedia
        }
        if item.mediaType == TargetType.browserOwnedMedia.rawValue {
            return .browserOwnedMedia
        }
        return .itemTextTTS
    }

    private func prepareGeneratedTextAudioIfAvailable(for item: Item) throws -> Item {
        guard shouldPrepareGeneratedTextAudio(for: item),
              let textAudio,
              let sourceText = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sourceText.isEmpty else {
            return item
        }
        guard let prepared = try textAudio.prepareTextAudio(itemId: item.id, title: item.title, text: sourceText) else {
            return item
        }
        do { return try applyPreparedTextAudio(prepared, to: item) }
        catch SessionKitError.invalidCommandForState("applyPreparedTextAudio:source_text_changed") {
            return try repository.loadItem(id: item.id)
        }
    }

    /// Prepared narration is cache-backed. If iOS purges that cache, the text item
    /// remains playable through live speech and can be rendered again in the
    /// background instead of handing AVPlayer a permanently missing file URL.
    private func discardUnavailableGeneratedTextAudio(from item: Item) throws -> Item {
        guard PreparedNarrationFallback.isMissing(item.media) else {
            return item
        }
        let repair = { () throws -> Item in
            var current = try self.repository.loadItem(id: item.id)
            if PreparedNarrationFallback.isMissing(current.media) {
                current.media = nil
                try self.saveItem(current)
                try PreparedNarrationFallback.markPreparedAudioForRepreparation(itemId: item.id, repository: self.repository)
            }
            return current
        }
        if let store = repository as? any SessionRepositoryTransaction { return try store.withSessionTransaction(repair) }
        return try repair()
    }

    private func applyPreparedTextAudio(_ prepared: PreparedTextAudio, to item: Item) throws -> Item {
        let write = { () throws -> Item in
            let stored = try self.repository.loadItem(id: item.id)
            guard stored.deletedAt == nil, stored.text == item.text,
                  Self.preparedAudioMatches(prepared, item: stored) else {
                throw SessionKitError.invalidCommandForState("applyPreparedTextAudio:source_text_changed")
            }
            return try self.writePreparedTextAudio(prepared, to: stored)
        }
        if let store = repository as? any SessionRepositoryTransaction { return try store.withSessionTransaction(write) }
        return try write()
    }

    private static func preparedAudioMatches(_ prepared: PreparedTextAudio, item: Item) -> Bool {
        let text = item.text ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let projected = SpeechTextNormalizer.projectForSystemSpeech(trimmed).text
        return prepared.normalizedText == text || prepared.normalizedText == trimmed
            || SpeechTextNormalizer.projectForSystemSpeech(prepared.normalizedText).text == projected
    }

    private func writePreparedTextAudio(_ prepared: PreparedTextAudio, to item: Item) throws -> Item {
        let transcriptId = item.transcriptId ?? "generated-transcript-\(item.id)"
        let map = currentMap?.itemId == item.id ? currentMap : (try? repository.loadListeningMap(itemId: item.id))
        let timeline = generatedTextTimeline(prepared.timeline, using: map)
        let stored = SourceTranscriptTimeline(
            id: transcriptId,
            itemId: item.id,
            createdAt: prepared.createdAt,
            timeline: timeline
        )
        try repository.saveTranscriptTimeline(stored)
        var updated = item
        updated.text = prepared.normalizedText
        updated.media = prepared.media
        updated.transcriptId = transcriptId
        if updated.status == "ready" || updated.status == "needs_listening_map" {
            updated.status = currentMap == nil ? "needs_listening_map" : "ready"
        }
        try saveItem(updated)
        return updated
    }

    private func shouldPrepareGeneratedTextAudio(for item: Item) -> Bool {
        guard profile.has("playback", "prerendered_audio") else { return false }
        guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return false }
        if item.mediaType == TargetType.transcriptBackedMedia.rawValue {
            return item.media?.sourceType == .generatedTTSPrerendered
        }
        if item.mediaType == TargetType.browserOwnedMedia.rawValue {
            return false
        }
        switch item.media?.sourceType {
        case .none, .some(.generatedTTSRealtime), .some(.generatedTTSPrerendered):
            return true
        case .some(.nativeMediaFile), .some(.browserOwnedMedia), .some(.remoteStream):
            return false
        }
    }

    private func generatedTextTimeline(_ timeline: TranscriptTimeline, using map: ListeningMap?) -> TranscriptTimeline {
        guard let map, !map.chapters.isEmpty, !timeline.segments.isEmpty else {
            return timeline
        }
        let chapters = map.chapters.compactMap { chapter -> MediaTimelineChapter? in
            guard let segment = timeline.segments.last(where: { ($0.startChar ?? 0) <= chapter.startChar })
                    ?? timeline.segments.first else {
                return nil
            }
            return MediaTimelineChapter(
                id: chapter.id,
                title: chapter.title,
                startMs: segment.startMs,
                transcriptSegmentId: segment.id
            )
        }
        guard !chapters.isEmpty else { return timeline }
        return TranscriptTimeline(
            segments: timeline.segments,
            chapters: chapters,
            durationMs: timeline.durationMs
        )
    }

    private func itemPlaybackTargetId(for item: Item, targetType: TargetType) -> String {
        guard targetType == .transcriptBackedMedia || targetType == .browserOwnedMedia else {
            return item.id
        }
        return item.media?.nativeMediaId ?? item.media?.url ?? item.id
    }

    private func sourceTranscriptTimeline(itemId: String) -> TranscriptTimeline? {
        if let publisher = publisherPlayback[itemId] { return publisher.timeline }
        return storedTranscriptTimeline(itemId: itemId)
    }

    /// The item's stored transcript timeline, decoded again only when its stamp moves.
    private func storedTranscriptTimeline(itemId: String) -> TranscriptTimeline? {
        // The stamp is read first: a save between the two reads leaves a newer timeline under an older stamp, which
        // the next call reads again; it can never leave an older timeline under a newer stamp.
        guard let stamp = (try? repository.transcriptTimelineStamp(itemId: itemId)) ?? nil else {
            transcriptTimelineCache = nil
            return try? repository.loadTranscriptTimeline(itemId: itemId)?.timeline
        }
        if let cached = transcriptTimelineCache, cached.itemId == itemId, cached.stamp == stamp { return cached.timeline }
        guard let timeline = (try? repository.loadTranscriptTimeline(itemId: itemId))?.timeline else { return nil }
        transcriptTimelineCache = (itemId: itemId, stamp: stamp, timeline: timeline)
        return timeline
    }

    private func sourceTranscriptTimeline(for session: Session) -> TranscriptTimeline? {
        sourceTranscriptTimeline(itemId: session.itemId)
    }

    private func mediaDurationMs(for session: Session, position: PlaybackPosition? = nil) -> Int? {
        position?.durationMs
            ?? audio.currentPlaybackDurationMs()
            ?? currentWatchPackage?.primaryAudioAsset?.durationMs
            ?? currentWatchPackage?.timeline.durationMs
            ?? sourceTranscriptTimeline(for: session)?.durationMs
            ?? item(for: session)?.media?.durationMs
    }

    private func durableMediaDurationMs(for session: Session) -> Int? {
        sourceTranscriptTimeline(for: session)?.durationMs
            ?? item(for: session)?.media?.durationMs
    }

    private func item(for session: Session) -> Item? {
        if currentItem?.id == session.itemId {
            return currentItem
        }
        return (try? repository.loadItem(id: session.itemId)).map { publisherPlayback[$0.id]?.playing($0) ?? $0 }
    }

    private func isGeneratedTextMedia(_ media: ItemMedia?) -> Bool {
        media?.sourceType == .generatedTTSPrerendered
    }

    /// Audio whose clock is mapped onto the article's text: generated narration, or the publisher's
    /// recording of the article (#547). Positions, percentages and Margin anchors come from the map.
    private func isTextBackedMedia(_ item: Item?) -> Bool {
        guard let item else { return false }
        return isGeneratedTextMedia(item.media) || publisherPlayback[item.id] != nil
    }

    /// A playing article whose publisher recording has just got its text map moves to the recording, from the place
    /// the on-device voice has reached (#2789). The map takes minutes to make (download, on-device transcription,
    /// alignment), so a post started at once begins in on-device speech; this is the hand-over. It returns nil and
    /// changes nothing unless the current session is that article read aloud and playing, its recording has a usable
    /// map, and the map reaches the place. A recording that then fails to play reads on with speech, as it always
    /// has (`readText(instead:)`). If starting the recording throws, the article goes on in on-device speech.
    @discardableResult
    public func adoptPublisherAudioIfReady() throws -> SessionSnapshot? {
        guard snapshot.status.isPlaybackActive, let session = currentSession,
              session.currentTargetType == .itemTextTTS, session.phase == .itemPlayback,
              let item = currentItem ?? (try? repository.loadItem(id: session.itemId)),
              item.id == session.itemId, publisherPlayback[item.id] == nil,
              let plan = publisherAudioPlan(for: item) else { return nil }
        let synchronized = syncSessionPositionFromAudio(session, item: item)
        guard let playing = plan.playingSession(from: synchronized) else { return nil }
        publisherPlayback[item.id] = plan
        currentItem = plan.playing(item)
        currentSession = playing
        do {
            try audio.stop()
            try persistSession(playing)
            protectPlaybackPosition(for: playing)
            try playCurrentTarget(playing)
        } catch {
            publisherPlayback[item.id] = nil
            currentItem = item
            currentSession = synchronized
            try? persistSession(synchronized)
            try? playCurrentTarget(synchronized)
            throw error
        }
        publishPlaybackContinuation(for: playing)
        return snapshot
    }

    /// The publisher recording `item` plays instead of on-device speech, if it has one that can be used.
    private func publisherAudioPlan(for item: Item) -> PublisherAudioPlayback? {
        guard let store = repository as? any PublisherAudioRepository,
              let record = try? store.loadPublisherAudio(itemId: item.id),
              let plan = PublisherAudioPlayback.plan(for: item, record: record) else { return nil }
        if let failure = publisherAudioUnavailable[item.id] {
            if failure.audioURL == record.audioURL, now().timeIntervalSince(failure.failedAt) < Self.publisherAudioRetryInterval {
                return nil
            }
            publisherAudioUnavailable[item.id] = nil
        }
        // The map carries the article's chapters too, as generated narration's does.
        return plan.with(timeline: generatedTextTimeline(plan.timeline, using: try? repository.loadListeningMap(itemId: item.id)))
    }

    /// `item`, a stored article, as a new session plays it: with its publisher's recording as its
    /// audio when it has a usable one, so it starts as the recording and not as on-device speech.
    private func adoptingPublisherAudio(for item: Item) -> Item {
        guard let plan = publisherAudioPlan(for: item) else {
            publisherPlayback[item.id] = nil
            return item
        }
        publisherPlayback[item.id] = plan
        return plan.playing(item)
    }

    /// A restored article session continues as the recording when the article has one that reaches
    /// the place it was left. Otherwise it stays as it was stored.
    private func resumingPublisherAudio(item: Item, session: Session) -> (Item, Session) {
        publisherPlayback[item.id] = nil
        guard let plan = publisherAudioPlan(for: item), let playing = plan.playingSession(from: session) else {
            return (item, session)
        }
        publisherPlayback[item.id] = plan
        return (plan.playing(item), playing)
    }

    /// Saves an item as the Library stores it: never with the publisher's recording as its audio.
    private func saveItem(_ item: Item) throws {
        try repository.saveItem(publisherPlayback[item.id]?.stored(item) ?? item)
    }

    private func isStarterGeneratedTextMedia(_ media: ItemMedia?) -> Bool {
        guard isGeneratedTextMedia(media) else { return false }
        let identifier = media?.nativeMediaId ?? media?.url ?? ""
        return identifier.contains("-starter.caf") || identifier.contains("-starter.")
    }

    private func isPartialGeneratedTextMedia(item: Item?, timeline: TranscriptTimeline?) -> Bool {
        guard let item,
              isStarterGeneratedTextMedia(item.media),
              let text = item.text,
              !text.isEmpty else {
            return false
        }
        let renderedEnd = timeline?.segments.compactMap(\.endChar).max() ?? 0
        return renderedEnd < text.count
    }

    private func isPartialGeneratedTextPlayback(_ session: Session) -> Bool {
        guard session.currentTargetType == .transcriptBackedMedia else { return false }
        return isPartialGeneratedTextMedia(item: item(for: session), timeline: sourceTranscriptTimeline(for: session))
    }

    private func generatedTextSourcePercent(for session: Session, textStart: Int?) -> Int {
        let text = item(for: session)?.text ?? ""
        return percent(for: max(0, min(textStart ?? session.position.charOffset, text.count)), text: text)
    }

    private func generatedTextOffset(mediaTimeMs: Int, timeline: TranscriptTimeline) -> Int {
        PreparedNarrationFallback.textOffset(mediaTimeMs: mediaTimeMs, timeline: timeline)
    }

    private func mediaPercent(_ mediaTimeMs: Int, durationMs: Int?) -> Int {
        guard let durationMs, durationMs > 0 else { return 0 }
        return max(0, min(100, Int((Double(max(0, mediaTimeMs)) / Double(durationMs)) * 100)))
    }

    private func mediaChapter(at mediaTimeMs: Int, timeline: TranscriptTimeline) -> MediaTimelineChapter? {
        timeline.chapters
            .filter { !isSyntheticTranscriptChapter($0) && $0.startMs <= max(0, mediaTimeMs) }
            .max { $0.startMs < $1.startMs }
    }

    private func mediaTimeMs(forTextOffset textOffset: Int, timeline: TranscriptTimeline) -> Int {
        let sortedSegments = timeline.segments.sorted { $0.startMs < $1.startMs }
        guard !sortedSegments.isEmpty else { return 0 }
        return PreparedNarrationFallback.mediaTimeMs(textOffset: textOffset, timeline: timeline)
            ?? sortedSegments.first(where: { ($0.startChar ?? .max) > textOffset })?.startMs
            ?? timeline.durationMs ?? sortedSegments.last?.endMs ?? 0
    }

    private func preferredPublisherChapterCollection(in candidate: LinkResolutionCandidate) -> PublisherChapterCollection? {
        candidate.publisherChapterCollections
            .filter { !$0.chapters.isEmpty }
            .max { lhs, rhs in lhs.source.precedence < rhs.source.precedence }
    }

    private func publisherChapterSource(from mapId: String) -> PublisherChapterSource? {
        PublisherChapterSource.allCases.first { mapId.hasSuffix("publisher-\($0.rawValue)") }
    }

    private func normalizedPublisherChapters(
        _ chapters: [PublisherChapter],
        durationMs: Int?
    ) -> [PublisherChapter] {
        let sorted = chapters
            .filter { chapter in
                let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, chapter.startMs >= 0 else { return false }
                if let durationMs, durationMs > 0, chapter.startMs > durationMs { return false }
                return true
            }
            .sorted { lhs, rhs in
                lhs.startMs == rhs.startMs ? lhs.title < rhs.title : lhs.startMs < rhs.startMs
            }
        var seenStarts: Set<Int> = []
        let unique = sorted.filter { seenStarts.insert($0.startMs).inserted }
        return Array(unique.prefix(500)).enumerated().map { index, chapter in
            let nextStart = unique.indices.contains(index + 1) ? unique[index + 1].startMs : durationMs
            let explicitEnd = chapter.endMs.flatMap { $0 >= chapter.startMs ? $0 : nil }
            let end = [explicitEnd, nextStart, durationMs]
                .compactMap { $0 }
                .filter { $0 >= chapter.startMs }
                .min()
            return PublisherChapter(
                title: String(chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)),
                description: chapter.description.map {
                    String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
                }.flatMap { $0.isEmpty ? nil : $0 },
                startMs: chapter.startMs,
                endMs: end
            )
        }
    }

    private func publisherChapterId(source: PublisherChapterSource, index: Int) -> String {
        "ch-publisher-\(source.rawValue)-\(String(format: "%03d", index + 1))"
    }

    private func sourceImportItem(
        from candidate: LinkResolutionCandidate,
        result: LinkResolutionResult,
        request: LinkResolutionRequest,
        sourceIdentity: String? = nil
    ) throws -> Item {
        let id = resolvedSourceItemId(for: candidate, request: request, sourceIdentity: sourceIdentity)
        // Reimport is idempotent. Keep the accepted media edition, transcript,
        // download and creation date; metadata is not permission to replace
        // audio underneath already-anchored sessions or private maps.
        do {
            var existing = try repository.loadItem(id: id)
            // Explicit import also restores a trashed item, without rebuilding
            // it and discarding its existing media/transcript association.
            existing.deletedAt = nil
            // Episode identity added since the item was first saved fills in only
            // where it is missing; nothing already stored is replaced (#177).
            if existing.episodeGUID == nil { existing.episodeGUID = Self.nonEmpty(candidate.episodeGUID) }
            if existing.showTitle == nil { existing.showTitle = Self.nonEmpty(candidate.showTitle) }
            if existing.publishedAt == nil { existing.publishedAt = Self.nonEmpty(candidate.publishedAt) }
            return existing
        } catch SessionKitError.missingFixture(let key) where key == "item:\(id)" || key == id {
            // A new identity gets a fresh record, never a legacy title-slug's
            // derivatives. Ambiguous old records remain available for recovery.
        }
        let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (candidate.sourceLink.title ?? request.inputURL) : candidate.title
        var item = Item(
            id: id,
            title: title,
            mediaType: TargetType.transcriptBackedMedia.rawValue,
            text: nil,
            externalReference: result.originalLink.url,
            status: "ready",
            externalReferenceType: "url",
            media: ItemMedia(
                sourceType: .remoteStream,
                url: candidate.audioURL,
                durationMs: candidate.durationMs
            ),
            transcriptId: nil,
            sourceTitle: candidate.showTitle ?? candidate.sourceLink.title,
            sourceURL: candidate.sourceLink.role == "canonical_feed" ? candidate.sourceLink.url : nil,
            createdAt: request.createdAt
        )
        item.episodeGUID = Self.nonEmpty(candidate.episodeGUID)
        item.showTitle = Self.nonEmpty(candidate.showTitle)
        item.publishedAt = Self.nonEmpty(candidate.publishedAt)
        return item
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func resolvedSourceItemId(
        for candidate: LinkResolutionCandidate,
        request: LinkResolutionRequest,
        sourceIdentity: String?
    ) -> String {
        // Titles and filenames are presentation, not identity. In particular,
        // unrelated CDN enclosures often all end in default.mp3. Preserve URL
        // path case and query parameters: either can distinguish episodes.
        let identity = sourceIdentity.map { "feed-entry:\($0)" }
            ?? "audio-url:\(candidate.audioURL ?? request.inputURL)"
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "item-source-v2-\(digest)"
    }

    private func publish(status: PlaybackStatus, phase: SessionPhase) {
        if status != .starting {
            startAttempt.clear()
        }
        // A start carries its request's time: a listener command stamps it, and a start from a stop or on another
        // item gets the publish time. Seeks and the engine's own target switches (narration falling back to live
        // speech) keep the request they belong to (audits of #580).
        if status.isPlaybackActive, playbackRequestedAt != nil || !snapshot.status.isPlaybackActive
            || snapshot.itemId != currentSession?.itemId {
            snapshot.playbackRequestedAt = playbackRequestedAt ?? now()
            playbackRequestedAt = nil
        }
        snapshot.status = status
        snapshot.phase = phase
        snapshot.isRecording = status == .recording
        guard let session = currentSession else { return }
        snapshot.sessionId = session.id
        snapshot.itemId = session.itemId
        snapshot.targetType = session.currentTargetType.rawValue
        snapshot.targetId = session.currentTargetId
        snapshot.title = currentItem?.title
        snapshot.progressPercent = session.completionPercent
        let progress = playbackProgress(for: session)
        let position = playbackPosition(for: session)
        snapshot.sourceProgressPercent = progress.sourcePercent
        let completedFullTarget = audio.isPlaybackComplete(targetId: session.currentTargetId)
            && !isPartialGeneratedTextPlayback(session)
        snapshot.currentPlaybackProgressPercent = completedFullTarget ? 100 : progress.currentPercent
        snapshot.currentMediaTimeMs = position.mediaTimeMs
        snapshot.currentPlaybackDurationMs = position.durationMs
        snapshot.currentTextStart = position.textStart
        snapshot.currentTextEnd = position.textEnd
        snapshot.currentTranscriptSegmentId = position.transcriptSegmentId
        snapshot.currentAnchorConfidence = position.anchorConfidence
        snapshot.playbackRate = session.playbackRate
        snapshot.preparedTextAudioStatus = preparedTextAudioStatus(for: currentItem)
        snapshot.sourceTranscriptStatus = sourceTranscriptStatus(for: session, item: currentItem)
        snapshot.chapterTitle = progress.chapterTitle ?? currentItem?.title
        // Counted, not decoded, where the store can (#2509): this runs on every playback tick.
        let counter = repository as? SessionRecordCounting
        snapshot.activeInterjectionCount = (try? counter?.activeInterjectionCount(sessionId: session.id)
            ?? repository.loadInterjections(sessionId: session.id).filter { $0.status == "active" }.count) ?? snapshot.activeInterjectionCount
        snapshot.pendingAiJobCount = (try? counter?.unfinishedAIJobCount(sessionId: session.id)
            ?? repository.loadAIJobs(sessionId: session.id).filter { $0.status != "complete" }.count) ?? snapshot.pendingAiJobCount
    }

    /// A chapter jump that starts playback (from a pause or stop, or onto another target such as a saved answer's
    /// chapter) is a new request, stamped before any audio work; within the target that is already playing it is a
    /// seek and keeps its request (audits of #580).
    private func stampRequestIfStarting(target targetId: String) {
        if !snapshot.status.isPlaybackActive || snapshot.targetId != targetId { playbackRequestedAt = now() }
    }

    private func publishPlaybackStart(for session: Session, phase: SessionPhase) {
        let attemptId = startAttempt.begin()
        switch playbackStartStatus(for: session.currentTargetId, attemptId: attemptId) {
        case .confirmed:
            forgetStartFailure()
            publish(status: .playing, phase: phase)
        case .pending:
            publish(status: .starting, phase: phase)
        case .failed(let message):
            snapshot.lastFailure = "playback_start_failed:\(message)"
            publish(status: .failed, phase: phase)
        }
    }

    private func publishPlaybackContinuation(for session: Session) {
        if snapshot.status.isPlaybackActive {
            publishPlaybackStart(for: session, phase: session.phase)
        } else {
            publish(status: snapshot.status, phase: session.phase)
        }
    }

    private func playbackStartStatus(for targetId: String, attemptId: Int) -> PlaybackStartStatus {
        switch audio.playbackStartStatus(targetId: targetId) {
        case .confirmed:
            startAttempt.clear()
            protectedPosition.playbackConfirmed(targetId: targetId)
            return .confirmed
        case .failed(let message):
            return recoverPlaybackStart(targetId: targetId, attemptId: attemptId, failure: message)
        case .pending:
            // A slow on-device render isn't a stalled start: the client's own render deadline and fallback
            // cover it. The cap still ends a start that never resolves (#235).
            let verdict = startAttempt.observePending(
                targetId: targetId, attemptId: attemptId, now: now(),
                awaitingRenderedAudio: { audio.isAwaitingRenderedAudio(targetId: targetId) }
            )
            switch verdict {
            case .waiting:
                return .pending
            case .expired:
                return recoverPlaybackStart(
                    targetId: targetId, attemptId: attemptId, failure: "playback_start_timeout"
                )
            }
        }
    }

    private func recoverPlaybackStart(targetId: String, attemptId: Int, failure: String) -> PlaybackStartStatus {
        readTextInsteadOfFailedNarration(targetId: targetId, attemptId: attemptId, failure: failure)
            ?? recoverRemotePlaybackStart(targetId: targetId, attemptId: attemptId, failure: failure)
    }

    /// An article's rendered narration failed to start or never started (#237). Read its text with
    /// live speech from the same place instead, once per start attempt, and report the new target's
    /// own start status. Nil when the target isn't generated narration.
    private func readTextInsteadOfFailedNarration(
        targetId: String, attemptId: Int, failure: String
    ) -> PlaybackStartStatus? {
        guard playbackStartRecoveryAttemptId != attemptId,
              let session = currentSession,
              session.currentTargetId == targetId,
              session.phase == .itemPlayback,
              let item = item(for: session),
              PreparedNarrationFallback.canReadText(
                  instead: session, item: item, playingPublisherAudio: isPlayingPublisherAudio(session)
              ) else {
            return nil
        }
        playbackStartRecoveryAttemptId = attemptId
        do {
            try audio.stop()
            let publisherAudio = isPlayingPublisherAudio(session)
            let reading = try readText(instead: session, item: item)
            snapshot.lastFailure = "\(publisherAudio ? "publisher_audio_unavailable" : "prepared_audio_unavailable"):\(failure)"
            try playCurrentTarget(reading)
        } catch {
            startAttempt.clear()
            return .failed("\(failure); text_fallback_failed:\(error.localizedDescription)")
        }
        startAttempt.movedToAnotherTarget()
        return playbackStartStatus(for: item.id, attemptId: attemptId)
    }

    /// A failure belongs to the item it happened on. Called before a different item becomes current,
    /// so the new item's snapshot (and the diagnostics recorded from it) doesn't carry the previous
    /// item's failure (#283). A failure raised while the new item starts is set after this, so it stays.
    private func forgetFailure(unlessItemIs itemId: String) {
        if snapshot.itemId != itemId {
            snapshot.lastFailure = nil
        }
    }

    /// A saved session can still point at narration whose file has since been deleted. Move it to
    /// live speech before anything hands the player a missing file.
    private func readingTextIfNarrationFileIsMissing(_ session: Session) throws -> Session {
        guard let url = PreparedNarrationFallback.fileURL(forTargetId: session.currentTargetId),
              !FileManager.default.fileExists(atPath: url.path),
              let item = item(for: session),
              PreparedNarrationFallback.canReadText(instead: session, item: item) else {
            return session
        }
        snapshot.lastFailure = "prepared_audio_unavailable:file_missing"
        return try readText(instead: session, item: item)
    }

    /// True when the current session is `itemId` and it plays, or is starting, its publisher's recording (#547). The
    /// app asks this at each play start instead of reading the item and its record again on main (#2508).
    public func playsPublisherAudio(itemId: String) -> Bool {
        currentSession?.itemId == itemId && publisherPlayback[itemId] != nil
    }

    /// True when `session` plays the publisher recording of its article (#547).
    private func isPlayingPublisherAudio(_ session: Session) -> Bool {
        publisherPlayback[session.itemId]?.plays(targetId: session.currentTargetId) ?? false
    }

    /// Detaches the unusable narration from the item (so it can be rendered again) and persists the
    /// session on live speech of the text at the matching position. A publisher recording that
    /// can't play isn't attached to the item: the article simply stops using it until the app opens again.
    private func readText(instead session: Session, item: Item) throws -> Session {
        // The cached item can be older than storage; don't write stale fields back.
        var detached = (try? repository.loadItem(id: item.id)) ?? item
        let publisher = publisherPlayback[item.id].flatMap { $0.plays(targetId: session.currentTargetId) ? $0 : nil }
        if let publisher {
            publisherAudioUnavailable[item.id] = (publisher.recording.audioURL, now())
        }
        let publisherTimeline = publisher?.timeline
        if publisher != nil {
            publisherPlayback[item.id] = nil
        }
        // Only the render this session was playing is unusable. If the article has since been
        // prepared again, its newer render and timeline stay, and the saved character offset is the
        // position: the stored timeline now describes the newer render, not the missing one (#277).
        let targetIsCurrentRender = PreparedNarrationFallback.media(detached.media, isTarget: session.currentTargetId)
        if targetIsCurrentRender, detached.media?.sourceType == .generatedTTSPrerendered {
            detached.media = nil
            try saveItem(detached)
            try PreparedNarrationFallback.markPreparedAudioForRepreparation(itemId: detached.id, repository: repository)
        }
        currentItem = detached
        let timelineDescribesTarget = targetIsCurrentRender
        var reading = PreparedNarrationFallback.liveSpeechSession(
            from: session, item: detached,
            timeline: publisherTimeline ?? (timelineDescribesTarget ? sourceTranscriptTimeline(for: session) : nil)
        )
        reading.position.chapterId = chapterId(for: reading.position.charOffset)
        currentSession = reading
        protectPlaybackPosition(for: reading)
        try persistSession(reading)
        return reading
    }

    /// Recreate a stalled remote transport once, just as closing and reopening
    /// playback does, while retaining the requested chapter rather than a stale
    /// player observation. A second failure remains terminal for this attempt.
    private func recoverRemotePlaybackStart(
        targetId: String, attemptId: Int, failure: String
    ) -> PlaybackStartStatus {
        guard playbackStartRecoveryAttemptId != attemptId,
              let session = currentSession,
              session.currentTargetId == targetId,
              session.currentTargetType == .transcriptBackedMedia,
              session.phase == .itemPlayback,
              let context = playbackMediaContext(for: session),
              context.sourceType == .remoteStream,
              let url = URL(string: context.playbackURL ?? targetId),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            startAttempt.clear()
            return .failed(failure)
        }
        playbackStartRecoveryAttemptId = attemptId
        do {
            try audio.stop()
            protectPlaybackPosition(for: session)
            try playCurrentTarget(session)
            startAttempt.restarted(targetId: targetId, attemptId: attemptId, now: now())
            return .pending
        } catch {
            startAttempt.clear()
            return .failed("\(failure); recovery_failed:\(error.localizedDescription)")
        }
    }

    /// A start that confirms supersedes an earlier failed one, so diagnostics stop reporting
    /// that failure while the source plays normally (#588).
    private func forgetStartFailure() {
        if snapshot.lastFailure?.hasPrefix("playback_start_failed:") == true {
            snapshot.lastFailure = nil
        }
    }

    private func preparedTextAudioStatus(for item: Item?) -> String? {
        guard let item, item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
        switch item.media?.sourceType {
        case .some(.generatedTTSPrerendered):
            return isPartialGeneratedTextMedia(item: item, timeline: sourceTranscriptTimeline(itemId: item.id)) ? "starter_ready" : "ready"
        case .some(.generatedTTSRealtime), .none:
            return profile.has("playback", "prerendered_audio") ? "live_fallback" : nil
        case .some(.nativeMediaFile), .some(.remoteStream), .some(.browserOwnedMedia):
            return nil
        }
    }

    private func sourceTranscriptStatus(for session: Session, item: Item?) -> String? {
        guard let item,
              session.currentTargetType == .transcriptBackedMedia || session.currentTargetType == .browserOwnedMedia else {
            return nil
        }
        if sourceTranscriptTimeline(for: session)?.segments.isEmpty == false {
            return "ready"
        }
        switch item.media?.sourceType {
        case .some(.remoteStream), .some(.nativeMediaFile), .some(.browserOwnedMedia):
            return "not_started"
        default:
            return nil
        }
    }

    private func playbackProgress(for session: Session) -> PlaybackProgress {
        let sourcePercent = session.completionPercent
        let position = playbackPosition(for: session)
        switch session.currentTargetType {
        case .itemTextTTS:
            let currentAudioOffset = rawAudioTextOffset()
            let prefixLength = itemPlaybackPreface().count
            let isInPreface = prefixLength > 0 && (currentAudioOffset ?? 0) <= prefixLength && session.position.chapterId == nil
            let currentPercent: Int
            if isInPreface, let offset = currentAudioOffset {
                currentPercent = percent(offset: offset, length: prefixLength)
            } else if let offset = currentAudioOffset {
                currentPercent = percent(for: itemSourceOffset(forAudioOffset: offset), text: currentItem?.text ?? "")
            } else {
                currentPercent = session.completionPercent
            }
            let title = isInPreface ? "Summary" : (currentMap?.chapters.first(where: { $0.id == session.position.chapterId })?.title ?? currentItem?.title)
            return PlaybackProgress(sourcePercent: sourcePercent, currentPercent: currentPercent, chapterTitle: title)
        case .summaryTurnTTS, .assistantTurnTTS:
            guard let turn = try? repository.loadTurns(sessionId: session.id).first(where: { $0.id == session.currentTargetId }) else {
                return PlaybackProgress(sourcePercent: sourcePercent, currentPercent: 0, chapterTitle: currentItem?.title)
            }
            let playable = playableText(for: turn)
            let audioOffset = rawAudioTextOffset() ?? turnAudioOffset(for: turn, responseOffset: session.position.charOffset)
            let currentPercent = playable.isEmpty ? 0 : percent(for: max(0, min(audioOffset, playable.count)), text: playable)
            let responseOffset = turnResponseOffset(for: turn, audioOffset: audioOffset)
            let title = turn.chapters?.last(where: { $0.startChar <= responseOffset })?.title ?? turnTitle(for: turn)
            return PlaybackProgress(sourcePercent: sourcePercent, currentPercent: currentPercent, chapterTitle: title)
        case .transcriptBackedMedia, .browserOwnedMedia:
            let mediaTimeMs = position.mediaTimeMs ?? session.position.mediaTimeMs ?? 0
            if let package = currentWatchPackage {
                let resolved = MediaTimelineAnchorResolver.resolve(
                    mediaTimeMs: mediaTimeMs,
                    timeline: package.timeline,
                    playbackRateObserved: session.playbackRate
                )
                let title = resolved.chapterId.flatMap { chapterId in
                    package.chapters.first(where: { $0.id == chapterId })?.title
                } ?? currentItem?.title
                return PlaybackProgress(
                    sourcePercent: mediaPercent(mediaTimeMs, package: package),
                    currentPercent: mediaPercent(mediaTimeMs, package: package),
                    chapterTitle: title
                )
            }
            if let timeline = sourceTranscriptTimeline(for: session) {
                let chapterTitle: String?
                if timeline.segments.isEmpty {
                    chapterTitle = mediaChapter(at: mediaTimeMs, timeline: timeline)?.title
                } else {
                    let resolved = MediaTimelineAnchorResolver.resolve(
                        mediaTimeMs: mediaTimeMs,
                        timeline: timeline,
                        playbackRateObserved: session.playbackRate
                    )
                    chapterTitle = resolved.chapterId.flatMap { chapterId in
                        timeline.chapters.first(where: {
                            $0.id == chapterId && !isSyntheticTranscriptChapter($0)
                        })?.title
                    }
                }
                let percent = isTextBackedMedia(item(for: session))
                    ? generatedTextSourcePercent(for: session, textStart: position.textStart)
                    : mediaPercent(mediaTimeMs, durationMs: mediaDurationMs(for: session, position: position))
                return PlaybackProgress(sourcePercent: percent, currentPercent: percent, chapterTitle: chapterTitle ?? currentItem?.title)
            }
            let percent = isTextBackedMedia(item(for: session))
                ? generatedTextSourcePercent(for: session, textStart: position.textStart)
                : mediaPercent(mediaTimeMs, durationMs: mediaDurationMs(for: session, position: position))
            return PlaybackProgress(sourcePercent: percent, currentPercent: percent, chapterTitle: currentItem?.title)
        }
    }

    private func rawAudioTextOffset() -> Int? {
        audio.currentPlaybackPosition()?.textStart ?? audio.currentCharOffset()
    }

    private func playbackPosition(for session: Session) -> PlaybackPosition {
        let audioPosition = audio.currentPlaybackPosition()
        let protectedPosition = protectedPosition.position(for: session)
        let positionIsPending = protectedPosition != nil
        switch session.currentTargetType {
        case .itemTextTTS:
            let prefixLength = itemPlaybackPreface().count
            let text = currentItem?.text ?? ""
            let rawOffset = positionIsPending ? nil : rawAudioTextOffset()
            let isInPreface = rawOffset.map { prefixLength > 0 && $0 <= prefixLength && session.position.chapterId == nil } ?? false
            let sourceOffset = rawOffset.map { isInPreface ? 0 : itemSourceOffset(forAudioOffset: $0) }
                ?? protectedPosition?.charOffset
                ?? session.position.charOffset
            let start = max(0, min(sourceOffset, text.count))
            let end = min(text.count, max(start + 1, nextBoundary(after: start, unit: "sentence", text: text)))
            return PlaybackPosition(
                itemId: session.itemId,
                targetType: session.currentTargetType,
                targetId: session.currentTargetId,
                textStart: start,
                textEnd: end,
                chapterId: isInPreface ? nil : chapterId(for: start),
                playbackRate: session.playbackRate,
                anchorConfidence: .textRange
            )
        case .summaryTurnTTS, .assistantTurnTTS:
            let turn = try? repository.loadTurns(sessionId: session.id).first(where: { $0.id == session.currentTargetId })
            let text = turn.map { generatedTurnNavigationText(for: $0) } ?? ""
            let canonicalOffset = protectedPosition?.charOffset ?? session.position.charOffset
            let audioOffset = (positionIsPending ? nil : rawAudioTextOffset())
                ?? turn.map { turnAudioOffset(for: $0, responseOffset: canonicalOffset) }
                ?? canonicalOffset
            let responseOffset = turn.map { turnResponseOffset(for: $0, audioOffset: audioOffset) } ?? session.position.charOffset
            let start = max(0, min(responseOffset, text.count))
            let end = min(text.count, max(start + 1, nextBoundary(after: start, unit: "sentence", text: text)))
            return PlaybackPosition(
                itemId: session.itemId,
                targetType: session.currentTargetType,
                targetId: session.currentTargetId,
                textStart: start,
                textEnd: end,
                chapterId: turn?.chapters?.last(where: { $0.startChar <= start })?.id,
                playbackRate: session.playbackRate,
                anchorConfidence: .textRange
            )
        case .transcriptBackedMedia, .browserOwnedMedia:
            let observedMediaTimeMs = audioPosition?.mediaTimeMs ?? audio.currentMediaTimeMs()
            let mediaTimeMs: Int?
            if positionIsPending {
                mediaTimeMs = protectedPosition?.mediaTimeMs
            } else if let observedMediaTimeMs,
                      let canonicalMediaTimeMs = session.position.mediaTimeMs,
                      observedMediaTimeMs + Self.mediaClockBackwardToleranceMs < canonicalMediaTimeMs {
                // Transport clocks may briefly publish an obsolete or reset
                // timestamp after a seek, route rebuild, or interruption. Every
                // legitimate backward movement enters through a canonical
                // command first, so an unsolicited backward sample is never
                // allowed to rewind the session or its scrubber.
                mediaTimeMs = canonicalMediaTimeMs
            } else {
                mediaTimeMs = observedMediaTimeMs ?? session.position.mediaTimeMs
            }
            let durationMs = mediaDurationMs(for: session, position: audioPosition)
            guard let mediaTimeMs else {
                return PlaybackPosition(
                    itemId: session.itemId,
                    targetType: session.currentTargetType,
                    targetId: session.currentTargetId,
                    durationMs: durationMs,
                    chapterId: session.position.chapterId,
                    playbackRate: session.playbackRate,
                    anchorConfidence: .localFallback
                )
            }
            if let package = currentWatchPackage {
                let resolved = MediaTimelineAnchorResolver.resolve(
                    mediaTimeMs: mediaTimeMs,
                    timeline: package.timeline,
                    playbackRateObserved: session.playbackRate
                )
                return PlaybackPosition(
                    itemId: session.itemId,
                    targetType: session.currentTargetType,
                    targetId: session.currentTargetId,
                    mediaTimeMs: resolved.mediaTimeMs,
                    durationMs: durationMs,
                    textStart: resolved.startChar,
                    textEnd: resolved.endChar,
                    transcriptSegmentId: resolved.transcriptSegmentId,
                    chapterId: resolved.chapterId,
                    playbackRate: resolved.playbackRateObserved,
                    anchorConfidence: resolved.transcriptSegmentId == nil ? .mediaTime : .transcriptSpan
                )
            }
            if let timeline = sourceTranscriptTimeline(for: session), !timeline.segments.isEmpty {
                let resolved = MediaTimelineAnchorResolver.resolve(
                    mediaTimeMs: mediaTimeMs,
                    timeline: timeline,
                    playbackRateObserved: session.playbackRate
                )
                let textStart = isTextBackedMedia(item(for: session))
                    ? generatedTextOffset(mediaTimeMs: mediaTimeMs, timeline: timeline)
                    : resolved.startChar
                return PlaybackPosition(
                    itemId: session.itemId,
                    targetType: session.currentTargetType,
                    targetId: session.currentTargetId,
                    mediaTimeMs: resolved.mediaTimeMs,
                    durationMs: durationMs,
                    textStart: textStart,
                    textEnd: resolved.endChar,
                    transcriptSegmentId: resolved.transcriptSegmentId,
                    chapterId: resolved.chapterId,
                    playbackRate: resolved.playbackRateObserved,
                    anchorConfidence: resolved.transcriptSegmentId == nil ? .mediaTime : .transcriptSpan
                )
            }
            if let timeline = sourceTranscriptTimeline(for: session),
               let chapter = mediaChapter(at: mediaTimeMs, timeline: timeline) {
                return PlaybackPosition(
                    itemId: session.itemId,
                    targetType: session.currentTargetType,
                    targetId: session.currentTargetId,
                    mediaTimeMs: max(0, mediaTimeMs),
                    durationMs: durationMs,
                    chapterId: chapter.id,
                    playbackRate: session.playbackRate,
                    anchorConfidence: .providerMetadata
                )
            }
            return PlaybackPosition(
                itemId: session.itemId,
                targetType: session.currentTargetType,
                targetId: session.currentTargetId,
                mediaTimeMs: max(0, mediaTimeMs),
                durationMs: durationMs,
                chapterId: session.position.chapterId,
                playbackRate: session.playbackRate,
                anchorConfidence: .mediaTime
            )
        }
    }

    private func require(_ command: String, category: String, capabilities: [String]) throws {
        guard profile.hasAny(category, capabilities) else {
            throw SessionKitError.invalidCommandForCapability(command)
        }
    }

    private func requirePlayback(_ command: String) throws {
        guard profile.hasAny("playback", ["realtime_tts", "prerendered_audio", "native_media", "assistant_turn_tts", "summary_turn_tts"])
            || profile.has("remoteControl", "send_transport_commands") else {
            throw SessionKitError.invalidCommandForCapability(command)
        }
    }

    private func requireNavigationAllowed(_ command: String) throws {
        guard snapshot.status != .recording, pendingWrittenInterjection == nil else {
            throw SessionKitError.invalidCommandForState(command)
        }
    }

    private func browserTextImportRecords(
        _ handoff: BrowserTextHandoff,
        structuredDocument: StructuredDocument? = nil
    ) throws -> (Item, ListeningMap?, StructuredDocument?, Bool) {
        guard case .records(let item, let map, let document, let persisted) = try browserTextImporter().outcome(handoff, structuredDocument: structuredDocument, upgrade: .inline) else {
            throw SessionKitError.invalidCommandForState("importBrowserText")
        }
        return (item, map, document, persisted)
    }

    private func browserTextImporter() -> BrowserTextImporter {
        BrowserTextImporter(
            repository: repository,
            openItemIds: Set([currentSession?.itemId, currentItem?.id].compactMap { $0 }),
            isPlaybackActive: snapshot.status.isPlaybackActive,
            publisherPlayback: publisherPlayback
        )
    }


    private func resolveSession(_ sessionId: String?) throws -> Session {
        if let sessionId, let session = try repository.loadSession(id: sessionId) {
            return session
        }
        if let currentSession { return currentSession }
        if let memory = repository as? InMemorySessionRepository, let session = memory.sessions.values.first {
            currentSession = session
            currentItem = try? repository.loadItem(id: session.itemId)
            currentMap = try? repository.loadListeningMap(itemId: session.itemId)
            publish(status: .paused, phase: session.phase)
            return session
        }
        if let item = currentItem {
            let session = Session(
                id: "session-\(item.id)-export",
                itemId: item.id,
                status: "in_progress",
                phase: .itemPlayback,
                currentTargetType: .itemTextTTS,
                currentTargetId: item.id,
                position: Position(),
                completionPercent: 0,
                playbackRate: 1
            )
            currentSession = session
            try persistSession(session)
            publish(status: .paused, phase: session.phase)
            return session
        }
        throw SessionKitError.invalidCommandForState("buildExport")
    }

    private func nextSessionId(itemId: String) -> String {
        if let memory = repository as? InMemorySessionRepository {
            let next = memory.sessions.values.filter { $0.itemId == itemId }.count + 1
            return "session-\(itemId)-gate1-\(String(format: "%03d", next))"
        }
        return "session-\(itemId)-\(UUID().uuidString)"
    }

    private func currentInterjectionTarget(for session: Session) -> (type: InterjectionTargetType, id: String) {
        switch session.currentTargetType {
        case .assistantTurnTTS:
            return (.assistantTurn, session.currentTargetId)
        case .summaryTurnTTS:
            return (.summaryTurn, session.currentTargetId)
        case .transcriptBackedMedia, .browserOwnedMedia:
            return (.item, session.itemId)
        default:
            return (.item, session.itemId)
        }
    }

    private func isFinishedAtEnd(_ session: Session) -> Bool {
        session.phase == .finished && session.completionPercent >= 100
            && session.currentTargetType != .summaryTurnTTS && session.currentTargetType != .assistantTurnTTS
    }

    private func settleFinishedSourceAfterInterjection(_ session: Session) throws -> SessionSnapshot {
        var session = session
        session.phase = .finished
        currentSession = session
        try persistSession(session)
        publish(status: .paused, phase: .finished)
        return snapshot
    }

    func buildAnchor(for session: Session, targetType: InterjectionTargetType, targetId: String) -> Anchor {
        let playbackPosition = playbackPosition(for: session)
        // A Margin on the publisher's recording anchors to the article's words, at the place the map gives
        // for the playing time, like a Margin on the article itself. Nothing about the recording (its time,
        // its map's segments) goes into the anchor, so a packet of it is an ordinary article packet (#547).
        if (session.currentTargetType == .transcriptBackedMedia || session.currentTargetType == .browserOwnedMedia),
           !isPlayingPublisherAudio(session) {
            let resolved = resolveMediaAnchor(for: session, playbackPosition: playbackPosition)
            lastResolvedMediaAnchor = resolved
            return Anchor(
                anchorType: resolved.transcriptSegmentId == nil ? .media : .transcript,
                startChar: resolved.startChar,
                endChar: resolved.endChar,
                anchorBefore: resolved.anchorBefore,
                anchorAfter: resolved.anchorAfter,
                mediaTimeMs: resolved.mediaTimeMs,
                playbackRateObserved: resolved.playbackRateObserved,
                transcriptSegmentId: resolved.transcriptSegmentId
            )
        }
        if targetType != .item {
            let turn = try? repository.loadTurns(sessionId: session.id).first(where: { $0.id == targetId })
            let turnText = turn.map { generatedTurnNavigationText(for: $0) } ?? ""
            let start = max(0, min(playbackPosition.textStart ?? session.position.charOffset, turnText.count))
            let sentenceStart = previousBoundary(before: min(start + 1, turnText.count), unit: "sentence", text: turnText)
            let end = min(turnText.count, max(sentenceStart + 1, nextBoundary(after: start, unit: "sentence", text: turnText)))
            let segmentIndex = completeSentenceUnits(in: slice(turnText, start: 0, end: sentenceStart)).count
            let context = textAnchorShoulder(in: turnText, at: start)
            return Anchor(
                anchorType: .turn,
                startChar: start,
                endChar: end,
                anchorBefore: context.before,
                anchorAfter: context.after,
                turnSegmentIndex: segmentIndex
            )
        }
        let text = currentItem?.text ?? ""
        let start = max(0, min(playbackPosition.textStart ?? session.position.charOffset, text.count))
        let end = min(text.count, max(start + 1, nextBoundary(after: start, unit: "sentence", text: text)))
        let context = textAnchorShoulder(in: text, at: start)
        return Anchor(
            anchorType: .text,
            startChar: start,
            endChar: end,
            anchorBefore: context.before,
            anchorAfter: context.after
        )
    }

    private func textAnchorShoulder(in text: String, at rawOffset: Int) -> (before: String, after: String) {
        guard !text.isEmpty else { return ("", "") }
        let split = completedWordBoundary(in: text, at: rawOffset)
        var beforeStart = split
        var afterEnd = split
        for _ in 0..<Self.textAnchorShoulderSentenceCount {
            let previous = previousBoundary(before: beforeStart, unit: "sentence", text: text)
            if previous == beforeStart { break }
            beforeStart = previous
        }
        // Lines that end no sentence (a heading, a title page's names and emails) are not part of the passage.
        beforeStart = max(beforeStart, unsentencedBlockEnd(in: text, before: split, notBefore: beforeStart))
        for _ in 0..<Self.textAnchorShoulderSentenceCount {
            let next = nextBoundary(after: afterEnd, unit: "sentence", text: text)
            if next == afterEnd { break }
            afterEnd = next
        }
        return (
            slice(text, start: beforeStart, end: split),
            slice(text, start: split, end: afterEnd)
        )
    }

    /// Where the text just before `offset` stops being sentences: the start of the line after the nearest earlier line
    /// that doesn't end in sentence punctuation. 0 when every earlier line does, so prose keeps its shoulder across
    /// paragraph breaks. A PDF's title page is a run of such lines with no full stops (names, affiliations, emails),
    /// and sentence boundaries alone ran back through it, so a Margin on the abstract kept the author block as the
    /// context shown for it (#2482).
    private static let sentenceEndings: Set<Character> = [
        ".", "?", "!", ":", ";", "…", "—", "\"", "'", "”", "’", "»", ")", "]", "。", "！", "？", "」", "』"
    ]
    /// A longer line is prose, not a heading or a name.
    private static let unsentencedLineLimit = 120

    /// Words a sentence doesn't end on. A line ending in one goes on in the next line, whatever that line starts with.
    private static let runOnWords: Set<String> = [
        "the", "a", "an", "of", "and", "or", "to", "in", "on", "for", "with", "by", "that", "as", "at", "from",
        "which", "is", "are", "was", "were", "be", "this", "these", "those", "its", "their", "than", "but", "into"
    ]
    /// A hard-wrapped body line is near the page's width; a short line ending in a comma is a list of names, and one
    /// ending in a function word or a hyphen is a heading (`Who We Are`).
    private static let runOnLineLength = 40

    /// The line starting at `from` goes on from the one before it (a hard-wrapped line): its first letter is lower
    /// case. Only blanks are skipped, so an indented continuation counts and a blank line doesn't.
    private func continues(_ characters: [Character], from: Int) -> Bool {
        var index = from
        while index < characters.count, characters[index].isWhitespace, !characters[index].isNewline { index += 1 }
        return index < characters.count && characters[index].isLowercase
    }

    /// The line `characters[start..<end]` ends a sentence, or looks like it was cut mid-sentence by the page's width.
    private func lineEndsUnsentenced(_ characters: ArraySlice<Character>, followedByContinuation: Bool) -> Bool {
        guard let lastIndex = characters.lastIndex(where: { !$0.isWhitespace }) else { return false }
        let last = characters[lastIndex]
        if Self.sentenceEndings.contains(last) { return false }
        if endsInFootnoteNumber(characters[...lastIndex]) { return false }
        if followedByContinuation { return false }
        if characters.count >= Self.runOnLineLength {
            if last == "-" || last == "," { return false }
            let word = String(characters[...lastIndex].reversed().prefix(while: { $0.isLetter }).reversed()).lowercased()
            if !word.isEmpty, Self.runOnWords.contains(word) { return false }
        }
        return characters.count <= Self.unsentencedLineLimit
    }

    /// A footnote number after the full stop that ends a word: `mechanism.1`. A section number (`3.1`, `A.1`) isn't one.
    private func endsInFootnoteNumber(_ characters: ArraySlice<Character>) -> Bool {
        let digits = characters.reversed().prefix(while: { $0.isNumber }).count
        let stop = characters.endIndex - digits - 1
        guard digits > 0, stop - 2 >= characters.startIndex, Self.sentenceEndings.contains(characters[stop]) else { return false }
        if characters[stop - 1].isLetter { return characters[stop - 2].isLetter }
        return !characters[stop - 1].isNumber
    }

    /// Looks back from `offset` only as far as `floor` (the shoulder's own start): anything before it is dropped by the
    /// caller, so the scan reads and copies just the lines between the two.
    private func unsentencedBlockEnd(in text: String, before offset: Int, notBefore floor: Int) -> Int {
        let offsetIndex = text.index(text.startIndex, offsetBy: max(0, offset), limitedBy: text.endIndex) ?? text.endIndex
        let floorIndex = text.index(text.startIndex, offsetBy: max(0, floor), limitedBy: text.endIndex) ?? text.endIndex
        guard floorIndex < offsetIndex else { return floor }
        // The first line is read whole, so a long line cut at `floor` isn't mistaken for a heading.
        let windowStart = text[..<floorIndex].lastIndex(where: { $0.isNewline }).map { text.index(after: $0) } ?? text.startIndex
        // The window runs on to the first letter of the Margin's line, which says whether the line before it runs on.
        var windowEnd = offsetIndex
        while windowEnd < text.endIndex, text[windowEnd].isWhitespace, !text[windowEnd].isNewline { windowEnd = text.index(after: windowEnd) }
        if windowEnd < text.endIndex { windowEnd = text.index(after: windowEnd) }
        let characters = Array(text[windowStart..<windowEnd])
        let base = floor - text.distance(from: windowStart, to: floorIndex)
        var lineStart = text.distance(from: windowStart, to: offsetIndex)
        while lineStart > 0, !characters[lineStart - 1].isNewline { lineStart -= 1 }
        var following = lineStart // the start of the line after the one being read
        var end = lineStart
        while end > 0 {
            end -= 1 // the line break that ends the previous line
            var start = end
            while start > 0, !characters[start - 1].isNewline { start -= 1 }
            if lineEndsUnsentenced(characters[start..<end], followedByContinuation: continues(characters, from: following)) {
                return base + following
            }
            if characters[start..<end].contains(where: { !$0.isWhitespace }) { following = start }
            end = start
        }
        return floor
    }

    private func completedWordBoundary(in text: String, at rawOffset: Int) -> Int {
        let characters = Array(text)
        let offset = max(0, min(rawOffset, characters.count))
        guard offset > 0, offset < characters.count else { return offset }
        if characters[offset].isWhitespace || characters[offset - 1].isWhitespace {
            return offset
        }
        var boundary = offset
        while boundary < characters.count, !characters[boundary].isWhitespace {
            boundary += 1
        }
        return boundary
    }

    private func interjectionPercent(
        for session: Session,
        targetType: InterjectionTargetType,
        targetId: String,
        anchor: Anchor
    ) -> Int {
        guard targetType != .item,
              let turn = try? repository.loadTurns(sessionId: session.id).first(where: { $0.id == targetId }) else {
            return session.completionPercent
        }
        let text = generatedTurnNavigationText(for: turn)
        return percent(for: anchor.startChar, text: text)
    }

    private func exportTurnAnchorContext(
        for anchor: Anchor,
        turn: ConversationTurn
    ) -> (before: String, after: String) {
        let text = generatedTurnNavigationText(for: turn)
        guard !text.isEmpty else { return (anchor.anchorBefore, anchor.anchorAfter) }

        // Older turn anchors stored the current sentence as `before` and only the
        // following sentence as `after`. Their exact playhead was not persisted,
        // but the end of the stored current-sentence span is the best recoverable
        // split. New anchors store the playhead in `startChar` and already carry
        // the same four-sentence shoulders as source-text anchors.
        let storedCurrentSentence = slice(
            text,
            start: max(0, min(anchor.startChar, text.count)),
            end: max(0, min(anchor.endChar, text.count))
        )
        let isLegacyTurnAnchor = anchor.anchorBefore == storedCurrentSentence
        let split = isLegacyTurnAnchor ? anchor.endChar : anchor.startChar
        return textAnchorShoulder(in: text, at: split)
    }

    private func aiJob(id: String, kind: String, session: Session, turnId: String?, status: String, messages: [String] = []) -> AIJob {
        AIJob(
            id: id,
            kind: kind,
            itemId: session.itemId,
            sessionId: session.id,
            turnId: turnId,
            providerType: aiProvider.providerType,
            model: aiProvider.model,
            status: status,
            attempts: 0,
            lastError: nil,
            messages: messages,
            playbackMode: session.currentTargetType.rawValue
        )
    }

    /// Loads a Margin, changes it and saves it whole, in one transaction when the store has them. Another thread's
    /// save of the same Margin (the anchor-evidence edits run off the main thread, #2509) then waits for this one
    /// instead of landing between the load and the save and being written over by the stale copy.
    func updateInterjection(
        _ id: String,
        sessionId: String? = nil,
        mutate: (inout Interjection) -> Void
    ) throws {
        try inRepositoryTransaction { try updateInterjectionUnlocked(id, sessionId: sessionId, mutate: mutate) }
    }

    private func inRepositoryTransaction<T>(_ operation: () throws -> T) throws -> T {
        if let store = repository as? any SessionRepositoryTransaction { return try store.withSessionTransaction(operation) }
        return try operation()
    }

    private func updateInterjectionUnlocked(
        _ id: String,
        sessionId: String?,
        mutate: (inout Interjection) -> Void
    ) throws {
        if let sessionId {
            guard (try repository.loadSession(id: sessionId)) != nil,
                  var interjection = try loadInterjection(id, inSession: sessionId) else {
                throw SessionKitError.invalidCommandForState("updateInterjection")
            }
            mutate(&interjection)
            try repository.saveInterjection(interjection)
            lastMediaPercentageRepair = nil
            return
        }
        if let memory = repository as? InMemorySessionRepository, var interjection = memory.interjections[id] {
            mutate(&interjection)
            try repository.saveInterjection(interjection)
            lastMediaPercentageRepair = nil
            return
        }
        guard let session = currentSession else { throw SessionKitError.invalidCommandForState("updateInterjection") }
        guard var interjection = try loadInterjection(id, inSession: session.id) else {
            // Fixtures may use a mapless session while the current runtime session differs; preserve trace intent.
            let all = try repository.loadInterjections(sessionId: "session-pill-mapless")
            guard var fallback = all.first(where: { $0.id == id }) else { throw SessionKitError.invalidCommandForState("updateInterjection") }
            mutate(&fallback)
            try repository.saveInterjection(fallback)
            lastMediaPercentageRepair = nil
            return
        }
        mutate(&interjection)
        try repository.saveInterjection(interjection)
        lastMediaPercentageRepair = nil
    }

    /// One Margin of a session, read by id where the store can (#2509) instead of decoding every Margin of the session.
    private func loadInterjection(_ id: String, inSession sessionId: String) throws -> Interjection? {
        if let reader = repository as? InterjectionByIdReading,
           let found = try reader.loadInterjection(id: id, sessionId: sessionId) {
            return found
        }
        return try repository.loadInterjections(sessionId: sessionId).first { $0.id == id && $0.sessionId == sessionId }
    }

    private func ensureWatchPackageRecords(_ package: WatchAudioPackage) throws {
        if (try? repository.loadItem(id: package.itemId)) == nil {
            let text = package.transcript.segments.map(\.text).joined(separator: " ")
            try saveItem(
                Item(
                    id: package.itemId,
                    title: package.item.title,
                    mediaType: package.item.mediaType,
                    text: text,
                    externalReference: package.item.externalReference,
                    status: "ready"
                )
            )
        }
        if try repository.loadSession(id: package.sessionId) == nil {
            let firstChapter = package.chapters.sorted { $0.startMs < $1.startMs }.first
            try persistSession(
                Session(
                    id: package.sessionId,
                    itemId: package.itemId,
                    status: "in_progress",
                    phase: .itemPlayback,
                    currentTargetType: .transcriptBackedMedia,
                    currentTargetId: package.primaryAudioAsset?.audioAssetId ?? package.id,
                    position: Position(
                        charOffset: package.transcript.segments.first?.startChar ?? 0,
                        mediaTimeMs: firstChapter?.startMs ?? 0,
                        segmentIndex: 0,
                        chapterId: firstChapter?.id
                    ),
                    completionPercent: mediaPercent(firstChapter?.startMs ?? 0, package: package),
                    playbackRate: package.settings.defaultPlaybackRate
                )
            )
        }
    }

    private func importWatchInterjection(_ event: WatchSyncEvent, package: WatchAudioPackage) throws {
        let mediaTimeMs = event.payload.mediaTimeMs ?? 0
        let resolved = MediaTimelineAnchorResolver.resolve(
            mediaTimeMs: mediaTimeMs,
            timeline: package.timeline,
            playbackRateObserved: event.payload.playbackRate ?? package.settings.defaultPlaybackRate
        )
        let interjectionId = watchInterjectionId(from: event)
        if try repository.loadInterjections(sessionId: event.sessionId).contains(where: { $0.id == interjectionId }) {
            return
        }
        let interjection = Interjection(
            id: interjectionId,
            itemId: event.itemId ?? package.itemId,
            sessionId: event.sessionId,
            targetType: .item,
            targetId: event.itemId ?? package.itemId,
            createdAt: event.createdAt,
            roughPercent: mediaPercent(mediaTimeMs, package: package),
            anchor: Anchor(
                anchorType: resolved.transcriptSegmentId == nil ? .media : .transcript,
                startChar: resolved.startChar,
                endChar: resolved.endChar,
                anchorBefore: resolved.anchorBefore,
                anchorAfter: resolved.anchorAfter,
                mediaTimeMs: resolved.mediaTimeMs,
                playbackRateObserved: resolved.playbackRateObserved,
                transcriptSegmentId: resolved.transcriptSegmentId
            ),
            audioPath: event.payload.audioFileName,
            audioStatus: event.payload.audioFileName == nil ? "missing" : "saved",
            transcriptionStatus: "pending",
            transcript: nil,
            cleanedTranscript: nil,
            displayText: nil,
            status: "active",
            anchorContextStatus: resolved.transcriptSegmentId == nil ? .pending : .ready
        )
        try repository.saveInterjection(interjection)
        lastMediaPercentageRepair = nil
        try transcriber.scheduleTranscription(interjection: interjection)
        lastScheduledTranscriptionInterjectionId = interjection.id
        lastResolvedMediaAnchor = resolved
        snapshot.lastInterjectionAnchorType = interjection.anchor.anchorType
        snapshot.lastInterjectionTargetType = interjection.targetType
        currentSession = try repository.loadSession(id: event.sessionId) ?? currentSession
    }

    private func importWatchPlaybackPosition(_ event: WatchSyncEvent, package: WatchAudioPackage) throws {
        let mediaTimeMs = event.payload.mediaTimeMs ?? 0
        let resolved = MediaTimelineAnchorResolver.resolve(
            mediaTimeMs: mediaTimeMs,
            timeline: package.timeline,
            playbackRateObserved: event.payload.playbackRate ?? package.settings.defaultPlaybackRate
        )
        var session = try repository.loadSession(id: event.sessionId) ?? Session(
            id: event.sessionId,
            itemId: event.itemId ?? package.itemId,
            status: "in_progress",
            phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia,
            currentTargetId: package.primaryAudioAsset?.audioAssetId ?? package.id,
            position: Position(),
            completionPercent: 0,
            playbackRate: package.settings.defaultPlaybackRate
        )
        session.currentTargetType = .transcriptBackedMedia
        session.currentTargetId = package.primaryAudioAsset?.audioAssetId ?? package.id
        session.position = Position(
            charOffset: resolved.startChar,
            mediaTimeMs: resolved.mediaTimeMs,
            segmentIndex: package.transcript.segments.firstIndex { $0.id == resolved.transcriptSegmentId },
            chapterId: resolved.chapterId
        )
        session.completionPercent = mediaPercent(mediaTimeMs, package: package)
        session.playbackRate = event.payload.playbackRate ?? session.playbackRate
        currentSession = session
        lastResolvedMediaAnchor = resolved
        try persistSession(session)
    }

    private func unimportedWatchEventCount(sessionId: String) throws -> Int {
        var count = 0
        for event in try repository.loadWatchSyncEvents(sessionId: sessionId) {
            if try !repository.hasImportedWatchSyncEvent(id: event.id) {
                count += 1
            }
        }
        return count
    }

    private func watchInterjectionId(from event: WatchSyncEvent) -> String {
        guard let audioFileName = event.payload.audioFileName, !audioFileName.isEmpty else {
            return event.id.replacingOccurrences(of: "watch-event-", with: "watch-")
        }
        return audioFileName.replacingOccurrences(of: ".m4a", with: "")
    }

    private func queueWatchInterjectionEvent(audioRef: String, session: Session, package: WatchAudioPackage) throws -> WatchSyncEvent {
        let resolved = lastResolvedMediaAnchor ?? resolveMediaAnchor(for: session)
        let audioFileName = audioRef.split(separator: "/").last.map(String.init) ?? audioRef
        let eventId = watchEventId(forAudioFileName: audioFileName)
        let event = WatchSyncEvent(
            id: eventId,
            watchPackageId: package.id,
            sessionId: package.sessionId,
            itemId: package.itemId,
            eventType: "interjection_recorded",
            createdAt: Date(),
            payload: WatchSyncEventPayload(
                mediaTimeMs: resolved.mediaTimeMs,
                chapterId: resolved.chapterId,
                transcriptSegmentId: resolved.transcriptSegmentId,
                playbackRate: resolved.playbackRateObserved,
                audioFileName: audioFileName,
                audioDurationMs: nil,
                error: nil
            )
        )
        try repository.saveWatchSyncEvent(event)
        return event
    }

    private func watchEventId(forAudioFileName audioFileName: String) -> String {
        let base = audioFileName.replacingOccurrences(of: ".m4a", with: "")
        if base.hasPrefix("watch-ij-") {
            return base.replacingOccurrences(of: "watch-ij-", with: "watch-event-ij-")
        }
        return "watch-event-\(base)"
    }

    private func resolveMediaAnchor(for session: Session, playbackPosition: PlaybackPosition? = nil) -> MediaResolvedAnchor {
        let position = playbackPosition ?? self.playbackPosition(for: session)
        if let package = currentWatchPackage {
            return MediaTimelineAnchorResolver.resolve(
                mediaTimeMs: position.mediaTimeMs ?? session.position.mediaTimeMs ?? 0,
                timeline: package.timeline,
                playbackRateObserved: position.playbackRate
            )
        }
        if let timeline = sourceTranscriptTimeline(for: session), !timeline.segments.isEmpty {
            return MediaTimelineAnchorResolver.resolve(
                mediaTimeMs: position.mediaTimeMs ?? session.position.mediaTimeMs ?? 0,
                timeline: timeline,
                playbackRateObserved: position.playbackRate
            )
        }
        return MediaResolvedAnchor(
            mediaTimeMs: position.mediaTimeMs ?? session.position.mediaTimeMs ?? 0,
            chapterId: position.chapterId ?? session.position.chapterId,
            transcriptSegmentId: nil,
            startChar: position.textStart ?? session.position.charOffset,
            endChar: position.textEnd ?? position.textStart ?? session.position.charOffset,
            anchorBefore: "",
            anchorAfter: "",
            playbackRateObserved: position.playbackRate
        )
    }

    private func mediaPercent(_ mediaTimeMs: Int, package: WatchAudioPackage) -> Int {
        guard let duration = package.primaryAudioAsset?.durationMs ?? package.timeline.durationMs,
              duration > 0 else {
            return 0
        }
        return max(0, min(100, Int((Double(mediaTimeMs) / Double(duration)) * 100)))
    }

    private func jumpToMediaChapter(chapterId: String, session: Session) throws -> SessionSnapshot {
        if currentWatchPackage == nil,
           let timeline = sourceTranscriptTimeline(for: session),
           let chapter = timeline.chapters.first(where: { $0.id == chapterId }) {
            var updated = mediaSession(session, movedTo: chapter.startMs)
            updated.currentTargetType = .transcriptBackedMedia
            updated.phase = .itemPlayback
            currentSession = updated
            try persistSession(updated)
            protectPlaybackPosition(for: updated)
            try playCurrentTarget(updated)
            publishPlaybackStart(for: updated, phase: updated.phase)
            return snapshot
        }
        guard let package = currentWatchPackage,
              let chapter = package.chapters.first(where: { $0.id == chapterId }) else {
            throw SessionKitError.invalidCommandForState("jumpToChapter")
        }
        var updated = session
        let resolved = MediaTimelineAnchorResolver.resolve(
            mediaTimeMs: chapter.startMs,
            timeline: package.timeline,
            playbackRateObserved: session.playbackRate
        )
        updated.currentTargetType = .transcriptBackedMedia
        updated.currentTargetId = package.primaryAudioAsset?.audioAssetId ?? package.id
        updated.phase = .itemPlayback
        updated.position = Position(
            charOffset: resolved.startChar,
            mediaTimeMs: resolved.mediaTimeMs,
            segmentIndex: package.transcript.segments.firstIndex { $0.id == resolved.transcriptSegmentId },
            chapterId: resolved.chapterId
        )
        updated.completionPercent = mediaPercent(chapter.startMs, package: package)
        currentSession = updated
        lastResolvedMediaAnchor = resolved
        try persistSession(updated)
        protectPlaybackPosition(for: updated)
        try playCurrentTarget(updated)
        publishPlaybackStart(for: updated, phase: updated.phase)
        return snapshot
    }

    private func skipMediaForward(session: Session, unit: String) throws -> SessionSnapshot {
        var updated = try syncMediaPositionFromAudio(session)
        let duration = mediaDurationMs(for: updated)
        let playbackCompleted = audio.isPlaybackComplete(targetId: updated.currentTargetId)
        let observedCurrent = updated.position.mediaTimeMs ?? 0
        let current = playbackCompleted ? (duration ?? observedCurrent) : observedCurrent
        let next: Int
        if let package = currentWatchPackage, unit == "chapter" {
            next = package.chapters.first(where: { $0.startMs > current })?.startMs ?? package.primaryAudioAsset?.durationMs ?? current
        } else if let intervalMs = mediaSkipIntervalMs(for: unit) {
            next = current + intervalMs
        } else if unit == "chapter", let timeline = sourceTranscriptTimeline(for: session) {
            next = timeline.chapters.first(where: { $0.startMs > current })?.startMs ?? timeline.durationMs ?? current
        } else if let package = currentWatchPackage {
            next = package.transcript.segments.first(where: { $0.startMs > current })?.startMs ?? package.primaryAudioAsset?.durationMs ?? current
        } else if let timeline = sourceTranscriptTimeline(for: session), !timeline.segments.isEmpty {
            next = timeline.segments.first(where: { $0.startMs > current })?.startMs ?? timeline.durationMs ?? current
        } else {
            next = current + 15_000
        }
        let clampedNext = duration.map { max(0, min(next, $0)) } ?? max(0, next)
        updated = mediaSession(updated, movedTo: clampedNext)
        let reachedEnd = duration.map { $0 > 0 && clampedNext >= $0 } ?? playbackCompleted
        if snapshot.status == .playing, !reachedEnd {
            // Keep the current stream/edition. Starting playback here can adopt
            // a background download whose ad timing differs from the stream.
            return try seekMedia(toMediaTimeMs: clampedNext)
        }
        protectPlaybackPosition(for: updated)
        if reachedEnd {
            updated = markPlaybackComplete(updated, item: item(for: updated))
            currentSession = updated
            try persistSession(updated)
            if let duration {
                try audio.seek(toMediaTimeMs: duration)
            }
            try audio.pause()
            publish(status: .paused, phase: updated.phase)
            return snapshot
        }
        currentSession = updated
        try persistSession(updated)
        if snapshot.status.isPlaybackActive {
            try playCurrentTarget(updated)
            publishPlaybackContinuation(for: updated)
            return snapshot
        }
        publish(status: snapshot.status, phase: updated.phase)
        return snapshot
    }

    private func skipMediaBack(session: Session, unit: String) throws -> SessionSnapshot {
        var updated = try syncMediaPositionFromAudio(session)
        let current = updated.position.mediaTimeMs ?? 0
        let previous: Int
        if let package = currentWatchPackage, unit == "chapter" {
            previous = package.chapters.last(where: { $0.startMs < current })?.startMs ?? 0
        } else if let intervalMs = mediaSkipIntervalMs(for: unit) {
            previous = current - intervalMs
        } else if unit == "chapter", let timeline = sourceTranscriptTimeline(for: session) {
            previous = timeline.chapters.last(where: { $0.startMs < current })?.startMs ?? 0
        } else if let package = currentWatchPackage {
            previous = package.transcript.segments.last(where: { $0.startMs < current })?.startMs ?? 0
        } else if let timeline = sourceTranscriptTimeline(for: session), !timeline.segments.isEmpty {
            previous = timeline.segments.last(where: { $0.startMs < current })?.startMs ?? 0
        } else {
            previous = current - 15_000
        }
        updated = reopeningIfMovedBeforeTheEnd(mediaSession(updated, movedTo: previous))
        if snapshot.status == .playing {
            return try seekMedia(toMediaTimeMs: updated.position.mediaTimeMs ?? 0)
        }
        currentSession = updated
        try persistSession(updated)
        protectPlaybackPosition(for: updated)
        if snapshot.status.isPlaybackActive {
            try playCurrentTarget(updated)
            publishPlaybackContinuation(for: updated)
            return snapshot
        }
        publish(status: snapshot.status, phase: updated.phase)
        return snapshot
    }

    /// Moves a source that is about to resume after a saved Margin to `MarginRejoin`'s position,
    /// persists it and protects it from the player's stale clock. Generated turns, and the Watch's
    /// own rollback, keep their exact resume.
    private func rejoiningAfterSavedMargin(_ session: Session) throws -> Session {
        forgetBackTapLanding()
        var rejoined = session
        switch session.currentTargetType {
        case .transcriptBackedMedia, .browserOwnedMedia:
            guard let pausedAtMs = session.position.mediaTimeMs else { return session }
            let resumeAtMs: Int
            if session.currentTargetType == .transcriptBackedMedia,
               let source = item(for: session), isGeneratedTextMedia(source.media),
               let text = source.text, !text.isEmpty,
               PreparedNarrationFallback.media(source.media, isTarget: session.currentTargetId),
               let timeline = sourceTranscriptTimeline(for: session) {
                // The stored timeline belongs to the item's current render, so it is used only while that
                // render is what plays (an older file's times differ after the article is prepared again, #277).
                // An article played as prepared audio is text: it rejoins at the start of its sentence (#806).
                let resume = MarginRejoin.preparedNarrationResume(pausedAtMs: pausedAtMs, text: text, timeline: timeline)
                resumeAtMs = resume.timeMs
                lastMarginRejoin = resume.outcome.rawValue
            } else {
                resumeAtMs = MarginRejoin.mediaResumeTimeMs(pausedAtMs: pausedAtMs)
                lastMarginRejoin = "media_step_back"
            }
            guard resumeAtMs != pausedAtMs else { return session }
            rejoined = mediaSession(session, movedTo: resumeAtMs)
        case .itemTextTTS:
            guard let text = item(for: session)?.text else { return session }
            lastMarginRejoin = "live_sentence_start"
            let start = MarginRejoin.textResumeOffset(pausedAt: session.position.charOffset, in: text)
            guard start != session.position.charOffset else { return session }
            rejoined.position.charOffset = start
            rejoined.position.chapterId = chapterId(for: start)
            rejoined.completionPercent = percent(for: start, text: text)
        case .summaryTurnTTS, .assistantTurnTTS:
            return session
        }
        currentSession = rejoined
        try persistSession(rejoined)
        protectPlaybackPosition(for: rejoined)
        return rejoined
    }

    private func mediaSkipIntervalMs(for unit: String) -> Int? {
        guard unit.hasPrefix("time_"), unit.hasSuffix("s") else { return nil }
        let start = unit.index(unit.startIndex, offsetBy: "time_".count)
        let end = unit.index(before: unit.endIndex)
        guard let seconds = Int(unit[start..<end]), (1...300).contains(seconds) else { return nil }
        return seconds * 1_000
    }

    private func applyMediaRollback(_ session: Session, package: WatchAudioPackage) -> Session {
        let current = session.position.mediaTimeMs ?? 0
        switch package.settings.rollbackUnit {
        case "previous_segment":
            let previous = package.transcript.segments.last(where: { $0.startMs < current })?.startMs ?? 0
            return mediaSession(session, movedTo: previous, package: package)
        case "time_15s":
            return mediaSession(session, movedTo: current - 15_000, package: package)
        case "none":
            return mediaSession(session, movedTo: current, package: package)
        default:
            return mediaSession(session, movedTo: current, package: package)
        }
    }

    private func mediaSession(_ session: Session, movedTo mediaTimeMs: Int, package: WatchAudioPackage) -> Session {
        let duration = package.primaryAudioAsset?.durationMs ?? package.timeline.durationMs ?? mediaTimeMs
        let clamped = max(0, min(mediaTimeMs, duration))
        let resolved = MediaTimelineAnchorResolver.resolve(
            mediaTimeMs: clamped,
            timeline: package.timeline,
            playbackRateObserved: session.playbackRate
        )
        var updated = session
        updated.position = Position(
            charOffset: resolved.startChar,
            mediaTimeMs: resolved.mediaTimeMs,
            segmentIndex: package.transcript.segments.firstIndex { $0.id == resolved.transcriptSegmentId },
            chapterId: resolved.chapterId
        )
        updated.completionPercent = mediaPercent(clamped, package: package)
        lastResolvedMediaAnchor = resolved
        return updated
    }

    private func mediaSession(_ session: Session, movedTo mediaTimeMs: Int) -> Session {
        if let package = currentWatchPackage {
            return mediaSession(session, movedTo: mediaTimeMs, package: package)
        }
        return mediaSession(session, movedTo: mediaTimeMs, durationMs: mediaDurationMs(for: session))
    }

    /// A listener who moves a finished episode back from its end has picked where to listen
    /// next, so it is no longer finished. The app replays a finished session from 0:00 in a
    /// new session, and used to do that even after a scrub back (#643). Skipping text back
    /// (skipBack) and reopening a session below 100% (inspectSession) follow the same rule.
    private func reopeningIfMovedBeforeTheEnd(_ session: Session) -> Session {
        guard session.phase == .finished, session.completionPercent < 100 else { return session }
        var reopened = session
        reopened.phase = .itemPlayback
        reopened.status = "in_progress"
        return reopened
    }

    /// With no known duration the position moves but the percent stays as it was. It
    /// used to fall back to the target itself, so any seek made before a stream
    /// reported its length read as 100% and persistSession marked the item completed
    /// (#293).
    private func mediaSession(_ session: Session, movedTo mediaTimeMs: Int, durationMs duration: Int?) -> Session {
        let clamped = duration.map { max(0, min(mediaTimeMs, $0)) } ?? max(0, mediaTimeMs)
        func percent() -> Int {
            duration == nil ? session.completionPercent : mediaPercent(clamped, durationMs: duration)
        }
        var updated = session
        if let timeline = sourceTranscriptTimeline(for: session), !timeline.segments.isEmpty {
            let resolved = MediaTimelineAnchorResolver.resolve(
                mediaTimeMs: clamped,
                timeline: timeline,
                playbackRateObserved: session.playbackRate
            )
            let textStart = isTextBackedMedia(item(for: session))
                ? generatedTextOffset(mediaTimeMs: clamped, timeline: timeline)
                : resolved.startChar
            updated.position = Position(
                charOffset: textStart,
                mediaTimeMs: resolved.mediaTimeMs,
                segmentIndex: timeline.segments.firstIndex { $0.id == resolved.transcriptSegmentId },
                chapterId: resolved.chapterId
            )
            updated.completionPercent = isTextBackedMedia(item(for: session))
                ? generatedTextSourcePercent(for: session, textStart: textStart)
                : percent()
            lastResolvedMediaAnchor = resolved
            return updated
        }
        updated.position.mediaTimeMs = clamped
        updated.completionPercent = isTextBackedMedia(item(for: session))
            ? generatedTextSourcePercent(for: session, textStart: updated.position.charOffset)
            : percent()
        return updated
    }

    private func chapterId(for charOffset: Int) -> String? {
        currentMap?.chapters.last(where: { $0.startChar <= charOffset })?.id
    }

    private func nextChapterBoundary(after charOffset: Int, text: String) -> Int {
        guard let chapters = currentMap?.chapters, !chapters.isEmpty else {
            return nextBoundary(after: charOffset, unit: "paragraph", text: text)
        }
        if let chapter = chapters.first(where: { $0.startChar > charOffset }) {
            return chapter.startChar
        }
        return text.count
    }

    private func previousChapterBoundary(before charOffset: Int) -> Int {
        guard let chapters = currentMap?.chapters, !chapters.isEmpty else {
            return 0
        }
        if let chapter = chapters.last(where: { $0.startChar < charOffset }) {
            return chapter.startChar
        }
        return 0
    }

    /// `seeking`: the listener moved on purpose (a seek, skip, chapter jump or restart from the
    /// beginning), so a playing client must move even when the new position is close to the live
    /// one. A plain play, resume or rate change isn't a seek (#346).
    private func playCurrentTarget(_ session: Session, seeking: Bool = false) throws {
        if session.currentTargetType == .transcriptBackedMedia || session.currentTargetType == .browserOwnedMedia {
            try audio.configureMediaContext(playbackMediaContext(for: session))
            try audio.play(targetId: session.currentTargetId, fromMediaTimeMs: session.position.mediaTimeMs ?? 0)
            try audio.setPlaybackRate(session.playbackRate)
            return
        }
        try audio.configureMediaContext(nil)
        let plan = try playbackPlan(for: session)
        lastSpokenText = try audio.prepareSpeechText(plan.text)
        if seeking {
            try audio.play(targetId: session.currentTargetId, seekingTo: plan.audioOffset)
        } else {
            try audio.play(targetId: session.currentTargetId, from: plan.audioOffset)
        }
        try audio.setPlaybackRate(session.playbackRate)
    }

    private func playbackMediaContext(for session: Session) -> PlaybackMediaContext? {
        guard let item = currentItem ?? (try? repository.loadItem(id: session.itemId)) else { return nil }
        if pinnedMediaTransport?.sessionId != session.id || pinnedMediaTransport?.targetId != session.currentTargetId {
            pinnedMediaTransport = (session.id, session.currentTargetId, playbackURLOverrides[item.id]
                ?? (item.media?.sourceType == .nativeMediaFile ? item.media?.url : nil))
        }
        let timeline = sourceTranscriptTimeline(for: session)
        let subtitle = [item.externalReferenceType, item.externalReference]
            .compactMap { value -> String? in
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return value
            }
            .joined(separator: " ")
        return PlaybackMediaContext(
            itemId: item.id,
            targetType: session.currentTargetType,
            targetId: session.currentTargetId,
            title: item.title,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            sourceURL: item.media?.url ?? item.externalReference,
            // Native media IDs name library assets; they need not be playable URLs.
            playbackURL: pinnedMediaTransport?.playbackURL,
            artworkURL: nil,
            durationMs: item.media?.durationMs ?? timeline?.durationMs,
            sourceType: item.media?.sourceType,
            chapters: timeline?.chapters ?? []
        )
    }

    private func syncSessionPositionFromAudio(_ session: Session, item: Item?) -> Session {
        let playbackPosition = playbackPosition(for: session)
        guard session.currentTargetType == .itemTextTTS,
              let textStart = playbackPosition.textStart,
              textStart >= 0 else {
            return session
        }
        guard textStart <= (item?.text ?? "").count else { return session }
        var updated = session
        updated.position.charOffset = max(0, min(textStart, item?.text?.count ?? 0))
        updated.completionPercent = percent(for: updated.position.charOffset, text: item?.text ?? "")
        updated.position.chapterId = playbackPosition.chapterId
        return updated
    }

    private func syncGeneratedTurnPositionFromAudio(_ session: Session) throws -> Session {
        guard session.currentTargetType == .summaryTurnTTS || session.currentTargetType == .assistantTurnTTS,
              externallyStreamedTurnId != session.currentTargetId,
              let turn = try repository.loadTurns(sessionId: session.id).first(where: { $0.id == session.currentTargetId }),
              let textStart = playbackPosition(for: session).textStart,
              textStart >= 0 else {
            return session
        }
        let text = generatedTurnNavigationText(for: turn)
        var updated = session
        updated.position.charOffset = max(0, min(textStart, text.count))
        updated.position.chapterId = turn.chapters?.last(where: { $0.startChar <= updated.position.charOffset })?.id
        return updated
    }

    private func syncMediaPositionFromAudio(_ session: Session) throws -> Session {
        let playbackPosition = playbackPosition(for: session)
        guard let mediaTimeMs = playbackPosition.mediaTimeMs ?? session.position.mediaTimeMs else {
            return session
        }
        var updated = session
        updated.position.mediaTimeMs = max(0, mediaTimeMs)
        if let package = currentWatchPackage {
            let resolved = MediaTimelineAnchorResolver.resolve(
                mediaTimeMs: max(0, mediaTimeMs),
                timeline: package.timeline,
                playbackRateObserved: playbackPosition.playbackRate
            )
            updated.position.chapterId = resolved.chapterId
            updated.position.charOffset = resolved.startChar
            updated.position.segmentIndex = package.transcript.segments.firstIndex { $0.id == resolved.transcriptSegmentId }
            updated.completionPercent = mediaPercent(mediaTimeMs, package: package)
            lastResolvedMediaAnchor = resolved
        }
        if currentWatchPackage == nil,
           let timeline = sourceTranscriptTimeline(for: session),
           !timeline.segments.isEmpty {
            let resolved = MediaTimelineAnchorResolver.resolve(
                mediaTimeMs: max(0, mediaTimeMs),
                timeline: timeline,
                playbackRateObserved: playbackPosition.playbackRate
            )
            let textStart = isTextBackedMedia(item(for: session))
                ? generatedTextOffset(mediaTimeMs: mediaTimeMs, timeline: timeline)
                : resolved.startChar
            updated.position.chapterId = resolved.chapterId
            updated.position.charOffset = textStart
            updated.position.segmentIndex = timeline.segments.firstIndex { $0.id == resolved.transcriptSegmentId }
            updated.completionPercent = isTextBackedMedia(item(for: session))
                ? generatedTextSourcePercent(for: session, textStart: textStart)
                : mediaPercent(mediaTimeMs, durationMs: mediaDurationMs(for: session, position: playbackPosition))
            lastResolvedMediaAnchor = resolved
        } else if currentWatchPackage == nil {
            if let timeline = sourceTranscriptTimeline(for: session),
               let chapter = mediaChapter(at: mediaTimeMs, timeline: timeline) {
                updated.position.chapterId = chapter.id
            }
            updated.completionPercent = isTextBackedMedia(item(for: session))
                ? generatedTextSourcePercent(for: session, textStart: playbackPosition.textStart)
                : mediaPercent(mediaTimeMs, durationMs: mediaDurationMs(for: session, position: playbackPosition))
        }
        if !isTextBackedMedia(item(for: session)),
           let durationMs = mediaDurationMs(for: session, position: playbackPosition),
           durationMs > 0 {
            try persistObservedMediaDuration(durationMs, for: session)
            updated = try repairMediaPercentages(updated, durationMs: durationMs)
        }
        return updated
    }

    private func persistObservedMediaDuration(_ durationMs: Int, for session: Session) throws {
        guard durationMs > 0,
              var item = item(for: session),
              var media = item.media else {
            return
        }
        // Feed duration is provisional. Persist a materially different player
        // observation so future sessions and saved interjection percentages do
        // not remain anchored to stale publisher metadata. Ignore sub-second
        // container rounding to avoid rewriting the item every progress tick.
        if let existingDurationMs = media.durationMs,
           abs(existingDurationMs - durationMs) < 1_000 {
            return
        }
        media.durationMs = durationMs
        item.media = media
        try saveItem(item)
        if currentItem?.id == item.id {
            currentItem = item
        }
    }

    private func repairMediaPercentages(_ session: Session, durationMs: Int, forceNotes: Bool = false) throws -> Session {
        guard durationMs > 0,
              !isTextBackedMedia(item(for: session)) else {
            return session
        }
        var updatedSession = session
        if (session.currentTargetType == .transcriptBackedMedia || session.currentTargetType == .browserOwnedMedia),
           let mediaTimeMs = session.position.mediaTimeMs {
            updatedSession.completionPercent = mediaPercent(mediaTimeMs, durationMs: durationMs)
            if updatedSession.completionPercent != session.completionPercent {
                try persistSession(updatedSession)
            }
        }
        guard forceNotes || lastMediaPercentageRepair?.sessionId != session.id
                || lastMediaPercentageRepair?.durationMs != durationMs else { return updatedSession }
        try inRepositoryTransaction {
            for var interjection in try repository.loadInterjections(sessionId: session.id)
            where interjection.targetType == .item {
                guard let mediaTimeMs = interjection.anchor.mediaTimeMs else { continue }
                let percent = mediaPercent(mediaTimeMs, durationMs: durationMs)
                guard percent != interjection.roughPercent else { continue }
                interjection.roughPercent = percent
                try repository.saveInterjection(interjection)
                lastMediaPercentageRepair = nil
            }
        }
        lastMediaPercentageRepair = (session.id, durationMs)
        return updatedSession
    }

    private func reconcilePendingMediaSeek(for session: inout Session) throws -> String? {
        guard let request = protectedPosition.mediaSeekRequest(for: session) else {
            return nil
        }
        let resolution = audio.mediaSeekResolution(for: request)
        lastMediaSeekRequest = request
        lastMediaSeekResolution = resolution
        switch resolution {
        case .pending:
            return nil
        case .accepted:
            self.protectedPosition.release()
            return nil
        case .failed(let actualMediaTimeMs, let reason):
            self.protectedPosition.release()
            if let actualMediaTimeMs,
               (session.currentTargetType == .transcriptBackedMedia || session.currentTargetType == .browserOwnedMedia) {
                session = mediaSession(session, movedTo: actualMediaTimeMs)
                currentSession = session
                try persistSession(session)
            }
            return reason
        }
    }

    private func syncCurrentPositionFromAudio(_ session: Session) throws -> Session {
        guard !protectedPosition.holdsPosition(for: session) else {
            return session
        }
        switch session.currentTargetType {
        case .itemTextTTS:
            return syncSessionPositionFromAudio(session, item: currentItem)
        case .summaryTurnTTS, .assistantTurnTTS:
            return try syncGeneratedTurnPositionFromAudio(session)
        case .transcriptBackedMedia, .browserOwnedMedia:
            return try syncMediaPositionFromAudio(session)
        }
    }

    private func protectPlaybackPosition(
        for session: Session,
        mediaSeekRequest: MediaSeekRequest? = nil
    ) {
        protectedPosition.protect(session, mediaSeekRequest: mediaSeekRequest)
    }

    private func markPlaybackComplete(_ session: Session, item: Item?) -> Session {
        var updated = session
        switch session.currentTargetType {
        case .itemTextTTS:
            let text = item?.text ?? ""
            updated.position.charOffset = text.count
            updated.position.chapterId = chapterId(for: text.count)
            updated.completionPercent = 100
            updated.phase = .finished
            updated.status = "finished"
        case .transcriptBackedMedia, .browserOwnedMedia:
            if isPartialGeneratedTextPlayback(session) {
                let duration = mediaDurationMs(for: session)
                updated = mediaSession(session, movedTo: duration ?? session.position.mediaTimeMs ?? 0)
                updated.phase = .itemPlayback
                return updated
            }
            let duration = mediaDurationMs(for: session)
            if let duration {
                updated.position.mediaTimeMs = duration
            }
            if let timeline = sourceTranscriptTimeline(for: session), let last = timeline.segments.last {
                updated.position.charOffset = last.endChar ?? updated.position.charOffset
                updated.position.segmentIndex = max(0, timeline.segments.count - 1)
                updated.position.chapterId = timeline.chapters.last?.id ?? updated.position.chapterId
            }
            updated.completionPercent = 100
            updated.phase = .finished
            updated.status = "finished"
        case .summaryTurnTTS:
            updated.phase = .summaryPlayback
        case .assistantTurnTTS:
            updated.phase = .aiResponsePlayback
        }
        return updated
    }

    private func playbackPlan(for session: Session) throws -> PlaybackPlan {
        let text = try playbackText(for: session)
        if session.currentTargetType == .summaryTurnTTS || session.currentTargetType == .assistantTurnTTS,
           let turn = try repository.loadTurns(sessionId: session.id).first(where: { $0.id == session.currentTargetId }) {
            let startsAtBeginning = session.position.charOffset == 0 && session.position.chapterId == nil
            return PlaybackPlan(text: text, audioOffset: startsAtBeginning ? 0 : turnAudioOffset(for: turn, responseOffset: session.position.charOffset))
        }
        guard session.currentTargetType == .itemTextTTS else {
            return PlaybackPlan(text: text, audioOffset: session.position.charOffset)
        }
        let prefixLength = itemPlaybackPreface().count
        let startsAtPreface = session.position.charOffset == 0 && session.position.chapterId == nil
        let spokenOffset = listenableProjection()?.spokenCharacterOffset(atOrAfterSourceOffset: session.position.charOffset)
            ?? session.position.charOffset
        let audioOffset = startsAtPreface ? 0 : prefixLength + spokenOffset
        return PlaybackPlan(text: text, audioOffset: audioOffset)
    }

    private func turnAudioOffset(for turn: ConversationTurn, responseOffset: Int) -> Int {
        let summary = turn.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !summary.isEmpty, !text.isEmpty else { return responseOffset }
        return summary.count + 2 + responseOffset
    }

    private func turnResponseOffset(for turn: ConversationTurn, audioOffset: Int) -> Int {
        let summary = turn.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !summary.isEmpty, !text.isEmpty else { return audioOffset }
        return max(0, audioOffset - summary.count - 2)
    }

    private func playbackText(for session: Session) throws -> String {
        switch session.currentTargetType {
        case .itemTextTTS, .transcriptBackedMedia, .browserOwnedMedia:
            if currentItem?.id != session.itemId {
                currentItem = try repository.loadItem(id: session.itemId)
            }
            let itemText = currentItem?.text ?? ""
            guard session.currentTargetType == .itemTextTTS else {
                return itemText
            }
            return itemPlaybackPreface() + (listenableProjection()?.text ?? itemText)
        case .summaryTurnTTS, .assistantTurnTTS:
            guard let turn = try repository.loadTurns(sessionId: session.id).first(where: { $0.id == session.currentTargetId }) else {
                throw SessionKitError.invalidCommandForState("playTurn")
            }
            return playableText(for: turn)
        }
    }

    private func playableText(for turn: ConversationTurn) -> String {
        let summary = turn.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summary.isEmpty, !text.isEmpty {
            return "\(summary)\n\n\(text)"
        }
        if !text.isEmpty { return text }
        if !summary.isEmpty { return summary }
        return turn.rawText ?? ""
    }

    private func generatedTurnNavigationText(for turn: ConversationTurn) -> String {
        let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return text }
        return playableText(for: turn)
    }

    private func itemPlaybackPreface() -> String {
        guard let map = currentMap else { return "" }
        let title = currentItem?.title ?? ""
        return ListeningMapOverviewText.spokenPreface(
            overview: map.overview,
            title: title,
            chapterCount: map.chapters.count,
            textOpening: String((listenableProjection()?.text ?? currentItem?.text ?? "").prefix(title.count * 2 + 200))
        )
    }

    private func turnTitle(for turn: ConversationTurn) -> String {
        ConversationTurnTitle.numbered(turn)
    }

    private func itemSourceOffset(forAudioOffset audioOffset: Int) -> Int {
        let prefixLength = itemPlaybackPreface().count
        if prefixLength > 0, audioOffset <= prefixLength {
            return 0
        }
        let spokenOffset = audioOffset - prefixLength
        return listenableProjection()?.sourceOffset(atSpokenCharacterOffset: spokenOffset) ?? spokenOffset
    }

    /// For a PDF imported with extraction v2 (C1 M3): what the speech engines are
    /// given instead of Item.text, with every character's offset in Item.text, so
    /// positions and written Margins stay in Item.text (I14: skipping never moves an
    /// anchor). Nil for every other item, and for a document whose text isn't
    /// exactly Item.text.
    private func listenableProjection() -> NormalizedSpeechText? {
        guard let item = currentItem, item.mediaType == "pdf", let text = item.text else { return nil }
        if let cache = listenableCache, cache.itemId == item.id, cache.textLength == text.count {
            return cache.projection
        }
        let document = try? (repository as? StructuredDocumentRepository)?.loadStructuredDocument(itemId: item.id)
        let projection = StructuredDocumentSpeech.listenableProjection(item: item, document: document)
        listenableCache = (item.id, text.count, projection)
        return projection
    }

    private func generatedListeningMap(for item: Item) -> ListeningMap {
        let text = listeningMapText(for: item)
        let starts = generatedChapterStarts(for: text)
        let chapters = starts.enumerated().map { index, start in
            let end = index + 1 < starts.count ? starts[index + 1] : text.count
            let title = generatedChapterTitle(text: text, start: start, end: end, index: index)
            return Chapter(
                id: "ch-generated-\(String(format: "%02d", index + 1))",
                title: title,
                startChar: start,
                endChar: max(start, end),
                percent: percent(for: start, text: text)
            )
        }
        return ListeningMap(
            id: "map-\(item.id)-generated",
            itemId: item.id,
            overview: generatedOverview(for: item, chapters: chapters),
            chapters: chapters
        )
    }

    private func listeningMapText(for item: Item) -> String {
        if let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        guard let timeline = sourceTranscriptTimeline(itemId: item.id) else { return "" }
        return timeline.segments
            .sorted { $0.startMs < $1.startMs }
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedSourceTranscriptTimeline(_ timeline: TranscriptTimeline) -> (text: String, timeline: TranscriptTimeline) {
        let sortedSegments = timeline.segments.sorted { $0.startMs < $1.startMs }
        var fullText = ""
        var normalizedSegments: [MediaTimelineSegment] = []
        for (index, segment) in sortedSegments.enumerated() {
            let text = segment.text
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if !fullText.isEmpty {
                fullText.append(" ")
            }
            let start = fullText.count
            fullText.append(text)
            let end = fullText.count
            normalizedSegments.append(MediaTimelineSegment(
                id: segment.id.isEmpty ? "seg-\(String(format: "%04d", index + 1))" : segment.id,
                startMs: max(0, segment.startMs),
                endMs: max(segment.startMs + 1, segment.endMs),
                startChar: start,
                endChar: end,
                text: text
            ))
        }
        let duration = timeline.durationMs
            ?? normalizedSegments.map(\.endMs).max()
        let chapters = normalizedSourceTranscriptChapters(
            existing: timeline.chapters,
            segments: normalizedSegments
        )
        return (
            fullText,
            TranscriptTimeline(
                segments: normalizedSegments,
                chapters: chapters,
                durationMs: duration
            )
        )
    }

    private func normalizedSourceTranscriptChapters(
        existing: [MediaTimelineChapter],
        segments: [MediaTimelineSegment]
    ) -> [MediaTimelineChapter] {
        guard !segments.isEmpty else { return [] }
        let semanticChapters = existing.filter { !isSyntheticTranscriptChapter($0) }
        if !semanticChapters.isEmpty {
            return semanticChapters.compactMap { chapter in
                let segment = segments.last(where: { $0.startMs <= chapter.startMs }) ?? segments.first
                guard let segment else { return nil }
                return MediaTimelineChapter(
                    id: chapter.id,
                    title: chapter.title,
                    description: chapter.description,
                    startMs: max(0, chapter.startMs),
                    transcriptSegmentId: segment.id
                )
            }
        }
        return []
    }

    private func isSyntheticTranscriptChapter(_ chapter: MediaTimelineChapter) -> Bool {
        chapter.id.hasPrefix("ch-transcript-") || chapter.id.contains("-ch-transcript-")
    }

    private func generatedChapterStarts(for text: String) -> [Int] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [0] }
        let sentenceStarts = sentenceStartOffsets(in: text)
        guard sentenceStarts.count > 8 else { return sentenceStarts }
        let targetCount = min(12, max(5, Int((Double(text.count) / 900.0).rounded(.up))))
        let stride = max(1, Int((Double(sentenceStarts.count) / Double(targetCount)).rounded(.up)))
        var starts = sentenceStarts.enumerated().compactMap { index, start in
            index % stride == 0 ? start : nil
        }
        if starts.first != 0 { starts.insert(0, at: 0) }
        return Array(starts.prefix(12))
    }

    private func sentenceStartOffsets(in text: String) -> [Int] {
        let chars = Array(text)
        var starts = [0]
        var index = 0
        while index < chars.count {
            if ".!?".contains(chars[index]) {
                let next = index + 1 + consumeSpaces(chars, from: index + 1)
                if next < chars.count {
                    starts.append(next)
                }
            }
            index += 1
        }
        return Array(NSOrderedSet(array: starts)) as? [Int] ?? starts
    }

    private func generatedChapterTitle(text: String, start: Int, end: Int, index: Int) -> String {
        let raw = slice(text, start: start, end: min(end, nextBoundary(after: start, unit: "sentence", text: text)))
        let words = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .prefix(6)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?;:,"))
        return words.isEmpty ? "Chapter \(index + 1)" : words
    }

    private func generatedOverview(for item: Item, chapters: [Chapter]) -> String {
        ListeningMapOverviewText.appGenerated(title: item.title, chapterCount: chapters.count)
    }

    private func percent(for charOffset: Int, text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return min(100, max(0, Int((Double(charOffset) / Double(text.count)) * 100)))
    }

    private func percent(offset: Int, length: Int) -> Int {
        guard length > 0 else { return 0 }
        return min(100, max(0, Int((Double(offset) / Double(length)) * 100)))
    }

    private func nextBoundary(after offset: Int, unit: String, text: String) -> Int {
        guard offset < text.count else { return text.count }
        if unit == "paragraph" {
            return nextParagraphBoundary(after: offset, text: text)
        }
        if unit == "section" {
            return min(text.count, offset + max(500, text.count / 10))
        }
        let chars = Array(text)
        let boundaryCharacters: Set<Character> = [".", "?", "!"]
        for index in min(offset + 1, chars.count)..<chars.count where boundaryCharacters.contains(chars[index]) {
            return min(chars.count, index + 1 + consumeSpaces(chars, from: index + 1))
        }
        return text.count
    }

    private func previousBoundary(before offset: Int, unit: String, text: String) -> Int {
        guard offset > 0 else { return 0 }
        if unit == "paragraph" {
            return previousParagraphBoundary(before: offset, text: text)
        }
        if unit == "section" {
            return max(0, offset - max(500, text.count / 10))
        }
        let chars = Array(text)
        let boundaryCharacters: Set<Character> = [".", "?", "!"]
        var index = min(offset - 1, chars.count - 1)
        while index > 0 {
            if boundaryCharacters.contains(chars[index]) {
                let boundary = min(chars.count, index + 1 + consumeSpaces(chars, from: index + 1))
                if boundary < offset {
                    return boundary
                }
            }
            index -= 1
        }
        return 0
    }

    /// Drops the place the last Back tap landed. A position within `BackTapWindow` of it reads as that tap's repeat,
    /// which holds only while the listener goes on hearing from there; anything else that moves the position within
    /// a target (Forward, a seek or scrub, a chapter jump, a Margin's rejoin) makes the next Back measure from the
    /// place the listener is now (#1122). Another session or target is a different `targetKey`, so it needs no call.
    private func forgetBackTapLanding() {
        lastBackTapLanding = nil
    }

    /// Where a Back tap lands, and what the next one measures from (#1102).
    private func backTapBoundary(from offset: Int, unit: String, text: String, session: Session) -> Int {
        let targetKey = "\(session.id)|\(session.currentTargetId)"
        let landing = backTapLanding(
            from: offset, unit: unit, text: text, window: BackTapWindow.characters(atSpeed: session.playbackRate), targetKey: targetKey
        )
        // A section is a fixed step, not a unit with a start, so it never counts as a place to walk back from.
        lastBackTapLanding = unit == "section" ? nil : (targetKey, landing)
        return landing
    }

    /// A position within `BackTapWindow` of where the last Back tap put the listener is that tap's repeat, so it
    /// goes on to the unit before that, even over a unit shorter than the speech since. Otherwise a position
    /// within the window of the start of the unit it is in counts as at that start, so Back goes to the unit
    /// before; further in, it goes to this unit's start.
    private func backTapLanding(from offset: Int, unit: String, text: String, window: Int, targetKey: String) -> Int {
        guard unit != "section", offset > 0 else {
            return previousBoundary(before: offset, unit: unit, text: text)
        }
        if let last = lastBackTapLanding, last.targetKey == targetKey,
           last.charOffset <= offset, offset - last.charOffset < window {
            return previousBoundary(before: last.charOffset, unit: unit, text: text)
        }
        let unitStart = previousBoundary(before: offset + 1, unit: unit, text: text)
        guard offset - unitStart < window else {
            return previousBoundary(before: offset, unit: unit, text: text)
        }
        return previousBoundary(before: unitStart, unit: unit, text: text)
    }

    private func nextParagraphBoundary(after offset: Int, text: String) -> Int {
        let chars = Array(text)
        guard offset < chars.count else { return text.count }
        var index = min(offset + 1, chars.count - 1)
        while index < chars.count {
            if chars[index] == "\n" {
                return min(chars.count, index + 1 + consumeSpaces(chars, from: index + 1))
            }
            index += 1
        }
        return nextBoundary(after: offset, unit: "sentence", text: text)
    }

    private func previousParagraphBoundary(before offset: Int, text: String) -> Int {
        let chars = Array(text)
        guard offset > 0, !chars.isEmpty else { return 0 }
        var index = min(offset - 1, chars.count - 1)
        while index > 0 {
            if chars[index] == "\n" {
                let boundary = min(chars.count, index + 1 + consumeSpaces(chars, from: index + 1))
                if boundary < offset {
                    return boundary
                }
            }
            index -= 1
        }
        return previousBoundary(before: offset, unit: "sentence", text: text)
    }

    private func consumeSpaces(_ chars: [Character], from start: Int) -> Int {
        var count = 0
        var idx = start
        while idx < chars.count, chars[idx].isWhitespace {
            count += 1
            idx += 1
        }
        return count
    }

    private func slice(_ text: String, start: Int, end: Int) -> String {
        let lower = text.index(text.startIndex, offsetBy: max(0, min(start, text.count)))
        let upper = text.index(text.startIndex, offsetBy: max(0, min(end, text.count)))
        return String(text[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractResponseText(from raw: String) -> String {
        if let start = raw.range(of: "<sm_response>")?.upperBound {
            let body = raw[start...]
            if let end = body.range(of: "</sm_response>")?.lowerBound {
                return String(body[..<end])
            }
            if let malformedStart = body.range(of: "<sm_chapters_json>")?.lowerBound {
                return String(body[..<malformedStart])
            }
            return String(body)
        }
        return raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    private struct ParsedAssistantResponse {
        var summary: String?
        var response: String
        var chapters: [Chapter]
    }

    private func parseSectionedResponse(from raw: String) -> ParsedAssistantResponse {
        let summary = extractTag("sm_summary", from: raw)
        let response = extractResponseText(from: raw)
        let chapters = extractAssistantChapters(from: raw, responseText: response)
        return ParsedAssistantResponse(summary: summary?.isEmpty == true ? nil : summary, response: response, chapters: chapters)
    }

    private func extractTag(_ tag: String, from raw: String) -> String? {
        guard let start = raw.range(of: "<\(tag)>")?.upperBound else { return nil }
        let body = raw[start...]
        guard let end = body.range(of: "</\(tag)>")?.lowerBound else {
            return String(body).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(body[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractAssistantChapters(from raw: String, responseText: String) -> [Chapter] {
        guard let json = extractTag("sm_chapters_json", from: raw),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schemaVersion"] as? String == "assistant-response-map.v1",
              let rawChapters = object["chapters"] as? [[String: Any]] else {
            return []
        }
        return rawChapters.enumerated().compactMap { _, object in
            guard let id = object["id"] as? String,
                  let title = object["title"] as? String,
                  let anchor = object["anchor"] as? String,
                  let range = responseText.range(of: anchor) else {
                return nil
            }
            let start = responseText.distance(from: responseText.startIndex, to: range.lowerBound)
            let end = responseText.distance(from: responseText.startIndex, to: range.upperBound)
            return Chapter(
                id: id,
                title: title,
                startChar: start,
                endChar: end,
                percent: percent(for: start, text: responseText)
            )
        }
    }

    private func completeSentenceUnits(in text: String) -> [String] {
        sentenceUnits(in: text, includeTrailingFragment: false)
    }

    /// A saved media position that moves back by more than this is logged with the command that wrote it (#2186).
    static let backwardPositionLogThresholdMs = 60_000

    /// Receives the fields of a `position.backward` event. The app records them in Diagnostics.
    public var positionDiagnosticHandler: (([String: String]) -> Void)?
    /// The last backward write, for `diagnostics()`.
    private var lastBackwardPositionWrite: String?
    /// The media position last saved for each session, so a write can be compared with what the previous one left.
    private var lastSavedMediaTimeMs: [String: Int] = [:]

    /// Logs a media position write that goes back by more than a minute. Every legitimate move back (a seek,
    /// a skip back, Play from the beginning) enters through a command, whose name is `source`; one that
    /// arrives from `syncPlaybackProgress` or a pause is a player sample that rewound the listener (#2186).
    private func noteMediaPositionWrite(_ session: Session, source: String) {
        guard session.currentTargetType == .transcriptBackedMedia || session.currentTargetType == .browserOwnedMedia,
              let newMs = session.position.mediaTimeMs else { return }
        let previousMs = lastSavedMediaTimeMs[session.id]
            ?? (try? repository.loadSession(id: session.id))?.position.mediaTimeMs
        guard let previousMs, previousMs - newMs > Self.backwardPositionLogThresholdMs else { return }
        let fields = [
            "event": "position_backward",
            "source": source,
            "sessionId": session.id,
            "itemId": session.itemId,
            "fromMs": "\(previousMs)",
            "toMs": "\(newMs)",
            "playerMs": audio.currentMediaTimeMs().map(String.init) ?? "none",
            "status": snapshot.status.rawValue,
            "positionPending": protectedPosition.holdsPosition(for: session) ? "yes" : "no"
        ]
        lastBackwardPositionWrite = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        positionDiagnosticHandler?(fields)
    }

    private func persistSession(_ session: Session, source: String = #function) throws {
        noteMediaPositionWrite(session, source: source)
        var stamped = session
        let timestamp = now()
        if stamped.createdAt == nil {
            stamped.createdAt = timestamp
        }
        stamped.updatedAt = timestamp
        if stamped.status == "finished", stamped.completedAt == nil {
            stamped.completedAt = timestamp
        }
        try repository.saveSession(storedForm(of: stamped))
        lastSavedMediaTimeMs[stamped.id] = stamped.position.mediaTimeMs
        lastProgressWriteAt[stamped.id] = timestamp
        if unsavedProgressSessionId == stamped.id { unsavedProgressSessionId = nil }
        if stamped.completionPercent > 98,
           completionPercentIsMeasured(stamped),
           var item = try? repository.loadItem(id: stamped.itemId),
           item.sourceCompletedAt == nil {
            item.sourceCompletedAt = timestamp
            try saveItem(item)
            if currentItem?.id == item.id { currentItem = item }
        }
        if currentSession?.id == stamped.id {
            currentSession = stamped
        }
    }

    /// The session as the Library stores it. A session playing a publisher recording is stored as the
    /// article being read at the same place, which Build 29 resumes with on-device speech (#547).
    private func storedForm(of session: Session) -> Session {
        guard let plan = publisherPlayback[session.itemId], let item = item(for: session) else { return session }
        return plan.stored(session, item: item)
    }

    /// A media percent is only as good as the length it was divided by. It completes the
    /// item only when this item's own length is known, or when the player reported
    /// reaching the end (phase .finished). An unknown length once made any seek read as
    /// 100%, and Build 29 episodes were marked completed on upgrade (#293, #352).
    /// A summary or reply keeps the item's percent while it plays, so the rule follows
    /// the item, not what is playing.
    private func completionPercentIsMeasured(_ session: Session) -> Bool {
        let item = item(for: session)
        let mediaTargetId: String?
        switch session.currentTargetType {
        case .transcriptBackedMedia, .browserOwnedMedia:
            mediaTargetId = session.currentTargetId
        case .summaryTurnTTS, .assistantTurnTTS:
            guard let item, playbackTargetType(for: item) != .itemTextTTS else { return true }
            mediaTargetId = item.media?.url
        case .itemTextTTS:
            return true
        }
        guard session.phase != .finished, !isTextBackedMedia(item) else {
            return true
        }
        let playerDurationMs = audio.currentPlaybackPosition().flatMap {
            $0.targetId == mediaTargetId ? $0.durationMs : nil
        }
        let packageDurationMs = currentWatchPackage.flatMap {
            $0.itemId == session.itemId ? $0.primaryAudioAsset?.durationMs ?? $0.timeline.durationMs : nil
        }
        return [durableMediaDurationMs(for: session), packageDurationMs, playerDurationMs].contains { ($0 ?? 0) > 0 }
    }

    private func sentenceUnits(in text: String, includeTrailingFragment: Bool) -> [String] {
        var units: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if [".", "?", "!"].contains(char) {
                let unit = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !unit.isEmpty { units.append(unit) }
                current = ""
            }
        }
        if includeTrailingFragment {
            let unit = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !unit.isEmpty { units.append(unit) }
        }
        return units
    }
}

public struct SummaryScope: Equatable {
    public var targetType: String?
    public var sessionId: String?
    public var turnId: String?
    public var interjectionIds: [String]?

    public init(targetType: String? = nil, sessionId: String? = nil, turnId: String? = nil, interjectionIds: [String]? = nil) {
        self.targetType = targetType
        self.sessionId = sessionId
        self.turnId = turnId
        self.interjectionIds = interjectionIds
    }
}

public struct NoopAudioPlaybackClient: AudioPlaybackClient {
    public init() {}
    public func prepareSpeechText(_ text: String) throws -> String { SpeechTextNormalizer.normalize(text) }
    public func play(targetId: String) throws {}
    public func pause() throws {}
}

public struct UnsupportedLinkResolutionClient: LinkResolutionClient {
    public init() {}

    public func resolve(_ request: LinkResolutionRequest) throws -> LinkResolutionResult {
        LinkResolutionResult(
            requestId: request.id,
            status: .unsupported,
            originalLink: SourceLink(url: request.inputURL, role: "discovery"),
            failureReason: "no_link_resolver_configured"
        )
    }
}

public struct NoopRecordingClient: RecordingClient {
    public init() {}
    public func beginRecording() throws {}
    public func finishRecording(audioRef: String?) throws -> String { audioRef ?? "interjections/generated.m4a" }
    public func cancelRecording() throws {}
}

public struct DeferredTranscriptionClient: TranscriptionClient {
    public init() {}
    public func scheduleTranscription(interjection: Interjection) throws {}
}

public struct DeterministicAIProvider: AIProviderClient {
    public let providerType: String
    public let model: String

    public init(providerType: String = "deterministic_test", model: String = "gate1-fixture-model") {
        self.providerType = providerType
        self.model = model
    }
}
