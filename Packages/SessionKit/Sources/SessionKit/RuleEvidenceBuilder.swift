import Foundation

/// What the learner knows about one episode of a followed show (#4046). Built on the device from the listener's own items,
/// sessions, Margins and Show less marks. Carries titles, flags and dates only: no Margin text and no feed link beyond the
/// show's key, and nothing here leaves the phone.
public struct EpisodeEvidence: Equatable, Sendable, Identifiable {
    /// The entry id when there is one, else the item id, else the mark's id.
    public let id: String
    /// `FeedURLKey.make` of the show's feed link.
    public var feedKey: String
    public var title: String
    public var publishedAt: Date?
    /// When the newest signal on this episode happened: the mark, the finish, the last listening or the add. The learner's
    /// 90-day window is over this date.
    public var at: Date
    /// The listener marked it Show less.
    public var showLess: Bool
    /// Finished, and the listener left no Margin on it.
    public var finishedNoMargin: Bool
    /// Started, not finished, and not played for 7 days, with no Margin.
    public var stoppedEarly: Bool
    /// In the Library for 14 days and never played.
    public var addedNeverPlayed: Bool
    /// The listener left a Margin on it, or shared one from it. A positive episode never counts toward a rule.
    public var positive: Bool

    public init(
        id: String, feedKey: String, title: String, publishedAt: Date? = nil, at: Date, showLess: Bool = false,
        finishedNoMargin: Bool = false, stoppedEarly: Bool = false, addedNeverPlayed: Bool = false, positive: Bool = false
    ) {
        self.id = id
        self.feedKey = feedKey
        self.title = title
        self.publishedAt = publishedAt
        self.at = at
        self.showLess = showLess
        self.finishedNoMargin = finishedNoMargin
        self.stoppedEarly = stoppedEarly
        self.addedNeverPlayed = addedNeverPlayed
        self.positive = positive
    }

    /// How much this episode argues for a rule. A positive episode argues for nothing.
    public var weight: Int {
        guard !positive else { return 0 }
        return (showLess ? RuleEvidenceBuilder.showLessWeight : 0)
            + (finishedNoMargin ? RuleEvidenceBuilder.quietWeight : 0)
            + (stoppedEarly ? RuleEvidenceBuilder.quietWeight : 0)
            + (addedNeverPlayed ? RuleEvidenceBuilder.quietWeight : 0)
    }
}

/// A Library item the caller has matched to a followed show (#4046), with the episode's own title and date from the feed
/// entry when one matched. The caller does the matching (`ListeningSignalContext.context(for:subscriptions:entries:)`), so this
/// stays a pure function of what it is given.
public struct RuleEvidenceEpisode: Sendable {
    public let item: Item
    /// `FeedURLKey.make` of the followed show's feed link.
    public let feedKey: String
    /// The feed entry the item was imported from, when one matched. A Show less mark made from the Show screen names the entry.
    public let entryId: String?
    /// The feed entry's title, else the item's.
    public let title: String
    public let publishedAt: Date?

    public init(item: Item, feedKey: String, entryId: String? = nil, title: String? = nil, publishedAt: Date? = nil) {
        self.item = item
        self.feedKey = feedKey
        self.entryId = entryId
        self.title = title ?? item.title
        self.publishedAt = publishedAt
    }
}

/// Turns what the listener did into per-episode evidence for the rule learner (#4046). Pure: the clock is an input.
///
/// Weights and thresholds (kept here and in `RuleSuggester`, in one place each):
/// - a Show less mark: 3
/// - finished with none of the listener's own Margins: 1
/// - started, not finished, and not played for 7 days: 1
/// - in the Library 14 days and never played: 1
/// - the listener's own Margin on the episode, or a share of one, makes the episode positive.
public enum RuleEvidenceBuilder {
    public static let showLessWeight = 3
    public static let quietWeight = 1
    public static let stoppedEarlyDays = 7
    public static let neverPlayedDays = 14

