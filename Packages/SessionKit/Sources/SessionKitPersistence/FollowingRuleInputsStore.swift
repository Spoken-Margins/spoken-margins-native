import Foundation
import SessionKit

extension FollowingRuleInputs {
    /// The listener's rules, lists and Show less marks, read from the store for the evaluator (#4046). A read that fails
    /// gives nothing for that part, which sets nothing aside: a store that can't be read never hides an episode from a
    /// screen. "Add everything new" must not use this; it reads `loadIfReadable`.
    public static func load(from store: SQLiteSessionStore) -> FollowingRuleInputs {
        FollowingRuleInputs(
            rules: (try? store.loadListeningRules()) ?? [],
            lists: (try? store.loadFollowLists()) ?? [],
            marks: (try? store.loadShowLessMarks()) ?? []
        )
    }

    /// The same three reads, or nil when any of them fails, so a caller that acts for good can tell "no rules" from "the
    /// rules couldn't be read".
    public static func loadIfReadable(from store: SQLiteSessionStore) -> FollowingRuleInputs? {
        guard let rules = try? store.loadListeningRules(),
              let lists = try? store.loadFollowLists(),
              let marks = try? store.loadShowLessMarks() else { return nil }
        return FollowingRuleInputs(rules: rules, lists: lists, marks: marks)
    }

    /// What `FollowedSourceCoordinator` asks before "Add everything new" adds an episode: the show's entries that the
    /// stored rules and marks set aside. Reads the store each time, so a rule switched on a moment ago counts.
    ///
    /// When the rules, lists or marks can't be read, every entry is set aside, so that refresh adds nothing on its own. An
    /// add is permanent and a skipped episode is not: it stays listed on Following and the Show screen, where the listener
    /// can still add it. Adding it anyway could put an episode a rule skips into the Library for good (PR 10a audit).
    public static func setAside(store: SQLiteSessionStore) -> @Sendable ([FeedEntry], FeedSubscription) -> Set<String> {
        { entries, subscription in
            guard let inputs = loadIfReadable(from: store) else { return Set(entries.map(\.id)) }
            return FollowingRuleEvaluation.setAside(entries: entries, subscription: subscription, inputs: inputs)
        }
    }
}
