import SessionKit
import SessionKitPersistence
import SwiftUI

/// The listening rules as the Rules screens watch them (#4046 PR 10b), so a switch, a new rule or a delete shows at once
/// without a flag on `Gate1AppModel`. `loaded` is false until the first read, so the Rules screen shows nothing rather than
/// "No rules yet" for a moment. The store is read and written only through `ListeningRulesStore`, an actor.
@MainActor
final class ListeningRulesState: ObservableObject {
    static let shared = ListeningRulesState()
    @Published private(set) var rules: [ListeningRule] = []
    @Published private(set) var loaded = false
    /// Following's entries revision, so the Rules screens (which don't observe `Gate1AppModel`, #4028) recount paused
    /// rules and matches when new episodes arrive.
    @Published private(set) var entriesRevision = 0
    private var service: ListeningRulesStore?
    private var serviceStore: SQLiteSessionStore?

    /// One service per store, so two quick taps queue behind each other instead of racing.
    func service(for store: SQLiteSessionStore) -> ListeningRulesStore {
        if let service, serviceStore === store { return service }
        let made = ListeningRulesStore(store: store)
        service = made
        serviceStore = store
        return made
    }

    func noteEntriesRevision(_ revision: Int) {
        if revision != entriesRevision { entriesRevision = revision }
    }

    func publish(_ stored: [ListeningRule]) {
        if stored != rules { rules = stored }
        if !loaded { loaded = true }
    }

    /// The first read failed: the Rules screen still shows its empty state and **New rule**, instead of nothing at all
    /// (PR 10b audit). Rules already shown stay.
    func noteReadFailed() {
        if !loaded { loaded = true }
    }
}

/// Thin wiring from the Rules screens to `ListeningRulesStore`. The words, sections, guard and match counts are in
/// SessionKit (`ListeningRuleScreens`, `ListeningRuleEvaluator`). After every change Following's entries and rules are read
/// again, so its rows, the Show screen's Skipped group and "Add everything new" follow the change at once.
extension Gate1AppModel {
    /// Reads the rules. A failed read keeps what is shown, and a failed first read still lets the screen offer New rule.
    func reloadListeningRules() async {
        guard let store else { return }
        let state = ListeningRulesState.shared
        guard let stored = try? await state.service(for: store).rules() else {
            state.noteReadFailed()
            return
        }
        state.publish(stored)
    }

    /// Saves a rule from the New rule form, switched on unless the guard refuses it.
    func createListeningRule(
        id: String, action: ListeningRuleAction, wordsField: String, scope: ListeningRuleScope
    ) async -> ListeningRulesStore.Change? {
        await changeListeningRules(context: "Saving the rule failed") {
            try await $0.create(action: action, wordsField: wordsField, scope: scope, id: id)
        }
    }

    func setListeningRuleOn(id: String, isOn: Bool) async -> ListeningRulesStore.Change? {
        await changeListeningRules(context: "Changing the rule failed") { try await $0.setOn(id: id, isOn: isOn) }
    }

    func setListeningRuleWords(id: String, wordsField: String) async -> ListeningRulesStore.Change? {
        await changeListeningRules(context: "Saving the rule’s words failed") { try await $0.setWords(id: id, wordsField: wordsField) }
    }

    func deleteListeningRule(id: String) async {
        _ = await changeListeningRules(context: "Deleting the rule failed") {
            ListeningRulesStore.Change(rules: try await $0.delete(id: id))
        }
    }

    func changeListeningRules(
        context: String, _ change: (ListeningRulesStore) async throws -> ListeningRulesStore.Change
    ) async -> ListeningRulesStore.Change? {
        guard let store else {
            reportFailure("The Library isn't ready yet.")
            return nil
        }
        let state = ListeningRulesState.shared
        do {
            let result = try await change(state.service(for: store))
            state.publish(result.rules)
            await reloadFollowingShowEntries()
            // A rule that covers a suggestion ends it; a deleted one may bring it back (#4046 PR 12).
            await reloadRuleSuggestions()
            return result
        } catch {
            reportFailure(error, context: context)
            return nil
        }
    }
}
