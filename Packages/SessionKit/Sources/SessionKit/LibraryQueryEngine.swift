import Foundation

/// The Library metadata needed to filter and order existing rows without copying them.
public protocol LibraryQueryRow {
    var id: String { get }
    var title: String { get }
    var sourceTitle: String? { get }
    var author: String? { get }
    var mediaType: String { get }
    var sourceReference: String? { get }
    var sourceReferenceType: String? { get }
    var isCompleted: Bool { get }
    var continuationProgressPercent: Int? { get }
    var offlineState: LibraryOfflineStateFilter { get }
    var addedAt: Date? { get }
    var publishedAt: Date? { get }
    var lastListenedAt: Date? { get }
    var storageRecencyRank: Int { get }
    var sharedMargins: SharedMarginTally { get }
}

extension LibraryQueryRow {
    /// Rows that don't track shared Margins have none.
    public var sharedMargins: SharedMarginTally { .none }
    public var publishedAt: Date? { nil }

    /// Whether the default "Unfinished" view lists the row: it isn't finished, or it is but a friend's Margins on it
    /// are still new to the listener (#4103). Without this, a friend's reply packet imported into an episode the
    /// listener had already finished left the item out of the default view, with nothing saying where it went.
    /// Unplayed and In Progress mean what they say about the listener's own listening and keep ignoring friends' Margins.
    var staysInUnfinished: Bool { !isCompleted || sharedMargins.new > 0 }
}

/// The Library's own rows. Declared here, not in the app, so host tests filter the same rows the screen does (#4178).
extension LibraryItemRow: LibraryQueryRow {}

/// Library query rules shared by the app and host tests.
public enum LibraryQueryEngine {
    public static func visibleLibraryItems<Row: LibraryQueryRow>(_ libraryItems: [Row], query libraryQuery: LibraryQuery) -> [Row] {
        let normalizedQuery = libraryQuery.query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = libraryItems.filter { row in
            let metadataMatch: Bool
            if normalizedQuery.isEmpty {
                metadataMatch = true
            } else {
                metadataMatch = [row.title, row.sourceTitle, row.author]
                    .compactMap { $0 }
                    .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
                    .contains { $0.localizedStandardContains(normalizedQuery) }
            }
            let contentMatch = libraryQuery.contentType == .all || libraryContentType(for: row) == libraryQuery.contentType
            let listeningMatch: Bool
            switch libraryQuery.listeningState {
            case .all: listeningMatch = true
            case .unfinished: listeningMatch = row.staysInUnfinished
            case .unplayed: listeningMatch = !row.isCompleted && (row.continuationProgressPercent ?? 0) == 0
            case .inProgress: listeningMatch = !row.isCompleted && (row.continuationProgressPercent ?? 0) > 0
            case .completed: listeningMatch = row.isCompleted
            }
            let offlineMatch = libraryQuery.offlineState == .all || row.offlineState == libraryQuery.offlineState
            let sharedMatch = libraryQuery.sharedMargins.matches(row.sharedMargins)
            return metadataMatch && contentMatch && listeningMatch && offlineMatch && sharedMatch
        }
        return filtered.sorted { lhs, rhs in
            let ordered: ComparisonResult
            switch libraryQuery.sort {
            case .recentlyAdded:
                if lhs.addedAt != nil, rhs.addedAt != nil {
                    ordered = compareDates(lhs.addedAt, rhs.addedAt)
                } else if lhs.storageRecencyRank != rhs.storageRecencyRank {
                    ordered = lhs.storageRecencyRank < rhs.storageRecencyRank ? .orderedAscending : .orderedDescending
                } else {
                    ordered = compareDates(lhs.addedAt, rhs.addedAt)
                }
            case .recentlyListened:
                ordered = compareDates(lhs.lastListenedAt, rhs.lastListenedAt)
            case .published:
                ordered = compareDates(lhs.publishedAt, rhs.publishedAt)
            case .title:
                ordered = lhs.title.localizedStandardCompare(rhs.title)
            case .progress:
                let left = lhs.continuationProgressPercent ?? 0
                let right = rhs.continuationProgressPercent ?? 0
                ordered = left == right ? .orderedSame : (left > right ? .orderedAscending : .orderedDescending)
            }
            return ordered == .orderedSame ? lhs.id < rhs.id : ordered == .orderedAscending
        }
    }

