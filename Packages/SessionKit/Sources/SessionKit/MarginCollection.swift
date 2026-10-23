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

        public init(interjection: Interjection, itemTitle: String, sessionDate: Date?, place: MarginPlaces.Place? = nil) {
            self.interjection = interjection
            self.itemTitle = itemTitle
            self.sessionDate = sessionDate
            self.place = place
        }

        public var id: String { "\(interjection.sessionId)::\(interjection.id)" }
    }

    public struct SharedEntry: Equatable, Sendable {
        public let interjection: ImportedCommentaryInterjection
        public let layer: ImportedCommentaryLayer
        public let itemTitle: String

        public init(interjection: ImportedCommentaryInterjection, layer: ImportedCommentaryLayer, itemTitle: String) {
            self.interjection = interjection
            self.layer = layer
            self.itemTitle = itemTitle
        }

        public var id: String { "shared::\(layer.id)::\(interjection.id)" }
    }

    public struct Entries: Equatable, Sendable {
        public let privateRows: [PrivateEntry]
        public let sharedRows: [SharedEntry]

        public init(privateRows: [PrivateEntry], sharedRows: [SharedEntry]) {
            self.privateRows = privateRows
            self.sharedRows = sharedRows
        }
    }

    /// Reads remain in the caller's synchronous closures, in the original order.
    /// No partial result escapes if any read throws.
    /// - `loadMap`: an item's listening map, nil when it has none. Without it, text Margins carry no `place`.
    /// - `loadMediaChapters`: an item's chapters with start times. Without it, Margins with a clock time carry no `place`.
    public static func build(
        items: [Item],
        sessions: [Session],
        loadMap: ((String) -> ListeningMap?)? = nil,
        loadMediaChapters: ((String) -> [MediaTimelineChapter])? = nil,
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
        guard loadMap != nil || loadMediaChapters != nil else { return Entries(privateRows: privateRows, sharedRows: sharedRows) }
        let places = MarginPlaces.places(
            for: privateRows, items: items, loadMap: loadMap, loadMediaChapters: loadMediaChapters ?? { _ in [] })
        let placedRows = privateRows.map { entry -> PrivateEntry in
            var placed = entry
            placed.place = places[entry.id]
            return placed
        }
        return Entries(privateRows: placedRows, sharedRows: sharedRows)
    }

    /// The most characters of context a Margin shows.
    public static let sourceContextLimit = 600
    private static let sourceContextJoiner = " … "

    /// The text around where the Margin was made, from the bounded anchor saved with it.
    /// Past the limit it keeps the text nearest the Margin: the end of what came before and the start of what
    /// follows. Cutting from the front kept the far end instead, and on a paper's title page that was the author
    /// block, not the passage (#2482).
    public static func sourceContext(anchorBefore: String?, anchorAfter: String?) -> String? {
        // The saved bounded anchor belongs to this Margin's source or generated target.
        let blank = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let before = anchorBefore.flatMap { blank($0) ? nil : $0 }
        let after = anchorAfter.flatMap { blank($0) ? nil : $0 }
        let limit = sourceContextLimit
        switch (before, after) {
        case (nil, nil):
            return nil
        case let (before?, nil):
            return String(before.suffix(limit))
        case let (nil, after?):
            return String(after.prefix(limit))
        case let (before?, after?):
            let joined = before + sourceContextJoiner + after
            guard joined.count > limit else { return joined }
            // Each side gets half; a side too short to use its half gives the rest to the other.
            let room = limit - sourceContextJoiner.count
            var beforeRoom = room / 2
            var afterRoom = room - beforeRoom
            if before.count < beforeRoom {
                afterRoom += beforeRoom - before.count
                beforeRoom = before.count
            } else if after.count < afterRoom {
                beforeRoom += afterRoom - after.count
                afterRoom = after.count
            }
            return String(before.suffix(beforeRoom)) + sourceContextJoiner + String(after.prefix(afterRoom))
        }
    }
}