    /// - Parameters:
    ///   - episodes: the Library items that came from a followed show.
    ///   - sessions: the listener's sessions (any items; the builder reads those of `episodes`).
    ///   - margins: the listener's own Margins. A friend's imported Margins are not among them, so they don't make an episode
    ///     positive.
    ///   - marks: Show less marks. One that names no episode in `episodes` becomes evidence of its own, because an episode
    ///     marked from the Show screen was never added to the Library.
    /// - Returns: one entry per episode with any signal, newest signal first. An episode with a Margin is included even with no
    ///   other signal, so the learner can see that it blocks a word.
    public static func build(
        episodes: [RuleEvidenceEpisode],
        sessions: [Session],
        margins: [Interjection],
        marks: [ShowLessMark],
        now: Date
    ) -> [EpisodeEvidence] {
        let sessionsByItem = Dictionary(grouping: sessions, by: \.itemId)
        let marginsByItem = Dictionary(grouping: margins, by: \.itemId)
        let stoppedBefore = now.addingTimeInterval(-Double(stoppedEarlyDays) * 86_400)
        let addedBefore = now.addingTimeInterval(-Double(neverPlayedDays) * 86_400)
        // By episode id, not position: two Library copies of one feed episode are one episode, so a mark that names the
        // second copy still counts for the first and is never also counted as a row of its own (PR 11 audit).
        var marksByEpisode: [String: [ShowLessMark]] = [:]
        for (index, assigned) in assignMarks(marks, to: episodes) {
            let episode = episodes[index]
            marksByEpisode[nonEmpty(episode.entryId) ?? episode.item.id, default: []].append(contentsOf: assigned)
        }
        var usedMarkIds = Set<String>()
        var result: [EpisodeEvidence] = []
        var seenIds = Set<String>()

        for episode in episodes {
            let item = episode.item
            let id = nonEmpty(episode.entryId) ?? item.id
            guard seenIds.insert(id).inserted else { continue }
            let itemSessions = sessionsByItem[item.id] ?? []
            let counted = ItemFinishedRule.countedSessions(item, sessions: itemSessions)
            let lastListening = counted.compactMap(ItemFinishedRule.lastListening(of:)).max()
            let finished = ItemFinishedRule.isFinished(item, sessions: itemSessions)
            let itemMargins = marginsByItem[item.id] ?? []
            let positive = itemMargins.contains { $0.status == "active" } || itemMargins.contains { !($0.sharedAs ?? []).isEmpty }

            var evidence = EpisodeEvidence(id: id, feedKey: episode.feedKey, title: episode.title, publishedAt: episode.publishedAt, at: .distantPast, positive: positive)
            var dates: [Date] = []

            let matching = marksByEpisode[id] ?? []
            if !matching.isEmpty {
                evidence.showLess = true
                usedMarkIds.formUnion(matching.map(\.id))
                dates.append(contentsOf: matching.map(\.markedAt))
            }
            if !positive {
                if finished {
                    evidence.finishedNoMargin = true
                    dates.append(contentsOf: [item.sourceCompletedAt, lastListening].compactMap { $0 })
                } else if let lastListening, lastListening <= stoppedBefore {
                    evidence.stoppedEarly = true
                    dates.append(lastListening)
                } else if counted.isEmpty, item.deletedAt == nil, let addedAt = ItemFinishedRule.addedAt(item), addedAt <= addedBefore {
                    evidence.addedNeverPlayed = true
                    dates.append(addedAt)
                }
            } else {
                dates.append(contentsOf: itemMargins.map(\.createdAt))
            }
            guard let at = dates.max() else { continue }
            evidence.at = at
            result.append(evidence)
        }

        for mark in marks where !usedMarkIds.contains(mark.id) && seenIds.insert(mark.id).inserted {
            result.append(EpisodeEvidence(id: mark.id, feedKey: mark.feedKey, title: mark.title, at: mark.markedAt, showLess: true))
        }
        return result.sorted { lhs, rhs in
            lhs.at == rhs.at ? lhs.id < rhs.id : lhs.at > rhs.at
        }
    }

    /// Which episode each Show less mark is about, by position in `episodes`. A mark is about at most one episode, so one tap
    /// never counts twice. Two passes:
    /// 1. A mark belongs to the episode whose item or feed entry it names.
    /// 2. A mark made from the Show screen names an entry and no item. If the caller found no feed entry for the item, that
    ///    mark still belongs to it when the feed and the folded title are the same, but only an episode with no entry of its
    ///    own and only a mark pass 1 left over, and only the first such episode, so a rerun posted under the same title with a
    ///    new entry id, or two Library copies of one episode, are never both counted.
    static func assignMarks(_ marks: [ShowLessMark], to episodes: [RuleEvidenceEpisode]) -> [Int: [ShowLessMark]] {
        var assigned: [Int: [ShowLessMark]] = [:]
        var claimed = Set<String>()
        for (index, episode) in episodes.enumerated() {
            for mark in marks where !claimed.contains(mark.id) {
                let namesItem = mark.itemId == episode.item.id
                let namesEntry = nonEmpty(episode.entryId).map { $0 == mark.entryId } ?? false
                if namesItem || namesEntry {
                    claimed.insert(mark.id)
                    assigned[index, default: []].append(mark)
                }
            }
        }
        for (index, episode) in episodes.enumerated() where nonEmpty(episode.entryId) == nil {
            let folded = ListeningRuleMatcher.Pattern.tokens(of: episode.title)
            guard !folded.isEmpty else { continue }
            for mark in marks where !claimed.contains(mark.id) && mark.itemId == nil && mark.feedKey == episode.feedKey {
                if ListeningRuleMatcher.Pattern.tokens(of: mark.title) == folded {
                    claimed.insert(mark.id)
                    assigned[index, default: []].append(mark)
                }
            }
        }
        return assigned
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
