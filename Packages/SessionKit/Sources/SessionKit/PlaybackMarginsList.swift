import Foundation

/// The Margins the playback screen's Margins view lists for the item being played (#450).
///
/// Own and shared Margins are merged into one list in source order. All shows both, Mine only the listener's own,
/// Shared only Margins shared with them. The view draws what `rows` returns and maps a row's `id` back to its own
/// row (`MarginCollection.PrivateEntry.id`, `MarginCollection.SharedEntry.id`) for the play button and the detail
/// sheet.
public enum PlaybackMarginsList {
    public enum Filter: String, CaseIterable, Sendable {
        case all
        case mine
        case shared

        public var title: String {
            switch self {
            case .all: "All"
            case .mine: "Mine"
            case .shared: "Shared"
            }
        }
    }

    /// Where a Margin sits in the source. An item uses one kind: audio Margins have a time, text Margins a
    /// Character offset.
    public enum Position: Sendable, Equatable {
        case mediaTimeMs(Int)
        case charOffset(Int)
    }

    public struct Row: Sendable, Equatable, Identifiable {
        public let id: String
        public let origin: PlaybackNowMargins.Origin
        /// Nil when the Margin has no usable position; such rows come last.
        public let position: Position?
        /// The position is a rough match, not a verified one.
        public let isApproximate: Bool
        public let createdAt: Date

        public init(id: String, origin: PlaybackNowMargins.Origin, position: Position?, isApproximate: Bool = false, createdAt: Date) {
            self.id = id
            self.origin = origin
            self.position = position
            self.isApproximate = isApproximate
            self.createdAt = createdAt
        }
    }

    public struct Counts: Sendable, Equatable {
        public let all: Int
        public let mine: Int
        public let shared: Int

        public init(all: Int, mine: Int, shared: Int) {
            self.all = all
            self.mine = mine
            self.shared = shared
        }
    }

    /// This item's Margins for `filter`, in source order.
    ///
    /// Order: earliest position first. At the same position the listener's own Margin comes before a shared one,
    /// then the older one, then by id. A Margin with no position comes after all the others in the same order.
    /// Margins of other items are left out, and so are the listener's Margins on an assistant or summary turn
    /// (their anchor is inside generated text, not the source; the Timeline leaves them out too). A shared
    /// Margin from a packet not tied to any item is left out as well.
    public static func rows(itemID: String, entries: MarginCollection.Entries, filter: Filter) -> [Row] {
        ordered(candidates(itemID: itemID, entries: entries), filter: filter)
    }

    /// How many Margins each filter would show, for the filter chips.
    public static func counts(itemID: String, entries: MarginCollection.Entries) -> Counts {
        let all = candidates(itemID: itemID, entries: entries)
        let mine = all.filter { $0.origin == .own }.count
        return Counts(all: all.count, mine: mine, shared: all.count - mine)
    }

    /// `rows` for candidates already mapped to rows.
    public static func ordered(_ candidates: [Row], filter: Filter) -> [Row] {
        candidates
            .filter { row in
                switch filter {
                case .all: true
                case .mine: row.origin == .own
                case .shared: row.origin == .shared
                }
            }
            .sorted(by: comesBefore)
    }

    // MARK: Mapping

    private static func candidates(itemID: String, entries: MarginCollection.Entries) -> [Row] {
        let own = entries.privateRows
            .filter { $0.interjection.itemId == itemID && $0.interjection.targetType == .item }
            .map { row(own: $0) }
        let shared = entries.sharedRows
            .filter { $0.layer.itemId == itemID }
            .map { row(shared: $0) }
        return own + shared
    }

    /// A Margin on the item's source sits at its recorded time, else at its text offset.
    static func row(own entry: MarginCollection.PrivateEntry) -> Row {
        let interjection = entry.interjection
        var position: Position?
        if let ms = interjection.anchor.mediaTimeMs, ms >= 0 {
            position = .mediaTimeMs(ms)
        } else if interjection.anchor.anchorType == .text, interjection.anchor.startChar >= 0 {
            position = .charOffset(interjection.anchor.startChar)
        }
        return Row(id: entry.id, origin: .own, position: position, createdAt: interjection.createdAt)
    }

    /// A shared Margin sits where the listener's copy matched it, else where the sender had it, and says so when
    /// that is only approximate. A podcast time goes through `SharedMarginPlaybackPosition`, the same choice the
    /// play button makes.
    static func row(shared entry: MarginCollection.SharedEntry) -> Row {
        let interjection = entry.interjection
        let resolution = interjection.resolution
        var position: Position?
        var approximate = false
        if let playback = SharedMarginPlaybackPosition(interjection) {
            position = .mediaTimeMs(playback.mediaTimeMs)
            approximate = playback.isApproximate
        } else if !resolution.isAmbiguous, let local = resolution.localStartChar, local >= 0 {
            position = .charOffset(local)
            approximate = !Self.verifiedTextClasses.contains(resolution.evidenceClass)
        } else if let sender = interjection.anchorEvidence.startChar, sender >= 0 {
            position = .charOffset(sender)
            approximate = true
        }
        return Row(id: entry.id, origin: .shared, position: position, isApproximate: approximate, createdAt: interjection.createdAt)
    }

    /// The evidence classes that place a text Margin for sure, as `SharedMarginPlacement.isPlaced` has it.
    private static let verifiedTextClasses: Set<AnchorResolutionEvidenceClass> = [
        .articleTextVerified, .exactEdition, .recipientConfirmed
    ]

    // MARK: Order

    private static func comesBefore(_ lhs: Row, _ rhs: Row) -> Bool {
        switch (lhs.position, rhs.position) {
        case (nil, nil): break
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?):
            if left != right { return sortKey(left) < sortKey(right) }
        }
        if lhs.origin != rhs.origin { return lhs.origin == .own }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }

    /// Times before offsets, so an item that somehow mixes the two still sorts the same way every time.
    private static func sortKey(_ position: Position) -> (Int, Int) {
        switch position {
        case .mediaTimeMs(let ms): (0, ms)
        case .charOffset(let offset): (1, offset)
        }
    }
}
