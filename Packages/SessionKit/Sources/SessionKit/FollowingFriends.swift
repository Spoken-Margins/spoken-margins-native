import Foundation

/// #3291 (done-when 6): the friends who sent Margins, one row each on Following, under the shows' row style.
/// "Cole", "3 Margins on 1 episode"; tapping opens their items.
///
/// The name is the packet's sender label (`ImportedCommentaryLayer.displayLabel`), which comes from the sender's app
/// and isn't proven, so rows group on what a listener would read as the same name: spaces at the ends and doubled
/// inside don't count, nor do letter case or how an accent was typed. A packet with no name, or one carrying a stand-in
/// ("Unsigned sender", "Someone", "Your friend"), still gets a row (#4104): all of them form one "A friend" row, never
/// merged with a real name. Only Margins on items in the Library count, so each row has something to open.
public enum FollowingFriends {
    public struct Friend: Identifiable, Hashable, Sendable {
        /// The grouping key, stable while the name reads the same.
        public let id: String
        /// The name as the newest packet spelled it.
        public let name: String
        public let marginCount: Int
        /// How many of their Margins the listener hasn't heard yet.
        public let newCount: Int
        /// When something last changed for this friend: the later of a Margin's recording time and when the
        /// listener received its packet (#3343). Nil when no Margin carries a usable date; the row then sorts last.
        public let newestAt: Date?
        /// Their items, the one with their newest Margin first.
        public let items: [Item]
        /// "3 Margins on 1 episode".
        public let summary: String
        /// "2 new" when any of their Margins are unheard; nil otherwise. Words carry it, never a colour alone.
        public var newLabel: String? { newCount > 0 ? "\(newCount) new" : nil }

        public struct Item: Identifiable, Hashable, Sendable {
            public let id: String
            public let title: String
            public let marginCount: Int
            /// How many of the friend's Margins on this item the listener hasn't heard yet.
            public let newCount: Int
            /// The item's own newest-Margin date, as for `Friend.newestAt`.
            public let newestAt: Date?
            /// "3 Margins".
            public var countLabel: String { FollowingFriends.margins(marginCount) }
            /// "2 new" when any are unheard; nil otherwise. Words carry it, never a colour alone.
            public var newLabel: String? { newCount > 0 ? "\(newCount) new" : nil }
        }
    }

    /// What the row for packets that carry no usable sender name is called.
    public static let unnamedFriendName = "A friend"
    /// The grouping key of that row: empty, which no real name produces, so a sender literally named "A friend" stays apart.
    static let unnamedKey = ""

    public static func friends(from entries: [MarginCollection.SharedEntry]) -> [Friend] {
        struct Group {
            var name: String
            var newest: Date
            var marginIds: Set<String> = []
            var newIds: Set<String> = []
            var items: [String: (title: String, newest: Date, marginIds: Set<String>, newIds: Set<String>, kind: SharedItemType)] = [:]
        }
        var groups: [String: Group] = [:]
        for entry in entries {
            guard let itemId = entry.layer.itemId else { continue }
            let name: String
            let key: String
            if let usable = FriendName.usable(entry.layer.displayLabel).flatMap(displayName) {
                name = usable
                key = groupingKey(usable)
            } else {
                name = unnamedFriendName
                key = unnamedKey
            }
            let date = activityDate(entry)
            var group = groups[key] ?? Group(name: name, newest: date)
            if date > group.newest { group.newest = date; group.name = name }
            group.marginIds.insert(entry.id)
            var item = group.items[itemId] ?? (entry.itemTitle, date, [], [], entry.layer.itemIdentity.itemType)
            item.newest = max(item.newest, date)
            item.marginIds.insert(entry.id)
            if entry.interjection.showsAsNew {
                group.newIds.insert(entry.id)
                item.newIds.insert(entry.id)
            }
            group.items[itemId] = item
            groups[key] = group
        }
        return groups
            .sorted { $0.value.newest != $1.value.newest ? $0.value.newest > $1.value.newest : $0.key < $1.key }
            .map { key, group in
                let items = group.items
                    .sorted { $0.value.newest != $1.value.newest ? $0.value.newest > $1.value.newest : $0.key < $1.key }
                    .map {
                        Friend.Item(
                            id: $0.key, title: $0.value.title, marginCount: $0.value.marginIds.count,
                            newCount: $0.value.newIds.count, newestAt: dated($0.value.newest)
                        )
                    }
                let noun = itemNoun(Set(group.items.values.map(\.kind)), count: items.count)
                return Friend(
                    id: key,
                    name: group.name,
                    marginCount: group.marginIds.count,
                    newCount: group.newIds.count,
                    newestAt: dated(group.newest),
                    items: items,
                    summary: "\(margins(group.marginIds.count)) on \(items.count) \(noun)"
                )
            }
    }

    /// When a Margin counts as having happened for this listener (#3343): the later of when it was recorded and when
    /// the packet arrived (`ImportedCommentaryLayer.importedAt`, already stored), so a packet recorded last month and
    /// opened today sorts as today. `.distantPast` when neither date is usable (at or before 1970).
    static func activityDate(_ entry: MarginCollection.SharedEntry) -> Date {
        let later = max(entry.interjection.createdAt, entry.layer.importedAt)
        return later.timeIntervalSince1970 > 0 ? later : .distantPast
    }

    static func dated(_ date: Date) -> Date? { date == .distantPast ? nil : date }

    /// A friend's item as a Library row reads it (#3343): site or author, kind, then listening progress, with the
    /// item's length first when it has one. Built from the same wording the Library row uses.
    public static func itemDetail(_ row: LibraryItemRow, playbackSpeed: Double) -> LibraryRowDetail {
        let listening: String? = row.isCompleted ? "Completed" : row.continuationProgressPercent.map { "\($0)%" }
        return LibraryRowDetail(
            byline: LibraryRowWording.byline(sourceTitle: row.sourceTitle, author: row.author, title: row.title),
            kind: LibraryRowWording.kindLabel(
                mediaType: row.mediaType, sourceReference: row.sourceReference,
                sourceReferenceType: row.sourceReferenceType, usesNewReader: row.usesNewReader
            ),
            length: ListeningTimeEstimator.libraryTotalText(textCharacterCount: row.textCharacterCount, playbackSpeed: playbackSpeed),
            listening: listening,
            status: nil
        )
    }

    /// The label as a row shows it: trimmed, inner runs of spaces made one, nil when nothing is left.
    static func displayName(_ label: String?) -> String? {
        guard let label else { return nil }
        let words = label.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    static func groupingKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    static func margins(_ count: Int) -> String {
        "\(count) Margin\(count == 1 ? "" : "s")"
    }

    /// "episode" when every item is a podcast episode, "article" for articles; "source" for a mix.
    static func itemNoun(_ kinds: Set<SharedItemType>, count: Int) -> String {
        let (one, many): (String, String)
        switch kinds.count == 1 ? kinds.first : nil {
        case .podcast: (one, many) = ("episode", "episodes")
        case .text: (one, many) = ("article", "articles")
        case .pdf: (one, many) = ("PDF", "PDFs")
        case .epub: (one, many) = ("book", "books")
        case .other, nil: (one, many) = ("source", "sources")
        }
        return count == 1 ? one : many
    }
}
