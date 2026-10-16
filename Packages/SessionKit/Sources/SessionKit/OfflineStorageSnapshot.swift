import Foundation

public struct OfflineStorageCategoryRow: Identifiable, Equatable, Sendable {
    public let category: OfflineAssetCategory
    public let byteCount: Int64

    public init(category: OfflineAssetCategory, byteCount: Int64) {
        self.category = category
        self.byteCount = byteCount
    }

    public var id: String { category.rawValue }

    public var title: String {
        switch category {
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
