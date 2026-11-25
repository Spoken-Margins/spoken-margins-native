import Foundation

/// The drawer's chip selection (#4285): Packs, Top, or one subject. It replaces the old `String?` subject, where nil
/// meant Top.
public enum CatalogDrawerChip: Hashable, Sendable {
    case packs
    case top
    case subject(String)

    /// The subject whose list the chip shows: nil for Top. Packs shows packs, not a list, so it has none either.
    public var listSubject: String? {
        if case .subject(let id) = self { return id }
        return nil
    }

    /// The end of the chip's accessibility identifier, `catalog.subject.<suffix>`.
    public var identifierSuffix: String {
        switch self {
        case .packs: return "packs"
        case .top: return "top"
        case .subject(let id): return id
        }
    }

    /// What every opening of the drawer starts on: Packs when the catalog has a visible pack, otherwise Top.
    public static func start(in catalog: SourceCatalog, notForMe: NotForMeSnapshot) -> CatalogDrawerChip {
        CatalogPackRanking.startChip(in: catalog, notForMe: notForMe) == .packs ? .packs : .top
    }
}

/// What a pack's button does when tapped (#4285 §2f): nothing while one of its follows is in flight (a second tap),
/// only the failed sources when the last batch had failures (Retry), otherwise every visible source not yet followed,
/// in `CatalogPackRanking.visibleSources` order.
public enum CatalogPackFollowPlan {
    public static func targets(
        visibleSources: [SourceCatalogEntry],
        states: [String: CatalogDrawerFollowState]
    ) -> [SourceCatalogEntry] {
        if visibleSources.contains(where: { states[$0.id] == .following }) { return [] }
        let failed = visibleSources.filter { if case .failed = states[$0.id] { return true } else { return false } }
        if !failed.isEmpty { return failed }
        return visibleSources.filter { states[$0.id] == nil }
    }
}

/// A followed source is never hidden (#4285 §2f): which feed keys and catalog entry ids the live subscriptions
/// cover, for `NotForMeStore.removeHides`. Entry ids come from `CatalogFollowState.followedEntryIds` (the recorded
/// source ids first, then the feed key), the same matching a hide was recorded with.
public enum NotForMeHideReconcile {
    public static func followed(
        subscriptions: [FeedSubscription],
        catalog: SourceCatalog?,
        recordedSourceIds: [String: String]
    ) -> (feedKeys: Set<String>, entryIds: Set<String>) {
        let keys = Set(subscriptions.compactMap { SourceCatalog.feedKey($0.source.canonicalURL) })
        guard let catalog else {
            // No catalog at hand: the recorded follows still name their entries.
            let subscribed = Set(subscriptions.map(\.source.id))
            return (keys, Set(recordedSourceIds.compactMap { subscribed.contains($0.value) ? $0.key : nil }))
        }
        let ids = CatalogFollowState.followedEntryIds(in: catalog, recordedSourceIds: recordedSourceIds, subscriptions: subscriptions)
        return (keys, ids)
    }

    /// The catalog entry id a hide records for a feed, when the catalog has one: the recorded follow first, then the
    /// first entry with the same feed key.
    public static func catalogEntryId(forFeedURL feedURL: String, sourceId: String?, catalog: SourceCatalog?,
                                      recordedSourceIds: [String: String]) -> String? {
        if let sourceId, let recorded = recordedSourceIds.first(where: { $0.value == sourceId })?.key { return recorded }
        return catalog?.entry(matchingFeedURL: feedURL)?.id
    }
}

/// Done on the first-run opening waits for the picks in tap order until one has landed, then starts the first listen
/// with that pick first (#4285 §2f). The rest follow in tap order, so a pick that landed later still has its place.
public enum FirstListenPickOrder {
    public static func sourceIds(leading: String?, settledInTapOrder: [String]) -> [String] {
        guard let leading else { return settledInTapOrder }
        return [leading] + settledInTapOrder.filter { $0 != leading }
    }
}

/// The words of the Packs chip, the Pack screen, the Not for me screen and Not for me on a show (#4285 §2a–§2d).
public enum CatalogPackWords {
    // MARK: Drawer

    public static let packsChipTitle = "Packs"
    public static let packsHeader = "A few shows and writers worth arguing with, picked by kind of listener. Follow a whole pack, then drop what isn't for you."
    public static let followingNote = "New episodes and posts show up in Following. Nothing downloads until you choose it."

    /// The pack button's title for each state. `.following` reads "Following…"; `.followedAll` is static text.
    public static func buttonTitle(_ state: CatalogPackButtonState) -> String {
        switch state {
        case .following: return "Following…"
        case .retry(let failed): return "Retry \(failed)"
        case .followedAll(let total): return "Following all \(total)"
        case .followRest(let remaining): return "Follow the other \(remaining)"
        case .followAll(let total): return "Follow all \(total)"
        }
    }

    /// Under a Retry button: "2 couldn't be reached. Check your connection."
    public static func retryFootnote(failed: Int) -> String {
        "\(failed) couldn't be reached. Check your connection."
    }

    /// VoiceOver reads a pack's first row as one element.
    public static func cardAccessibilityLabel(title: String, summary: String, footnote: String) -> String {
        "\(title). \(summary). \(footnote)"
    }

    /// The "+K" after the artwork strip, or nil when every source has a thumbnail.
    public static let artworkStripLimit = 6
    public static func artworkOverflow(sourceCount: Int) -> String? {
        sourceCount > artworkStripLimit ? "+\(sourceCount - artworkStripLimit)" : nil
    }

    /// The last row of every chip once something is hidden: "Not for me (3)".
    public static func notForMeRowTitle(hidden: Int) -> String { "Not for me (\(hidden))" }

    // MARK: Pack screen

    public static let packScreenFooter = "Not for me hides a show from every pack on this iPhone and moves similar ones down."
    public static let packEmptyTitle = "Nothing left in this pack"
    public static let packEmptyDescription = "Everything here is marked Not for me. You can show them again from Not for me at the bottom of the list."
    public static let moreActionsLabel = "More actions"
    public static let unfollowTitle = "Unfollow"

    /// The drawer's toast after a Pack-row Unfollow: "Unfollowed Hard Fork."
    public static func unfollowedToast(title: String) -> String { "Unfollowed \(title)." }

    /// The toast after a Pack-row Not for me, and the banner after Not for me on a show: "Hard Fork won't be suggested again."
    public static func hiddenMessage(title: String) -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "It won't be suggested again." : "\(name) won't be suggested again."
    }

    /// How long a drawer toast stays before the summary comes back.
    public static let toastSeconds: Double = 6

    // MARK: Not for me screen

    public static let notForMeScreenTitle = "Not for me"
    public static let showAgainTitle = "Show again"
    public static let notForMeScreenFooter = "These aren't suggested again on this iPhone. Searching by name still finds them."

    /// "Hidden Nov 20", from the date the hide was made.
    public static func hiddenOn(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        return "Hidden \(date.formatted(style))"
    }

    // MARK: Not for me on a show

    public static let showNotForMeIdentifier = "show.notForMe"
    public static let showNotForMeHint = "Unfollows this show and stops suggesting it on this iPhone. Everything already in your Library is kept. You can undo right after."

    /// VoiceOver's Undo on the show banner: "Undo Not for me, Hard Fork".
    public static func showUndoAccessibilityLabel(showTitle: String) -> String {
        FollowingDismissMessages.notForMeUndoAccessibilityLabel(title: showTitle)
    }
}
