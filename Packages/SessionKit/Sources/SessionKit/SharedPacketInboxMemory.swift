import Foundation

/// Remembers which files in the Share inbox a launch has already shown (#3291). A shown file stays in the inbox until
/// the listener imports or cancels it (#2123), so a later launch stages it again; that launch keeps the sheet rather
/// than opening it directly, because opening fetches the item and the listener did nothing this time (the audit on
/// PR #3298).
public struct SharedPacketInboxMemory {
    private static let defaultsKey = "sharedPacketInboxShown.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func wasShown(payloadID: String) -> Bool {
        shownIDs().contains(payloadID)
    }

    public func noteShown(payloadID: String) {
        var all = shownIDs()
        guard all.insert(payloadID).inserted else { return }
        save(all)
    }

    /// Drops the files that are no longer in the inbox.
    public func forgetAll(except pendingIDs: Set<String>) {
        let all = shownIDs()
        let kept = all.intersection(pendingIDs)
        guard kept != all else { return }
        save(kept)
    }

    private func shownIDs() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    private func save(_ all: Set<String>) {
        if all.isEmpty { defaults.removeObject(forKey: Self.defaultsKey); return }
        defaults.set(all.sorted(), forKey: Self.defaultsKey)
    }
}
