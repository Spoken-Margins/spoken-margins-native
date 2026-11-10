import Foundation

/// "Add to Queue" on a row whose item is not in the Library yet (#4044): save the item, then queue it once the import
/// has landed. The wish is a note that a tap made, held in memory and keyed by the entry or file id. The app registers
/// it before it asks for the import, tells the wishes how the import ended, and queues what comes back.
///
/// Rules, all from the Design comment on #4044:
/// - **One wish per key.** Add to Queue twice is one wish, so the item is queued once.
/// - **Registered before the import starts.** An import that is already running for the same entry (the listener tapped
///   Add first) never starts a second one, so the wish cannot depend on a new import beginning.
/// - **Tap order.** Two rows queued back to back reach the queue in the order they were tapped, even when the second
///   import finishes first: a wish is released only when every wish tapped before it has ended, one way or the other.
/// - **A failed import queues nothing** and clears its wish. **An item deleted before its wish is released** is dropped.
/// - **Queuing is not playing.** Nothing here cancels a wish because the listener opened or played something else; the
///   "latest open or play wins" rule (#2124) is about what plays now.
/// - **Memory only.** A relaunch loses the wishes. The item still lands in the Library and the queue file is untouched.
public struct SaveThenQueueWishes: Equatable, Sendable {
    /// How an import ended.
    public enum Outcome: Equatable, Sendable {
        /// The item is in the Library under this id.
        case imported(itemId: String)
        /// Nothing was saved (offline, refused, or the import threw).
        case failed
    }

    /// A wish that is ready: queue `itemId`, and say "Added ‹title› to the Library and the queue."
    public struct Release: Equatable, Sendable {
        public let key: String
        public let itemId: String
    }

    private struct Wish: Equatable, Sendable {
        let key: String
        var outcome: Outcome?
    }

    /// In tap order.
    private var wishes: [Wish] = []

    public init() {}

    /// Keys that still wait for an import, in tap order. A key whose import ended but which waits behind an earlier
    /// wish is still listed, because it has not reached the queue.
    public var pendingKeys: [String] { wishes.map(\.key) }

    public func isWished(_ key: String) -> Bool { wishes.contains { $0.key == key } }

    /// Notes that the listener wants the item queued once it lands. Returns false when the key already has a wish,
    /// which changes nothing (Add to Queue twice).
    ///
    /// A wish whose import already failed, and which only waits behind an earlier wish, is a spent wish: a new tap
    /// replaces it (at the end, in tap order) instead of being swallowed until the head settles.
    ///
    /// Call this **before** asking for the import. `settle` for a key with no wish queues nothing, so a wish registered
    /// after its import ended would wait forever. And every way an import can end, including an early return or a
    /// cancel, must call `settle(_:outcome: .failed…)`: a wish whose import never reports holds back every wish tapped
    /// after it.
    @discardableResult
    public mutating func register(_ key: String) -> Bool {
        if let index = wishes.firstIndex(where: { $0.key == key }) {
            guard wishes[index].outcome == .failed else { return false }
            wishes.remove(at: index)
        }
        wishes.append(Wish(key: key, outcome: nil))
        return true
    }

    /// The import for `key` ended. Returns the wishes that can now be queued, in tap order: this one and any that were
    /// waiting behind it, up to the first wish whose import is still running. `itemExists` is asked at release time,
    /// so an item deleted while it waited is dropped. A key with no wish (the listener only tapped Add) returns nothing.
    public mutating func settle(_ key: String, outcome: Outcome, itemExists: (String) -> Bool) -> [Release] {
        guard let index = wishes.firstIndex(where: { $0.key == key }), wishes[index].outcome == nil else { return [] }
        wishes[index].outcome = outcome
        var released: [Release] = []
        while let first = wishes.first, let ended = first.outcome {
            wishes.removeFirst()
            if case .imported(let itemId) = ended, itemExists(itemId) {
                released.append(Release(key: first.key, itemId: itemId))
            }
        }
        return released
    }
}

/// What a row's queue button says and shows (#4044), in one place so the swipe button, the menu item, the VoiceOver
/// action and the Voice Control name are the same words. The state is read from the queue's ids as they are now,
/// never from a copy a row cached, so a row redrawn before the Library loads, or after the queue screen changed the
/// queue, shows the right button.
public enum QueueRowAction: Equatable, Sendable {
    case add
    case remove

    public static func action(forItem itemId: String, queuedItemIds: [String]) -> QueueRowAction {
        queuedItemIds.contains(itemId) ? .remove : .add
    }

    /// The name on the swipe button, the menu item, the VoiceOver action and the Voice Control name.
    public var title: String {
        switch self {
        case .add: "Add to Queue"
        case .remove: "Remove from Queue"
        }
    }

    /// The Following show row has no menu, so its VoiceOver action names the episode it reaches.
    public var newestEpisodeTitle: String {
        switch self {
        case .add: "Add newest episode to Queue"
        case .remove: "Remove newest episode from Queue"
        }
    }

    public var systemImage: String {
        switch self {
        case .add: "text.line.last.and.arrowtriangle.forward"
        case .remove: "text.badge.minus"
        }
    }

    /// The banner after the tap, for an item that is already in the Library.
    public func banner(title: String) -> String {
        switch self {
        case .add: "Added \(title) to the queue."
        case .remove: "Removed \(title) from the queue."
        }
    }

    /// The one banner for a row that was saved first, which replaces the import's own banner.
    public static func savedAndQueuedBanner(title: String) -> String {
        "Added \(title) to the Library and the queue."
    }
}
