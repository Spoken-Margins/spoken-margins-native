import Foundation

public enum CompactControlCommand: String, Codable, CaseIterable, Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case skipBack
    case skipForward
    case skimBackward
    case skimForward
    case seekToMediaTime
    case setPlaybackRate
    case jumpToChapter
    case beginInterjection
    case finishInterjection
    case cancelInterjection
    case generateInterjectionSummary
    case submitFollowup
}

public struct CompactControlSnapshot: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var itemId: String?
    public var targetType: String?
    public var targetId: String?
    public var title: String?
    public var chapterTitle: String?
    public var status: PlaybackStatus
    public var phase: SessionPhase
    public var progressPercent: Int
    public var currentPlaybackProgressPercent: Int
    public var sourceProgressPercent: Int
    public var currentMediaTimeMs: Int?
    public var currentPlaybackDurationMs: Int?
    public var currentTranscriptSegmentId: String?
    public var currentAnchorConfidence: AnchorConfidence?
    public var playbackRate: Double
    public var isRecording: Bool
    public var pendingAiJobCount: Int
    public var pendingAiJobKind: String?
    public var pendingAiJobStatus: String?
    public var lastUserTurnType: String?
    public var exposedCommands: [CompactControlCommand]
    public var availableCommands: [CompactControlCommand]
    public var timeline: [CompactTimelineEntry]
    public var compactSurfaceReady: Bool
    public var surfaceProfileId: String
    public var skimBridgeState: SkimBridgeState?
    public var canSkimForward: Bool
    public var canSkimBackward: Bool
    /// Where Skim forward and back would land, so the Lock Screen can say it (#115). Nil when
    /// that Skim isn't available. Optional, so a snapshot encoded without them still decodes.
    public var skimForwardDestinationMs: Int?
    public var skimBackwardDestinationMs: Int?

    public init(
        sessionId: String?,
        itemId: String?,
        targetType: String?,
        targetId: String?,
        title: String?,
        chapterTitle: String?,
        status: PlaybackStatus,
        phase: SessionPhase,
        progressPercent: Int,
        currentPlaybackProgressPercent: Int,
        sourceProgressPercent: Int,
        currentMediaTimeMs: Int? = nil,
        currentPlaybackDurationMs: Int? = nil,
        currentTranscriptSegmentId: String? = nil,
        currentAnchorConfidence: AnchorConfidence? = nil,
        playbackRate: Double,
        isRecording: Bool,
        pendingAiJobCount: Int,
        pendingAiJobKind: String?,
        pendingAiJobStatus: String?,
        lastUserTurnType: String?,
        exposedCommands: [CompactControlCommand],
        availableCommands: [CompactControlCommand]? = nil,
        timeline: [CompactTimelineEntry] = [],
        compactSurfaceReady: Bool,
        surfaceProfileId: String,
        skimBridgeState: SkimBridgeState? = nil,
        canSkimForward: Bool = false,
        canSkimBackward: Bool = false,
        skimForwardDestinationMs: Int? = nil,
        skimBackwardDestinationMs: Int? = nil
    ) {
        self.sessionId = sessionId
        self.itemId = itemId
        self.targetType = targetType
        self.targetId = targetId
        self.title = title
        self.chapterTitle = chapterTitle
        self.status = status
        self.phase = phase
        self.progressPercent = progressPercent
        self.currentPlaybackProgressPercent = currentPlaybackProgressPercent
        self.sourceProgressPercent = sourceProgressPercent
        self.currentMediaTimeMs = currentMediaTimeMs
        self.currentPlaybackDurationMs = currentPlaybackDurationMs
        self.currentTranscriptSegmentId = currentTranscriptSegmentId
        self.currentAnchorConfidence = currentAnchorConfidence
        self.playbackRate = playbackRate
        self.isRecording = isRecording
        self.pendingAiJobCount = pendingAiJobCount
        self.pendingAiJobKind = pendingAiJobKind
        self.pendingAiJobStatus = pendingAiJobStatus
        self.lastUserTurnType = lastUserTurnType
        self.exposedCommands = exposedCommands
        self.availableCommands = availableCommands ?? exposedCommands
        self.timeline = timeline
        self.compactSurfaceReady = compactSurfaceReady
        self.surfaceProfileId = surfaceProfileId
        self.skimBridgeState = skimBridgeState
        self.canSkimForward = canSkimForward
        self.canSkimBackward = canSkimBackward
        self.skimForwardDestinationMs = skimForwardDestinationMs
        self.skimBackwardDestinationMs = skimBackwardDestinationMs
    }
}

