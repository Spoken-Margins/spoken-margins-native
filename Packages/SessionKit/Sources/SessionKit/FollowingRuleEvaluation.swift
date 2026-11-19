import Foundation

/// What the evaluator reads besides the episodes (#4046): the listener's rules, lists and Show less marks.
public struct FollowingRuleInputs: Equatable, Sendable {
    public var rules: [ListeningRule]
    public var lists: [FollowList]
    public var marks: [ShowLessMark]

    public init(rules: [ListeningRule] = [], lists: [FollowList] = [], marks: [ShowLessMark] = []) {
        self.rules = rules
        self.lists = lists
        self.marks = marks
    }

    /// Nothing here can set an episode aside or make it a pick: no rule is on and no episode is marked. Following is
    /// then exactly what it was before rules existed.
    public var isInert: Bool { !rules.contains(where: \.isOn) && marks.isEmpty }
}

/// Runs `ListeningRuleEvaluator` over a listener's followed shows (#4046). The Following rows, the Show screen, ▶, the
/// swipe actions and "Add everything new" all call this with the same inputs, so they set aside the same episodes.
public enum FollowingRuleEvaluation {
    /// Entry ids a rule or a Show less mark must never set aside: an episode in the Library, which covers one played or
    /// finished and one holding Margins (the listener's own or a friend's), because each of those is an item in the
    /// Library. An entry with a Library item behind it counts even if its own state hasn't caught up.
    public static func protectedEntryIds(
        entries: [FeedEntry], libraryEpisodes: [String: FollowingLibraryEpisode] = [:]
    ) -> Set<String> {
        Set(entries.filter { $0.state == .imported || libraryEpisodes[$0.id] != nil }.map(\.id))
    }

    /// The evaluation for `subscriptions`, whose episodes are the entries that belong to them. Entries of any other show
    /// are ignored. An empty evaluation, without reading any episode, when `inputs.isInert`.
    public static func evaluate(
        subscriptions: [FeedSubscription],
        entries: [FeedEntry],
        inputs: FollowingRuleInputs,
        libraryEpisodes: [String: FollowingLibraryEpisode] = [:]
    ) -> ListeningRuleEvaluation {
        guard !inputs.isInert else { return ListeningRuleEvaluation() }
        let bySubscription = Dictionary(grouping: entries, by: \.subscriptionId)
        let shows = subscriptions.map { subscription in
            ListeningRuleShow(
                id: subscription.id,
                member: FollowListEditing.member(for: subscription),
                entries: bySubscription[subscription.id] ?? []
            )
        }
        return ListeningRuleEvaluator.evaluate(
            entriesByShow: shows,
            rules: inputs.rules,
            lists: inputs.lists,
            marks: inputs.marks,
            protected: protectedEntryIds(entries: entries, libraryEpisodes: libraryEpisodes)
        )
    }

    /// The entry ids of one show that its rules and marks set aside: what "Add everything new" leaves out.
    /// - Parameter entries: the show's stored episodes, in any state.
    public static func setAside(
        entries: [FeedEntry], subscription: FeedSubscription, inputs: FollowingRuleInputs
    ) -> Set<String> {
        evaluate(subscriptions: [subscription], entries: entries, inputs: inputs).outcome(for: subscription.id).setAside
    }
}
