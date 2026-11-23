import Foundation
import SessionKit
import SessionKitPersistence
import SwiftUI

/// The live rule suggestions (#4046 PR 12) as views watch them: the card on Following shows the first, the Rules screen's
/// Suggested section all of them. Empty until the learner has run.
@MainActor
final class RuleSuggestionsState: ObservableObject {
    static let shared = RuleSuggestionsState()
    @Published private(set) var suggestions: [RuleSuggestion] = []
    /// Each run's number, so a slow run that finishes after a newer one never puts back an old answer.
    private var generation = 0

    func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    func publish(_ found: [RuleSuggestion], generation: Int) {
        guard generation == self.generation, found != suggestions else { return }
        suggestions = found
    }
}

/// Thin wiring for Show less and the suggestions. The marks, the words and the learner are SessionKit's
/// (`ShowLessMarking`, `ShowLessWords`, `RuleSuggestionWords`, `RuleSuggestionsLoader`); the store is written only through
/// `ListeningRulesStore`, and Following's entries and rules are read again after each change, so the rows, ▶, the count
/// and "Add everything new" follow it at once.
extension Gate1AppModel {
    /// Runs the learner off the main thread, after a feed refresh and after a Show less mark.
    func reloadRuleSuggestions() async {
        guard let store else { return }
        let state = RuleSuggestionsState.shared
        let generation = state.nextGeneration()
        let imported = listeningSignals.importedEntries.entryIds()
        let found = await Task.detached(priority: .utility) {
            RuleSuggestionsLoader.load(store: store, importedEntryIds: imported)
        }.value
        state.publish(found, generation: generation)
    }

    /// The mark for this episode, when the Show screen's or the Item screen's menu wrote one.
    func showLessMark(entryId: String?, itemId: String?) -> ShowLessMark? {
        ShowLessMarking.existing(entryId: entryId, itemId: itemId, in: followingRuleInputs.marks)
    }

    /// The followed show an Item screen's item came from, and its feed entry when one matches, by the same match the
    /// listening-signal log uses; nil for an item from no followed show, and then the menu offers no Show less.
    func showLessTarget(itemId: String) async -> ShowLessTarget? {
        guard let store, !itemId.isEmpty else { return nil }
        let subscriptions = feedSubscriptions, entries = followingShowEntries
        let imported = listeningSignals.importedEntries.entryIds()
        return await Task.detached(priority: .userInitiated) { () -> ShowLessTarget? in
            guard let item = try? store.loadItem(id: itemId), item.deletedAt == nil,
                  let subscription = FollowedShowMatch.subscription(for: item, subscriptions: subscriptions) else { return nil }
            let entryId = FollowedShowMatch.entryId(for: item, subscription: subscription, entries: entries, importedEntryIds: imported)
            return ShowLessTarget(item: item, subscription: subscription, entryId: entryId)
        }.value
    }

    /// **Show less like this**, from either menu. The toast offers **Undo**.
    func markShowLess(_ mark: ShowLessMark) async {
        guard let store else {
            reportFailure("The Library isn't ready yet.")
            return
        }
        do {
            _ = try await ListeningRulesState.shared.service(for: store).markShowLess(mark)
        } catch {
            reportFailure(error, context: "Marking the episode failed")
            return
        }
        await reloadFollowingShowEntries()
        presentFeedback(UserFeedbackEvent(
            kind: .success,
            message: ShowLessWords.toast,
            action: UserFeedbackEvent.Action(
                title: ShowLessWords.undo,
                accessibilityLabel: ShowLessWords.menuTitle(isMarked: true),
                identifier: "showLess.undo.button",
                perform: { [weak self] in
                    Task { await self?.unmarkShowLess(entryId: mark.entryId, itemId: mark.itemId) }
                })))
        await reloadRuleSuggestions()
    }

    /// **Undo Show less**, from either menu or the toast.
    func unmarkShowLess(entryId: String?, itemId: String?) async {
        guard let store else { return }
        do {
            _ = try await ListeningRulesState.shared.service(for: store).unmarkShowLess(entryId: entryId, itemId: itemId)
        } catch {
            reportFailure(error, context: "Undoing Show less failed")
            return
        }
        await reloadFollowingShowEntries()
        await reloadRuleSuggestions()
    }

    /// **Turn on**: saves the suggested rule. When the guard refuses it, it is saved switched off and the caller shows the
    /// refusal; otherwise the toast says what is now skipped and offers **Undo**, which deletes the rule again.
    func turnOnSuggestion(_ suggestion: RuleSuggestion) async -> ListeningRulesStore.Change? {
        let change = await changeListeningRules(context: "Turning the rule on failed") { try await $0.turnOn(suggestion) }
        guard let change, change.refusal == nil, !change.isFull, let id = change.changedRuleID else { return change }
        presentFeedback(UserFeedbackEvent(
            kind: .success,
            message: RuleSuggestionWords.turnedOn(suggestion),
            action: UserFeedbackEvent.Action(
                title: ShowLessWords.undo,
                accessibilityLabel: "Undo turning the rule on",
                identifier: "ruleSuggestion.undo.button",
                perform: { [weak self] in
                    Task { await self?.deleteListeningRule(id: id) }
                })))
        return change
    }

    /// **Not now**: quiet for 30 days.
    func putOffSuggestion(_ suggestion: RuleSuggestion) async {
        await changeSuggestionState(context: "Putting the suggestion off failed") { try await $0.putOff(key: suggestion.key) }
    }

    /// **Don’t suggest this**: never again.
    func refuseSuggestion(_ suggestion: RuleSuggestion) async {
        await changeSuggestionState(context: "Saving your choice failed") { try await $0.refuse(key: suggestion.key) }
    }

    private func changeSuggestionState(
        context: String, _ change: (ListeningRulesStore) async throws -> [RuleSuggestionState]
    ) async {
        guard let store else { return }
        do {
            _ = try await change(ListeningRulesState.shared.service(for: store))
        } catch {
            reportFailure(error, context: context)
            return
        }
        await reloadRuleSuggestions()
    }
}

/// What the Item screen's **Show less like this** marks (#4046 PR 12).
struct ShowLessTarget: Sendable {
    let item: Item
    let subscription: FeedSubscription
    let entryId: String?

    var mark: ShowLessMark { ShowLessMarking.mark(item: item, subscription: subscription, entryId: entryId) }
}