extension CompactControlCommand {
    /// The commands a headphone click, a car button or the Lock Screen sends. While a Margin records,
    /// the listener's hands are busy and any of them means "that's the Margin" (#1030).
    public var endsRecordingMargin: Bool {
        switch self {
        case .play, .pause, .togglePlayPause, .skipForward:
            return true
        case .skipBack, .skimBackward, .skimForward, .seekToMediaTime, .setPlaybackRate, .jumpToChapter,
             .beginInterjection, .finishInterjection, .cancelInterjection, .generateInterjectionSummary,
             .submitFollowup:
            return false
        }
    }
}

extension CompactControlSnapshot {
    /// What the listener hears, for the Lock Screen card (#2965). A Skim summary plays while the source is paused
    /// under it; the card says playing then, not "Paused, tap to resume", whose tap would send Play to a source
    /// that has moved on by the time it lands. A summary that is preparing reads as starting, so the card says
    /// Loading. A source that is itself playing or recording keeps its own status.
    public var audibleStatus: PlaybackStatus {
        guard status == .paused, let skimBridgeState else { return status }
        switch skimBridgeState.status {
        case .preparing: return .starting
        case .playing, .completing: return .playing
        case .paused, .cancelled: return status
        }
    }

    /// A Margin is recording and this surface may finish it, so the system transport commands must reach
    /// the app and end the Margin. Now Playing keeps them enabled for that; disabled, iOS never delivers
    /// the headphone click and the Margin can't be ended without touching the screen (#1030).
    public var transportCommandsEndMargin: Bool {
        isRecording && availableCommands.contains(.finishInterjection)
    }
}

public struct CompactTimelineEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var title: String
    public var detail: String?
    public var chapterId: String?
    public var turnId: String?
    public var percent: Int?
    public var isCurrent: Bool

    public init(
        id: String,
        kind: String,
        title: String,
        detail: String? = nil,
        chapterId: String? = nil,
        turnId: String? = nil,
        percent: Int? = nil,
        isCurrent: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.chapterId = chapterId
        self.turnId = turnId
        self.percent = percent
        self.isCurrent = isCurrent
    }
}

public struct CompactControlResult: Equatable, Sendable {
    public var snapshot: CompactControlSnapshot
    public var delegatedToCanonicalRuntime: Bool
    public var rejectedReason: String?

    public init(snapshot: CompactControlSnapshot, delegatedToCanonicalRuntime: Bool, rejectedReason: String? = nil) {
        self.snapshot = snapshot
        self.delegatedToCanonicalRuntime = delegatedToCanonicalRuntime
        self.rejectedReason = rejectedReason
    }

    /// Play reached a source that was already playing, or Pause one already paused (#2965).
    public static let alreadyPlaying = "already_playing"
    public static let alreadyPaused = "already_paused"

    /// The source already had what the command asked for, so nothing ran and nothing failed.
    public var isAlreadyInRequestedState: Bool {
        !delegatedToCanonicalRuntime
            && (rejectedReason == Self.alreadyPlaying || rejectedReason == Self.alreadyPaused)
    }
}

public final class CompactControlDispatcher {
    public private(set) var surfaceProfile: RuntimeCapabilityProfile
    private let canonicalRuntime: SessionEngine
    private let defaultSkipUnit: String
    /// The timeline and the summary check read the session's Margins and turns from the store. The card is rebuilt on
    /// every playback tick, so they are kept until something they show changes (#2505).
    private var timelineCache: TimelineCache?
    private var contentRevision = 0

