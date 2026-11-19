import Foundation
import SessionKit

extension FollowingRuleInputs {
    /// The listener's rules, lists and Show less marks, read from the store for the evaluator (#4046). A read that fails
    /// gives nothing for that part, which sets nothing aside: a store that can't be read never hides an episode.
    public static func load(from store: SQLiteSessionStore) -> FollowingRuleInputs {
        FollowingRuleInputs(
            rules: (try? store.loadListeningRules()) ?? [],
            lists: (try? store.loadFollowLists()) ?? [],
            marks: (try? store.loadShowLessMarks()) ?? []
        )
    }

    /// What `FollowedSourceCoordinator` asks before "Add everything new" adds an episode: the show's entries that the
    /// stored rules and marks set aside. Reads the store each time, so a rule switched on a moment ago counts.
    public static func setAside(store: SQLiteSessionStore) -> @Sendable ([FeedEntry], FeedSubscription) -> Set<String> {
        { entries, subscription in
            FollowingRuleEvaluation.setAside(entries: entries, subscription: subscription, inputs: load(from: store))
        }
    }
}
