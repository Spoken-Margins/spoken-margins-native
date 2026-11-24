import Foundation
import SessionKit

/// Reads what the rule learner needs from the store and runs it (#4046 PR 12): the Library items, their sessions and
/// Margins, the Show less marks, the followed shows with their episodes, the rules, the suggestion states and the lists.
/// Call it off the main thread. A read that fails gives no suggestions, never a wrong one.
public enum RuleSuggestionsLoader {
    public static func load(
        store: SQLiteSessionStore, importedEntryIds: [String: String] = [:], now: Date = Date()
    ) -> [RuleSuggestion] {
        guard let subscriptions = try? store.loadFeedSubscriptions(), !subscriptions.isEmpty,
              let entries = try? store.loadFeedEntries(subscriptionId: nil),
              let items = try? store.listItems(),
              let sessions = try? store.loadSessions(),
              let marks = try? store.loadShowLessMarks(),
              let rules = try? store.loadListeningRules(),
              let states = try? store.loadRuleSuggestionStates(),
              let lists = try? store.loadFollowLists()
        else { return [] }
        // Margins only for the items that came from a followed show: the rest say nothing about one.
        let matched = RuleSuggestionInputs.episodes(
            items: items, subscriptions: subscriptions, entries: entries, importedEntryIds: importedEntryIds)
        var margins: [Interjection] = []
        for itemId in Set(matched.map(\.item.id)) {
            guard let loaded = try? store.loadInterjections(itemId: itemId) else { return [] }
            margins += loaded
        }
        return RuleSuggestionInputs.suggestions(
            items: items, sessions: sessions, margins: margins, marks: marks, subscriptions: subscriptions,
            entries: entries, rules: rules, states: states, lists: lists, importedEntryIds: importedEntryIds, now: now)
    }
}
