import Foundation

/// Library audio preparation (#281): one item at a time, the playing item first.
public enum LibraryAudioPreparationQueue {
    /// The order jobs are prepared in: the listener's own priority, then the playing
    /// item, then opening buffers, explicit requests and demand windows, newest first.
    /// The order is stable while jobs progress, so one item runs to its target before
    /// the next starts.
    public static func precedes(_ lhs: AudioPreparationJob, _ rhs: AudioPreparationJob, activeItemId: String?) -> Bool {
        if lhs.userPriority != rhs.userPriority {
            return (lhs.userPriority ?? .max) < (rhs.userPriority ?? .max)
        }
        if let activeItemId, (lhs.itemId == activeItemId) != (rhs.itemId == activeItemId) {
            return lhs.itemId == activeItemId
        }
        let lhsIsOpeningBuffer = lhs.policy == .demandWindow && lhs.maximumChunkCount != nil
        let rhsIsOpeningBuffer = rhs.policy == .demandWindow && rhs.maximumChunkCount != nil
        if lhsIsOpeningBuffer != rhsIsOpeningBuffer {
            return lhsIsOpeningBuffer
        }
        if (lhs.policy == .explicit) != (rhs.policy == .explicit) {
            return lhs.policy == .explicit
        }
        if lhs.policy != rhs.policy {
            if lhs.policy == .demandWindow { return true }
            if rhs.policy == .demandWindow { return false }
        }
        if lhs.requestedAt != rhs.requestedAt {
            return lhs.requestedAt > rhs.requestedAt
        }
        return lhs.id < rhs.id
    }

    /// Each queued item's place: 0 for the one being prepared now, then 1, 2, ... in
    /// the order they'll be prepared. Only one item is ever at 0.
    public static func places(
        jobs: [AudioPreparationJob],
        activeItemId: String?,
        preparingItemId: String?
    ) -> [String: Int] {
        var order: [String] = []
        if let preparingItemId { order.append(preparingItemId) }
        for job in jobs.filter({ !$0.isCancelled }).sorted(by: { precedes($0, $1, activeItemId: activeItemId) })
        where !order.contains(job.itemId) {
            order.append(job.itemId)
        }
        let offset = preparingItemId == nil ? 1 : 0
        return Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset + offset) })
    }
}

/// Lets one piece of work run at a time; the rest wait their turn in order. The app's
/// two preparation passes (foreground demand and background) share one, so two Library
/// items never render at once (#281).
public actor SerialWorkGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
