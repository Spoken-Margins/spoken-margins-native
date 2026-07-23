import Foundation

public enum AudioAssetAvailability: String, Codable, Equatable, Sendable {
    case localPhone = "local_phone"
    case localWatch = "local_watch"
    case remote
    case browserOnly = "browser_only"
    case missing
}

/// A transport asset is intentionally separate from an Item's canonical remote source.
public struct AudioAsset: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: String
    public var id: String
    public var itemId: String
    public var audioSourceType: AudioSourceType
    public var availability: AudioAssetAvailability
    public var filePath: String?
    public var url: String?
    public var durationMs: Int?
    public var codec: String?
    public var voiceId: String?
    public var createdAt: Date

    public init(
        id: String,
        itemId: String,
        audioSourceType: AudioSourceType,
        availability: AudioAssetAvailability,
        filePath: String? = nil,
        url: String? = nil,
        durationMs: Int? = nil,
        codec: String? = nil,
        voiceId: String? = nil,
        createdAt: Date = Date()
    ) {
        schemaVersion = "audio-asset.v1"
        self.id = id
        self.itemId = itemId
        self.audioSourceType = audioSourceType
        self.availability = availability
        self.filePath = filePath
        self.url = url
        self.durationMs = durationMs
        self.codec = codec
        self.voiceId = voiceId
        self.createdAt = createdAt
    }
}

public enum PodcastDownloadState: String, Codable, Equatable, Sendable {
    case waitingForWiFi = "waiting_for_wifi"
    case downloading
    case availableOffline = "available_offline"
    case streamingOnly = "streaming_only"
    case failed
    case evicted

    public var displayName: String {
        switch self {
        case .waitingForWiFi: return "Waiting for Wi-Fi"
        case .downloading: return "Downloading"
        case .availableOffline: return "Available Offline"
        case .streamingOnly: return "Streaming Only"
        case .failed: return "Failed"
        case .evicted: return "Evicted"
        }
    }
}

public struct PodcastDownloadRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var itemId: String
    public var remoteURL: String
    public var localRelativePath: String?
    public var state: PodcastDownloadState
    public var bytesWritten: Int64
    public var expectedBytes: Int64?
    public var lastPlayedAt: Date?
    public var updatedAt: Date
    public var failureReason: String?
    public var retryCount: Int

    public init(
        id: String,
        itemId: String,
        remoteURL: String,
        localRelativePath: String? = nil,
        state: PodcastDownloadState,
        bytesWritten: Int64 = 0,
        expectedBytes: Int64? = nil,
        lastPlayedAt: Date? = nil,
        updatedAt: Date = Date(),
        failureReason: String? = nil,
        retryCount: Int = 0
    ) {
        self.id = id
        self.itemId = itemId
        self.remoteURL = remoteURL
        self.localRelativePath = localRelativePath
        self.state = state
        self.bytesWritten = bytesWritten
        self.expectedBytes = expectedBytes
        self.lastPlayedAt = lastPlayedAt
        self.updatedAt = updatedAt
        self.failureReason = failureReason
        self.retryCount = retryCount
    }

    public var progress: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, max(0, Double(bytesWritten) / Double(expectedBytes)))
    }
}

public enum PodcastNetworkTransport: Equatable, Sendable {
    case wifi
    case cellular
    case unavailable
    case other
}

public enum PodcastDownloadAction: Equatable, Sendable {
    case download
    case waitForWiFi
    case streamOnly
}

public enum PodcastDownloadPolicy {
    public static func action(for transport: PodcastNetworkTransport, userInitiated: Bool) -> PodcastDownloadAction {
        switch transport {
        case .wifi:
            return .download
        case .cellular:
            return userInitiated ? .download : .streamOnly
        case .unavailable, .other:
            return .waitForWiFi
        }
    }
}

public enum PodcastCacheLimitGB: Int, CaseIterable, Codable, Sendable {
    case one = 1
    case two = 2
    case five = 5
    case ten = 10
    case twenty = 20

    public static let defaultValue: PodcastCacheLimitGB = .five
    public var bytes: Int64 { Int64(rawValue) * 1_000_000_000 }
}

public enum PodcastCacheEvictionPlanner {
    /// Returns least-recently-played records until the cache is at or below its cap.
    public static func recordsToEvict(
        from records: [PodcastDownloadRecord],
        limitBytes: Int64,
        protectedItemIds: Set<String>
    ) -> [PodcastDownloadRecord] {
        var total = records
            .filter { $0.state == .availableOffline }
            .reduce(Int64(0)) { $0 + max(0, $1.bytesWritten) }
        guard total > limitBytes else { return [] }
        let candidates = records
            .filter { $0.state == .availableOffline && !protectedItemIds.contains($0.itemId) }
            .sorted {
                let lhs = $0.lastPlayedAt ?? .distantPast
                let rhs = $1.lastPlayedAt ?? .distantPast
                return lhs == rhs ? $0.updatedAt < $1.updatedAt : lhs < rhs
            }
        var evictions: [PodcastDownloadRecord] = []
        for record in candidates where total > limitBytes {
            evictions.append(record)
            total -= max(0, record.bytesWritten)
        }
        return evictions
    }
}
