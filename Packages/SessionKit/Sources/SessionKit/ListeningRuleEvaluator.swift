import Foundation

/// One followed show and its episodes, as the evaluator reads them (#4046).
public struct ListeningRuleShow: Sendable {
    /// The caller's id for the show (the subscription id). The evaluation is keyed by it.
    public let id: String
    /// How rules and lists find the show: its feed key, and its podcast GUID where one is known.
    public let member: ListMember
    public var entries: [FeedEntry]

    public init(id: String, member: ListMember, entries: [FeedEntry]) {
        self.id = id
        self.member = member
        self.entries = entries
    }
}

/// What the rules do to one show's episodes (#4046).
public struct ListeningRuleShowOutcome: Equatable, Sendable {
    /// Entry ids left out of the Following row, the count, ▶ and "Add everything new": skipped by a rule or marked Show less.
    public var setAside: Set<String> = []
    /// For an entry a rule skipped, the word, as the rule's author wrote it, that matched first ("Skipped: about “word”").
    public var skippedByWord: [String: String] = [:]
    /// Entry ids marked Show less (a subset of `setAside`).
    public var markedShowLess: Set<String> = []
    /// Entry ids a pick rule matched. A set-aside entry is never a pick.
    public var picks: Set<String> = []
    /// Skip rules switched on that have become too broad for this show, so they don't apply to it.
    public var pausedRuleIds: [String] = []

    public init() {}

    public var isEmpty: Bool { setAside.isEmpty && picks.isEmpty && pausedRuleIds.isEmpty }
}

/// The result of one evaluation, keyed by the caller's show ids (#4046).
public struct ListeningRuleEvaluation: Equatable, Sendable {
    public private(set) var byShow: [String: ListeningRuleShowOutcome]

    public init(byShow: [String: ListeningRuleShowOutcome] = [:]) { self.byShow = byShow }

    /// An empty outcome for a show no rule touched.
    public func outcome(for showId: String) -> ListeningRuleShowOutcome { byShow[showId] ?? ListeningRuleShowOutcome() }

    public var setAsideEntryIds: Set<String> { byShow.values.reduce(into: []) { $0.formUnion($1.setAside) } }
}

/// How broad a skip rule is for one show (#4046), for the refusal to turn on a rule that would skip almost everything.
public struct ListeningRuleBroadness: Equatable, Sendable {
    public let showId: String
    /// How many of the show's last `window` episodes the rule matches.
    public let matched: Int
    public let window: Int
}

/// The one place a rule's effect is worked out (#4046). The Following row, ▶, the swipe actions, the Show screen and
/// "Add everything new" all read this, so they can't disagree about which episode is set aside.
public enum ListeningRuleEvaluator {
    /// The guard looks at a show's last 30 episodes.
    public static let guardWindow = 30
    /// A skip rule is too broad at 90% or more of the window...
    public static let guardPercent = 90
    /// ...and at least this many matches.
    public static let guardMinimumMatches = 5

