import Foundation

public enum NativeTextStartupAudioState: String, Hashable, Sendable {
    case notRequired = "not_required"
    case waiting // queued behind the one Library item being prepared now (#281)
    case preparing
    case ready
    case paused
    case failed
}

public struct LibraryItemRow: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let status: String
    public let canDelete: Bool
    public var hasContinuationSession: Bool
    public var continuationProgressPercent: Int?
    public let isCompleted: Bool
    public let mediaType: String
    public let hasNativeAudio: Bool
    public let sourceTitle: String?
    public let sourceURL: String?
    public let author: String?
    public let sourceReference: String?
    public let sourceReferenceType: String?
    public var offlineState: LibraryOfflineStateFilter
    public var startupAudioState: NativeTextStartupAudioState
    public var startupAudioCompletedChunkCount: Int
    public var startupAudioTargetChunkCount: Int
    public let addedAt: Date?
    /// When the publisher released it, for the Published sort (#1867); nil when the feed gave no usable date.
    public var publishedAt: Date?
    public let lastListenedAt: Date?
    public let storageRecencyRank: Int
    /// A PDF read through the structured-document reader (#359).
    public var usesNewReader = false
    /// Marked complete by hand, not finished by listening, so Mark Unfinished can clear it (#273).
    public var canMarkUnfinished = false
    public var textCharacterCount: Int?  // a text item's length for its time estimate (#305); nil for recorded audio
    /// Margins other people shared on this item, and how many of them the listener hasn't heard (#1792).
    public var sharedMargins = SharedMarginTally.none
    /// How many Margins the listener has made on this item (#2394), so a row can be cleared without opening it to look.
    public var marginCount = 0

    public init(
        id: String,
        title: String,
        status: String,
        canDelete: Bool,
        hasContinuationSession: Bool = false,
        continuationProgressPercent: Int? = nil,
        isCompleted: Bool = false,
        mediaType: String = "text",
        hasNativeAudio: Bool = false,
        sourceTitle: String? = nil,
        sourceURL: String? = nil,
        author: String? = nil,
        sourceReference: String? = nil,
        sourceReferenceType: String? = nil,
        offlineState: LibraryOfflineStateFilter = .onlineOnly,
        startupAudioState: NativeTextStartupAudioState = .notRequired,
        startupAudioCompletedChunkCount: Int = 0,
        startupAudioTargetChunkCount: Int = 0,
        addedAt: Date? = nil,
        lastListenedAt: Date? = nil,
        storageRecencyRank: Int = .max
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.canDelete = canDelete
        self.hasContinuationSession = hasContinuationSession
        self.continuationProgressPercent = continuationProgressPercent
        self.isCompleted = isCompleted
        self.hasNativeAudio = hasNativeAudio
        self.mediaType = mediaType
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.author = author
        self.sourceReference = sourceReference
        self.sourceReferenceType = sourceReferenceType
        self.offlineState = offlineState
        self.startupAudioState = startupAudioState
        self.startupAudioCompletedChunkCount = max(0, startupAudioCompletedChunkCount)
        self.startupAudioTargetChunkCount = max(0, startupAudioTargetChunkCount)
        self.addedAt = addedAt
        self.lastListenedAt = lastListenedAt
        self.storageRecencyRank = storageRecencyRank
    }

    /// The SF Symbol the Library row shows for this kind of item.
    public var mediaSymbol: String {
        if hasNativeAudio { return "headphones" }
        return switch mediaType.lowercased() {
        case "podcast", "audio", "audiobook", "m4a", "m4b", "mp3":
            "headphones"
        case "pdf":
            "doc.richtext"
        case "epub":
            "book.closed"
        default:
            "doc.text"
        }
    }
}
