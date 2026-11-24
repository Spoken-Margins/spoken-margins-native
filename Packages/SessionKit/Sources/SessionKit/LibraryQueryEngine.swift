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
    /// When the newest friend's Margins that count (`SharedMarginTally.total`) arrived on this item: the newest
    /// `ImportedCommentaryLayer.importedAt`, never the sender's own clock (#4101).
    var friendMarginsArrivedAt: Date? { get }
}

extension LibraryQueryRow {
    /// Rows that don't track shared Margins have none.
    public var sharedMargins: SharedMarginTally { .none }
    public var publishedAt: Date? { nil }
    public var friendMarginsArrivedAt: Date? { nil }

    /// Where Recently Added places the row: the later of when the listener added it (first add or latest add again) and
    /// when a friend's Margins last arrived on it, so an old item a friend just replied on comes forward (#4101).
    /// Nil only when neither is known; the sort then falls back to storage order.
    var recentlyAddedDate: Date? { [addedAt, friendMarginsArrivedAt].compactMap { $0 }.max() }

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
    /// The rows that pass the query's filters and search, in the order they came.
    private static func filteredLibraryItems<Row: LibraryQueryRow>(
        _ libraryItems: [Row], query libraryQuery: LibraryQuery, includingSenders: Bool
    ) -> [Row] {
        let normalizedQuery = libraryQuery.query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return libraryItems.filter { row in
            let metadataMatch = normalizedQuery.isEmpty
                || titleSourceOrAuthorMatches(row, normalizedQuery: normalizedQuery)
                || (includingSenders && row.sharedMargins.senderMatches(libraryQuery.query))
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
    }

    private static func titleSourceOrAuthorMatches<Row: LibraryQueryRow>(_ row: Row, normalizedQuery: String) -> Bool {
        [row.title, row.sourceTitle, row.author]
            .compactMap { $0 }
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
            .contains { $0.localizedStandardContains(normalizedQuery) }
    }

    /// Why the search listed a row that its title, source and author do not match: who sent the Margins on it, "From Sam
    /// and 2 friends". Nil for a row the search found by title, source or author, with no search, or when senders are
    /// not searched, so the line appears only where the match would otherwise be a mystery (#4649).
    public static func matchedSenderLine<Row: LibraryQueryRow>(
        _ row: Row, query libraryQuery: LibraryQuery, includingSenders: Bool = true, spoken: Bool = false
    ) -> String? {
        let normalizedQuery = libraryQuery.query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard includingSenders, !normalizedQuery.isEmpty,
              !titleSourceOrAuthorMatches(row, normalizedQuery: normalizedQuery) else { return nil }
        return row.sharedMargins.senderMatchLine(libraryQuery.query, spoken: spoken)
    }

    /// How many finished items the listening filter hides, for the "N finished hidden · Show" line at the end of the
    /// Library (#4698). Zero when nothing is hidden. The hidden items are the finished ones that pass every other filter
    /// and the search, and that the listening filter leaves out.
    public static func completedHiddenCount<Row: LibraryQueryRow>(_ libraryItems: [Row], query libraryQuery: LibraryQuery) -> Int {
        guard libraryHidesCompleted(query: libraryQuery) else { return 0 }
        var finished = libraryQuery
        finished.listeningState = .completed
        // A finished item passes the other filters the same under either listening state, so what the listening state
        // hides is decided by its own rule: Unfinished lists a finished item only while a friend's Margins on it are new
        // (#4103); Unplayed and In Progress never list one.
        return filteredLibraryItems(libraryItems, query: finished, includingSenders: true)
            .filter { libraryQuery.listeningState != .unfinished || !$0.staysInUnfinished }
            .count
    }

    /// - Parameter includingSenders: whether a search also finds items through who sent the Margins on them (#3794).
    ///   The Library's search does; a list that says "title, source, or author" (the collection checklist) doesn't.
    public static func visibleLibraryItems<Row: LibraryQueryRow>(
        _ libraryItems: [Row], query libraryQuery: LibraryQuery, includingSenders: Bool = true
    ) -> [Row] {
        let filtered = filteredLibraryItems(libraryItems, query: libraryQuery, includingSenders: includingSenders)
        return filtered.sorted { areInOrder($0, $1, sort: libraryQuery.sort) }
    }

    /// The Library's order for two rows under `sort`, ties broken by id. One function, so a Library folder's row and a
    /// collection's row (#3769) are placed among items by exactly the rules items follow.
    static func areInOrder<Row: LibraryQueryRow>(_ lhs: Row, _ rhs: Row, sort: LibrarySort) -> Bool {
        let ordered: ComparisonResult
        switch sort {
        case .recentlyAdded:
            let (left, right) = (lhs.recentlyAddedDate, rhs.recentlyAddedDate)
            if left != nil, right != nil {
                ordered = compareDates(left, right)
            } else if lhs.storageRecencyRank != rhs.storageRecencyRank {
                ordered = lhs.storageRecencyRank < rhs.storageRecencyRank ? .orderedAscending : .orderedDescending
            } else {
                ordered = compareDates(left, right)
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

    /// Whether the "N finished hidden" footer reads "Include in search" (a search is typed) or "Show" (none is). A search
    /// of only spaces finds nothing by itself, so it counts as no search, the same as the filtering above (#5006).
    public static func revealsFinishedWithinSearch(query libraryQuery: LibraryQuery) -> Bool {
        !libraryQuery.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The query after the footer's tap. With a search typed, Listening goes to Everything so the finished matches join
    /// the unfinished ones and the search stays; with none, it goes to Completed, which is what "Show" has always opened.
    public static func queryRevealingFinished(_ libraryQuery: LibraryQuery) -> LibraryQuery {
        var revealed = libraryQuery
        revealed.listeningState = revealsFinishedWithinSearch(query: libraryQuery) ? .all : .completed
        return revealed
    }

    /// The menu words of each filter that narrows the list, in the summary line's order: content type,
    /// listening, offline, shared Margins. A filter set to `.all` is skipped; search and sort never count.
    public static func libraryFilterSelections(query libraryQuery: LibraryQuery) -> [String] {
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
        return selections
    }

    public static func libraryFilterDescription(query libraryQuery: LibraryQuery) -> String {
        let selections = libraryFilterSelections(query: libraryQuery)
        return selections.isEmpty ? "Everything" : selections.joined(separator: " · ")
    }

    /// What the Library's Filter chip shows (#4762). It comes from the query alone, never from the rows,
    /// so it is right on the first draw. It is filled whenever a filter narrows the list, the everyday
    /// Unfinished view included; that differs from the summary line, which shows only when the filters
    /// differ from the everyday view.
    public static func libraryFilterChip(query libraryQuery: LibraryQuery) -> LibraryFilterChipState {
        let selections = libraryFilterSelections(query: libraryQuery)
        switch selections.count {
        case 0:
            return LibraryFilterChipState(isNarrowing: false, title: "Filter", accessibilityValue: "Everything")
        case 1:
            return LibraryFilterChipState(isNarrowing: true, title: selections[0], accessibilityValue: selections[0])
        default:
            let count = selections.count
            return LibraryFilterChipState(
                isNarrowing: true,
                title: "\(count) Filters",
                accessibilityValue: "\(count) filters: " + selections.joined(separator: ", ")
            )
        }
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

    /// Whether the row is a PDF by the Library's "PDF" filter rule (#4338).
    public static func isPDF<Row: LibraryQueryRow>(_ row: Row) -> Bool {
        libraryContentType(for: row) == .pdf
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

/// The Library Filter chip's look and words, from `LibraryQueryEngine.libraryFilterChip(query:)` (#4762).
public struct LibraryFilterChipState: Equatable, Sendable {
    /// True when any of content type, listening, offline or shared Margins is not `.all`.
    public let isNarrowing: Bool
    /// `Filter`, the one filter's menu words, or `N Filters`.
    public let title: String
    /// What VoiceOver reads after the label `Filter Library`.
    public let accessibilityValue: String

    public init(isNarrowing: Bool, title: String, accessibilityValue: String) {
        self.isNarrowing = isNarrowing
        self.title = title
        self.accessibilityValue = accessibilityValue
    }
}
