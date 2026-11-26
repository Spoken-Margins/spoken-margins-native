import Foundation

// "Show less like this" and rule suggestions on screen (#4046 PR 12): which followed show an item belongs to, the mark
// either menu writes, the words of the toast, the suggestion card and the Rules screen's Suggested section, and the
// learner's inputs gathered from what the device holds. Pure; the clock is an input.

/// Which followed show a Library item came from, the match the listening-signal log uses, so the Item screen's **Show less
/// like this** names the same show the log would.
public enum FollowedShowMatch {
    public static func subscription(for item: Item, subscriptions: [FeedSubscription]) -> FeedSubscription? {
        ListeningSignalContext.followedSubscription(for: item, subscriptions: subscriptions)
    }

    /// The feed entry the item was imported from, inside its followed show, when one matches.
    public static func entryId(
        for item: Item, subscription: FeedSubscription, entries: [FeedEntry], importedEntryIds: [String: String] = [:]
    ) -> String? {
        ListeningSignalContext.importedEntry(
            for: item, among: entries.filter { $0.subscriptionId == subscription.id },
            knownSubscriptionId: subscription.id, importedEntryIds: importedEntryIds)?.id
    }
}

/// The Show less mark the Show screen's and the Item screen's menus write, and whether an episode carries one. Both menus
/// build the mark here, so an episode marked from either is the same mark (its id is the entry id when there is one).
public enum ShowLessMarking {
    public static func mark(entry: FeedEntry, subscription: FeedSubscription, now: Date = Date()) -> ShowLessMark {
        ShowLessMark(
            feedKey: FollowListEditing.member(for: subscription).feedKey, entryId: entry.id, itemId: nil,
            title: entry.title, markedAt: now)
    }

    public static func mark(
        item: Item, subscription: FeedSubscription, entryId: String?, now: Date = Date()
    ) -> ShowLessMark {
        ShowLessMark(
            feedKey: FollowListEditing.member(for: subscription).feedKey, entryId: entryId, itemId: item.id,
            title: item.title, markedAt: now)
    }

    /// The mark for this entry, or for this item, when there is one.
    public static func existing(entryId: String?, itemId: String?, in marks: [ShowLessMark]) -> ShowLessMark? {
        marks.first { mark in
            if let entryId, !entryId.isEmpty, mark.entryId == entryId { return true }
            if let itemId, !itemId.isEmpty, mark.itemId == itemId { return true }
            return false
        }
    }
}

/// The words of Show less (#4046 PR 12).
public enum ShowLessWords {
    public static let label = "Show less"
    public static let symbol = "hand.thumbsdown"
    public static let toast = "Got it. After a few like this, Spoken Margins may suggest a rule."
    public static let undo = "Undo"

    /// The menu entry: **Show less like this**, or **Undo Show less** on an episode already marked.
    public static func menuTitle(isMarked: Bool) -> String { isMarked ? "Undo Show less" : "Show less like this" }
}

/// The words of a suggested rule (#4046 PR 12).
public enum RuleSuggestionWords {
    public static let eyebrow = "Suggestion"
    public static let turnOn = "Turn on"
    public static let notNow = "Not now"
    public static let never = "Don’t suggest this"
    public static let suggestedHeader = "Suggested"

    /// "Skip Planet Money episodes about “crypto”?"
    public static func title(_ suggestion: RuleSuggestion) -> String {
        "Skip \(suggestion.showTitle) episodes about “\(suggestion.word)”?"
    }

    /// "Rule on: Planet Money episodes about “crypto” are skipped."
    public static func turnedOn(_ suggestion: RuleSuggestion) -> String {
        "Rule on: \(suggestion.showTitle) episodes about “\(suggestion.word)” are skipped."
    }

    /// The rule **Turn on** saves: skip the show's episodes about the word, suggested, on (unless the guard refuses it).
    public static func rule(for suggestion: RuleSuggestion, id: String = UUID().uuidString, now: Date = Date()) -> ListeningRule {
        ListeningRule(
            id: id, action: .skip, words: [suggestion.word], scope: .show(suggestion.member), origin: .suggested,
            isOn: true, createdAt: now)
    }
}

/// Gathers what the learner reads from what the device holds (#4046 PR 12): the Library items that came from a followed
/// show, with their feed entry when one matched, and the followed shows with their stored episodes.
public enum RuleSuggestionInputs {
    /// Library items matched to a followed show. An item from no followed show says nothing about one, so it is left out.
    public static func episodes(
        items: [Item], subscriptions: [FeedSubscription], entries: [FeedEntry], importedEntryIds: [String: String] = [:]
    ) -> [RuleEvidenceEpisode] {
        let followedEntries = entries.filter { entry in subscriptions.contains { $0.id == entry.subscriptionId } }
        return items.compactMap { item in
            guard item.deletedAt == nil else { return nil }
            let known = ListeningSignalContext.followedSubscription(for: item, subscriptions: subscriptions)
            let entry = ListeningSignalContext.importedEntry(
                for: item, among: followedEntries, knownSubscriptionId: known?.id, importedEntryIds: importedEntryIds)
            guard let subscription = entry.flatMap({ entry in subscriptions.first { $0.id == entry.subscriptionId } }) ?? known
            else { return nil }
            return RuleEvidenceEpisode(
                item: item, feedKey: FollowListEditing.member(for: subscription).feedKey, entryId: entry?.id,
                title: entry?.title, publishedAt: entry?.publishedAt)
        }
    }

    public static func shows(subscriptions: [FeedSubscription], entries: [FeedEntry]) -> [RuleSuggestionShow] {
        let bySubscription = Dictionary(grouping: entries, by: \.subscriptionId)
        return subscriptions.map { subscription in
            RuleSuggestionShow(
                id: subscription.id, member: FollowListEditing.member(for: subscription),
                title: FollowingShowRows.displayTitle(of: subscription), entries: bySubscription[subscription.id] ?? [])
        }
    }

    /// The suggestions, strongest first: the card on Following shows the first, the Rules screen all of them.
    public static func suggestions(
        items: [Item],
        sessions: [Session],
        margins: [Interjection],
        marks: [ShowLessMark],
        subscriptions: [FeedSubscription],
        entries: [FeedEntry],
        rules: [ListeningRule],
        states: [RuleSuggestionState],
        lists: [FollowList],
        importedEntryIds: [String: String] = [:],
        now: Date
    ) -> [RuleSuggestion] {
        let episodes = episodes(items: items, subscriptions: subscriptions, entries: entries, importedEntryIds: importedEntryIds)
        let evidence = RuleEvidenceBuilder.build(episodes: episodes, sessions: sessions, margins: margins, marks: marks, now: now)
        return RuleSuggester.suggest(
            evidence: evidence, shows: shows(subscriptions: subscriptions, entries: entries),
            rules: rules, states: states, lists: lists, now: now)
    }
}
