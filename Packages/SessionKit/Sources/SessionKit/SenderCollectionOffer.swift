import Foundation

/// What the app remembers about each sender's collection offer (#5033): `[senderId: collectionId | "declined"]`.
/// A sender with no entry has not been offered yet. The key is the packet's random sender id, never the display name,
/// which comes from the sender's app and isn't proven.
public struct SenderCollectionRecord: Equatable, Sendable {
    /// The value kept for a sender whose listener said Not now, or whose collection was deleted.
    public static let declinedMarker = "declined"

    public private(set) var entries: [String: String]

    public init(entries: [String: String] = [:]) {
        // A saved file goes through the same checks as a new value: only real sender ids, never an empty value.
        self.entries = entries.filter { SenderID.isValid($0.key) && !$0.value.isEmpty }
    }

    public enum Standing: Equatable, Sendable {
        case unknown
        case declined
        case collection(String)
    }

    public func standing(of senderId: String) -> Standing {
        guard let value = entries[senderId] else { return .unknown }
        return value == Self.declinedMarker ? .declined : .collection(value)
    }

    public mutating func decline(_ senderId: String) {
        guard SenderID.isValid(senderId) else { return }
        entries[senderId] = Self.declinedMarker
    }

    /// Links the sender to the collection the listener made through the offer. False when either id is unusable.
    @discardableResult
    public mutating func link(_ senderId: String, toCollection collectionId: String) -> Bool {
        guard SenderID.isValid(senderId), !collectionId.isEmpty, collectionId != Self.declinedMarker else { return false }
        entries[senderId] = collectionId
        return true
    }

    /// A link to a collection that no longer exists becomes "declined", so the sender is not offered again.
    public func reconciled(with collections: [ItemCollection]) -> SenderCollectionRecord {
        let existing = Set(collections.map(\.id))
        var next = self
        for (senderId, value) in entries where value != Self.declinedMarker && !existing.contains(value) {
            next.entries[senderId] = Self.declinedMarker
        }
        return next
    }
}

/// Keeps `SenderCollectionRecord` in UserDefaults under `senderCollectionOfferV1`. No database change.
public struct SenderCollectionRecordStore {
    public static let key = "senderCollectionOfferV1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> SenderCollectionRecord {
        let saved = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        return SenderCollectionRecord(entries: saved)
    }

    public func save(_ record: SenderCollectionRecord) {
        defaults.set(record.entries, forKey: Self.key)
    }
}

/// Decides whether a packet from a sender should offer "Keep Sam's readings together" or join an existing collection
/// silently (#5033 Design section 3). Plain inputs only; nothing here touches the store or the screen.
public enum SenderCollectionOffer {
    /// What the caller knows about one Library item.
    public struct ItemFacts: Equatable, Sendable {
        public let itemId: String
        /// The valid sender ids on the item's imported layers.
        public let senderIds: Set<String>
        public let isInRecentlyDeleted: Bool
        /// The listener has saved a Margin of their own on this item.
        public let hasListenerMargin: Bool

        public init(itemId: String, senderIds: Set<String>, isInRecentlyDeleted: Bool = false, hasListenerMargin: Bool = false) {
            self.itemId = itemId
            self.senderIds = senderIds.filter { SenderID.isValid($0) }
            self.isInRecentlyDeleted = isInRecentlyDeleted
            self.hasListenerMargin = hasListenerMargin
        }
    }

    public enum Decision: Equatable, Sendable {
        case none
        /// Show the row. `itemIds` are the sender's items a new collection would hold, in the Library's order.
        case offer(itemIds: [String])
        /// Add the item to the collection the listener already made for this sender, then show the banner.
        case join(collectionId: String, itemId: String)
    }

    /// - Parameters:
    ///   - newItemId: the item whose screen is opening, or whose packet just arrived.
    ///   - senderId: the packet's sender id on that item; nil or invalid (an older sender build) gives no offer.
    ///   - items: every Library item with its facts, in the Library's order.
    ///   - isHidden: whether the listener hid this sender.
    public static func decide(
        newItemId: String,
        senderId: String?,
        items: [ItemFacts],
        collections: [ItemCollection],
        record: SenderCollectionRecord,
        isHidden: (String) -> Bool
    ) -> Decision {
        guard let senderId = SenderID.valid(senderId), !isHidden(senderId) else { return .none }
        guard let newItem = items.first(where: { $0.itemId == newItemId }),
              !newItem.isInRecentlyDeleted, newItem.senderIds.contains(senderId) else { return .none }

        switch record.reconciled(with: collections).standing(of: senderId) {
        case .declined:
            return .none
        case .collection(let collectionId):
            let alreadyIn = collections.first(where: { $0.id == collectionId })?.itemIDs.contains(newItemId) ?? true
            return alreadyIn ? .none : .join(collectionId: collectionId, itemId: newItemId)
        case .unknown:
            let theirs = items.filter { $0.senderIds.contains(senderId) && !$0.isInRecentlyDeleted }
            guard theirs.count >= 2, theirs.contains(where: \.hasListenerMargin) else { return .none }
            return .offer(itemIds: theirs.map(\.itemId))
        }
    }
}
