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
/// the same closure sees the save. Cancelling the awaiting task before the closure starts skips it; cancelling it
/// later lets a long closure see `Task.isCancelled`, but a closure that has started runs to its end.
///
/// `readLatest` is for a screen that asks again before the answer comes back: it returns nil for every request
/// except the newest one with the same key on the same store, so an old answer can't overwrite a newer one. The
/// newest request is tracked per store, not per `StoreReader`, so a call site may make a reader for each call.
public struct StoreReader: Sendable {
    public let store: SQLiteSessionStore
    public init(_ store: SQLiteSessionStore) {
        self.store = store
    }

    public func read<Value: Sendable>(
        priority: TaskPriority = .utility,
        _ body: @escaping @Sendable (SQLiteSessionStore) throws -> Value
    ) async throws -> Value {
        // A detached task doesn't inherit the caller's cancellation, so it is checked here and passed on below.
        try Task.checkCancellation()
        let store = store
        let task = Task.detached(priority: priority) {
            try Task.checkCancellation()
            return try body(store)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The newest request for `key` gets its value; an older one that finishes after a newer one started gets nil.
    public func readLatest<Value: Sendable>(
        _ key: String,
        priority: TaskPriority = .utility,
        _ body: @escaping @Sendable (SQLiteSessionStore) throws -> Value
    ) async throws -> Value? {
        let storeKey = ObjectIdentifier(store)
        let ticket = LatestRequests.shared.next(store: storeKey, key: key)
        let value = try await read(priority: priority, body)
        return LatestRequests.shared.isCurrent(ticket, store: storeKey, key: key) ? value : nil
    }
}

/// One counter per (store, key). A store that is gone leaves its counters behind; they are a few bytes each, and a
/// new store at the same address only continues the count, which no ticket comparison can mistake.
private final class LatestRequests: @unchecked Sendable {
    static let shared = LatestRequests()

    private struct Key: Hashable {
        let store: ObjectIdentifier
        let name: String
    }

    private let lock = NSLock()
    private var counters: [Key: Int] = [:]

    func next(store: ObjectIdentifier, key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = Key(store: store, name: key)
        let value = (counters[id] ?? 0) + 1
        counters[id] = value
        return value
    }

    func isCurrent(_ ticket: Int, store: ObjectIdentifier, key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return counters[Key(store: store, name: key)] == ticket
    }
}
