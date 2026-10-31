import Foundation

public enum OfflineAssetCategory: String, Codable, Equatable, CaseIterable, Sendable {
    case preparedAudio = "prepared_audio"
    case preparedChunk = "prepared_chunk"
    case podcast
    case guidedTour = "guided_tour"
    case audiobook
    case interjection
    case recording
    case sourceDocument = "source_document"
    case fingerprintMap = "fingerprint_map"
    case transientEpisodeTranscript = "transient_episode_transcript"
    case resolvedListeningMapProjection = "resolved_listening_map_projection"
    case summaryBridge = "summary_bridge"
    case dormantWatchPackage = "dormant_watch_package"
}

public enum OfflineProtectionReason: String, Codable, Equatable, Sendable {
    case activePlayback = "active_playback"
    case activeRender = "active_render"
    case activeCommit = "active_commit"
    case activeEpisodeMapPreparation = "active_episode_map_preparation"
    case activeSummaryBridge = "active_summary_bridge"
    case recentlyDeleted = "recently_deleted"
    case importedAudiobook = "imported_audiobook"
    case interjection
    case recording
    case dormantWatchTransfer = "dormant_watch_transfer"
}

public enum OfflineAssetIntegrity: String, Codable, Equatable, Sendable {
    case valid
    case stale
    case corrupt
}

public struct OfflineStorageBudget: Codable, Equatable, Sendable {
    public static let allowedGigabytes = [1, 2, 5, 10, 20]
    public static let bytesPerGigabyte: Int64 = 1_000_000_000
    /// The key saves of the budget are ordered under, so a quick second change can't be overwritten by the first (#2509).
    public static let saveOrderKey = "offline-storage-budget"
    public var limitBytes: Int64

    public init(limitBytes: Int64 = 5 * bytesPerGigabyte) {
        self.limitBytes = max(0, limitBytes)
    }
}

public struct OwnedOfflineAsset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var itemId: String?
    public var category: OfflineAssetCategory
    public var relativePath: String
    public var byteCount: Int64
    public var checksumSHA256: String?
    public var isReproducible: Bool
    public var integrity: OfflineAssetIntegrity
    public var isRedundant: Bool
    public var protections: Set<OfflineProtectionReason>
    public var lastAccessedAt: Date
    public var createdAt: Date

    public init(
        id: String,
        itemId: String? = nil,
        category: OfflineAssetCategory,
        relativePath: String,
        byteCount: Int64,
        checksumSHA256: String? = nil,
        isReproducible: Bool,
        integrity: OfflineAssetIntegrity = .valid,
        isRedundant: Bool = false,
        protections: Set<OfflineProtectionReason> = [],
        lastAccessedAt: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.itemId = itemId
        self.category = category
        self.relativePath = relativePath
        self.byteCount = max(0, byteCount)
        self.checksumSHA256 = checksumSHA256
        self.isReproducible = isReproducible
        self.integrity = integrity
        self.isRedundant = isRedundant
        self.protections = protections
        self.lastAccessedAt = lastAccessedAt
        self.createdAt = createdAt
    }

    public var isAutomaticallyEvictable: Bool {
        protections.isEmpty && isReproducible && category != .audiobook && category != .interjection && category != .recording
    }
}

public enum OfflineStoragePlanner {
    public static func usageBytes(assets: [OwnedOfflineAsset], reservations: [OfflineStorageReservation], now: Date) -> Int64 {
        assets.reduce(0) { $0 + $1.byteCount }
            + reservations.filter { $0.expiresAt > now }.reduce(0) { $0 + $1.byteCount }
    }

    public static func evictionPlan(requiredBytes: Int64, assets: [OwnedOfflineAsset]) -> OfflineEvictionPlan {
        let ordered = assets.filter(\.isAutomaticallyEvictable).sorted { lhs, rhs in
            let left = priority(lhs)
            let right = priority(rhs)
            if left != right { return left < right }
            if lhs.lastAccessedAt != rhs.lastAccessedAt { return lhs.lastAccessedAt < rhs.lastAccessedAt }
            return lhs.id < rhs.id
        }
        var selected: [String] = []
        var reclaimed: Int64 = 0
        for asset in ordered where reclaimed < requiredBytes {
            selected.append(asset.id)
            reclaimed += asset.byteCount
        }
        return OfflineEvictionPlan(requiredBytes: requiredBytes, selectedAssetIds: selected, reclaimableBytes: reclaimed)
    }