    private struct TimelineKey: Equatable {
        var sessionId: String?
        var itemId: String?
        var targetType: TargetType?
        var targetId: String?
        var chapterId: String?
        var itemTitle: String?
        var map: ListeningMap?
        var snapshotTargetType: String?
        var snapshotTargetId: String?
        var isRecording: Bool
        var activeInterjectionCount: Int
        var pendingAiJobCount: Int
        var pendingAiJobStatus: String?
        var turnStatus: String?
        var lastUserTurnType: String?
        var revision: Int
    }

    private struct TimelineCache {
        var key: TimelineKey
        var entries: [CompactTimelineEntry]
        var hasSummaryCandidates: Bool?
    }

    public init(
        surfaceProfile: RuntimeCapabilityProfile,
        canonicalRuntime: SessionEngine,
        defaultSkipUnit: String = "paragraph"
    ) {
        self.surfaceProfile = surfaceProfile
        self.canonicalRuntime = canonicalRuntime
        self.defaultSkipUnit = defaultSkipUnit
    }

    public func updateSurfaceProfile(_ profile: RuntimeCapabilityProfile) {
        surfaceProfile = profile
    }

    public func snapshot() -> CompactControlSnapshot {
        compactSnapshot(from: canonicalRuntime.snapshot)
    }

    /// A Margin or a turn changed outside the engine (saved, deleted, transcribed in the app): the next card reads them again.
    public func noteContentChanged() {
        contentRevision &+= 1
    }

    private func timelineKey(_ snapshot: SessionSnapshot) -> TimelineKey {
        let session = canonicalRuntime.currentSession
        return TimelineKey(
            sessionId: session?.id, itemId: session?.itemId, targetType: session?.currentTargetType,
            targetId: session?.currentTargetId, chapterId: session?.position.chapterId,
            itemTitle: canonicalRuntime.currentItem?.title, map: canonicalRuntime.currentMap,
            snapshotTargetType: snapshot.targetType, snapshotTargetId: snapshot.targetId, isRecording: snapshot.isRecording,
            activeInterjectionCount: snapshot.activeInterjectionCount, pendingAiJobCount: snapshot.pendingAiJobCount,
            pendingAiJobStatus: snapshot.pendingAiJobStatus, turnStatus: snapshot.turnStatus,
            lastUserTurnType: snapshot.lastUserTurnType, revision: contentRevision)
    }

    /// The cache for this snapshot, emptied when its key moved.
    private func currentTimelineCache(_ snapshot: SessionSnapshot) -> TimelineCache {
        let key = timelineKey(snapshot)
        if let cached = timelineCache, cached.key == key { return cached }
        let fresh = TimelineCache(key: key, entries: canonicalRuntime.compactTimelineEntries())
        timelineCache = fresh
        return fresh
    }

    private func hasSummaryCandidates(_ snapshot: SessionSnapshot) -> Bool {
        var cache = currentTimelineCache(snapshot)
        if let known = cache.hasSummaryCandidates { return known }
        let answer = canonicalRuntime.hasSummaryCandidates(scope: defaultSummaryScope())
        cache.hasSummaryCandidates = answer
        timelineCache = cache
        return answer
    }

