import Foundation

/// #1865: one row per followed show on the Following tab, and the episode list on a show's own screen.
///
/// The row model is pure: the app passes the subscriptions, every stored entry of them (muted shows
/// and imported episodes included) and the per-show "last looked" times, and gets back the rows in
/// the order the tab shows them.
public struct FollowingShowRow: Equatable, Identifiable, Sendable {
    /// The subscription's id.
    public var id: String
    public var title: String
    /// Episodes that arrived since the listener last opened the show. Always 0 for a Quiet show.
    public var newCount: Int
    public var newestEpisodeTitle: String?
    public var newestEpisodeDate: Date?
    /// "Oct 16", nil when the newest episode has no date.
    public var dateLabel: String?
    /// The entry the row's play button plays: the show's newest episode not yet played or dismissed.
    public var playEntryID: String?
    public var isQuiet: Bool
    public var accessibilityLabel: String

    /// "3 new", nil when nothing is new (the row then shows no badge).
    public var newLabel: String? { newCount > 0 ? "\(newCount) new" : nil }
}

public struct FollowingShowList: Equatable, Sendable {
    /// Shows that are not Quiet, the one with the newest episode first.
    public var rows: [FollowingShowRow]
    /// Quiet shows, ordered the same way; the tab keeps them in a collapsed group at the bottom.
    public var quiet: [FollowingShowRow]

    public var quietTitle: String { "Quiet (\(quiet.count))" }

    public init(rows: [FollowingShowRow] = [], quiet: [FollowingShowRow] = []) {
        self.rows = rows
        self.quiet = quiet
    }
}

/// One episode on a show's screen.
public struct FollowingShowEpisode: Equatable, Identifiable, Sendable {
    public var entry: FeedEntry
    /// Arrived since the listener last looked (so the screen can mark it).
    public var isNew: Bool
    /// Played or added already, so it is in the Library.
    public var isInLibrary: Bool
    public var id: String { entry.id }
}

