import Foundation

public enum SessionKitError: Error, Equatable, CustomStringConvertible {
    case invalidCommandForCapability(String)
    case invalidCommandForState(String)
    case missingFixture(String)
    case persistenceFailed(String)

    public var description: String {
        switch self {
        case .invalidCommandForCapability(let command):
            return "invalid_command_for_capability:\(command)"
        case .invalidCommandForState(let command):
            return "invalid_command_for_state:\(command)"
        case .missingFixture(let id):
            return "missing_fixture:\(id)"
        case .persistenceFailed(let message):
            return "persistence_failed:\(message)"
        }
    }
}

public enum SessionPhase: String, Codable, Equatable, Sendable {
    case idle
    case itemPlayback = "item_playback"
    case recordingInterjection = "recording_interjection"
    case interjectionSummary = "interjection_summary"
    case summaryPlayback = "summary_playback"
    case addendumCapture = "addendum_capture"
    case aiResponsePlayback = "ai_response_playback"
    case conversation
    case finished
    case abandoned
}

public enum PlaybackStatus: String, Codable, Equatable, Sendable {
    case idle
    case playing
    case paused
    case recording
    case failed
}

public enum TargetType: String, Codable, Equatable, Sendable {
    case itemTextTTS = "item_text_tts"
    case transcriptBackedMedia = "transcript_backed_media"
    case assistantTurnTTS = "assistant_turn_tts"
    case summaryTurnTTS = "summary_turn_tts"
    case browserOwnedMedia = "browser_owned_media"
}

public enum InterjectionTargetType: String, Codable, Equatable, Sendable {
    case item
    case summaryTurn = "summary_turn"
    case assistantTurn = "assistant_turn"
}

public enum AnchorType: String, Codable, Equatable, Sendable {
    case text
    case transcript
    case media
    case turn
}

public struct RuntimeCapabilityProfile: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let capabilities: [String: [String]]
    public let forbiddenCapabilities: [String]

    public init(id: String, displayName: String, capabilities: [String: [String]], forbiddenCapabilities: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.forbiddenCapabilities = forbiddenCapabilities
    }

    public func has(_ category: String, _ capability: String) -> Bool {
        capabilities[category, default: []].contains(capability)
    }

    public func hasAny(_ category: String, _ candidates: [String]) -> Bool {
        candidates.contains { has(category, $0) }
    }
}

public struct Item: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var mediaType: String
    public var text: String?
    public var externalReference: String?
    public var externalReferenceType: String?
    public var status: String

    public init(
        id: String,
        title: String,
        mediaType: String,
        text: String?,
        externalReference: String?,
        status: String,
        externalReferenceType: String? = nil
    ) {
        self.id = id
        self.title = title
        self.mediaType = mediaType
        self.text = text
        self.externalReference = externalReference
        self.externalReferenceType = externalReferenceType
        self.status = status
    }
}

public enum BrowserTextCaptureMode: String, Codable, Equatable, Sendable {
    case selectedText = "selected_text"
    case readablePage = "readable_page"
}

public struct BrowserTextSource: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    public var author: String?
    public var publishedAt: String?

    public init(url: String, title: String, author: String? = nil, publishedAt: String? = nil) {
        self.url = url
        self.title = title
        self.author = author
        self.publishedAt = publishedAt
    }
}

public struct BrowserTextSelection: Codable, Equatable, Sendable {
    public var textStart: Int?
    public var textEnd: Int?
    public var prefix: String?
    public var suffix: String?

    public init(textStart: Int? = nil, textEnd: Int? = nil, prefix: String? = nil, suffix: String? = nil) {
        self.textStart = textStart
        self.textEnd = textEnd
        self.prefix = prefix
        self.suffix = suffix
    }
}

public struct BrowserTextContinuation: Codable, Equatable, Sendable {
    public var startSession: Bool
    public var preferredPlaybackOwner: String?

    public init(startSession: Bool = false, preferredPlaybackOwner: String? = nil) {
        self.startSession = startSession
        self.preferredPlaybackOwner = preferredPlaybackOwner
    }
}

public struct BrowserTextHandoff: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var itemId: String?
    public var captureMode: BrowserTextCaptureMode
    public var source: BrowserTextSource
    public var text: String
    public var selection: BrowserTextSelection?
    public var requestedContinuation: BrowserTextContinuation

    public init(
        schemaVersion: String = "browser-text-handoff.v1",
        itemId: String? = nil,
        captureMode: BrowserTextCaptureMode,
        source: BrowserTextSource,
        text: String,
        selection: BrowserTextSelection? = nil,
        requestedContinuation: BrowserTextContinuation = BrowserTextContinuation()
    ) {
        self.schemaVersion = schemaVersion
        self.itemId = itemId
        self.captureMode = captureMode
        self.source = source
        self.text = text
        self.selection = selection
        self.requestedContinuation = requestedContinuation
    }
}

