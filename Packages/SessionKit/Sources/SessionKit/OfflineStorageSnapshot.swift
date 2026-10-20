import Foundation

public struct OfflineStorageCategoryRow: Identifiable, Equatable, Sendable {
    public let category: OfflineAssetCategory
    public let byteCount: Int64
    /// Downloaded voices (#1819) are stored under an existing category, because Build 29 decodes the
    /// category enum strictly, and get their own row by their asset ids instead.
    public let isDownloadedVoices: Bool

    public init(category: OfflineAssetCategory, byteCount: Int64, isDownloadedVoices: Bool = false) {
        self.category = category
        self.byteCount = byteCount
        self.isDownloadedVoices = isDownloadedVoices
    }

    public static let downloadedVoicesId = "downloaded_voices"

    public var id: String { isDownloadedVoices ? Self.downloadedVoicesId : category.rawValue }

    public var title: String {
        if isDownloadedVoices { return "Downloaded voices" }
        return switch category {
        case .preparedAudio: "Prepared audio"
        case .preparedChunk: "Prepared audio parts"
        case .podcast: "Podcasts"
        case .guidedTour: "Guided tour"
        case .audiobook: "Audiobooks"
        case .interjection: "Margins"
        case .recording: "Recordings"
        case .sourceDocument: "Source documents"
        case .dormantWatchPackage: "Dormant Watch packages"
        case .fingerprintMap: "Fingerprint maps"
        case .transientEpisodeTranscript: "Transient transcripts"
        case .resolvedListeningMapProjection: "Resolved Listening Maps"
        case .summaryBridge: "Scene summary audio"
        }
    }
}

/// What the Storage screen shows: the budget, what is used and reserved, and how much can be cleared.
public struct OfflineStorageSnapshot: Equatable, Sendable {
    public var budgetBytes: Int64 = 0
    public var usedBytes: Int64 = 0
    public var reservedBytes: Int64 = 0
    public var protectedBytes: Int64 = 0
    public var reproducibleBytes: Int64 = 0
    public var clearableBytes: Int64 = 0
    public var currentOverageBytes: Int64 = 0
    public var residualOverageBytes: Int64 = 0
    public var categories: [OfflineStorageCategoryRow] = []

    public init() {}

    public init(
        budgetBytes: Int64,
        usedBytes: Int64,
        reservedBytes: Int64,
        protectedBytes: Int64,
        reproducibleBytes: Int64,
        clearableBytes: Int64,
        currentOverageBytes: Int64,
        residualOverageBytes: Int64,
        categories: [OfflineStorageCategoryRow]
    ) {
        self.budgetBytes = budgetBytes
        self.usedBytes = usedBytes
        self.reservedBytes = reservedBytes
        self.protectedBytes = protectedBytes
        self.reproducibleBytes = reproducibleBytes
        self.clearableBytes = clearableBytes
        self.currentOverageBytes = currentOverageBytes
        self.residualOverageBytes = residualOverageBytes
        self.categories = categories
    }

    public var totalCommittedAndReservedBytes: Int64 { usedBytes + reservedBytes }

    public static func make(
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
        let isVoice: (OwnedOfflineAsset) -> Bool = { $0.id.hasPrefix(VoiceCatalogCoordinator.ledgerAssetPrefix) }
        let grouped = Dictionary(grouping: assets.filter { !isVoice($0) }, by: \.category)
        var categories = OfflineAssetCategory.allCases.compactMap { category -> OfflineStorageCategoryRow? in
            let bytes = grouped[category, default: []].reduce(Int64(0)) { $0 + $1.byteCount }
            return bytes == 0 ? nil : OfflineStorageCategoryRow(category: category, byteCount: bytes)
        }
        let voiceBytes = assets.filter(isVoice).reduce(Int64(0)) { $0 + $1.byteCount }
        if voiceBytes > 0 {
            categories.append(OfflineStorageCategoryRow(category: VoiceCatalogCoordinator.ledgerCategory, byteCount: voiceBytes, isDownloadedVoices: true))
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
