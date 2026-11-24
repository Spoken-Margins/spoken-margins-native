import Foundation

/// "Keep Sam's readings together" (#5033): the one offer a listener gets to put the items one friend or class sent
/// them in one collection, and the silent join of that friend's later items once they said yes.
///
/// A student whose readings arrive from one classmate or professor meets it after they have answered that sender at
/// least once, on the screen of one of the sender's items. One reading from one person is an ordinary friend share and
/// gets nothing. No packet field and no database change: the choice is the receiver's, kept in a small record on this
/// device (`SenderCollectionOfferRecord`), and the collection is an ordinary `ItemCollection`.
///
/// The sender is the packet's random sender id (one per friendship or group, `SenderIDLedger`), never the display name,
/// which the sender's app chose and nothing proves. A layer from a build that sends no id never counts.
public enum SenderCollectionOffer {
    /// What one Library item says about who sent it Margins and whether the listener answered.
    public struct ItemSenders: Equatable, Sendable {
        public let itemID: String
        /// The friends whose Margins are on the item, merged by sender (the Library row's `sharedMargins.senders`).
        /// Hidden senders, deleted layers and items in Recently Deleted are already left out by the Library's read.
        public let senders: [SharedMarginTally.Sender]
        /// How many Margins the listener made on the item themselves.
        public let ownMarginCount: Int

        public init(itemID: String, senders: [SharedMarginTally.Sender], ownMarginCount: Int) {
            self.itemID = itemID
            self.senders = senders
            self.ownMarginCount = ownMarginCount
        }

        /// From the Library's rows, which hold only items that are not in Recently Deleted.
        public init(_ row: LibraryItemRow) {
            self.init(itemID: row.id, senders: row.sharedMargins.senders, ownMarginCount: row.marginCount)
        }
    }

    /// The row's words and what Make a Collection puts in the collection.
    public struct Offer: Equatable, Sendable, Identifiable {
        public let senderID: String
        public let senderName: String
        /// Every Library item holding Margins from this sender, in the Library's order.
        public let itemIDs: [String]

        public var title: String { "Keep \(senderName)'s readings together" }
        public var detail: String { "Put the \(itemIDs.count) readings from \(senderName) in one collection." }
        public var countLine: String { "\(itemIDs.count) readings from \(senderName)" }
        /// The name the New Collection sheet starts with; the listener may type a course name instead.
        public var defaultCollectionName: String {
            ItemCollectionEditing.normalizedName("From \(senderName)") ?? "From \(senderName)"
        }
        public var accessibilityLabel: String { "\(title). \(detail)" }
        public var id: String { senderID }
    }

    /// A later item from a sender whose collection the listener made through the offer: it joins that collection.
    public struct Join: Equatable, Sendable {
        public let senderID: String
        public let collectionID: String
        public let collectionName: String
        public let itemID: String

        public var banner: String { SenderCollectionOffer.addedBanner(collectionName: collectionName) }
    }

    public enum Decision: Equatable, Sendable {
        case none
        case offer(Offer)
        case join(Join)
    }

    /// The fewest items from one sender before the offer: a single reading is a friend share, not a set to keep together.
    public static let minimumItems = 2

    /// The banner after Make a Collection and after a silent join.
    public static func addedBanner(collectionName: String) -> String { "Added to \(collectionName)." }

    /// What the screen of `itemID` shows or does. A join comes before an offer when the item has Margins from two
    /// senders, so an earlier yes is honoured before anything new is asked.
    public static func decide(
        itemID: String,
        items: [ItemSenders],
        collections: [ItemCollection],
        record: SenderCollectionOfferRecord,
        hidden: HiddenSenders = HiddenSenders()
    ) -> Decision {
        guard let current = items.first(where: { $0.itemID == itemID }) else { return .none }
        let senderIDs = uniqueSenderIDs(current.senders).filter { !hidden.isHidden($0) }
        guard !senderIDs.isEmpty else { return .none }

        for senderID in senderIDs {
            guard case .collection(let collectionID) = record.choice(for: senderID) else { continue }
            // A deleted collection drops the link and counts as Not now: no join and no new offer.
            // An item this offer already placed and the listener took out by hand stays out.
            guard !record.wasPlaced(itemID),
                  let collection = collections.first(where: { $0.id == collectionID }),
                  !collection.itemIDs.contains(itemID) else { continue }
            return .join(Join(senderID: senderID, collectionID: collection.id, collectionName: collection.name, itemID: itemID))
        }

        for senderID in senderIDs where record.choice(for: senderID) == nil {
            let fromSender = items.filter { uniqueSenderIDs($0.senders).contains(senderID) }
            guard fromSender.count >= minimumItems,
                  fromSender.contains(where: { $0.ownMarginCount > 0 }),
                  let name = senderName(senderID, current: current, items: fromSender) else { continue }
            return .offer(Offer(senderID: senderID, senderName: name, itemIDs: fromSender.map(\.itemID)))
        }
        return .none
    }

