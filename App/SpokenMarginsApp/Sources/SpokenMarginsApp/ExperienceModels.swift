import Foundation
import SessionKit

enum AppRoot: String, CaseIterable, Identifiable, Hashable, Sendable {
    case library
    case sources
    case margins

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: "Library"
        case .sources: "Sources"
        case .margins: "Margins"
        }
    }

    var systemImage: String {
        switch self {
        case .library: "books.vertical"
        case .sources: "dot.radiowaves.left.and.right"
        case .margins: "quote.bubble"
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
        bottomInset: CGFloat
    ) -> CGFloat {
        let maximumScrollOffset = max(0, contentHeight + bottomInset - containerHeight)
        return max(0, contentOffsetY - maximumScrollOffset)
    }

    static func shouldOpenTimeline(overscrollDistance: CGFloat) -> Bool {
        overscrollDistance >= activationDistance
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
        case .documentOrBook: "Plain text, Markdown, text-based PDF, or DRM-free EPUB"
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
        .margins: []
    ]
    var taskRoute: AppRoute?
    var addSourceRoute: AddSourceRoute?

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

    mutating func dismissTask(recordingIsLocked: Bool) {
        guard !recordingIsLocked else { return }
        taskRoute = nil
    }
}

enum LibraryPresentation {
    static func continueItem(in rows: [LibraryItemRow], activeItemId: String?) -> LibraryItemRow? {
        if let activeItemId,
           let active = rows.first(where: {
               $0.id == activeItemId
                   && $0.hasContinuationSession
                   && ($0.continuationProgressPercent ?? 0) < 100
           }) {
            return active
        }

        return rows
            .filter {
                $0.hasContinuationSession
                    && ($0.continuationProgressPercent ?? 0) > 0
                    && ($0.continuationProgressPercent ?? 0) < 100
            }
            .sorted {
                let lhs = $0.lastListenedAt ?? .distantPast
                let rhs = $1.lastListenedAt ?? .distantPast
                return lhs == rhs ? $0.id < $1.id : lhs > rhs
            }
            .first
    }

    static func compactItems(_ rows: [LibraryItemRow], excluding continueItem: LibraryItemRow?) -> [LibraryItemRow] {
        guard let continueItem else { return rows }
        return rows.filter { $0.id != continueItem.id }
    }
}

enum OnboardingEvidenceClassifier {
    static let defaultSeededItemIDs: Set<String> = [
        "item-spoken-margins-overview",
        "guided-onboarding"
    ]

    static func sourceSteps(
        items: [Item],
        seededItemIDs: Set<String> = defaultSeededItemIDs
    ) -> Set<OnboardingStep> {
        let userItems = items.filter { !seededItemIDs.contains($0.id) }
        var evidence: Set<OnboardingStep> = []
        if !userItems.isEmpty {
            evidence.insert(.addedOwnSource)
        }
        if userItems.contains(where: { $0.mediaType == "text" && $0.externalReferenceType == "url" }) {
            evidence.formUnion([.addedOwnSource, .addedFromSafari])
        }
        if userItems.contains(where: { $0.externalReferenceType == "file" }) {
            evidence.formUnion([.addedOwnSource, .addedFromFiles])
        }
        return evidence
    }
}

enum TimelineProvenance: String, CaseIterable, Hashable, Sendable {
    case source
    case myMargin
    case userResponse
    case assistantResponse

    var label: String {
        switch self {
        case .source: "Source"
        case .myMargin: "My Margin"
        case .userResponse: "My response"
        case .assistantResponse: "Assistant response"
        }
    }

    var systemImage: String {
        switch self {
        case .source: "doc.text"
        case .myMargin: "quote.bubble.fill"
        case .userResponse: "person.crop.circle"
        case .assistantResponse: "sparkles"
        }
    }
}

struct TimelineRailSortKey: Comparable, Equatable, Sendable {
    let position: Int
    let rank: Int
    let id: String

    static func < (lhs: TimelineRailSortKey, rhs: TimelineRailSortKey) -> Bool {
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        return lhs.id < rhs.id
    }
}

struct MarginRow: Identifiable, Equatable, Sendable {
    let interjection: Interjection
    let itemTitle: String
    let sessionDate: Date?

