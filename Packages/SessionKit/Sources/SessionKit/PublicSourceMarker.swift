import Foundation

/// Checks an item's source and records the result as its `PublicSourceMark` (#3449).
///
/// Every call is a listener's action: adding the item, the Prepare Listening Map tap, or a share or export tap that finds
/// no mark. Nothing here is scheduled, and no background path may call it (`test_public_source_check_callers.py`).
public struct PublicSourceMarker: Sendable {
    private let verifier: PublicSourceVerifier
    private let now: @Sendable () -> Date
    private let memory = NegativeMemory()

    /// What the last look found for an item that is not public, so toggling an export option does not fetch the page
    /// again each time. Only a definite "not public" is remembered, and only for a few minutes; an offline or timed-out
    /// check is tried again on the next tap.
    private final class NegativeMemory: @unchecked Sendable {
        private let lock = NSLock()
        private var notPublicUntil: [String: Date] = [:]
        static let seconds: TimeInterval = 300
        func isRemembered(_ key: String, now: Date) -> Bool { lock.withLock { (notPublicUntil[key] ?? .distantPast) > now } }
        func remember(_ key: String, now: Date) { lock.withLock { notPublicUntil[key] = now.addingTimeInterval(Self.seconds) } }
    }

    public init(verifier: PublicSourceVerifier, now: @escaping @Sendable () -> Date = { Date() }) {
        self.verifier = verifier
        self.now = now
    }

    /// The item's mark after the check. An item that already holds a valid mark is not fetched again. A failed or
    /// timed-out check leaves the item as it was, so the next tap tries again.
    @discardableResult
    public func ensureMark(itemId: String, repository: any SessionRepository, timeout: Duration = PublicSourceVerifier.defaultTimeout) async -> PublicSourceVerifier.Outcome {
        guard let item = try? repository.loadItem(id: itemId) else { return .couldNotCheck }
        let started = now()
        if MapTextDisclosure.allowsModelText(of: item, now: started), let mark = item.publicSourceMark { return .marked(mark) }
        let key = itemId + "|" + (MapTextDisclosure.checkableAddress(of: item) ?? "")
        if memory.isRemembered(key, now: started) { return .notPublic }
        let outcome = await verifier.verify(item, now: started, timeout: timeout)
        if outcome == .notPublic { memory.remember(key, now: started) }
        guard case .marked(let mark) = outcome else { return outcome }
        // Read the item again: the check took time, and the listener may have changed it meanwhile. Only the mark is set.
        // The read, the address check and the save are one transaction where the store has them, so another save of the
        // same item (the add flow, a status or title repair) cannot land between the read and the write and be overwritten
        // by the older copy (#3449 audit).
        let attach = { () throws -> Bool in
            var fresh = try repository.loadItem(id: itemId)
            guard MapTextDisclosure.checkableAddress(of: fresh) == mark.url else { return false }
            fresh.publicSourceMark = mark
            try repository.saveItem(fresh)
            return true
        }
        do {
            let saved: Bool
            if let store = repository as? any SessionRepositoryTransaction { saved = try store.withSessionTransaction(attach) } else { saved = try attach() }
            return saved ? outcome : .couldNotCheck
        } catch { return .couldNotCheck }
    }
}
