import Foundation

/// The items the playback engine holds in memory: its current item and its
/// session's item. An awaited re-import reads this inside the upgrade's
/// transaction, so an item the listener opened while the upgrade was being
/// planned keeps its text, and the new text becomes its own edition (#344 audit 2).
final class HeldItems: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    func set(_ newIds: Set<String>) {
        lock.lock()
        ids = newIds
        lock.unlock()
    }

    func contains(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(id)
    }
}
