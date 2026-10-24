import Foundation

/// Runs a store read off the caller's actor and hands the result back (#2507, fix class `async-store`).
///
/// `SQLiteSessionStore` is synchronous and thread-safe (one write connection behind a lock, a pool of read
/// connections), so a read can already leave the main actor; what a screen was missing was one shape to do it
/// with. A call site adopts it alone:
///
///     let rows = try await StoreReader(store).read { try $0.loadCommunityMapUploads() }
///
/// Reads and writes in one `read` closure run in order on one background task, so a save followed by a read in
/// the same closure sees the save. Cancelling the awaiting task before the closure starts skips it.
///
/// `readLatest` is for a screen that asks again before the answer comes back: it returns nil for every request
/// except the newest one with the same key, so an old answer can't overwrite a newer one.
public struct StoreReader: Sendable {
    public let store: SQLiteSessionStore
    private let latest = LatestRequests()

    public init(_ store: SQLiteSessionStore) {
        self.store = store
    }

    public func read<Value: Sendable>(
        priority: TaskPriority = .utility,
        _ body: @escaping @Sendable (SQLiteSessionStore) throws -> Value
    ) async throws -> Value {
        let store = store
        return try await Task.detached(priority: priority) {
            try Task.checkCancellation()
            return try body(store)
        }.value
    }

    /// The newest request for `key` gets its value; an older one that finishes after a newer one started gets nil.
    public func readLatest<Value: Sendable>(
        _ key: String,
        priority: TaskPriority = .utility,
        _ body: @escaping @Sendable (SQLiteSessionStore) throws -> Value
    ) async throws -> Value? {
        let ticket = latest.next(for: key)
        let value = try await read(priority: priority, body)
        return latest.isCurrent(ticket, for: key) ? value : nil
    }
}

private final class LatestRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var counters: [String: Int] = [:]

    func next(for key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let value = (counters[key] ?? 0) + 1
        counters[key] = value
        return value
    }

    func isCurrent(_ ticket: Int, for key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return counters[key] == ticket
    }
}
