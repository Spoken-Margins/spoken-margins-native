import Foundation

/// A listening position reported by the phone or a standalone Watch (#789).
public struct WatchPositionReport: Codable, Equatable, Sendable {
    /// Which device: the phone, or one Watch. It must change whenever the device's `sequence`
    /// starts again (a reinstall or data reset), so make it per installation, not per hardware.
    public var deviceId: String
    /// The playback session on that device, so two sessions on one device are told apart.
    public var playbackSessionId: String
    public var itemId: String
    public var sourceRevision: String
    public var positionMs: Int
    /// Counts up with every report from this device, across its sessions.
    public var sequence: Int
    /// The listener moved here on purpose (seek, skip, chapter jump), rather than playback moving on.
    public var isExplicitSeek: Bool
    /// The reporting device's clock.
    public var reportedAt: Date

    public init(
        deviceId: String,
        playbackSessionId: String,
        itemId: String,
        sourceRevision: String,
        positionMs: Int,
        sequence: Int,
        isExplicitSeek: Bool,
        reportedAt: Date
    ) {
        self.deviceId = deviceId
        self.playbackSessionId = playbackSessionId
        self.itemId = itemId
        self.sourceRevision = sourceRevision
        self.positionMs = positionMs
        self.sequence = sequence
        self.isExplicitSeek = isExplicitSeek
        self.reportedAt = reportedAt
    }
}

/// Keeps one item's position when the phone and a Watch both play it, possibly apart (#789).
///
/// The newest deliberate action wins, not the furthest position: a backward seek on one device
/// stands, and progress the other device made before that seek (delivered late, after a
/// reconnect) doesn't undo it. Reports from one device are applied in its own order; positions
/// from another revision of the item are never applied.
public struct WatchPositionReconciler: Codable, Equatable, Sendable {
    /// Device clocks can disagree by this much. Progress from another device this close to a seek
    /// may have been made before it, so it doesn't override the seek.
    public static let clockSkewTolerance: TimeInterval = 2

    public enum Decision: Equatable, Sendable {
        case accepted
        case ignored(IgnoreReason)
    }

    public enum IgnoreReason: Equatable, Sendable {
        case otherItem
        /// Made against a different revision than the item's current one.
        case otherRevision
        /// This device already sent this report or a later one.
        case outOfOrder
        /// The current position is newer.
        case superseded
        /// Progress from another device that doesn't clearly come after the current seek.
        case progressBeforeSeek
    }

    public let itemId: String
    public private(set) var current: WatchPositionReport?
    /// The newest accepted seek, kept after later progress replaces it as `current`, so another
    /// device's progress from before it can never come back.
    public private(set) var lastSeek: WatchPositionReport?
    public private(set) var lastSequenceByDevice: [String: Int] = [:]

    public init(itemId: String) {
        self.itemId = itemId
    }

    public mutating func apply(_ report: WatchPositionReport, currentRevision: String) -> Decision {
        guard report.itemId == itemId else { return .ignored(.otherItem) }
        guard report.sourceRevision == currentRevision else { return .ignored(.otherRevision) }
        if let last = lastSequenceByDevice[report.deviceId], report.sequence <= last {
            return .ignored(.outOfOrder)
        }
        lastSequenceByDevice[report.deviceId] = report.sequence

        if lastSeek?.sourceRevision != currentRevision { lastSeek = nil }
        if !report.isExplicitSeek, let lastSeek, lastSeek.deviceId != report.deviceId,
           report.reportedAt.timeIntervalSince(lastSeek.reportedAt) <= Self.clockSkewTolerance {
            return .ignored(.progressBeforeSeek)
        }
        if let current, current.sourceRevision == currentRevision, report.deviceId != current.deviceId,
           report.reportedAt <= current.reportedAt {
            return .ignored(.superseded)
        }
        // Same device with a newer sequence: its own order is authoritative.
        accept(report)
        return .accepted
    }

    private mutating func accept(_ report: WatchPositionReport) {
        current = report
        if report.isExplicitSeek { lastSeek = report }
    }
}
