import Foundation
import SessionKit

extension LibraryItemRow: LibraryQueryRow {}

struct WrittenMarginDraft: Equatable {
    let capture: WrittenInterjectionCapture
    var text: String
    let itemTitle: String
    let targetDescription: String
    let progressPercent: Int
    /// The shared Margin this note answers, and whether the listener switched it to independent (#473).
    var replyChoice = MarginReplyChoice()
    var reply: MarginReplyDraft? { replyChoice.effective }

    var captureID: String { capture.id }
    var priorWasPlaying: Bool { capture.wasPlaying }
    var lockedSessionID: String { capture.sessionId }
    var lockedItemID: String { capture.itemId }
    var lockedTargetID: String { capture.targetId }
}

enum AppRoot: String, CaseIterable, Identifiable, Hashable, Sendable {
    case library
    case sources
    case margins
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .sources: "Following"
        case .margins: "Margins"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .library: "books.vertical"
        case .sources: "dot.radiowaves.left.and.right"
        case .margins: "quote.bubble"
        case .settings: "gearshape"
        }
    }
}

enum AppRoute: Hashable, Sendable {
    case item(String)
    case nowPlaying
    case timeline(String?)
    case marginDetail(String)
    case settings
    case offlineStorage
    case export(String?)
    case batchExport
    case help
}

enum TimelinePullPresentation {
    static let activationDistance: CGFloat = 72

    static func overscrollDistance(
        contentOffsetY: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        bottomInset: CGFloat,
        topInset: CGFloat = 0
    ) -> CGFloat {
        let maximumScrollOffset = max(-topInset, contentHeight + bottomInset - containerHeight)
        return max(0, contentOffsetY - maximumScrollOffset)
    }

    static func shouldOpenTimeline(overscrollDistance: CGFloat) -> Bool {
        overscrollDistance >= activationDistance
    }
}

enum TimelineTextPresentation {
    static let marginCharacterLimit = 180
    static let supportingCharacterLimit = 280

    static func excerpt(_ text: String, characterLimit: Int) -> String {
        let normalized = text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard normalized.count > characterLimit else { return normalized }

        let boundary = normalized.index(normalized.startIndex, offsetBy: characterLimit)
        let prefix = normalized[..<boundary]
        // The limit lands exactly after a word: it fits whole, so keep it.
        if normalized[boundary] == " " { return String(prefix) + "…" }
        if let wordBoundary = prefix.lastIndex(of: " ") {
            return String(prefix[..<wordBoundary]) + "…"
        }
        return String(prefix) + "…"
    }
}

enum AddSourceRoute: String, CaseIterable, Identifiable, Hashable, Sendable {
    case linkOrPodcast
    case pastedText
    case documentOrBook
    case audiobook
    case quickFolder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linkOrPodcast: "Link or Podcast"
        case .pastedText: "Paste Text"
        case .documentOrBook: "Document or Book"
        case .audiobook: "Audiobook"
        case .quickFolder: "Quick Folder"
        }
    }

    var detail: String {
        switch self {
        case .linkOrPodcast: "Podcast episode, RSS feed, public audio, or readable web link"
        case .pastedText: "Create a listening item from text already on your clipboard"
        case .documentOrBook: "Plain text, Markdown, text-based PDF, DRM-free EPUB, or a Listening Edition"
        case .audiobook: "Import an app-owned MP3, M4A, M4B, or audio-bearing MP4"
        case .quickFolder: "Choose a folder whose eligible files appear in Sources"
        }
    }

    var systemImage: String {
        switch self {
        case .linkOrPodcast: "link"
        case .pastedText: "text.quote"
        case .documentOrBook: "doc.richtext"
        case .audiobook: "headphones"
        case .quickFolder: "folder"
        }
    }
}

enum AddSourcePresentation {
    static let primaryObjectRoutes: [AddSourceRoute] = [
        .linkOrPodcast,
        .pastedText,
        .documentOrBook,
        .audiobook
    ]
}