    var id: String { "\(interjection.sessionId)::\(interjection.id)" }

    var preview: String {
        for value in [interjection.displayText, interjection.cleanedTranscript, interjection.transcript] {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return needsAttention ? attentionDescription : "Audio Margin"
    }

    var needsAttention: Bool {
        let transcriptReady = ["transcribed", "complete"].contains(interjection.transcriptionStatus)
        let contextFailed = interjection.anchorContextStatus == .unavailable
        return !transcriptReady || contextFailed || interjection.audioStatus == "missing"
    }

    var attentionDescription: String {
        if interjection.anchorContextStatus == .unavailable { return "Context needs retry" }
        if interjection.audioStatus == "missing" { return "Recording is unavailable" }
        switch interjection.transcriptionStatus {
        case "pending": return "Transcription is pending"
        case "failed": return "Transcription needs retry"
        default: return "Margin needs attention"
        }
    }

    var targetDescription: String {
        switch interjection.targetType {
        case .item: "Source"
        case .assistantTurn: "Assistant response"
        case .summaryTurn: "Interjection summary"
        }
    }
}

struct OfflineStorageCategoryRow: Identifiable, Equatable, Sendable {
    let category: OfflineAssetCategory
    let byteCount: Int64

    var id: String { category.rawValue }

    var title: String {
        switch category {
        case .preparedAudio: "Prepared audio"
        case .preparedChunk: "Prepared chunks"
        case .podcast: "Podcasts"
        case .guidedTour: "Guided tour"
        case .audiobook: "Audiobooks"
        case .interjection: "Margins"
        case .recording: "Recordings"
        case .sourceDocument: "Source documents"
        case .dormantWatchPackage: "Dormant Watch packages"
        }
    }
}

struct OfflineStorageSnapshot: Equatable, Sendable {
    var budgetBytes: Int64 = 0
    var usedBytes: Int64 = 0
    var reservedBytes: Int64 = 0
    var protectedBytes: Int64 = 0
    var reproducibleBytes: Int64 = 0
    var clearableBytes: Int64 = 0
    var currentOverageBytes: Int64 = 0
    var residualOverageBytes: Int64 = 0
    var categories: [OfflineStorageCategoryRow] = []

    var totalCommittedAndReservedBytes: Int64 { usedBytes + reservedBytes }

    static func make(
        budget: OfflineStorageBudget,
        assets: [OwnedOfflineAsset],
        reservations: [OfflineStorageReservation],
        now: Date = Date()
    ) -> OfflineStorageSnapshot {
        let activeReservations = reservations.filter { $0.expiresAt > now }
        let used = assets.reduce(Int64(0)) { $0 + $1.byteCount }
        let reserved = activeReservations.reduce(Int64(0)) { $0 + $1.byteCount }
        let protected = assets.filter { !$0.isAutomaticallyEvictable }.reduce(Int64(0)) { $0 + $1.byteCount }
        let reproducible = assets.filter(\.isReproducible).reduce(Int64(0)) { $0 + $1.byteCount }
        let clearable = assets.filter(\.isAutomaticallyEvictable).reduce(Int64(0)) { $0 + $1.byteCount }
        let overage = max(0, used + reserved - budget.limitBytes)
        let grouped = Dictionary(grouping: assets, by: \.category)
        let categories = OfflineAssetCategory.allCases.compactMap { category -> OfflineStorageCategoryRow? in
            let bytes = grouped[category, default: []].reduce(Int64(0)) { $0 + $1.byteCount }
            return bytes == 0 ? nil : OfflineStorageCategoryRow(category: category, byteCount: bytes)
        }
        return OfflineStorageSnapshot(
            budgetBytes: budget.limitBytes,
            usedBytes: used,
            reservedBytes: reserved,
            protectedBytes: protected,
            reproducibleBytes: reproducible,
            clearableBytes: clearable,
            currentOverageBytes: overage,
            residualOverageBytes: max(0, overage - clearable),
            categories: categories
        )
    }
}

struct RecordingPresentationContext: Equatable, Sendable {
    let itemTitle: String
    let locationTitle: String
    let progressPercent: Int
    let startedAt: Date
}
