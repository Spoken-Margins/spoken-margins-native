import Foundation

/// One line on the play queue screen (#1990).
public struct PlayQueueRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// Who or where it is from, when the item says: the author, else the source's name.
    public let subtitle: String?
    /// The SF Symbol the Library row shows for this kind of item.
    public let symbol: String
}

/// What the play queue screen and its Library entry show. Pure, so the words and the "deleted items never show" rule
/// are host-tested.
public enum PlayQueueRows {
    /// The queued items in queue order. An item deleted since it was queued has no row (the queue drops it when its
    /// turn comes), so the screen never lists something that cannot play.
    public static func rows(for queue: PlayQueue, items: [LibraryItemRow]) -> [PlayQueueRow] {
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return queue.itemIds.compactMap { id in
            guard let item = byId[id] else { return nil }
            return PlayQueueRow(id: id, title: item.title, subtitle: subtitle(of: item), symbol: item.mediaSymbol)
        }
    }

    /// "3 waiting", for the Library entry.
    public static func countLine(_ count: Int) -> String {
        "\(count) waiting"
    }

    /// The Library entry's second line: what plays first.
    public static func nextLine(_ rows: [PlayQueueRow]) -> String? {
        rows.first.map { "Next: \($0.title)" }
    }

    private static func subtitle(of item: LibraryItemRow) -> String? {
        for candidate in [item.author, item.sourceTitle] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
