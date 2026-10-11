import Foundation

public enum MarginCollectionFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case starred
    case attention
    case shared

    public var title: String {
        switch self {
        case .all: "Mine"
        case .starred: "Starred"
        case .attention: "Needs attention"
        case .shared: "Shared"
        }
    }
}

public struct MarginCollectionQuery: Equatable, Sendable {
    public var text = ""
    public var filter: MarginCollectionFilter = .all
    public var itemID: String? = nil
    /// Only the items of this collection (#490). Never set together with `itemID`; see `selectScope`.
    public var collection: ItemCollectionScope? = nil

    public init(text: String = "", filter: MarginCollectionFilter = .all, itemID: String? = nil,
                collection: ItemCollectionScope? = nil) {
        self.text = text
        self.filter = filter
        self.itemID = itemID
        self.collection = collection
    }

    public func includes(itemID: String?) -> Bool {
        if let collection, !(itemID.map(collection.contains(itemID:)) ?? false) { return false }
        return self.itemID == nil || self.itemID == itemID
    }

    public func matches(_ values: [String]) -> Bool {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return query.isEmpty || values.joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .contains(query)
    }
}

/// Foundation-only entries; the app adds speech-recognition and placement presentation state.
public enum MarginCollection {
    public struct PrivateEntry: Equatable, Sendable {
        public let interjection: Interjection
        public let itemTitle: String
        public let sessionDate: Date?
        /// The chapter and paragraph the Margin was made at, when `build` was given a way to read listening maps (#777).
        public var place: MarginPlaces.Place? = nil

        public var id: String { "\(interjection.sessionId)::\(interjection.id)" }
    }

    public struct SharedEntry: Equatable, Sendable {
        public let interjection: ImportedCommentaryInterjection
        public let layer: ImportedCommentaryLayer
        public let itemTitle: String

        public var id: String { "shared::\(layer.id)::\(interjection.id)" }
    }

    public struct Entries: Equatable, Sendable {
        public let privateRows: [PrivateEntry]
        public let sharedRows: [SharedEntry]
    }

    /// Reads remain in the caller's synchronous closures, in the original order.
    /// No partial result escapes if any read throws.
    /// - `loadMap`: an item's listening map, nil when it has none. Without it the entries carry no `place`.
    public static func build(
        items: [Item],
        sessions: [Session],
        loadMap: ((String) -> ListeningMap?)? = nil,
        loadInterjections: (String) throws -> [Interjection],
        loadImportedLayers: () throws -> [ImportedCommentaryLayer],
        loadImportedInterjections: (String) throws -> [ImportedCommentaryInterjection]
    ) throws -> Entries {
        let activeItems = Dictionary(uniqueKeysWithValues: items
            .filter { $0.deletedAt == nil }.map { ($0.id, $0.title) })
        let rows = try sessions.flatMap { session -> [PrivateEntry] in
            guard let itemTitle = activeItems[session.itemId] else { return [] }
            return try loadInterjections(session.id)
                .filter { $0.status == "active" }
                .map {
                    PrivateEntry(
                        interjection: $0,
                        itemTitle: itemTitle,
                        sessionDate: session.updatedAt ?? session.createdAt
                    )
                }
        }
        let sharedRows = try loadImportedLayers()
            .filter { $0.deletedAt == nil && ($0.itemId == nil || activeItems[$0.itemId ?? ""] != nil) }
            .flatMap { layer in
                try loadImportedInterjections(layer.id).map {
                    SharedEntry(interjection: $0, layer: layer, itemTitle: activeItems[layer.itemId ?? ""] ?? layer.itemIdentity.title)
                }
            }
            .sorted { $0.interjection.createdAt > $1.interjection.createdAt }
        let privateRows = rows.sorted { lhs, rhs in
            let leftSessionDate = lhs.sessionDate ?? .distantPast
            let rightSessionDate = rhs.sessionDate ?? .distantPast
            if leftSessionDate != rightSessionDate { return leftSessionDate > rightSessionDate }
            if lhs.interjection.createdAt != rhs.interjection.createdAt {
                return lhs.interjection.createdAt > rhs.interjection.createdAt
            }
            return lhs.id < rhs.id
        }
        guard let loadMap else { return Entries(privateRows: privateRows, sharedRows: sharedRows) }
        let places = MarginPlaces.places(for: privateRows, items: items, loadMap: loadMap)
        let placedRows = privateRows.map { entry -> PrivateEntry in
            var placed = entry
            placed.place = places[entry.id]
            return placed
        }
        return Entries(privateRows: placedRows, sharedRows: sharedRows)
    }

    public static func sourceContext(anchorBefore: String?, anchorAfter: String?) -> String? {
        // The saved bounded anchor belongs to this Margin's source or generated target.
        let parts = [anchorBefore, anchorAfter]
            .compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !parts.isEmpty else { return nil }
        return String(parts.joined(separator: " … ").prefix(600))
    }
}