    @discardableResult
    public func dispatch(
        _ command: CompactControlCommand,
        chapterId: String? = nil,
        unit: String? = nil,
        mediaTimeMs: Int? = nil,
        playbackRate: Double? = nil,
        followUpText: String? = nil,
        summaryScope: SummaryScope? = nil
    ) throws -> CompactControlResult {
        // While a start is pending the system card shows Play, because its clock must not run (#943).
        // Before that change the card showed Pause and a tap cancelled the load, so a Play tap during a
        // pending start still cancels it: the listener asked to stop waiting, not to start again.
        // The same holds when playing audio has stalled for the network: the adapter publishes rate 0
        // (Play glyph) while the engine still says playing, and `validate` would refuse that Play.
        if command == .play,
           canonicalRuntime.snapshot.status == .starting
            || (canonicalRuntime.snapshot.status == .playing
                && canonicalRuntime.currentPlaybackTransportState() == .waiting),
           surfaceProfile.has("remoteControl", "send_transport_commands") {
            let paused = try canonicalRuntime.pause()
            return CompactControlResult(snapshot: compactSnapshot(from: paused), delegatedToCanonicalRuntime: true)
        }
        if let reason = alreadyInRequestedState(command) {
            return CompactControlResult(
                snapshot: compactSnapshot(from: canonicalRuntime.snapshot),
                delegatedToCanonicalRuntime: false,
                rejectedReason: reason
            )
        }
        try validate(command)
        let updated: SessionSnapshot
        switch command {
        case .play:
            updated = try canonicalRuntime.resumePlayback()
        case .pause:
            updated = try canonicalRuntime.pause()
        case .togglePlayPause:
            updated = try canonicalRuntime.togglePlayPause()
        case .skipBack:
            updated = try canonicalRuntime.skipBack(unit: unit ?? defaultSkipUnit)
        case .skipForward:
            updated = try canonicalRuntime.skipForward(unit: unit ?? defaultSkipUnit)
        case .skimBackward, .skimForward:
            throw SessionKitError.invalidCommandForState("skim_requires_app_bridge")
        case .seekToMediaTime:
            guard let mediaTimeMs else {
                throw SessionKitError.invalidCommandForState("seekToMediaTime")
            }
            updated = try canonicalRuntime.seekMedia(toMediaTimeMs: mediaTimeMs)
        case .setPlaybackRate:
            guard let playbackRate else {
                throw SessionKitError.invalidCommandForState("setPlaybackRate")
            }
            updated = try canonicalRuntime.setPlaybackRate(playbackRate)
        case .jumpToChapter:
            guard let chapterId else {
                throw SessionKitError.invalidCommandForState("jumpToChapter")
            }
            updated = try canonicalRuntime.jumpToChapter(chapterId: chapterId)
        case .beginInterjection:
            updated = try canonicalRuntime.beginInterjection()
        case .finishInterjection:
            updated = try canonicalRuntime.finishInterjection(audioRef: nil)
        case .cancelInterjection:
            updated = try canonicalRuntime.cancelInterjection()
        case .generateInterjectionSummary:
            updated = try canonicalRuntime.generateInterjectionSummary(scope: summaryScope ?? defaultSummaryScope())
        case .submitFollowup:
            updated = try canonicalRuntime.submitFollowup(text: normalizedFollowUpText(followUpText))
        }
        noteContentChanged() // a command may have saved a Margin or a turn the snapshot doesn't count
        return CompactControlResult(snapshot: compactSnapshot(from: updated), delegatedToCanonicalRuntime: true)
    }

    /// A card or a Lock Screen button is drawn from the state when it was last published, so its tap can land
    /// after the state moved on: Play on a source that is playing again, Pause on one that already paused. The
    /// listener has what they asked for, so that is a no-op rather than a failure (#2965). A recording Margin, a
    /// session the surface can't show and a command this surface doesn't expose still go to `validate`.
    private func alreadyInRequestedState(_ command: CompactControlCommand) -> String? {
        let snapshot = canonicalRuntime.snapshot
        guard command == .play || command == .pause,
              !snapshot.isRecording,
              surfaceProfile.has("remoteControl", "display_snapshot"),
              surfaceProfile.has("remoteControl", "send_transport_commands"),
              isCompactSessionEligible(snapshot) else {
            return nil
        }
        if command == .play, snapshot.status.isPlaybackActive { return CompactControlResult.alreadyPlaying }
        if command == .pause, snapshot.status == .paused { return CompactControlResult.alreadyPaused }
        return nil
    }

    private func validate(_ command: CompactControlCommand) throws {
        guard surfaceProfile.has("remoteControl", "display_snapshot") else {
            throw SessionKitError.invalidCommandForCapability(command.rawValue)
        }
        let compact = compactSnapshot(from: canonicalRuntime.snapshot)
        guard compact.exposedCommands.contains(command) else {
            throw SessionKitError.invalidCommandForCapability(command.rawValue)
        }
        guard compact.availableCommands.contains(command) else {
            throw SessionKitError.invalidCommandForState(command.rawValue)
        }
    }

