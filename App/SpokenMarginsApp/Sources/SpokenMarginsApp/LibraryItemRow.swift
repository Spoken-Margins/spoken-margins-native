import Foundation
import SessionKit

enum NativeTextStartupAudioState: String, Hashable {
    case notRequired = "not_required"
    case waiting // queued behind the one Library item being prepared now (#281)
    case preparing
    case ready
    case paused
    case failed
}

struct LibraryItemRow: Identifiable, Hashable {
    let id: String
    let title: String
    let status: String
    let canDelete: Bool
    var hasContinuationSession: Bool
    var continuationProgressPercent: Int?
    let isCompleted: Bool
    let mediaType: String
    let hasNativeAudio: Bool
    let sourceTitle: String?
    let sourceURL: String?
    let author: String?
    let sourceReference: String?
    let sourceReferenceType: String?
    var offlineState: LibraryOfflineStateFilter
    var startupAudioState: NativeTextStartupAudioState
    var startupAudioCompletedChunkCount: Int
    var startupAudioTargetChunkCount: Int
    let addedAt: Date?
    let lastListenedAt: Date?
    let storageRecencyRank: Int
    /// A PDF read through the structured-document reader (#359).
    var usesNewReader = false
    /// Marked complete by hand, not finished by listening, so Mark Unfinished can clear it (#273).
    var canMarkUnfinished = false
    var textCharacterCount: Int?  // a text item's length for its time estimate (#305); nil for recorded audio

    init(
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
}
