import Foundation

public enum CompactControlCommand: String, Codable, CaseIterable, Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case skipBack
    case skipForward
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
        playbackRate: Double,
        isRecording: Bool,
        pendingAiJobCount: Int,
        pendingAiJobKind: String?,
        pendingAiJobStatus: String?,
        lastUserTurnType: String?,
        exposedCommands: [CompactControlCommand],
        timeline: [CompactTimelineEntry] = [],
        compactSurfaceReady: Bool,
        surfaceProfileId: String
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
        self.playbackRate = playbackRate
        self.isRecording = isRecording
        self.pendingAiJobCount = pendingAiJobCount
        self.pendingAiJobKind = pendingAiJobKind
        self.pendingAiJobStatus = pendingAiJobStatus
        self.lastUserTurnType = lastUserTurnType
        self.exposedCommands = exposedCommands
        self.availableCommands = exposedCommands
        self.timeline = timeline
        self.compactSurfaceReady = compactSurfaceReady
        self.surfaceProfileId = surfaceProfileId
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
}

public final class CompactControlDispatcher {
    public private(set) var surfaceProfile: RuntimeCapabilityProfile
    private let canonicalRuntime: SessionEngine
    private let defaultSkipUnit: String

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

    @discardableResult
    public func dispatch(
        _ command: CompactControlCommand,
        chapterId: String? = nil,
        unit: String? = nil,
        followUpText: String? = nil,
        summaryScope: SummaryScope? = nil
    ) throws -> CompactControlResult {
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
        return CompactControlResult(snapshot: compactSnapshot(from: updated), delegatedToCanonicalRuntime: true)
    }

    private func validate(_ command: CompactControlCommand) throws {
        guard surfaceProfile.has("remoteControl", "display_snapshot") else {
            throw SessionKitError.invalidCommandForCapability(command.rawValue)
        }

        switch command {
        case .play, .pause, .togglePlayPause, .skipBack, .skipForward:
            guard surfaceProfile.has("remoteControl", "send_transport_commands") else {
                throw SessionKitError.invalidCommandForCapability(command.rawValue)
            }
        case .jumpToChapter:
            guard surfaceProfile.has("timeline", "chapter_timing"),
                  surfaceProfile.has("remoteControl", "send_chapter_jump") else {
                throw SessionKitError.invalidCommandForCapability(command.rawValue)
            }
        case .beginInterjection, .finishInterjection, .cancelInterjection:
            guard surfaceProfile.has("interjection", "delegate_interjection_to_canonical_runtime"),
                  surfaceProfile.has("remoteControl", "send_interjection_commands") else {
                throw SessionKitError.invalidCommandForCapability(command.rawValue)
            }
        case .generateInterjectionSummary, .submitFollowup:
            guard surfaceProfile.has("remoteControl", "send_ai_commands") else {
                throw SessionKitError.invalidCommandForCapability(command.rawValue)
            }
        }
    }

    private func compactSnapshot(from snapshot: SessionSnapshot) -> CompactControlSnapshot {
        let canDisplay = surfaceProfile.has("remoteControl", "display_snapshot")
        let commands = CompactControlCommand.allCases.filter { command in
            switch command {
            case .play, .pause, .togglePlayPause, .skipBack, .skipForward:
                return surfaceProfile.has("remoteControl", "send_transport_commands")
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
            case .generateInterjectionSummary, .submitFollowup:
                return !snapshot.isRecording
                    && surfaceProfile.has("remoteControl", "send_ai_commands")
            }
        }

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
            playbackRate: snapshot.playbackRate,
            isRecording: snapshot.isRecording,
            pendingAiJobCount: snapshot.pendingAiJobCount,
            pendingAiJobKind: snapshot.pendingAiJobKind,
            pendingAiJobStatus: snapshot.pendingAiJobStatus,
            lastUserTurnType: snapshot.lastUserTurnType,
            exposedCommands: commands,
            timeline: canonicalRuntime.compactTimelineEntries(),
            compactSurfaceReady: canDisplay && snapshot.sessionId != nil,
            surfaceProfileId: surfaceProfile.id
        )
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