    private func compactSnapshot(from snapshot: SessionSnapshot) -> CompactControlSnapshot {
        let canDisplay = surfaceProfile.has("remoteControl", "display_snapshot")
        let exposedCommands = CompactControlCommand.allCases.filter { command in
            switch command {
            case .play, .pause, .togglePlayPause, .skipBack, .skipForward:
                return surfaceProfile.has("remoteControl", "send_transport_commands")
            case .skimBackward, .skimForward:
                return surfaceProfile.has("remoteControl", "send_transport_commands")
                    && surfaceProfile.has("timeline", "chapter_timing")
            case .seekToMediaTime:
                return surfaceProfile.has("remoteControl", "send_transport_commands")
                    && surfaceProfile.has("timeline", "media_time")
            case .setPlaybackRate:
                return surfaceProfile.has("remoteControl", "send_transport_commands")
                    && surfaceProfile.has("timeline", "playback_rate_observation")
            case .jumpToChapter:
                return surfaceProfile.has("timeline", "chapter_timing")
                    && surfaceProfile.has("remoteControl", "send_chapter_jump")
            case .beginInterjection:
                return !snapshot.isRecording
                    && surfaceProfile.has("interjection", "delegate_interjection_to_canonical_runtime")
                    && surfaceProfile.has("remoteControl", "send_interjection_commands")
            case .finishInterjection, .cancelInterjection:
                return snapshot.isRecording
                    && surfaceProfile.has("interjection", "delegate_interjection_to_canonical_runtime")
                    && surfaceProfile.has("remoteControl", "send_interjection_commands")
            case .generateInterjectionSummary:
                return !snapshot.isRecording
                    && surfaceProfile.has("remoteControl", "send_ai_commands")
                    && surfaceProfile.has("ai", "summarize_interjections")
            case .submitFollowup:
                return !snapshot.isRecording
                    && surfaceProfile.has("remoteControl", "send_ai_commands")
                    && surfaceProfile.has("ai", "continue_discussion")
            }
        }
        let availableCommands = exposedCommands.filter { command in
            isCommandAvailable(command, snapshot: snapshot)
        }

        let compactSurfaceReady = canDisplay && isCompactSessionEligible(snapshot)
        return CompactControlSnapshot(
            sessionId: snapshot.sessionId,
            itemId: snapshot.itemId,
            targetType: snapshot.targetType,
            targetId: snapshot.targetId,
            title: snapshot.title,
            chapterTitle: compactChapterTitle(from: snapshot),
            status: snapshot.status,
            phase: snapshot.phase,
            progressPercent: snapshot.progressPercent,
            currentPlaybackProgressPercent: snapshot.currentPlaybackProgressPercent,
            sourceProgressPercent: snapshot.sourceProgressPercent,
            currentMediaTimeMs: snapshot.currentMediaTimeMs,
            currentPlaybackDurationMs: snapshot.currentPlaybackDurationMs,
            currentTranscriptSegmentId: snapshot.currentTranscriptSegmentId,
            currentAnchorConfidence: snapshot.currentAnchorConfidence,
            playbackRate: snapshot.playbackRate,
            isRecording: snapshot.isRecording,
            pendingAiJobCount: snapshot.pendingAiJobCount,
            pendingAiJobKind: snapshot.pendingAiJobKind,
            pendingAiJobStatus: snapshot.pendingAiJobStatus,
            lastUserTurnType: snapshot.lastUserTurnType,
            exposedCommands: exposedCommands,
            availableCommands: availableCommands,
            timeline: currentTimelineCache(snapshot).entries,
            compactSurfaceReady: compactSurfaceReady,
            surfaceProfileId: surfaceProfile.id,
            skimBridgeState: snapshot.skimBridgeState,
            canSkimForward: snapshot.canSkimForward,
            canSkimBackward: snapshot.canSkimBackward
        )
    }

