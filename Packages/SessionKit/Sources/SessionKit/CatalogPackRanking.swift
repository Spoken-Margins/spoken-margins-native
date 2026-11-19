import Foundation

/// What a listener has told the app "Not for me" about, as a value the drawer can read synchronously (#4285).
/// A hidden source is matched by its catalog entry id or by its normalized feed key, so a hide still matches an
/// entry whose id changed in a later catalog. Marks are episodes marked Not for me, counted per feed key.
public struct NotForMeSnapshot: Equatable, Sendable {
    public var hiddenEntryIds: Set<String>
    public var hiddenFeedKeys: Set<String>
    public var marksByFeedKey: [String: Int]

    public static let empty = NotForMeSnapshot()

    public init(hiddenEntryIds: Set<String> = [], hiddenFeedKeys: Set<String> = [], marksByFeedKey: [String: Int] = [:]) {
        self.hiddenEntryIds = hiddenEntryIds
        self.hiddenFeedKeys = hiddenFeedKeys
        self.marksByFeedKey = marksByFeedKey
    }

    public func isHidden(_ entry: SourceCatalogEntry) -> Bool {
        if hiddenEntryIds.contains(entry.id) { return true }
        guard let key = SourceCatalog.feedKey(entry.feedURL) else { return false }
        return hiddenFeedKeys.contains(key)
    }

    public func marks(for entry: SourceCatalogEntry) -> Int {
        guard let key = SourceCatalog.feedKey(entry.feedURL) else { return 0 }
        return max(0, marksByFeedKey[key] ?? 0)
    }
}

/// Which chip the first-run drawer opens on.
public enum CatalogDrawerStartChip: Equatable, Sendable {
    case packs
    case top
}

/// The state of a pack card's one button, first match wins (#4285).
public enum CatalogPackButtonState: Equatable, Sendable {
    /// A follow from this pack is in flight: a spinner and "Following…", disabled.
    case following
    /// Some failed in the last batch: "Retry R".
    case retry(failed: Int)
    /// Every visible source is followed: "Following all N", as static text.
    case followedAll(Int)
    /// k of N are followed: "Follow the other N−k".
    case followRest(remaining: Int)
    /// Nothing followed yet: "Follow all N".
    case followAll(Int)
}

/// Which packs the drawer shows, in what order, and which sources lead each one, from the catalog and what the
/// listener has hidden or marked (#4285). Pure functions of values: nothing here reads a store or a clock.
public enum CatalogPackRanking {
    /// Marks beyond this many on one source add nothing to its weight.
    static let markCap = 3

    // MARK: Sources

    /// The pack's entries the catalog holds, in the order the pack names them. Hidden ones are included: they still
    /// count against the pack.
    public static func members(of pack: SourceCatalogPack, in catalog: SourceCatalog) -> [SourceCatalogEntry] {
        let byId = Dictionary(catalog.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return pack.entryIds.compactMap { byId[$0] }
    }

    /// The pack's sources the listener hasn't hidden, in the one order every surface uses: podcasts first, then
    /// everything else (newsletters); within each group, lighter weight first, and ties in the order the pack names
    /// them (Default taken: the pack's own `entryIds` order, which the catalog builder writes as its editorial order,
    /// not the order of `catalog.entries`). The Pack screen, a card's artwork strip, Follow all and Done's first
    /// listen all use it, so the first listen is a podcast whenever the pack has one.
    public static func visibleSources(
        of pack: SourceCatalogPack,
        in catalog: SourceCatalog,
        notForMe: NotForMeSnapshot
    ) -> [SourceCatalogEntry] {
        let members = members(of: pack, in: catalog)
        let visible = members.enumerated().filter { !notForMe.isHidden($0.element) }
        return visible.sorted { lhs, rhs in
            let lhsGroup = lhs.element.contentKind == .podcast ? 0 : 1
            let rhsGroup = rhs.element.contentKind == .podcast ? 0 : 1
            let lhsWeight = weight(of: lhs.element, among: members, notForMe: notForMe)
            let rhsWeight = weight(of: rhs.element, among: members, notForMe: notForMe)
            return (lhsGroup, lhsWeight, lhs.offset) < (rhsGroup, rhsWeight, rhs.offset)
        }.map(\.element)
    }

    /// `min(3, marks)` on the source, plus, for every other member that is hidden or has marks, that member's
    /// count (1 if hidden, else `min(3, marks)`) times how alike the two are: 2 for the same author, 1 for the same
    /// content kind, 1 for each shared subject.
    public static func weight(of source: SourceCatalogEntry, among members: [SourceCatalogEntry], notForMe: NotForMeSnapshot) -> Int {
        var total = min(markCap, notForMe.marks(for: source))
        for other in members where other.id != source.id {
            let hidden = notForMe.isHidden(other)
            let marks = notForMe.marks(for: other)
            guard hidden || marks > 0 else { continue }
            let count = hidden ? 1 : min(markCap, marks)
            total += count * similarity(source, other)
        }
        return total
    }

    static func similarity(_ lhs: SourceCatalogEntry, _ rhs: SourceCatalogEntry) -> Int {
        var score = 0
        if let left = normalizedAuthor(lhs.author), left == normalizedAuthor(rhs.author) { score += 2 }
        if lhs.contentKind == rhs.contentKind { score += 1 }
        score += Set(lhs.subjects).intersection(rhs.subjects).count
        return score
    }

    private static func normalizedAuthor(_ author: String?) -> String? {
        guard let folded = author?.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil), !folded.isEmpty else { return nil }
        return folded
    }

