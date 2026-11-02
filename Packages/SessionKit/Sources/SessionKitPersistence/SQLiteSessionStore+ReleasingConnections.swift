import Foundation
import SQLite3

extension SQLiteSessionStore {
    /// Gives back every file descriptor this store holds: the read connections and the writer's connection (#2818).
    ///
    /// A store normally closes in `deinit`. A test that builds an app model leaves the model alive after the test
    /// (startup tasks and observers keep it), and with it the store, so a full app test run piled up stores until iOS's
    /// 256 descriptors ran out. This is for a holder that can't wait for the store to deallocate.
    ///
    /// The store stays safe to call afterwards. The writer's connection is swapped for an empty in-memory database,
    /// which holds no file, so a late call fails to find its tables, or reads nothing, instead of using a closed
    /// connection. Nothing is written to the file again. Never call this on a store the app is still using.
    public func releaseConnections() {
        withConnectionLock {
            readConnections?.close()
            let old = db
            db = nil
            var placeholder: OpaquePointer?
            if sqlite3_open_v2(":memory:", &placeholder, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
                db = placeholder
            } else {
                sqlite3_close(placeholder)
            }
            // `_v2` waits for a statement still running on another thread to finish instead of failing.
            sqlite3_close_v2(old)
        }
    }

    /// Starts remembering every store opened from now on, so `releaseTrackedStores()` can close them (#2818). The
    /// app test bundle opens a window like this around each test, so a store the host app opened on its own is never
    /// in it. The app itself never calls this, so a shipping build keeps no list of stores.
    public static func trackOpenStores() {
        OpenStoreRegistry.shared.startTracking()
    }

    /// Releases the connections of every store opened since `trackOpenStores()` that is still alive, ends the window,
    /// and returns how many it released.
    @discardableResult
    public static func releaseTrackedStores() -> Int {
        OpenStoreRegistry.shared.releaseAll()
    }
}

/// Weak references to the stores opened while tracking is on.
final class OpenStoreRegistry: @unchecked Sendable {
    static let shared = OpenStoreRegistry()

    private final class Entry {
        weak var store: SQLiteSessionStore?
        init(_ store: SQLiteSessionStore) { self.store = store }
    }

    private let lock = NSLock()
    private var isTracking = false
    private var entries: [Entry] = []

    func startTracking() {
        lock.lock(); defer { lock.unlock() }
        isTracking = true
    }

    func registerIfTracking(_ store: SQLiteSessionStore) {
        lock.lock(); defer { lock.unlock() }
        guard isTracking else { return }
        entries.removeAll { $0.store == nil }
        entries.append(Entry(store))
    }

    func releaseAll() -> Int {
        lock.lock()
        let stores = entries.compactMap(\.store)
        entries = []
        isTracking = false
        lock.unlock()
        // Outside the registry lock: releasing waits on each store's own lock.
        stores.forEach { $0.releaseConnections() }
        return stores.count
    }
}