/// Scene-local presentation state. Playback and persistence remain in
/// `Gate1AppModel`; switching roots must not replace an active session.
struct AppNavigationState: Equatable, Sendable {
    var selectedRoot: AppRoot = .library
    var paths: [AppRoot: [AppRoute]] = [
        .library: [],
        .sources: [],
        .margins: [],
        .settings: []
    ]
    var taskRoute: AppRoute?
    var addSourceRoute: AddSourceRoute?
    /// "Search podcasts by name" in the add sheet: the sheet closes first, then the catalog opens (#1784).
    var opensCatalogAfterAddSheet = false
    /// Where Following was scrolled to, kept across the screen switches that destroy its list (#479).
    var followingScroll = FollowingScrollMemory()
    /// The same for the Library list, whose rows are also destroyed when an item opens (#2395).
    var libraryScroll = FollowingScrollMemory()

    mutating func select(_ root: AppRoot, recordingIsLocked: Bool) {
        guard !recordingIsLocked else { return }
        selectedRoot = root
    }

    mutating func push(_ route: AppRoute, in root: AppRoot? = nil, recordingIsLocked: Bool) {
        guard !recordingIsLocked else { return }
        let destination = root ?? selectedRoot
        paths[destination, default: []].append(route)
    }

    mutating func present(_ route: AppRoute, recordingIsLocked: Bool) {
        guard !recordingIsLocked else { return }
        taskRoute = route
    }

    mutating func searchPodcastsFromAddSheet() {
        addSourceRoute = nil
        opensCatalogAfterAddSheet = true
    }

    /// True once per request, so a later dismissal of the sheet doesn't open the catalog again.
    mutating func takeCatalogRequest() -> Bool {
        defer { opensCatalogAfterAddSheet = false }
        return opensCatalogAfterAddSheet
    }

    mutating func dismissTask(recordingIsLocked: Bool) {
        guard !recordingIsLocked else { return }
        taskRoute = nil
    }
}

enum LibraryPresentation {
    static let continuationSuggestionCutoffPercent = 99

    static func continueItem(in rows: [LibraryItemRow], activeItemId: String?) -> LibraryItemRow? {
        if let activeItemId,
           let active = rows.first(where: {
               $0.id == activeItemId
                   && !$0.isCompleted
                   && $0.hasContinuationSession
                   && ($0.continuationProgressPercent ?? 0) < continuationSuggestionCutoffPercent
           }) {
            return active
        }

        return rows
            .filter {
                !$0.isCompleted && $0.hasContinuationSession
                    && ($0.continuationProgressPercent ?? 0) > 0
                    && ($0.continuationProgressPercent ?? 0) < continuationSuggestionCutoffPercent
            }
            .sorted {
                let lhs = $0.lastListenedAt ?? .distantPast
                let rhs = $1.lastListenedAt ?? .distantPast
                return lhs == rhs ? $0.id < $1.id : lhs > rhs
            }
            .first
    }
}

enum TimelineProvenance: String, CaseIterable, Hashable, Sendable {
    case source
    case listeningMap
    case myMargin
    case sharedMargin
    case userResponse
    case assistantResponse

    var label: String {
        switch self {
        case .source: "Chapter"
        case .listeningMap: "Listening map"
        case .myMargin: "My Margin"
        case .sharedMargin: "Shared Margin"
        case .userResponse: "My response"
        case .assistantResponse: "Assistant response"
        }
    }

    var systemImage: String {
        switch self {
        case .source: "doc.text"
        case .listeningMap: "map"
        case .myMargin: "quote.bubble.fill"
        case .sharedMargin: "person.2.fill"
        case .userResponse: "person.crop.circle"
        case .assistantResponse: "sparkles"
        }
    }
}

struct MarginRow: Identifiable, Equatable, Sendable {
    let interjection: Interjection
    let itemTitle: String
    let sessionDate: Date?
    /// The chapter the Margin was made in and, for text, its paragraph number (#777). nil when the item has no
    /// chapters or the position isn't a paragraph.
    var place: MarginPlaces.Place? = nil

