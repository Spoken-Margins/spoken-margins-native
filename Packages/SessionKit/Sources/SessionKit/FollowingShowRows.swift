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
    /// The entry the row's play button plays (`FollowingUpNext.pick`, the same episode the show's Up next card names): always the episode the row previews (`newestEntryID`), so ▶ plays
    /// what the listener sees. Nil when the show has nothing left to hear (every episode played or dismissed).
    public var playEntryID: String?
    /// When the previewed episode is already in the Library, its item: ▶ resumes it there instead of importing it again.
    public var playItemID: String?
    /// The episode the row previews (`newestEpisodeTitle`): the show's newest one still worth hearing, meaning one
    /// not yet played, or one in the Library that the listener has started but not finished. A finished episode gives
    /// way to the next unread one, and the row sorts by that episode's date. Only when every episode is finished does it
    /// show the newest of them. The swipe's Add (#2929) saves this one, so it is exactly what the listener sees on the
    /// row and finds in the show.
    public var newestEntryID: String?
    /// The previewed episode is in the Library already, so there is nothing for the swipe to add.
    public var isNewestInLibrary: Bool = false
    public var isQuiet: Bool
    public var accessibilityLabel: String
    /// New episodes a pick rule matched (#4046), always 0 for a Quiet show and while no rule is on.
    public var pickCount: Int = 0

    /// What the row's swipe Add saves: the previewed episode, nil when the show has none or it is in the Library already.
    public var addEntryID: String? { isNewestInLibrary ? nil : newestEntryID }

    /// "3 new", nil when nothing is new (the row then shows no badge).
    public var newLabel: String? { newCount > 0 ? "\(newCount) new" : nil }

    /// "1 pick", "2 picks", nil when none.
    public var pickLabel: String? { pickCount > 0 ? "\(pickCount) \(pickCount == 1 ? "pick" : "picks")" : nil }

    /// The row's badge: "3 new", or "3 new · 1 pick" when a pick rule matched some of them (#4046). Nil when nothing is new.
    /// Picks are counted among the new episodes only, so there is never a pick without a new count.
    public var countLabel: String? {
        guard let newLabel else { return nil }
        return pickLabel.map { "\(newLabel) · \($0)" } ?? newLabel
    }
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
    /// A rule skipped it or the listener marked it Show less (#4046): it is not counted as new, and the screen lists it
    /// apart. Always false while no rule is on and nothing is marked.
    public var isSetAside: Bool = false
    /// A pick rule matched it.
    public var isPick: Bool = false
    /// The rule word that skipped it, as its author wrote it, for the Show screen's "Skipped by your rules" group and its
    /// "Skipped: about “word”" line. Nil when no rule skipped it (an episode marked Show less is set aside with no word).
    public var skippedWord: String? = nil
    public var id: String { entry.id }
}