    /// Prepared chunk files live at `PreparedAudio/<item>/<render signature digest>/chunks/<file>`.
    /// A change of voice, speed or chunking changes the digest (Build 30 re-keyed every chunk, #240),
    /// and chunks under another digest are never read again: they become stale, so eviction takes
    /// them first. Rows under the current digest that were marked stale become valid again. Corrupt
    /// rows, and files outside chunk directories (such as assembled audio), are left alone. Returns
    /// only the rows that change (#281).
    public static func preparedChunkStaleness(
        assets: [OwnedOfflineAsset],
        currentSignatureDigest: String
    ) -> [OwnedOfflineAsset] {
        assets.compactMap { asset in
            let parts = asset.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 5, parts[0] == "PreparedAudio", parts[3] == "chunks", asset.integrity != .corrupt else {
                return nil
            }
            let wanted: OfflineAssetIntegrity = parts[2] == currentSignatureDigest ? .valid : .stale
            guard asset.integrity != wanted else { return nil }
            var changed = asset
            changed.integrity = wanted
            return changed
        }
    }

    private static func priority(_ asset: OwnedOfflineAsset) -> Int {
        if asset.integrity == .corrupt || asset.integrity == .stale { return 0 }
        if asset.category == .preparedChunk && asset.isRedundant { return 1 }
        if asset.category == .preparedAudio { return 2 }
        if asset.category == .podcast || asset.category == .guidedTour { return 3 }
        return 4
    }
}

public struct OfflineStorageReservation: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var ownerId: String
    public var byteCount: Int64
    public var createdAt: Date
    public var expiresAt: Date

    public init(id: String, ownerId: String, byteCount: Int64, createdAt: Date = Date(), expiresAt: Date) {
        self.id = id
        self.ownerId = ownerId
        self.byteCount = max(0, byteCount)
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct OfflineEvictionPlan: Codable, Equatable, Sendable {
    public var requiredBytes: Int64
    public var selectedAssetIds: [String]
    public var reclaimableBytes: Int64

    public init(requiredBytes: Int64, selectedAssetIds: [String], reclaimableBytes: Int64) {
        self.requiredBytes = max(0, requiredBytes)
        self.selectedAssetIds = selectedAssetIds
        self.reclaimableBytes = max(0, reclaimableBytes)
    }
}

public struct PreparationEnvironment: Equatable, Sendable {
    public var isOnExternalPower: Bool
    public var isLowPowerModeEnabled: Bool
    public var thermalStateAllowsWork: Bool
    public var availableBytes: Int64

    public init(isOnExternalPower: Bool, isLowPowerModeEnabled: Bool, thermalStateAllowsWork: Bool, availableBytes: Int64) {
        self.isOnExternalPower = isOnExternalPower
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalStateAllowsWork = thermalStateAllowsWork
        self.availableBytes = max(0, availableBytes)
    }
}

public struct PreparationHorizon: Equatable, Sendable {
    public var segmentIds: [String]
    public var estimatedDurationMs: Int
    public var estimatedBytes: Int64
}

public enum PreparationHorizonPolicy {
    public static func select(
        segments: [SpeakableSegment],
        activeSegmentId: String?,
        currentChapterSegmentIds: Set<String>,
        nextChapterSegmentIds: Set<String>,
        estimatedDuration: (SpeakableSegment) -> Int,
        estimatedBytes: (SpeakableSegment) -> Int64,
        environment: PreparationEnvironment,
        explicitFullRequest: Bool
    ) -> PreparationHorizon {
        guard environment.thermalStateAllowsWork, !environment.isLowPowerModeEnabled else {
            return PreparationHorizon(segmentIds: [], estimatedDurationMs: 0, estimatedBytes: 0)
        }
        let activeIndex = activeSegmentId.flatMap { id in segments.firstIndex { $0.id == id } } ?? 0
        let remainder = Array(segments.dropFirst(min(activeIndex, segments.count)))
        let eligible: [SpeakableSegment]
        if explicitFullRequest || environment.isOnExternalPower {
            eligible = remainder
        } else {
            eligible = remainder.filter { currentChapterSegmentIds.contains($0.id) || nextChapterSegmentIds.contains($0.id) }
        }
        let durationCap = environment.isOnExternalPower ? Int.max : 30 * 60 * 1_000
        let byteCap = min(environment.availableBytes, environment.isOnExternalPower ? Int64.max : 128 * 1_024 * 1_024)
        var ids: [String] = []
        var duration = 0
        var bytes: Int64 = 0
        for segment in eligible {
            let nextDuration = max(0, estimatedDuration(segment))
            let nextBytes = max(0, estimatedBytes(segment))
            if duration + nextDuration > durationCap || bytes + nextBytes > byteCap { break }
            ids.append(segment.id)
            duration += nextDuration
            bytes += nextBytes
        }
        return PreparationHorizon(segmentIds: ids, estimatedDurationMs: duration, estimatedBytes: bytes)
    }
}