    /// The sender id a tally's merged sender carries, or nil for one keyed only by a name (an older sender build).
    public static func senderID(of sender: SharedMarginTally.Sender) -> String? {
        guard sender.key.hasPrefix(idPrefix) else { return nil }
        return SenderID.valid(String(sender.key.dropFirst(idPrefix.count)))
    }

    private static let idPrefix = "id:"

    private static func uniqueSenderIDs(_ senders: [SharedMarginTally.Sender]) -> [String] {
        var seen = Set<String>()
        return senders.compactMap(senderID(of:)).filter { seen.insert($0).inserted }
    }

    /// The name on this item's packet, else the first the sender gave on another item. Nil when no packet named them:
    /// the row would have nobody to name.
    private static func senderName(_ wanted: String, current: ItemSenders, items: [ItemSenders]) -> String? {
        let named = ([current] + items).lazy.flatMap(\.senders).first { senderID(of: $0) == wanted && $0.isNamed }
        return named?.name
    }
}

/// What the listener chose for each sender (#5033): the collection they made through the offer, or Not now. Kept on
/// this device in UserDefaults under `senderCollectionOfferV1` as `[senderId: collectionId | "declined"]`; never sent.
/// A record that can't be read starts empty, which at worst offers once more.
public struct SenderCollectionOfferRecord: Equatable, Sendable {
    public enum Choice: Equatable, Sendable {
        case collection(String)
        case declined
    }

    public static let defaultsKey = "senderCollectionOfferV1"
    /// The items the offer has put in a collection, so one the listener took out again is never added back.
    public static let placedDefaultsKey = "senderCollectionOfferPlacedV1"
    private static let declinedValue = "declined"

    public private(set) var choices: [String: Choice]
    public private(set) var placedItemIDs: Set<String>

    public init(choices: [String: Choice] = [:], placedItemIDs: Set<String> = []) {
        self.choices = choices
        self.placedItemIDs = placedItemIDs
    }

    public func wasPlaced(_ itemID: String) -> Bool { placedItemIDs.contains(itemID) }

    /// Records the items Make a Collection or a join put in the sender's collection.
    public mutating func recordPlaced(_ itemIDs: [String]) {
        placedItemIDs.formUnion(itemIDs)
    }

    public func choice(for senderID: String) -> Choice? { choices[senderID] }

    /// Records Make a Collection. The link is the collection's id, so a rename keeps it.
    public mutating func recordCollection(_ collectionID: String, for senderID: String) {
        choices[senderID] = .collection(collectionID)
    }

    /// Records Not now: this sender is not offered again.
    public mutating func recordDeclined(for senderID: String) {
        choices[senderID] = .declined
    }

    public static func load(from defaults: UserDefaults) -> Self {
        guard let stored = defaults.dictionary(forKey: defaultsKey) as? [String: String] else { return Self() }
        var choices: [String: Choice] = [:]
        for (senderID, value) in stored where SenderID.isValid(senderID) && !value.isEmpty {
            choices[senderID] = value == declinedValue ? .declined : .collection(value)
        }
        let placed = (defaults.stringArray(forKey: placedDefaultsKey) ?? []).filter { !$0.isEmpty }
        return Self(choices: choices, placedItemIDs: Set(placed))
    }

    public func save(to defaults: UserDefaults) {
        let stored = choices.mapValues { choice -> String in
            switch choice {
            case .collection(let id): return id
            case .declined: return Self.declinedValue
            }
        }
        defaults.set(stored, forKey: Self.defaultsKey)
        defaults.set(placedItemIDs.sorted(), forKey: Self.placedDefaultsKey)
    }
}
