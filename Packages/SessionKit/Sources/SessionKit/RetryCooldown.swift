import Foundation

/// Remembers that a keyed piece of repeat-trigger work was attempted and failed (or came back not ready),
/// so the next triggers inside a cooldown do nothing instead of redoing it (#2653, class of #2626).
///
/// An in-flight set only stops overlapping runs; once a run ends in failure the next trigger starts it
/// again, so a bad network turns every refresh into a retry. Here each failure pushes the next allowed
/// attempt out by `base * 2^(failures - 1)`, capped at `ceiling`. A success, or an explicit `clear` from a
/// listener action that should retry at once, forgets the key.
public struct RetryCooldown {
    public let base: TimeInterval
    public let ceiling: TimeInterval
    private let now: () -> Date
    private var failures: [String: Int] = [:]
    private var blockedUntil: [String: Date] = [:]

    public init(base: TimeInterval = 30, ceiling: TimeInterval = 15 * 60, now: @escaping () -> Date = Date.init) {
        self.base = base
        self.ceiling = max(ceiling, base)
        self.now = now
    }

    /// True when no failure is being waited out for `key`.
    public func canAttempt(_ key: String) -> Bool {
        guard let until = blockedUntil[key] else { return true }
        return now() >= until
    }

    /// Marks the key as served-but-failed. Consecutive failures back off exponentially up to the ceiling.
    public mutating func recordFailure(_ key: String) {
        let count = (failures[key] ?? 0) + 1
        failures[key] = count
        let exponent = Double(min(count - 1, 30))
        let delay = min(base * pow(2, exponent), ceiling)
        blockedUntil[key] = now().addingTimeInterval(delay)
    }

    public mutating func recordSuccess(_ key: String) { clear(key) }

    public mutating func clear(_ key: String) {
        failures[key] = nil
        blockedUntil[key] = nil
    }

    public mutating func clear(_ keys: some Sequence<String>) { for key in keys { clear(key) } }

    public func failureCount(_ key: String) -> Int { failures[key] ?? 0 }
}
