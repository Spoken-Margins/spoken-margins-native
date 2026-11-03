import Foundation

/// #3291 (done-when 6): the friends who sent Margins, one row each on Following, under the shows' row style.
/// "Cole", "3 Margins on 1 episode"; tapping opens their items.
///
/// The name is the packet's sender label (`ImportedCommentaryLayer.displayLabel`), which comes from the sender's app
/// and isn't proven, so rows group on what a listener would read as the same name: spaces at the ends and doubled
/// inside don't count, nor do letter case or how an accent was typed. A packet with no name has no row; its Margins
/// still show on their item. Only Margins on items in the Library count, so each row has something to open.
public enum FollowingFriends {
    public struct Friend: Identifiable, Hashable, Sendable {
        /// The grouping key, stable while the name reads the same.
        public let id: String
        /// The name as the newest packet spelled it.
        public let name: String
        public let marginCount: Int
        /// Their items, the one with their newest Margin first.
        public let items: [Item]
        /// "3 Margins on 1 episode".
        public let summary: String

        public struct Item: Identifiable, Hashable, Sendable {
            public let id: String
            public let title: String
            public let marginCount: Int
            /// "3 Margins".
            public var countLabel: String { FollowingFriends.margins(marginCount) }
        }
    }

    public static func friends(from entries: [MarginCollection.SharedEntry]) -> [Friend] {
        struct Group {
            var name: String
            var newest: Date
            var marginIds: Set<String> = []
            var items: [String: (title: String, newest: Date, marginIds: Set<String>, kind: SharedItemType)] = [:]
        }
        var groups: [String: Group] = [:]
        for entry in entries {
            guard let itemId = entry.layer.itemId, let name = displayName(entry.layer.displayLabel) else { continue }
            let key = groupingKey(name)
            let date = entry.interjection.createdAt
            var group = groups[key] ?? Group(name: name, newest: date)
            if date > group.newest { group.newest = date; group.name = name }
            group.marginIds.insert(entry.id)
            var item = group.items[itemId] ?? (entry.itemTitle, date, [], entry.layer.itemIdentity.itemType)
            item.newest = max(item.newest, date)
            item.marginIds.insert(entry.id)
            group.items[itemId] = item
            groups[key] = group
        }
        return groups
            .sorted { $0.value.newest != $1.value.newest ? $0.value.newest > $1.value.newest : $0.key < $1.key }
            .map { key, group in
                let items = group.items
                    .sorted { $0.value.newest != $1.value.newest ? $0.value.newest > $1.value.newest : $0.key < $1.key }
                    .map { Friend.Item(id: $0.key, title: $0.value.title, marginCount: $0.value.marginIds.count) }
                let noun = itemNoun(Set(group.items.values.map(\.kind)), count: items.count)
                return Friend(
                    id: key,
                    name: group.name,
                    marginCount: group.marginIds.count,
                    items: items,
                    summary: "\(margins(group.marginIds.count)) on \(items.count) \(noun)"
                )
            }
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

    /// "episode" when every item is a podcast episode, "article" for articles; "item" for a mix.
    static func itemNoun(_ kinds: Set<SharedItemType>, count: Int) -> String {
        let (one, many): (String, String)
        switch kinds.count == 1 ? kinds.first : nil {
        case .podcast: (one, many) = ("episode", "episodes")
        case .text: (one, many) = ("article", "articles")
        case .pdf: (one, many) = ("PDF", "PDFs")
        case .epub: (one, many) = ("book", "books")
        case .other, nil: (one, many) = ("item", "items")
        }
        return count == 1 ? one : many
    }
}
