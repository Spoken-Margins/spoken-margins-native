import Foundation

/// Counts how many times a saved link list failed to land while the phone was online, so a list that never lands
/// stops being retried after `maxTries` (#4683, Design section 2g).
///
/// One ledger per kind of waiting list, each over its own `UserDefaults` key: a handoff file under
/// `handoffKey` and a Quick Folder list under `quickFolderKey`. The record is a dictionary from the list's id (a
/// handoff file's name, a Quick Folder file's id) to its failed tries. Only a failed try while online counts; opening
/// the app offline never does, so the caller simply doesn't call `recordFailedTry`.
///
/// No call site yet: PR 3 of #4683 wires the arrival, the handoff drain and the Quick Folder refresh to it.
public final class LinkListRetryLedger: @unchecked Sendable {
    /// `UserDefaults` key for link list handoff files: file name to failed tries.
    public static let handoffKey = "linkListHandoffTriesV1"
    /// `UserDefaults` key for Quick Folder link lists: file id to failed tries.
    public static let quickFolderKey = "quickFolderLinkListRetryV1"
    /// A list that fails this many times while online is not tried again.
    public static let maxTries = 3

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
    }

    /// Failed tries so far for `id`; 0 for one never seen.
    public func tries(for id: String) -> Int {
        lock.withLock { read()[id] ?? 0 }
    }

    /// Whether `id` has failed `maxTries` times and should not be tried again.
    public func isExhausted(_ id: String) -> Bool {
        tries(for: id) >= Self.maxTries
    }

    /// Counts one failed try while online and returns the new count.
    @discardableResult
    public func recordFailedTry(for id: String) -> Int {
        lock.withLock {
            var counts = read()
            let next = (counts[id] ?? 0) + 1
            counts[id] = next
            write(counts)
            return next
        }
    }

    /// Forgets `id`, after it landed in full or was removed. Safe for an id never seen.
    public func clear(_ id: String) {
        lock.withLock {
            var counts = read()
            guard counts.removeValue(forKey: id) != nil else { return }
            write(counts)
        }
    }

    /// Drops every id not in `liveIDs`, so the record never outlives the files it counts (a file the listener deleted
    /// in Files, or one another route removed).
    public func prune(keeping liveIDs: Set<String>) {
        lock.withLock {
            let counts = read()
            let kept = counts.filter { liveIDs.contains($0.key) }
            if kept.count != counts.count { write(kept) }
        }
    }

    private func read() -> [String: Int] {
        guard let stored = defaults.dictionary(forKey: key) else { return [:] }
        var counts: [String: Int] = [:]
        for (id, value) in stored {
            // A value this code didn't write (a string, a negative number) is treated as no tries, never a crash.
            if let count = value as? Int, count > 0 { counts[id] = count }
        }
        return counts
    }

    private func write(_ counts: [String: Int]) {
        if counts.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(counts, forKey: key)
        }
    }
}
