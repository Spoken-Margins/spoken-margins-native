import Foundation

/// What the item screen shows for the sender collection offer (#5033 Design sections 1 and 2): the words, the facts read
/// off the Library's rows, and the one place that turns the rule's answer into a row, a silent join or nothing. Plain
/// inputs only, so the screen holds no logic of its own and every line here is host-tested.
public enum SenderCollectionOfferPresentation {
    public enum Words {
        /// "Keep Sam’s readings together"
        public static func title(sender: String) -> String { "Keep \(sender)’s readings together" }

        /// "Put the 2 articles from Sam in one collection." The noun is the listener's word, never the app's own (#3599).
        public static func detail(count: Int, sender: String, noun: String) -> String {
            "Put the \(count) \(noun) from \(sender) in one collection."
        }

        /// One container for VoiceOver: the title, then the detail.
        public static func accessibilityLabel(count: Int, sender: String, noun: String) -> String {
            "\(title(sender: sender)). \(detail(count: count, sender: sender, noun: noun))"
        }

        /// What a listener calls these sources: "episodes", "articles", "PDFs", "books"; "sources" when they differ or
        /// are plain text.
        public static func noun(for nouns: [SourceNoun]) -> String {
            guard let first = nouns.first, first != .text, nouns.allSatisfy({ $0 == first }) else {
                return nouns.count == 1 ? "source" : "sources"
            }
            return nouns.count == 1 ? first.inSentence : first.inSentence + "s"
        }

        public static let makeButton = "Make a Collection"
        public static let notNowButton = "Not now"
        public static let sheetTitle = "New Collection"
        public static let namePlaceholder = "Name, such as HIST 210"
        public static let createButton = "Create"

        /// The sheet's name field starts as "From Sam".
        public static func defaultName(sender: String) -> String { "From \(sender)" }

        /// "2 articles from Sam", under the name field.
        public static func sheetLine(count: Int, sender: String, noun: String) -> String { "\(count) \(noun) from \(sender)" }

        /// "Added to From Sam."
        public static func banner(collectionName: String) -> String { "Added to \(collectionName)." }
    }

    /// The row the item screen shows.
    public struct Offer: Equatable, Sendable {
        public let senderId: String
        /// The display name on the sender's newest packet.
        public let senderName: String
        /// The items a new collection would hold, in the Library's order.
        public let itemIds: [String]
        /// What the listener calls them: "articles", "episodes", "sources".
        public let noun: String

        public init(senderId: String, senderName: String, itemIds: [String], noun: String = "sources") {
            self.senderId = senderId
            self.senderName = senderName
            self.itemIds = itemIds
            self.noun = noun
        }

        public var title: String { Words.title(sender: senderName) }
        public var detail: String { Words.detail(count: itemIds.count, sender: senderName, noun: noun) }
        public var accessibilityLabel: String {
            Words.accessibilityLabel(count: itemIds.count, sender: senderName, noun: noun)
        }
        public var defaultCollectionName: String { Words.defaultName(sender: senderName) }
        public var sheetLine: String { Words.sheetLine(count: itemIds.count, sender: senderName, noun: noun) }
    }

    public enum Result: Equatable, Sendable {
        case none
        case offer(Offer)
        /// Add the open item to the collection the listener already made for this sender, then say so in a banner.
        case join(senderId: String, collectionId: String, itemId: String)
    }

    /// The rule's facts for every live Library row. Senders come from the rows' tallies, which already leave out a hidden
    /// sender's and a deleted layer's Margins; the key is `"id:<senderId>"` (a sender with no id is keyed by name and
    /// never counts). Recently Deleted items are not Library rows, so none is counted.
    public static func facts(from rows: [LibraryItemRow]) -> [SenderCollectionOffer.ItemFacts] {
        rows.map { row in
            SenderCollectionOffer.ItemFacts(
                itemId: row.id,
                senderIds: Set(row.sharedMargins.senders.compactMap { sender in
                    sender.key.hasPrefix("id:") ? String(sender.key.dropFirst(3)) : nil
                }),
                hasListenerMargin: row.marginCount > 0)
        }
    }

    /// The answer for the item that is open. `layers` are that item's live imported layers; the newest sender whose
    /// answer is not "nothing" wins. A row needs a name the sender gave ("Unsigned sender" gets no row, Design section 2);
    /// a silent join needs none.
    public static func decide(
        openItemId: String,
        layers: [ImportedCommentaryLayer],
        rows: [LibraryItemRow],
        collections: [ItemCollection],
        record: SenderCollectionRecord,
        isHidden: (String) -> Bool
    ) -> Result {
        let items = facts(from: rows)
        var seen = Set<String>()
        for layer in layers.sorted(by: { $0.importedAt > $1.importedAt }) {
            guard let senderId = SenderID.valid(layer.senderId), seen.insert(senderId).inserted else { continue }
            let decision = SenderCollectionOffer.decide(
                newItemId: openItemId, senderId: senderId, items: items,
                collections: collections, record: record, isHidden: isHidden)
            switch decision {
            case .none:
                continue
            case .join(let collectionId, let itemId):
                return .join(senderId: senderId, collectionId: collectionId, itemId: itemId)
            case .offer(let itemIds):
                guard let name = SharedPacketArrival.senderName(layer.displayLabel) else { continue }
                let rowsById = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let nouns = itemIds.compactMap { rowsById[$0] }.map {
                    SourceNoun(mediaType: $0.mediaType, sourceReference: $0.sourceReference,
                               sourceReferenceType: $0.sourceReferenceType)
                }
                return .offer(Offer(senderId: senderId, senderName: name, itemIds: itemIds, noun: Words.noun(for: nouns)))
            }
        }
        return .none
    }
}

/// The record's life across the screen's taps (#5033): Not now is final, a made collection is linked by id, and a
/// collection that was deleted is written back as declined so the sender is not offered again.
public struct SenderCollectionOfferKeeper {
    private let store: SenderCollectionRecordStore

    public init(defaults: UserDefaults = .standard) {
        store = SenderCollectionRecordStore(defaults: defaults)
    }

    /// The saved record with deleted collections already dropped. A change is written back at once.
    public func record(reconciledWith collections: [ItemCollection]) -> SenderCollectionRecord {
        let saved = store.load()
        let reconciled = saved.reconciled(with: collections)
        if reconciled != saved { store.save(reconciled) }
        return reconciled
    }

    public func declined(_ senderId: String) {
        var record = store.load()
        record.decline(senderId)
        store.save(record)
    }

    public func linked(_ senderId: String, toCollection collectionId: String) {
        var record = store.load()
        if record.link(senderId, toCollection: collectionId) { store.save(record) }
    }
}
