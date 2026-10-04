import Foundation

/// Why a pick is on Today's picks, in one line. Exactly one per pick. Reasons from ranking
/// signals ("You finished the last 6") come with #484's scores in a later slice; until then a
/// pick says how new it is, or that its show is pinned.
public enum FollowingPickReason: Equatable, Sendable {
    case pinned
    case justFollowed
    case newToday
    case newThisWeek
    case youFollowThis

    public var text: String {
        switch self {
        case .pinned: "Pinned"
        case .justFollowed: "You just followed this"
        case .newToday: "New today"
        case .newThisWeek: "New this week"
        case .youFollowThis: "You follow this"
        }
    }
}

/// One card on Today's picks.
public struct FollowingPick: Equatable, Sendable, Identifiable {
    public var entry: FeedEntry
    public var showTitle: String?
    public var reason: FollowingPickReason

    public var id: String { entry.id }
    public var subscriptionID: String { entry.subscriptionId }

    public init(entry: FeedEntry, showTitle: String?, reason: FollowingPickReason) {
        self.entry = entry
        self.showTitle = showTitle
        self.reason = reason
    }
}

/// One "Also new" row: a show's new items that aren't picks, folded into a count.
public struct FollowingAlsoNewRow: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// New items waiting on the show's page.
        case new
        /// A show set to "Add every new item": its new items went to the Library instead.
        case addedToLibrary
    }

    public var subscriptionID: String
    public var showTitle: String?
    public var count: Int
    public var kind: Kind

    public var id: String { subscriptionID }

    public var text: String {
        switch kind {
        case .new: "\(count) new"
        case .addedToLibrary: "\(count) added to Library"
        }
    }

    public init(subscriptionID: String, showTitle: String?, count: Int, kind: Kind) {
        self.subscriptionID = subscriptionID
        self.showTitle = showTitle
        self.count = count
        self.kind = kind
    }
}

/// The one "From your folder" row. Quick Folder files are never ranked or picked.
public struct FollowingFolderRow: Equatable, Sendable {
    public var newFileCount: Int

    public var text: String {
        "From your folder · \(newFileCount) new \(newFileCount == 1 ? "file" : "files")"
    }

    public init(newFileCount: Int) {
        self.newFileCount = newFileCount
    }
}

/// Following's length filter. An entry whose length is unknown shows only under `any`.
public enum FollowingLengthFilter: String, Equatable, Sendable, CaseIterable {
    case any
    case under20
    case twentyToSixty
    case overAnHour

    public func includes(minutes: Double?) -> Bool {
        if self == .any { return true }
        guard let minutes else { return false }
        switch self {
        case .any: return true
        case .under20: return minutes < 20
        case .twentyToSixty: return minutes >= 20 && minutes <= 60
        case .overAnHour: return minutes > 60
        }
    }

    /// The entry's listening length: the episode's duration, else the article's words at
    /// `wordsPerMinute`. Nil when neither is known.
    public static func minutes(of entry: FeedEntry, wordsPerMinute: Double) -> Double? {
        if let ms = entry.audioDurationMs, ms > 0 { return Double(ms) / 60_000 }
        if let words = entry.bodyWordCount, words > 0, wordsPerMinute > 0 { return Double(words) / wordsPerMinute }
        return nil
    }
}

/// Today's picks (D3, #774): Following as an edition with an end, not an endless inbox.
///
/// Up to eight picks, best first, at most one per show (two for a pinned show), each with one
/// reason. Every other new item folds into one "Also new" row per show, and Quick Folder files
/// into one folder row. A pure function of its inputs, so the rules are host-testable; the
/// screen comes in a later slice.
///
/// Rules, in order:
/// 1. Pinned shows first, newest episode each.
/// 2. Then by score when there is one, otherwise newest first.
/// 3. At most one item per show (two for a pinned show).
/// 4. "Less of this show" shows give picks only if fewer than eight others qualify.
/// 5. Entries older than 30 days never become picks (undated ones neither: their age is unknown).
///    Nor does a show's back catalogue at follow time, except its newest episode.
/// 6. Stop at eight.
///
/// **Stable while you look.** Built with the previous edition, it keeps that edition's picks in
/// their order. Entries the previous edition never saw come back as `pendingArrivals`
/// ("1 new pick · Show"), and join only when the screen builds afresh (`previous: nil`). A pick
/// played or kept since stays where it is; one dismissed, passed for today, or whose show was
/// muted, unfollowed or set to "Add every new item" leaves without another moving up. Changing
/// the length filter is a fresh build: pass `previous: nil`.
public struct FollowingEdition: Equatable, Sendable {
    public static let maxPicks = 8
    public static let pickWindowDays = 30
    /// Words per minute for an article's length when the screen doesn't pass the speech rate.
    public static let defaultWordsPerMinute: Double = 170