public enum FollowingShowRows {
    /// Builds the tab's rows.
    /// - Parameters:
    ///   - entries: every stored entry; entries of shows that are no longer followed are ignored.
    ///   - lookedAt: when the listener last opened each show, by subscription id. A show never opened
    ///     counts every waiting episode after the follow baseline as new.
    public static func build(
        subscriptions: [FeedSubscription],
        entries: [FeedEntry],
        lookedAt: [String: Date] = [:],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> FollowingShowList {
        let bySubscription = Dictionary(grouping: entries, by: \.subscriptionId)
        var built: [(row: FollowingShowRow, sortDate: Date, createdAt: Date)] = []
        for subscription in subscriptions {
            let shown = (bySubscription[subscription.id] ?? []).filter { $0.state != .dismissed }
            let newest = shown.min(by: newestFirst)
            let newestDate = newest.flatMap(date(of:))
            let isQuiet = subscription.state == .muted
            let count = isQuiet ? 0 : newCount(of: subscription, in: shown, lookedAt: lookedAt[subscription.id])
            let title = displayTitle(of: subscription)
            let dateLabel = newestDate.map {
                FollowingEntryRow.dateText($0, now: now, calendar: calendar, locale: locale, spoken: false)
            }
            let spokenDate = newestDate.map {
                FollowingEntryRow.dateText($0, now: now, calendar: calendar, locale: locale, spoken: true)
            }
            let newestTitle = newest.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            let label = [
                title,
                count > 0 ? "\(count) new" : nil,
                newestTitle.map { "Newest: \($0)" },
                spokenDate.map { "Published \($0)" },
                isQuiet ? "Quiet" : nil,
            ].compactMap { $0 }.map { $0.hasSuffix(".") ? $0 : "\($0)." }.joined(separator: " ")
            let row = FollowingShowRow(
                id: subscription.id, title: title, newCount: count,
                newestEpisodeTitle: newestTitle, newestEpisodeDate: newestDate, dateLabel: dateLabel,
                playEntryID: shown.filter(isUnplayed).min(by: newestFirst)?.id,
                isQuiet: isQuiet, accessibilityLabel: label
            )
            built.append((row, newestDate ?? .distantPast, subscription.createdAt))
        }
        // Newest episode first; a show with no episode yet sorts by when it was followed, then by name.
        built.sort { a, b in
            if a.sortDate != b.sortDate { return a.sortDate > b.sortDate }
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            let order = a.row.title.localizedCaseInsensitiveCompare(b.row.title)
            return order == .orderedSame ? a.row.id < b.row.id : order == .orderedAscending
        }
        return FollowingShowList(
            rows: built.map(\.row).filter { !$0.isQuiet },
            quiet: built.map(\.row).filter(\.isQuiet)
        )
    }

    /// A show's episodes, newest first, for its own screen. Dismissed episodes are left out.
    public static func episodes(
        of subscription: FeedSubscription, in entries: [FeedEntry], lookedAt: Date? = nil
    ) -> [FollowingShowEpisode] {
        entries
            .filter { $0.subscriptionId == subscription.id && $0.state != .dismissed }
            .sorted(by: newestFirst)
            .map { entry in
                FollowingShowEpisode(
                    entry: entry,
                    isNew: isNew(entry, of: subscription, lookedAt: lookedAt),
                    isInLibrary: entry.state == .imported
                )
            }
    }

    // MARK: - Rules

    /// Waiting (not played, not dismissed), not back catalogue, and arrived after the listener last looked.
    static func isNew(_ entry: FeedEntry, of subscription: FeedSubscription, lookedAt: Date?) -> Bool {
        guard isUnplayed(entry), !FollowBaseline.isBackCatalogue(entry, of: subscription) else { return false }
        guard let lookedAt else { return true }
        // Arrival is when this app first saw it; entries saved before that was recorded fall back to the publish date.
        guard let arrived = entry.firstSeenAt ?? entry.publishedAt else { return true }
        return arrived > lookedAt
    }

    static func newCount(of subscription: FeedSubscription, in entries: [FeedEntry], lookedAt: Date?) -> Int {
        entries.filter { isNew($0, of: subscription, lookedAt: lookedAt) }.count
    }

    static func isUnplayed(_ entry: FeedEntry) -> Bool { entry.state == .unseen || entry.state == .seen }

    static func date(of entry: FeedEntry) -> Date? { entry.publishedAt ?? entry.firstSeenAt }

    static func newestFirst(_ a: FeedEntry, _ b: FeedEntry) -> Bool {
        let (da, db) = (date(of: a) ?? .distantPast, date(of: b) ?? .distantPast)
        return da != db ? da > db : a.id < b.id
    }

    static func displayTitle(of subscription: FeedSubscription) -> String {
        let title = subscription.source.title?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        return title.isEmpty ? subscription.source.host : title
    }
}

/// When the listener last opened each show (#1865), which "N new" counts from. A small JSON side file
/// next to Following's other per-listener preferences, so the database is untouched and an older
/// build opens it as before (it never reads this file). Losing the file only makes every waiting
/// episode count as new again.
public struct FollowingLookedMarkers: Codable, Equatable, Sendable {
    public static let fileName = "following-looked.json"

    public private(set) var lookedAt: [String: Date]

    public init(lookedAt: [String: Date] = [:]) { self.lookedAt = lookedAt }

    public mutating func markLooked(_ subscriptionID: String, at date: Date = Date()) {
        lookedAt[subscriptionID] = date
    }

    /// Gives every show in `subscriptionIDs` that has no marker the time `date`, so nothing counts as new
    /// until a later refresh brings an episode. Used on the first run and after a lost or corrupt file.
    public mutating func seed(_ subscriptionIDs: some Sequence<String>, at date: Date = Date()) {
        for id in subscriptionIDs where lookedAt[id] == nil { lookedAt[id] = date }
    }

    public mutating func remove(_ subscriptionID: String) { lookedAt[subscriptionID] = nil }

    /// Drops markers of shows no longer followed. Returns whether anything changed.
    @discardableResult
    public mutating func prune(keeping subscriptionIDs: Set<String>) -> Bool {
        let kept = lookedAt.filter { subscriptionIDs.contains($0.key) }
        guard kept.count != lookedAt.count else { return false }
        lookedAt = kept
        return true
    }

    /// The saved markers, or nil when the file is missing or unreadable (the caller then seeds).
    /// Dates are stored as full-precision seconds, so an entry first seen a moment before a show was
    /// opened never compares as newer after a round trip.
    public static func loadIfPresent(from url: URL) -> FollowingLookedMarkers? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FollowingLookedMarkers.self, from: data)
    }

    public static func load(from url: URL) -> FollowingLookedMarkers {
        loadIfPresent(from: url) ?? FollowingLookedMarkers()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