    var id: String { "\(interjection.sessionId)::\(interjection.id)" }
    var isWritten: Bool { interjection.captureKind == .written }
    var fullText: String {
        [interjection.displayText, interjection.cleanedTranscript, interjection.transcript]
            .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? preview
    }

    var preview: String {
        for value in [interjection.displayText, interjection.cleanedTranscript, interjection.transcript] {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return needsAttention ? attentionDescription : "Audio Margin"
    }

    var needsAttention: Bool {
        if isWritten { return false }
        let transcriptReady = ["transcribed", "complete"].contains(interjection.transcriptionStatus)
        let contextFailed = interjection.anchorContextStatus == .unavailable
        return !transcriptReady || contextFailed || interjection.audioStatus == "missing"
    }

    var canPlayRecording: Bool { !isWritten && interjection.audioPath != nil }
    var canRetryTranscription: Bool { !isWritten && !["transcribed", "complete"].contains(interjection.transcriptionStatus) && interjection.audioPath != nil }

    /// A voice Margin whose transcript can't be made until Speech Recognition is back on (#268).
    var transcriptWaitsForSpeechRecognition: Bool {
        canRetryTranscription && interjection.transcriptionStatus == "failed" && SpeechRecognitionAccess.isOff
    }

    var attentionDescription: String {
        TranscriptionFailureWording.marginAttention(
            transcriptionStatus: interjection.transcriptionStatus,
            speechRecognitionOff: SpeechRecognitionAccess.isOff,
            contextUnavailable: interjection.anchorContextStatus == .unavailable,
            recordingMissing: interjection.audioStatus == "missing"
        )
    }

    /// The row's second line: where the Margin was made, then the day (#777). Responses and summaries keep their label.
    func placeDescription(now: Date = Date()) -> String {
        guard interjection.targetType == .item else { return "\(targetDescription) · \(interjection.roughPercent)%" }
        return MarginRowWording.placeLine(
            placeName: place?.chapterName, mediaTimeMs: interjection.anchor.mediaTimeMs,
            paragraph: place?.paragraph, roughPercent: interjection.roughPercent,
            createdAt: interjection.createdAt, now: now)
    }

    /// Set when a call, Siri, the headphones or a closed app ended this recording early, until the listener opens it (#1976).
    var cutShort: CutShortMark? {
        CutShortMargins.shared.mark(sessionId: interjection.sessionId, interjectionId: interjection.id)
    }

    /// The row's headline: what needs attention, else where it was made, led by "Cut short" or "Recovered" while that
    /// mark is on. A recovered Margin always waits on its transcript, so the mark can't be shown only when nothing does.
    func captionDescription(now: Date = Date()) -> String {
        [cutShort?.tag, needsAttention ? attentionDescription : placeDescription(now: now)].compactMap { $0 }.joined(separator: " · ")
    }

    var targetDescription: String {
        switch interjection.targetType {
        case .item: "Source"
        case .assistantTurn: "Assistant response"
        case .summaryTurn: "Margin summary"
        }
    }
}

struct SharedMarginRow: Identifiable, Equatable, Sendable {
    let interjection: ImportedCommentaryInterjection
    let layer: ImportedCommentaryLayer
    let itemTitle: String
    /// The item's placement work in flight, if any (#872).
    var placement: SharedMarginPlacementPasses.Pass? = nil

    var id: String { "shared::\(layer.id)::\(interjection.id)" }
    var placementStatus: SharedMarginPlacementStatus {
        SharedMarginPlacementStatus(resolution: interjection.resolution, marginId: interjection.id,
                                    layerStatus: layer.sourceResolutionStatus, pass: placement,
                                    hasPositionEvidence: interjection.carriesPositionEvidence(in: layer),
                                    awaitingPlacementPass: layer.awaitsPlacementPass)
    }
    /// Its voice hasn't played for this listener yet (#469).
    var isNew: Bool { interjection.isNewToListener }
    var collectionLabel: String { layer.displayLabel.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "Imported collection" }
    var positionDescription: String {
        if let placing = placementStatus.positionDescription { return placing }
        return SharedMarginPlacementWording.line(for: interjection.resolution)
    }
}
