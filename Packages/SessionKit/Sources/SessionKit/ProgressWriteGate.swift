import Foundation

/// Decides when a stream of progress ticks (download bytes, a position) may touch the database (#2509).
///
/// The caller still updates its in-memory value and tells the screen on every tick; only the write waits.
/// A write that is not a tick (a state change, a finish, a failure) is made at once and told to the gate
/// with `didWrite`, so the next tick does not write straight after it.
public struct ProgressWriteGate: Sendable {
    public let interval: TimeInterval
    private var lastWriteByKey: [String: Date] = [:]

    public init(interval: TimeInterval = 5) {
        self.interval = interval
    }

    /// True when a tick for `key` should be written now. A true answer counts as the write.
    public mutating func shouldWrite(key: String, at now: Date) -> Bool {
        if let last = lastWriteByKey[key], now.timeIntervalSince(last) < interval, now >= last { return false }
        lastWriteByKey[key] = now
        return true
    }

    /// Records a write made for another reason than a tick.
    public mutating func didWrite(key: String, at now: Date) {
        lastWriteByKey[key] = now
    }

    public mutating func forget(key: String) {
        lastWriteByKey[key] = nil
    }
}
