import Foundation

/// Which keyed jobs are in flight, with a per-start token, so a job that was cancelled or replaced can't
/// clear the mark of the job that replaced it (#2812, class of a `defer { pending.remove(id) }`).
///
/// A plain pending set breaks two ways when someone empties it while a job is still running: a new
/// trigger for the same key passes the "not pending" guard and starts a second job, and then the first
/// job's `defer` removes the second job's mark. Here `begin` hands out a token, `finish` removes the
/// mark only if the token is still current, and the removers hand back the handles to cancel.
public struct OwnedWorkRegistry<Handle> {
    public typealias Token = UInt64

    private struct Entry {
        var token: Token
        var handle: Handle?
    }

    private var entries: [String: Entry] = [:]
    private var lastToken: Token = 0

    public init() {}

    public var keys: Set<String> { Set(entries.keys) }

    public func contains(_ key: String) -> Bool { entries[key] != nil }

    /// Marks `key` in flight under a new token. Any earlier job for the key loses its claim, and its
    /// handle comes back so the caller can cancel it.
    public mutating func begin(_ key: String) -> (token: Token, replaced: Handle?) {
        let replaced = entries[key]?.handle
        lastToken += 1
        entries[key] = Entry(token: lastToken, handle: nil)
        return (lastToken, replaced)
    }

    /// Records the job started under `token`. Ignored when the claim has moved on since.
    public mutating func attach(_ handle: Handle, to key: String, token: Token) {
        guard entries[key]?.token == token else { return }
        entries[key]?.handle = handle
    }

    /// Ends the job started under `token`. Returns false, and leaves the mark alone, when a newer job
    /// owns the key or the mark was already removed.
    @discardableResult
    public mutating func finish(_ key: String, token: Token) -> Bool {
        guard entries[key]?.token == token else { return false }
        entries[key] = nil
        return true
    }

    /// Removes the mark whatever its token; the handle comes back to cancel.
    @discardableResult
    public mutating func remove(_ key: String) -> Handle? {
        entries.removeValue(forKey: key)?.handle
    }

    public mutating func remove<S: Sequence>(_ keys: S) -> [Handle] where S.Element == String {
        keys.compactMap { remove($0) }
    }

    public mutating func removeAll() -> [Handle] {
        let handles = entries.values.compactMap(\.handle)
        entries.removeAll()
        return handles
    }
}