    /// - Parameters:
    ///   - shows: each followed show with its episodes. Only rules whose scope covers a show apply to it.
    ///   - rules: all the listener's rules. Only those switched on act.
    ///   - lists: the listener's lists, for rules scoped to a list.
    ///   - marks: Show less marks, matched to an entry by `entryId`, so a caller marking a feed episode must pass its entry id. A
    ///     marked entry is set aside whatever the rules say.
    ///   - protected: entry ids that are never set aside, by a rule or by a mark: in the Library, played, or holding Margins,
    ///     the listener's own or a friend's. The caller works this out (finished, part played, the Library and every Margin
    ///     layer), so a played episode never vanishes under the listener.
    /// - Returns: per show, what is set aside, which episodes are picks, and which rules are paused. Shows with nothing to
    ///   report are left out; ask `outcome(for:)`.
    public static func evaluate(
        entriesByShow shows: [ListeningRuleShow],
        rules: [ListeningRule],
        lists: [FollowList],
        marks: [ShowLessMark],
        protected: Set<String>
    ) -> ListeningRuleEvaluation {
        let active = rules.filter(\.isOn)
        let markedIds = Set(marks.compactMap { $0.entryId.flatMap { $0.isEmpty ? nil : $0 } })
        if active.isEmpty && markedIds.isEmpty { return ListeningRuleEvaluation() }
        var matchers: [String: ListeningRuleMatcher] = [:]
        for rule in active { matchers[rule.id] = ListeningRuleMatcher(words: rule.words) }

        var result: [String: ListeningRuleShowOutcome] = [:]
        for show in shows {
            let applicable = active.filter { covers($0.scope, show: show.member, lists: lists) }
            if applicable.isEmpty && !show.entries.contains(where: { markedIds.contains($0.id) }) { continue }
            let texts = show.entries.map { ListeningRuleText(title: $0.title, summary: $0.summary) }
            let window = Set(windowIndices(show.entries))
            var outcome = ListeningRuleShowOutcome()

            var skipRules: [(rule: ListeningRule, matcher: ListeningRuleMatcher)] = []
            var pickMatchers: [ListeningRuleMatcher] = []
            for rule in applicable {
                guard let matcher = matchers[rule.id] else { continue }
                switch rule.action {
                case .more:
                    pickMatchers.append(matcher)
                case .skip:
                    let matched = window.filter { matcher.matches(texts[$0]) }.count
                    if isTooBroad(matched: matched, window: window.count) {
                        outcome.pausedRuleIds.append(rule.id)
                    } else {
                        skipRules.append((rule, matcher))
                    }
                }
            }

            for (index, entry) in show.entries.enumerated() {
                if markedIds.contains(entry.id), !protected.contains(entry.id) {
                    outcome.setAside.insert(entry.id)
                    outcome.markedShowLess.insert(entry.id)
                    continue
                }
                if !protected.contains(entry.id),
                   let word = skipRules.lazy.compactMap({ $0.matcher.firstMatch(in: texts[index]) }).first {
                    outcome.setAside.insert(entry.id)
                    outcome.skippedByWord[entry.id] = word
                    continue
                }
                if pickMatchers.contains(where: { $0.matches(texts[index]) }) { outcome.picks.insert(entry.id) }
            }
            if !outcome.isEmpty { result[show.id] = outcome }
        }
        return ListeningRuleEvaluation(byShow: result)
    }

    /// The shows in a skip rule's scope that it is too broad for. Turning the rule on is refused when this isn't empty. A
    /// pick rule is never too broad.
    public static func tooBroadShows(
        for rule: ListeningRule,
        shows: [ListeningRuleShow],
        lists: [FollowList]
    ) -> [ListeningRuleBroadness] {
        guard rule.action == .skip else { return [] }
        let matcher = ListeningRuleMatcher(words: rule.words)
        return shows.compactMap { show in
            guard covers(rule.scope, show: show.member, lists: lists) else { return nil }
            let indices = windowIndices(show.entries)
            let matched = indices.filter { index in
                matcher.matches(title: show.entries[index].title, summary: show.entries[index].summary)
            }.count
            guard isTooBroad(matched: matched, window: indices.count) else { return nil }
            return ListeningRuleBroadness(showId: show.id, matched: matched, window: indices.count)
        }
    }

    /// The definition of "too broad", used by the guard at evaluation time and by turning a rule on.
    public static func isTooBroad(matched: Int, window: Int) -> Bool {
        matched >= guardMinimumMatches && window > 0 && matched * 100 >= window * guardPercent
    }

    /// Whether a rule with this scope applies to the show.
    public static func covers(_ scope: ListeningRuleScope, show: ListMember, lists: [FollowList]) -> Bool {
        switch scope {
        case .any:
            return true
        case .show(let member):
            return member.matches(feedKey: show.feedKey, podcastGUID: show.podcastGUID)
        case .list(let id):
            return lists.first { $0.id == id }?.contains(feedKey: show.feedKey, podcastGUID: show.podcastGUID) ?? false
        }
    }

    /// Indices of the show's last 30 episodes, newest first. An entry with no publish date counts from when it was first
    /// seen, and one with neither is oldest. Ties go by id, so the window is the same on every call.
    static func windowIndices(_ entries: [FeedEntry]) -> [Int] {
        let order = entries.indices.sorted { lhs, rhs in
            let a = entries[lhs].publishedAt ?? entries[lhs].firstSeenAt ?? .distantPast
            let b = entries[rhs].publishedAt ?? entries[rhs].firstSeenAt ?? .distantPast
            return a == b ? entries[lhs].id < entries[rhs].id : a > b
        }
        return Array(order.prefix(guardWindow))
    }
}