    /// Where an item the app just said it added stands in the Library as the listener has it filtered (#4178): listed,
    /// or the first reason the list leaves it out. "Added to Library" for an item the list doesn't show is the bug class
    /// #4178 was; Diagnostics records this answer with every confirmation, so the next one names its cause.
    public static func addedItemVisibility<Row: LibraryQueryRow>(
        itemId: String, in libraryItems: [Row], query libraryQuery: LibraryQuery
    ) -> String {
        guard let row = libraryItems.first(where: { $0.id == itemId }) else { return "hidden:no_row" }
        if visibleLibraryItems([row], query: libraryQuery).isEmpty {
            var unfiltered = libraryQuery
            unfiltered.query = ""
            if !visibleLibraryItems([row], query: unfiltered).isEmpty { return "hidden:search" }
            let listedDespiteFinished = libraryQuery.listeningState == .unfinished && row.staysInUnfinished
            if row.isCompleted, libraryHidesCompleted(query: libraryQuery), !listedDespiteFinished { return "hidden:finished" }
            if libraryQuery.contentType != .all { return "hidden:content_filter" }
            if libraryQuery.offlineState != .all { return "hidden:offline_filter" }
            if libraryQuery.sharedMargins != .all { return "hidden:shared_filter" }
            return "hidden:listening_filter"
        }
        let position = visibleLibraryItems(libraryItems, query: libraryQuery).firstIndex { $0.id == itemId } ?? 0
        return "visible:row_\(position + 1)"
    }

    public static func loadLibraryListeningFilter(defaults: UserDefaults) -> LibraryListeningStateFilter {
        let key = "libraryListeningStateFilter"
        let saved = LibraryListeningStateFilter(rawValue: defaults.string(forKey: key) ?? "")
        if !defaults.bool(forKey: "libraryUnfinishedDefaultApplied") {
            let selection = saved == nil || saved == .all ? LibraryListeningStateFilter.unfinished : saved!
            defaults.set(selection.rawValue, forKey: key)
            defaults.set(true, forKey: "libraryUnfinishedDefaultApplied")
            return selection
        }
        return saved ?? .unfinished
    }

    public static func libraryIsCaughtUp<Row: LibraryQueryRow>(_ libraryItems: [Row], query libraryQuery: LibraryQuery) -> Bool {
        !libraryItems.isEmpty && libraryItems.allSatisfy { !$0.staysInUnfinished }
            && libraryQuery.listeningState == .unfinished
            && libraryQuery.contentType == .all && libraryQuery.offlineState == .all
            && libraryQuery.sharedMargins == .all
            && libraryQuery.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func libraryHidesCompleted(query libraryQuery: LibraryQuery) -> Bool {
        [.unfinished, .unplayed, .inProgress].contains(libraryQuery.listeningState)
    }

    public static func libraryFilterDescription(query libraryQuery: LibraryQuery) -> String {
        var selections: [String] = []
        if libraryQuery.contentType != .all {
            selections.append(Self.displayName(libraryQuery.contentType.rawValue))
        }
        if libraryQuery.listeningState != .all {
            selections.append(Self.displayName(libraryQuery.listeningState.rawValue))
        }
        if libraryQuery.offlineState != .all {
            selections.append(Self.displayName(libraryQuery.offlineState.rawValue))
        }
        if libraryQuery.sharedMargins != .all {
            selections.append(libraryQuery.sharedMargins.title)
        }
        return selections.isEmpty ? "Everything" : selections.joined(separator: " · ")
    }

    public static func librarySortDescription(query libraryQuery: LibraryQuery) -> String {
        Self.displayName(libraryQuery.sort.rawValue)
    }

    /// The words the Library's filter and sort menus show for a raw filter or sort value, so "pdf"
    /// reads "PDF" in the menu and in the filter summary alike (#972).
    public static func displayName(_ rawValue: String) -> String {
        switch rawValue {
        case "pdf": return "PDF"
        case "epub": return "EPUB"
        default: return rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func libraryContentType<Row: LibraryQueryRow>(for row: Row) -> LibraryContentTypeFilter {
        LibraryRowWording.contentType(mediaType: row.mediaType, sourceReference: row.sourceReference, sourceReferenceType: row.sourceReferenceType)
    }

    private static func compareDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        let left = lhs ?? .distantPast
        let right = rhs ?? .distantPast
        if left == right { return .orderedSame }
        return left > right ? .orderedAscending : .orderedDescending
    }
}