    private func isCommandAvailable(_ command: CompactControlCommand, snapshot: SessionSnapshot) -> Bool {
        guard surfaceProfile.has("remoteControl", "display_snapshot"),
              isCompactSessionEligible(snapshot) else {
            return false
        }

        switch command {
        case .play:
            return !snapshot.isRecording && !snapshot.status.isPlaybackActive
        case .pause:
            return !snapshot.isRecording && snapshot.status.isPlaybackActive
        case .togglePlayPause:
            return !snapshot.isRecording
        case .skipBack, .skipForward:
            return !snapshot.isRecording
        case .skimBackward:
            return !snapshot.isRecording && snapshot.canSkimBackward
        case .skimForward:
            return !snapshot.isRecording && snapshot.canSkimForward
        case .seekToMediaTime:
            return !snapshot.isRecording
                && snapshot.currentPlaybackDurationMs != nil
                && (snapshot.targetType == TargetType.transcriptBackedMedia.rawValue
                    || snapshot.targetType == TargetType.browserOwnedMedia.rawValue)
        case .setPlaybackRate:
            return !snapshot.isRecording
                && (snapshot.targetType == TargetType.itemTextTTS.rawValue
                    || snapshot.targetType == TargetType.assistantTurnTTS.rawValue
                    || snapshot.targetType == TargetType.summaryTurnTTS.rawValue
                    || snapshot.currentPlaybackDurationMs != nil)
        case .jumpToChapter:
            return !snapshot.isRecording
        case .beginInterjection:
            return !snapshot.isRecording
                && snapshot.skimBridgeState == nil
                && surfaceProfile.has("interjection", "delegate_interjection_to_canonical_runtime")
        case .finishInterjection, .cancelInterjection:
            return snapshot.isRecording
                && surfaceProfile.has("interjection", "delegate_interjection_to_canonical_runtime")
        case .generateInterjectionSummary:
            return !snapshot.isRecording
                && surfaceProfile.has("remoteControl", "send_ai_commands")
                && surfaceProfile.has("ai", "summarize_interjections")
                && hasSummaryCandidates(snapshot)
        case .submitFollowup:
            return !snapshot.isRecording
                && surfaceProfile.has("remoteControl", "send_ai_commands")
                && surfaceProfile.has("ai", "continue_discussion")
        }
    }

    private func isCompactSessionEligible(_ snapshot: SessionSnapshot) -> Bool {
        guard snapshot.sessionId != nil else { return false }
        switch snapshot.phase {
        case .abandoned:
            return false
        case .finished where snapshot.status == .idle:
            return false
        default:
            return true
        }
    }

    private func compactChapterTitle(from snapshot: SessionSnapshot) -> String? {
        guard snapshot.targetType == TargetType.itemTextTTS.rawValue else {
            return snapshot.chapterTitle
        }
        if snapshot.chapterTitle == "Summary" || snapshot.chapterTitle?.isEmpty != false {
            if let chapterId = canonicalRuntime.currentSession?.position.chapterId,
               let chapter = canonicalRuntime.currentMap?.chapters.first(where: { $0.id == chapterId }) {
                return chapter.title
            }
            return canonicalRuntime.currentMap?.chapters.first?.title ?? snapshot.title
        }
        return snapshot.chapterTitle
    }

    private func defaultSummaryScope() -> SummaryScope {
        let snapshot = canonicalRuntime.snapshot
        switch snapshot.targetType {
        case TargetType.summaryTurnTTS.rawValue, TargetType.assistantTurnTTS.rawValue:
            return SummaryScope(targetType: "turn", sessionId: snapshot.sessionId, turnId: snapshot.targetId)
        default:
            return SummaryScope(targetType: "item", sessionId: snapshot.sessionId)
        }
    }

    private func normalizedFollowUpText(_ text: String?) throws -> String {
        let trimmed = (text ?? "Can you respond to my interjection?").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SessionKitError.invalidCommandForState("submitFollowup")
        }
        return trimmed
    }
}