    // MARK: Packs

    /// Packs with at least one visible source, in catalog order, stable-sorted by how much the listener has pushed
    /// each away: its hidden sources plus the sum of `min(3, marks)` over all its sources, fewest first.
    public static func visiblePacks(in catalog: SourceCatalog, notForMe: NotForMeSnapshot) -> [SourceCatalogPack] {
        let packs = (catalog.packs ?? []).enumerated().compactMap { offset, pack -> (Int, Int, SourceCatalogPack)? in
            let members = members(of: pack, in: catalog)
            guard members.contains(where: { !notForMe.isHidden($0) }) else { return nil }
            let pushedAway = members.reduce(0) { $0 + (notForMe.isHidden($1) ? 1 : 0) + min(markCap, notForMe.marks(for: $1)) }
            return (pushedAway, offset, pack)
        }
        return packs.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    /// Packs is the first chip when the catalog has a visible pack; otherwise the drawer opens on Top.
    public static func startChip(in catalog: SourceCatalog, notForMe: NotForMeSnapshot) -> CatalogDrawerStartChip {
        visiblePacks(in: catalog, notForMe: notForMe).isEmpty ? .top : .packs
    }

    /// A pack card's pace: its visible sources' rates, as of the catalog's `generatedAt`.
    public static func packPace(of pack: SourceCatalogPack, in catalog: SourceCatalog, notForMe: NotForMeSnapshot) -> CatalogPackPace.Measure? {
        CatalogPackPace.packMeasure(visibleSources(of: pack, in: catalog, notForMe: notForMe).map { CatalogPackPace.measure(for: $0, in: catalog) })
    }

    // MARK: Following a pack

    /// What Follow all follows, in order: visible sources not yet followed, in `visibleSources` order.
    public static func followAllOrder(
        of pack: SourceCatalogPack,
        in catalog: SourceCatalog,
        notForMe: NotForMeSnapshot,
        followedEntryIds: Set<String>
    ) -> [SourceCatalogEntry] {
        visibleSources(of: pack, in: catalog, notForMe: notForMe).filter { !followedEntryIds.contains($0.id) }
    }

    /// The card's button, from each visible source's state (see `CatalogDrawerFollowState.merged`). "Followed" means
    /// a live subscription matches the entry however it was followed; a show that sits in two packs counts in both.
    /// States are read per source, so a follow in flight or a failure on a show this pack shares with another pack
    /// or with a single row shows here too: the caller clears a state when its batch is over.
    public static func buttonState(visibleSourceIds: [String], states: [String: CatalogDrawerFollowState]) -> CatalogPackButtonState {
        let total = visibleSourceIds.count
        let own = visibleSourceIds.compactMap { states[$0] }
        if own.contains(.following) { return .following }
        let failed = own.filter { if case .failed = $0 { return true } else { return false } }.count
        if failed > 0 { return .retry(failed: failed) }
        let followed = own.filter { $0 == .followed }.count
        if total > 0, followed == total { return .followedAll(total) }
        if followed > 0 { return .followRest(remaining: total - followed) }
        return .followAll(total)
    }

    // MARK: Card words

    /// The card's footnote: `<pace> · <N shows>, <M newsletters>`. Only parts that exist are shown, and only visible
    /// sources are counted. A source that is neither a podcast nor a newsletter is not named.
    public static func footnote(pace: CatalogPackPace.Measure?, visibleSources: [SourceCatalogEntry]) -> String {
        let shows = visibleSources.filter { $0.contentKind == .podcast }.count
        let newsletters = visibleSources.filter { $0.contentKind == .newsletter }.count
        var parts: [String] = []
        if shows > 0 { parts.append("\(shows) \(shows == 1 ? "show" : "shows")") }
        if newsletters > 0 { parts.append("\(newsletters) \(newsletters == 1 ? "newsletter" : "newsletters")") }
        let pace = CatalogPackPace.packWords(pace)
        return parts.isEmpty ? pace : pace + " · " + parts.joined(separator: ", ")
    }
}