public enum FollowingShowRows {
    /// Builds the tab's rows.
    /// - Parameters:
    ///   - entries: every stored entry; entries of shows that are no longer followed are ignored.
    ///   - lookedAt: when the listener last opened each show, by subscription id. A show never opened
    ///     counts every waiting episode after the follow baseline as new.
    ///   - libraryEpisodes: the Library item behind each imported entry and whether it is finished
    ///     (`FollowingLibraryEpisodes.resolve`). An imported entry with no item here counts as finished: nothing is
    ///     known to resume, so the row moves on to the next unread episode.
    ///   - rules: what the listener's rules and Show less marks set aside, from `FollowingRuleEvaluation` (#4046). An
    ///     episode set aside is removed before the row is built, so the preview, date, sort, count, ▶ and swipe all describe
    ///     the newest episode that is not. Empty (the default) leaves every row as it was.
    public static func build(
        subscriptions: [FeedSubscription],
        entries: [FeedEntry],
        lookedAt: [String: Date] = [:],
        libraryEpisodes: [String: FollowingLibraryEpisode] = [:],
        rules: ListeningRuleEvaluation = ListeningRuleEvaluation(),
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> FollowingShowList {
        let bySubscription = Dictionary(grouping: entries, by: \.subscriptionId)
        var built: [(row: FollowingShowRow, sortDate: Date, createdAt: Date)] = []
        for subscription in subscriptions {
            let outcome = rules.outcome(for: subscription.id)
            let shown = (bySubscription[subscription.id] ?? []).filter {
                $0.state != .dismissed && !outcome.setAside.contains($0.id)
            }
            // The episode worth hearing next: unplayed, or in the Library and not finished. If none is left, the newest of
            // what is there, which only names the show's last word and offers no ▶.
            // One rule decides, here and on the show's Up next card (`FollowingUpNext`).
            let upNext = FollowingUpNext.pick(entries: shown, libraryEpisodes: libraryEpisodes)
            let newest = upNext ?? shown.min(by: newestFirst)
            let newestDate = newest.flatMap(date(of:))
            let isQuiet = subscription.state == .muted
            let count = isQuiet ? 0 : newCount(of: subscription, in: shown, lookedAt: lookedAt[subscription.id])
            let picks = isQuiet ? 0 : shown.filter {
                outcome.picks.contains($0.id) && isNew($0, of: subscription, lookedAt: lookedAt[subscription.id])
            }.count
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
                picks > 0 ? "\(picks) \(picks == 1 ? "pick" : "picks")" : nil,
                newestTitle.map { "\(upNext == nil ? "Newest" : "Up next"): \($0)" },
                newest?.state == .imported ? "In your Library" : nil,
                spokenDate.map { "Published \($0)" },
                isQuiet ? "Quiet" : nil,
            ].compactMap { $0 }.map { $0.hasSuffix(".") ? $0 : "\($0)." }.joined(separator: " ")
            let row = FollowingShowRow(
                id: subscription.id, title: title, newCount: count,
                newestEpisodeTitle: newestTitle, newestEpisodeDate: newestDate, dateLabel: dateLabel,
                playEntryID: upNext?.id,
                playItemID: upNext.flatMap { $0.state == .imported ? libraryEpisodes[$0.id]?.itemID : nil },
                newestEntryID: newest?.id, isNewestInLibrary: newest?.state == .imported,
                isQuiet: isQuiet, accessibilityLabel: label, pickCount: picks
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

    /// A show's episodes, newest first, for its own screen. Dismissed episodes are left out. Episodes the rules set
    /// aside stay in the list, flagged, for the screen's own group; they are never new.
    public static func episodes(
        of subscription: FeedSubscription, in entries: [FeedEntry], lookedAt: Date? = nil,
        rules: ListeningRuleEvaluation = ListeningRuleEvaluation()
    ) -> [FollowingShowEpisode] {
        let outcome = rules.outcome(for: subscription.id)
        return entries
            .filter { $0.subscriptionId == subscription.id && $0.state != .dismissed }
            .sorted(by: newestFirst)
            .map { entry in
                let isSetAside = outcome.setAside.contains(entry.id)
                return FollowingShowEpisode(
                    entry: entry,
                    isNew: !isSetAside && isNew(entry, of: subscription, lookedAt: lookedAt),
                    isInLibrary: entry.state == .imported,
                    isSetAside: isSetAside,
                    isPick: outcome.picks.contains(entry.id),
                    skippedWord: outcome.skippedByWord[entry.id]
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

    /// Still worth previewing and playing: not played yet, or in the Library with an item the listener hasn't finished.
    static func isHearable(_ entry: FeedEntry, libraryEpisodes: [String: FollowingLibraryEpisode]) -> Bool {
        if isUnplayed(entry) { return true }
        return entry.state == .imported && libraryEpisodes[entry.id].map { !$0.isFinished } ?? false
    }

    static func date(of entry: FeedEntry) -> Date? { entry.publishedAt ?? entry.firstSeenAt }

    static func newestFirst(_ a: FeedEntry, _ b: FeedEntry) -> Bool {
        let (da, db) = (date(of: a) ?? .distantPast, date(of: b) ?? .distantPast)
        return da != db ? da > db : a.id < b.id
    }

    public static func displayTitle(of subscription: FeedSubscription) -> String {
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

    /// Folds in markers read from disk: per show, the newer date wins.
    public mutating func merge(_ other: FollowingLookedMarkers) {
        for (id, date) in other.lookedAt where (lookedAt[id] ?? .distantPast) < date { lookedAt[id] = date }
    }

    public mutating func remove(_ subscriptionID: String) { lookedAt[subscriptionID] = nil }

    /// The markers once the first read of a launch has both the file and the store's followed shows. The newer
    /// date wins per show, and markers of shows no longer followed go. Only with no readable file (the first run,
    /// or a lost one) is every followed show stamped `now`, so nothing counts as new until a later refresh brings
    /// an episode. With a file, a show it has no marker for was followed and never opened, and keeps counting
    /// what arrived since: stamping it would zero that count (#2690 audit on c79b872). Everything is judged
    /// against `followed`, the store's list, never the model's in-memory list, which is still empty when
    /// Following opens before the first feed refresh lands: judged against that, the saved file came out empty
    /// and the next launch counted every episode as new (#2690 audits on 7bb846d and 6dc3a18).
    public static func afterFirstLoad(inMemory: FollowingLookedMarkers, saved: FollowingLookedMarkers?,
                                      followed: [String], now: Date = Date()) -> FollowingLookedMarkers {
        var markers = inMemory
        if let saved { markers.merge(saved) } else { markers.seed(followed, at: now) }
        markers.prune(keeping: Set(followed))
        return markers
    }

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
