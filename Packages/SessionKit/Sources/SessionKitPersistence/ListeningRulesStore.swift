import Foundation
import SessionKit

/// Listening rules (#4046 PR 10b) read and written off the main thread. Each edit from the Rules screens is one call here:
/// it loads what is stored, applies the change, saves, and answers with the rules as they now are. One actor per store, so
/// two quick taps run one after the other and the second sees the first's result (a double tap on Save makes one rule).
public actor ListeningRulesStore {
    /// The rules after a change, and why the change was refused or only partly made.
    public struct Change: Equatable, Sendable {
        public var rules: [ListeningRule]
        /// The words were refused; nothing was saved.
        public var problem: ListeningRuleWords.Problem?
        /// The rule would skip almost everything for a show, so it was not turned on. A new rule is still saved, switched off.
        public var refusal: ListeningRuleScreens.Refusal?
        /// The listener already keeps the most rules allowed; nothing was saved.
        public var isFull: Bool = false
        /// The rule that was made or changed.
        public var changedRuleID: String?

        public init(
            rules: [ListeningRule],
            problem: ListeningRuleWords.Problem? = nil,
            refusal: ListeningRuleScreens.Refusal? = nil,
            isFull: Bool = false,
            changedRuleID: String? = nil
        ) {
            self.rules = rules
            self.problem = problem
            self.refusal = refusal
            self.isFull = isFull
            self.changedRuleID = changedRuleID
        }
    }

    private let store: SQLiteSessionStore

    public init(store: SQLiteSessionStore) {
        self.store = store
    }

    public func rules() throws -> [ListeningRule] {
        try store.loadListeningRules()
    }

    /// A rule the listener wrote on the New rule form. Saving is their intent, so it is saved switched on, unless it would
    /// skip almost everything for a show in its scope: then it is saved switched off and the refusal says why.
    public func create(
        action: ListeningRuleAction,
        wordsField: String,
        scope: ListeningRuleScope,
        id: String = UUID().uuidString,
        now: Date = Date()
    ) throws -> Change {
        let existing = try store.loadListeningRules()
        let words: [String]
        switch ListeningRuleWords.validate(ListeningRuleWords.split(wordsField)) {
        case .invalid(let problem): return Change(rules: existing, problem: problem)
        case .valid(let valid): words = valid
        }
        // A second Save of the same form (a double tap) finds its rule already there.
        if existing.contains(where: { $0.id == id }) { return Change(rules: existing, changedRuleID: id) }
        guard ListeningRuleWords.hasRoom(forRulesAlreadyKept: existing.count) else {
            return Change(rules: existing, isFull: true)
        }
        var rule = ListeningRule(id: id, action: action, words: words, scope: scope, origin: .listener, isOn: true, createdAt: now)
        let refusal = try refusal(for: rule)
        if refusal != nil { rule.isOn = false }
        try store.saveListeningRule(rule)
        return Change(rules: try store.loadListeningRules(), refusal: refusal, changedRuleID: id)
    }

    /// The rule's switch. Turning a skip rule on is refused while it would skip almost everything for a show in its scope.
    /// Turning one off is always allowed.
    public func setOn(id: String, isOn: Bool, now: Date = Date()) throws -> Change {
        guard var rule = try store.loadListeningRule(id: id) else { return Change(rules: try store.loadListeningRules()) }
        if rule.isOn == isOn { return Change(rules: try store.loadListeningRules(), changedRuleID: id) }
        if isOn, let refusal = try refusal(for: rule) {
            return Change(rules: try store.loadListeningRules(), refusal: refusal, changedRuleID: id)
        }
        rule.isOn = isOn
        rule.updatedAt = now
        try store.saveListeningRule(rule)
        return Change(rules: try store.loadListeningRules(), changedRuleID: id)
    }

    /// The Rule screen's Words field. A rule that is on stays on: if the new words make it too broad for a show, the
    /// evaluator pauses it there, as it does for a rule that became too broad as episodes arrived.
    public func setWords(id: String, wordsField: String, now: Date = Date()) throws -> Change {
        guard var rule = try store.loadListeningRule(id: id) else { return Change(rules: try store.loadListeningRules()) }
        switch ListeningRuleWords.validate(ListeningRuleWords.split(wordsField)) {
        case .invalid(let problem):
            return Change(rules: try store.loadListeningRules(), problem: problem, changedRuleID: id)
        case .valid(let words):
            if words != rule.words {
                rule.words = words
                rule.updatedAt = now
                try store.saveListeningRule(rule)
            }
            return Change(rules: try store.loadListeningRules(), changedRuleID: id)
        }
    }

    public func delete(id: String) throws -> [ListeningRule] {
        try store.deleteListeningRule(id: id)
        return try store.loadListeningRules()
    }

    /// The followed shows with their stored episodes and the lists, read here so the guard sees what the store holds now.
    private func refusal(for rule: ListeningRule) throws -> ListeningRuleScreens.Refusal? {
        guard rule.action == .skip else { return nil }
        let subscriptions = try store.loadFeedSubscriptions()
        let shows = ListeningRuleScreens.shows(subscriptions: subscriptions, entries: try store.loadFeedEntries(subscriptionId: nil))
        let titles = Dictionary(subscriptions.map { ($0.id, FollowingShowRows.displayTitle(of: $0)) }, uniquingKeysWith: { a, _ in a })
        return ListeningRuleScreens.refusal(for: rule, shows: shows, lists: try store.loadFollowLists(), showTitles: titles)
    }
}
