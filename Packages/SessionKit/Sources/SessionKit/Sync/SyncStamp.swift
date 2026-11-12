import Foundation

/// The version stamp of one edit in the sync layer (#4152, `docs/design/icloud-library-sync.md`): a hybrid logical
/// clock reading plus the device that made it. Stamps are totally ordered, and two devices never make the same one.
///
/// The wall clock is only the first part of the order. `SyncClock` never hands out a stamp at or below one it has seen,
/// so a phone whose clock is a year behind still wins over an edit it had already received, and a phone whose clock is
/// a year ahead only wins until the others have seen its edit.
public struct SyncStamp: Codable, Hashable, Comparable, Sendable {
    public var wallMillis: Int64
    public var counter: Int
    public var device: String

    public init(wallMillis: Int64, counter: Int, device: String) {
        self.wallMillis = wallMillis
        self.counter = counter
        self.device = device
    }

    public static func < (lhs: SyncStamp, rhs: SyncStamp) -> Bool {
        if lhs.wallMillis != rhs.wallMillis { return lhs.wallMillis < rhs.wallMillis }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.device < rhs.device
    }

    /// The wall-clock time of the edit, for the 90-day tombstone rule. Not for ordering.
    public var date: Date { Date(timeIntervalSince1970: Double(wallMillis) / 1000) }
}

/// One device's hybrid logical clock. A value type with no global state: the caller passes the wall clock in, so a test
/// can run it at any time, including backwards.
public struct SyncClock: Codable, Equatable, Sendable {
    public let device: String
    private var lastWallMillis: Int64
    private var lastCounter: Int

    public init(device: String) {
        self.device = device
        self.lastWallMillis = 0
        self.lastCounter = -1
    }

    /// A stamp above every stamp this clock has made or observed, whatever `wallMillis` says.
    public mutating func tick(wallMillis: Int64) -> SyncStamp {
        if wallMillis > lastWallMillis {
            lastWallMillis = wallMillis
            lastCounter = 0
        } else {
            lastCounter += 1
        }
        return SyncStamp(wallMillis: lastWallMillis, counter: lastCounter, device: device)
    }

    /// Records a stamp that arrived from anywhere, this device's own earlier stamps included (a restore from backup
    /// brings those back), so the next `tick` is above it.
    public mutating func observe(_ stamp: SyncStamp) {
        if stamp.wallMillis > lastWallMillis {
            lastWallMillis = stamp.wallMillis
            lastCounter = stamp.counter
        } else if stamp.wallMillis == lastWallMillis, stamp.counter > lastCounter {
            lastCounter = stamp.counter
        }
    }
}