public struct Chapter: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var startChar: Int
    public var endChar: Int
    public var percent: Int

    public init(id: String, title: String, startChar: Int, endChar: Int, percent: Int) {
        self.id = id
        self.title = title
        self.startChar = startChar
        self.endChar = endChar
        self.percent = percent
    }
}

public struct ListeningMap: Codable, Equatable, Sendable {
    public var id: String
    public var itemId: String
    public var overview: String
    public var chapters: [Chapter]

    public init(id: String, itemId: String, overview: String, chapters: [Chapter]) {
        self.id = id
        self.itemId = itemId
        self.overview = overview
        self.chapters = chapters
    }
}

public struct Position: Codable, Equatable, Sendable {
    public var charOffset: Int
    public var mediaTimeMs: Int?
    public var segmentIndex: Int?
    public var chapterId: String?

    public init(charOffset: Int = 0, mediaTimeMs: Int? = nil, segmentIndex: Int? = nil, chapterId: String? = nil) {
        self.charOffset = charOffset
        self.mediaTimeMs = mediaTimeMs
        self.segmentIndex = segmentIndex
        self.chapterId = chapterId
    }
}

public struct Anchor: Codable, Equatable, Sendable {
    public var anchorType: AnchorType
    public var startChar: Int
    public var endChar: Int
    public var anchorBefore: String
    public var anchorAfter: String
    public var mediaTimeMs: Int?
    public var playbackRateObserved: Double
    public var transcriptSegmentId: String?
    public var turnSegmentIndex: Int?

    public init(
        anchorType: AnchorType,
        startChar: Int,
        endChar: Int,
        anchorBefore: String,
        anchorAfter: String,
        mediaTimeMs: Int? = nil,
        playbackRateObserved: Double = 1,
        transcriptSegmentId: String? = nil,
        turnSegmentIndex: Int? = nil
    ) {
        self.anchorType = anchorType
        self.startChar = startChar
        self.endChar = endChar
        self.anchorBefore = anchorBefore
        self.anchorAfter = anchorAfter
        self.mediaTimeMs = mediaTimeMs
        self.playbackRateObserved = playbackRateObserved
        self.transcriptSegmentId = transcriptSegmentId
        self.turnSegmentIndex = turnSegmentIndex
    }
}

public struct Interjection: Codable, Equatable, Sendable {
    public var id: String
    public var itemId: String
    public var sessionId: String
    public var targetType: InterjectionTargetType
    public var targetId: String
    public var createdAt: Date
    public var roughPercent: Int
    public var anchor: Anchor
    public var audioPath: String?
    public var audioStatus: String
    public var transcriptionStatus: String
    public var transcript: String?
    public var cleanedTranscript: String?
    public var displayText: String?
    public var status: String
}

public struct ConversationTurn: Codable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var role: String
    public var turnType: String
    public var status: String
    public var summary: String?
    public var text: String?
    public var rawText: String?
    public var chapters: [Chapter]? = nil
    public var sourceInterjectionIds: [String]
}

public struct AIJob: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var itemId: String?
    public var sessionId: String
    public var turnId: String?
    public var providerType: String
    public var model: String
    public var status: String
    public var attempts: Int
    public var lastError: String?
    public var messages: [String]
    public var playbackMode: String?
}

public struct Session: Codable, Equatable, Sendable {
    public var id: String
    public var itemId: String
    public var status: String
    public var phase: SessionPhase
    public var currentTargetType: TargetType
    public var currentTargetId: String
    public var position: Position
    public var completionPercent: Int
    public var playbackRate: Double
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var itemId: String?
    public var targetType: String?
    public var targetId: String?
    public var status: PlaybackStatus
    public var phase: SessionPhase
    public var title: String?
    public var chapterTitle: String?
    public var progressPercent: Int
    public var sourceProgressPercent: Int
    public var currentPlaybackProgressPercent: Int
    public var playbackRate: Double
    public var isRecording: Bool
    public var activeInterjectionCount: Int
    public var pendingAiJobCount: Int
    public var lastInterjectionAnchorType: AnchorType?
    public var lastInterjectionTargetType: InterjectionTargetType?
    public var recordingTargetId: String?
    public var pendingAiJobKind: String?
    public var pendingAiJobStatus: String?
    public var providerCallStarted: Bool
    public var turnStatus: String?
    public var lastUserTurnType: String?
    public var spokenUnits: [String]
    public var lastFailure: String?

    public init() {
        sessionId = nil
        itemId = nil
        targetType = nil
        targetId = nil
        status = .idle
        phase = .idle
        title = nil
        chapterTitle = nil
        progressPercent = 0
        sourceProgressPercent = 0
        currentPlaybackProgressPercent = 0
        playbackRate = 1
        isRecording = false
        activeInterjectionCount = 0
        pendingAiJobCount = 0
        lastInterjectionAnchorType = nil
        lastInterjectionTargetType = nil
        recordingTargetId = nil
        pendingAiJobKind = nil
        pendingAiJobStatus = nil
        providerCallStarted = false
        turnStatus = nil
        lastUserTurnType = nil
        spokenUnits = []
        lastFailure = nil
    }
}