    public var builtAt: Date
    public var picks: [FollowingPick]
    public var alsoNew: [FollowingAlsoNewRow]
    /// Nil when there are no new Quick Folder files.
    public var folderRow: FollowingFolderRow?
    /// New picks that arrived after this edition was first built, best first.
    public var pendingArrivals: [FollowingPick]
    /// Every entry id the first build of this edition saw. A later entry is an arrival.
    public var seenEntryIDs: Set<String>

    public init(
        builtAt: Date,
        picks: [FollowingPick],
        alsoNew: [FollowingAlsoNewRow],
        folderRow: FollowingFolderRow?,
        pendingArrivals: [FollowingPick],
        seenEntryIDs: Set<String>
    ) {
        self.builtAt = builtAt
        self.picks = picks
        self.alsoNew = alsoNew
        self.folderRow = folderRow
        self.pendingArrivals = pendingArrivals
        self.seenEntryIDs = seenEntryIDs
    }

    /// Builds the edition.
    /// - Parameters:
    ///   - entries: the feed entries; only `unseen` and `seen` ones count as new, plus `imported`
    ///     ones for the "added to Library" count of "Add every new item" shows.
    ///   - subscriptions: followed shows; muted ones and entries of shows no longer followed are left out.
    ///   - pinnedSourceIDs, lessOfSourceIDs: #484's Pin and "Less of this show", by the show's
    ///     `SourceIdentity` id.
    ///   - scores: #484's score per entry id, higher first. Empty means newest first.
    ///   - notToday: entry ids passed for today. They stay new on the show page but aren't picks.
    ///   - inLibrary: entry ids already in the Library by another route (de-duplicated by the caller).
    ///   - quickFolderNewFileCount: new Quick Folder files, shown as one row.
    ///   - previous: the edition on screen, to rebuild without reordering it. Nil builds afresh.
    public static func build(
        entries: [FeedEntry],
        subscriptions: [FeedSubscription],
        pinnedSourceIDs: Set<String> = [],
        lessOfSourceIDs: Set<String> = [],
        scores: [String: Double] = [:],
        notToday: Set<String> = [],
        inLibrary: Set<String> = [],
        lengthFilter: FollowingLengthFilter = .any,
        wordsPerMinute: Double = defaultWordsPerMinute,
        quickFolderNewFileCount: Int = 0,
        now: Date,
        previous: FollowingEdition? = nil
    ) -> FollowingEdition {
        let shows = Dictionary(subscriptions.filter { $0.state == .active }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pickCutoff = now.addingTimeInterval(-Double(pickWindowDays) * 86_400)
        let weekCutoff = now.addingTimeInterval(-7 * 86_400)

        func isWaiting(_ entry: FeedEntry) -> Bool {
            (entry.state == .unseen || entry.state == .seen) && !inLibrary.contains(entry.id)
        }
        func addsEveryItem(_ show: FeedSubscription) -> Bool { show.newItemPolicy == .addEveryNewItem }
        // The back catalogue at follow time isn't new: it waits on the show's page under "Earlier".
        // Only a show's newest episode may still be a pick, so a just-followed show gives one.
        var newestByShow: [String: FeedEntry] = [:]
        for entry in entries {
            guard let date = entry.publishedAt else { continue }
            if let newest = newestByShow[entry.subscriptionId]?.publishedAt, newest >= date { continue }
            newestByShow[entry.subscriptionId] = entry
        }
        func isBackCatalogue(_ entry: FeedEntry, of show: FeedSubscription) -> Bool {
            guard let date = entry.publishedAt else { return false }
            return date < show.createdAt
        }
        // New on the show's page: waiting, inside the pick window (or undated), not back catalogue.
        func isNew(_ entry: FeedEntry, of show: FeedSubscription) -> Bool {
            guard isWaiting(entry), !isBackCatalogue(entry, of: show) else { return false }
            guard let date = entry.publishedAt else { return true }
            return date >= pickCutoff
        }

        // Candidates: waiting entries of followed "Let me pick" shows, dated inside the window,
        // not passed today, the length the filter asks for.
        var seenIDs = Set<String>()
        var candidates: [(entry: FeedEntry, show: FeedSubscription)] = []
        for entry in entries where seenIDs.insert(entry.id).inserted {
            guard let show = shows[entry.subscriptionId], !addsEveryItem(show), isWaiting(entry),
                  let date = entry.publishedAt, date >= pickCutoff,
                  !isBackCatalogue(entry, of: show) || newestByShow[show.id]?.id == entry.id,
                  !notToday.contains(entry.id),
                  lengthFilter.includes(minutes: FollowingLengthFilter.minutes(of: entry, wordsPerMinute: wordsPerMinute))
            else { continue }
            candidates.append((entry, show))
        }

        func newestFirst(_ a: FeedEntry, _ b: FeedEntry) -> Bool {
            let (da, db) = (a.publishedAt ?? .distantPast, b.publishedAt ?? .distantPast)
            return da != db ? da > db : a.id < b.id
        }
        func better(_ a: FeedEntry, _ b: FeedEntry) -> Bool {
            if !scores.isEmpty {
                let (sa, sb) = (scores[a.id] ?? -.infinity, scores[b.id] ?? -.infinity)
                if sa != sb { return sa > sb }
            }
            return newestFirst(a, b)
        }
        func reason(for entry: FeedEntry, show: FeedSubscription) -> FollowingPickReason {
            if pinnedSourceIDs.contains(show.source.id) { return .pinned }
            if show.createdAt >= now.addingTimeInterval(-86_400) { return .justFollowed }
            let date = entry.publishedAt ?? .distantPast
            if date >= now.addingTimeInterval(-86_400) { return .newToday }
            if date >= weekCutoff { return .newThisWeek }
            return .youFollowThis
        }

        var picks: [FollowingPick] = []
        var perShow: [String: Int] = [:]
        func take(_ candidate: (entry: FeedEntry, show: FeedSubscription), cap: Int) {
            guard picks.count < maxPicks, (perShow[candidate.show.id] ?? 0) < cap,
                  !picks.contains(where: { $0.id == candidate.entry.id }) else { return }
            perShow[candidate.show.id, default: 0] += 1
            picks.append(FollowingPick(entry: candidate.entry, showTitle: candidate.show.source.title, reason: reason(for: candidate.entry, show: candidate.show)))
        }

        let pinned = candidates.filter { pinnedSourceIDs.contains($0.show.source.id) }
        let less = candidates.filter { lessOfSourceIDs.contains($0.show.source.id) && !pinnedSourceIDs.contains($0.show.source.id) }
        let lessIDs = Set(less.map(\.entry.id))
        let others = candidates.filter { !lessIDs.contains($0.entry.id) }
        // 1. Each pinned show's newest episode, newest show first.
        for candidate in pinned.sorted(by: { newestFirst($0.entry, $1.entry) }) { take(candidate, cap: 1) }
        // 2-3. Then everything else that isn't "less of", best first, one per show (two when pinned).
        for candidate in others.sorted(by: { better($0.entry, $1.entry) }) {
            take(candidate, cap: pinnedSourceIDs.contains(candidate.show.source.id) ? 2 : 1)
        }
        // 4. "Less of this show" only fills what's left.
        for candidate in less.sorted(by: { better($0.entry, $1.entry) }) { take(candidate, cap: 1) }

        // Stable rebuild: keep the previous picks in place; fresh picks it never saw are arrivals.
        var seenEntryIDs = Set(entries.map(\.id))
        var pendingArrivals: [FollowingPick] = []
        if let previous {
            let current = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let kept: [FollowingPick] = previous.picks.compactMap { pick in
                guard let entry = current[pick.id], entry.state != .dismissed, !notToday.contains(pick.id),
                      let show = shows[entry.subscriptionId], !addsEveryItem(show) else { return nil }
                var updated = pick
                updated.entry = entry
                return updated
            }
            let keptIDs = Set(kept.map(\.id))
            pendingArrivals = picks.filter { !previous.seenEntryIDs.contains($0.id) && !keptIDs.contains($0.id) }
            picks = kept
            seenEntryIDs = previous.seenEntryIDs
        }

        // Also new: per show, the new items that aren't on screen as picks or arrivals.
        let shown = Set(picks.map(\.id)).union(pendingArrivals.map(\.id))
        var newCounts: [String: Int] = [:]
        var addedCounts: [String: Int] = [:]
        var latest: [String: Date] = [:]
        var counted = Set<String>()
        for entry in entries where counted.insert(entry.id).inserted {
            guard let show = shows[entry.subscriptionId] else { continue }
            if addsEveryItem(show) {
                // Added this week by "Add every new item"; its back catalogue never counts.
                guard entry.state == .imported, let date = entry.publishedAt, date >= weekCutoff else { continue }
                addedCounts[show.id, default: 0] += 1
            } else {
                guard isNew(entry, of: show), !shown.contains(entry.id) else { continue }
                newCounts[show.id, default: 0] += 1
            }
            latest[show.id] = max(latest[show.id] ?? .distantPast, entry.publishedAt ?? .distantPast)
        }
        var alsoNew: [FollowingAlsoNewRow] = []
        for (id, count) in newCounts { alsoNew.append(FollowingAlsoNewRow(subscriptionID: id, showTitle: shows[id]?.source.title, count: count, kind: .new)) }
        for (id, count) in addedCounts { alsoNew.append(FollowingAlsoNewRow(subscriptionID: id, showTitle: shows[id]?.source.title, count: count, kind: .addedToLibrary)) }
        alsoNew.sort { a, b in
            let (da, db) = (latest[a.subscriptionID] ?? .distantPast, latest[b.subscriptionID] ?? .distantPast)
            return da != db ? da > db : a.subscriptionID < b.subscriptionID
        }

        return FollowingEdition(
            builtAt: previous?.builtAt ?? now,
            picks: picks,
            alsoNew: alsoNew,
            folderRow: quickFolderNewFileCount > 0 ? FollowingFolderRow(newFileCount: quickFolderNewFileCount) : nil,
            pendingArrivals: pendingArrivals,
            seenEntryIDs: seenEntryIDs
        )
    }
}
