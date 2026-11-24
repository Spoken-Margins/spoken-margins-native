import Foundation

/// What the Rules screens show (#4046 PR 10b): each rule's sentence and origin line, the On and Off sections, the Lists
/// screen's Rules row value, the Rule screen's match count, the New rule form's choices and the refusal to turn on a rule
/// that would skip almost everything. Pure, so every string is host-tested; the SwiftUI only draws it.
public enum ListeningRuleScreens {
    // MARK: Sentences

    /// “a”, “a” or “b”, “a”, “b” or “c”.
    public static func wordList(_ words: [String]) -> String {
        let quoted = words.map { "“\($0)”" }
        guard let last = quoted.last else { return "" }
        if quoted.count == 1 { return last }
        return quoted.dropLast().joined(separator: ", ") + " or " + last
    }

    /// "Skip Planet Money episodes about “crypto”", "Skip episodes about “a” in Commute", "Skip episodes about “a” from any
    /// show", and the same three as picks ("Mark … as picks").
    /// - Parameters:
    ///   - showTitle: the show's title for a show rule; nil when the listener no longer follows it.
    ///   - listName: the list's name for a list rule; nil when the list was deleted.
    public static func sentence(for rule: ListeningRule, showTitle: String?, listName: String?) -> String {
        let words = wordList(rule.words)
        let verb = rule.action == .skip ? "Skip" : "Mark"
        let tail = rule.action == .skip ? "" : " as picks"
        switch rule.scope {
        case .show:
            if let showTitle { return "\(verb) \(showTitle) episodes about \(words)\(tail)" }
            return "\(verb) episodes about \(words) from a show you no longer follow\(tail)"
        case .list:
            return "\(verb) episodes about \(words) in \(listName ?? "a deleted list")\(tail)"
        case .any:
            return "\(verb) episodes about \(words) from any show\(tail)"
        }
    }

    /// "You wrote this", "Suggested from your Show less marks", "From <list>", "From your AI · Nov 13". A skip rule that is on
    /// but has become too broad for some shows reads "Paused for <show>: it matched almost every recent episode." instead.
    public static func originLine(
        for rule: ListeningRule,
        pausedFor pausedShowTitles: [String] = [],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if rule.isOn, let first = pausedShowTitles.first {
            let others = pausedShowTitles.count - 1
            let shows = others == 0 ? first : "\(first) and \(others) more \(others == 1 ? "show" : "shows")"
            return "Paused for \(shows): it matched almost every recent episode."
        }
        switch rule.origin {
        case .listener: return "You wrote this"
        case .suggested: return "Suggested from your Show less marks"
        case .list(let name): return "From \(name)"
        case .ai(let date): return "From your AI · \(ListStatusWords.time(date, now: now, calendar: calendar, locale: locale))"
        }
    }

    // MARK: The Rules screen

    public struct Row: Equatable, Identifiable, Sendable {
        public var id: String
        public var sentence: String
        public var originLine: String
        public var isOn: Bool
        public var isPaused: Bool
        /// The rule's switch for VoiceOver: the sentence, then the origin line.
        public var accessibilityLabel: String { "\(sentence). \(originLine.hasSuffix(".") ? originLine : originLine + ".")" }
    }

    public struct Sections: Equatable, Sendable {
        public var on: [Row]
        public var off: [Row]
        public var isEmpty: Bool { on.isEmpty && off.isEmpty }
    }

    /// The On and Off sections, oldest rule first in each (the store's order).
    /// - Parameters:
    ///   - onlyList: "Rules for this list": only the rules scoped to this list.
    ///   - pausedShowTitles: per rule id, the shows it is paused for (`pausedShowTitles(in:subscriptions:)`).
    public static func sections(
        rules: [ListeningRule],
        lists: [FollowList],
        subscriptions: [FeedSubscription],
        pausedShowTitles: [String: [String]] = [:],
        onlyList: String? = nil,
        now: Date = Date()
    ) -> Sections {
        let shown = onlyList.map { id in rules.filter { $0.scope == .list(id) } } ?? rules
        let rows = shown.map { rule -> Row in
            let paused = rule.isOn ? (pausedShowTitles[rule.id] ?? []) : []
            return Row(
                id: rule.id,
                sentence: sentence(for: rule, subscriptions: subscriptions, lists: lists),
                originLine: originLine(for: rule, pausedFor: paused, now: now),
                isOn: rule.isOn,
                isPaused: !paused.isEmpty
            )
        }
        return Sections(on: rows.filter(\.isOn), off: rows.filter { !$0.isOn })
    }

    /// The sentence, finding the show among the followed ones and the list among the listener's lists.
    public static func sentence(for rule: ListeningRule, subscriptions: [FeedSubscription], lists: [FollowList]) -> String {
        sentence(for: rule, showTitle: showTitle(for: rule.scope, subscriptions: subscriptions),
                 listName: listName(for: rule.scope, lists: lists))
    }

    /// For each rule that is paused somewhere, the titles of the shows it is paused for, in the order of `subscriptions`.
    public static func pausedShowTitles(
        in evaluation: ListeningRuleEvaluation, subscriptions: [FeedSubscription]
    ) -> [String: [String]] {
        var titles: [String: [String]] = [:]
        for subscription in subscriptions {
            for ruleID in evaluation.outcome(for: subscription.id).pausedRuleIds {
                titles[ruleID, default: []].append(FollowingShowRows.displayTitle(of: subscription))
            }
        }
        return titles
    }

    /// The Lists screen's Rules row and the list screen's Rules for this list: "<n> on", or "None yet" with no rule at all.
    public static func rowValue(rules: [ListeningRule], onlyList: String? = nil) -> String {
        let shown = onlyList.map { id in rules.filter { $0.scope == .list(id) } } ?? rules
        if shown.isEmpty { return "None yet" }
        return "\(shown.filter(\.isOn).count) on"
    }

    public static let title = "Rules"
    public static let emptyTitle = "No rules yet"
    public static let emptyDetail = "A rule skips episodes you don’t want, or marks ones you do. Write one, or mark episodes Show less and Spoken Margins may suggest one."
    public static let newRuleTitle = "New rule"
    public static let deleteQuestion = "Delete this rule?"
    public static let fullMessage = "You can keep at most \(ListeningRuleWords.maxRules) rules. Delete one to add another."

    // MARK: Turning a rule on

    /// Why a rule could not be turned on.
    public struct Refusal: Equatable, Sendable {
        public var title: String
        public var message: String

        public init(title: String, message: String) {
            self.title = title
            self.message = message
        }
    }

    /// The alert when the listener already keeps the most rules allowed.
    public static let fullRefusal = Refusal(title: "Can’t add another rule", message: fullMessage)

    /// The alert for a skip rule that would skip almost everything for a show, nil when it is fine to turn on.
    public static func refusal(
        for rule: ListeningRule, shows: [ListeningRuleShow], lists: [FollowList], showTitles: [String: String]
    ) -> Refusal? {
        guard let broad = ListeningRuleEvaluator.tooBroadShows(for: rule, shows: shows, lists: lists).first else { return nil }
        let show = showTitles[broad.showId] ?? "this show"
        return Refusal(
            title: "This rule would skip almost everything",
            message: "It matches \(broad.matched) of the last \(broad.window) episodes from \(show). To hear less of a whole show, set it to Quiet on its page."
        )
    }

    // MARK: The Rule screen

    public struct Matches: Equatable, Sendable {
        /// The matching episodes among the last `window` in the rule's scope, newest first.
        public var matched: [FeedEntry]
        public var window: Int

        /// "Matches 3 of the last 30 episodes", "No episodes to check yet" when the scope has none.
        public var summary: String {
            if window == 0 { return "No episodes to check yet" }
            return "Matches \(matched.count) of the last \(window) \(window == 1 ? "episode" : "episodes")"
        }
    }

    /// The last 30 episodes in the rule's scope across its shows, newest first, and the ones it matches. Dismissed episodes
    /// count, as they do for the guard, so the number agrees with the refusal's.
    public static func matches(for rule: ListeningRule, shows: [ListeningRuleShow], lists: [FollowList]) -> Matches {
        let entries = shows
            .filter { ListeningRuleEvaluator.covers(rule.scope, show: $0.member, lists: lists) }
            .flatMap(\.entries)
        let window = ListeningRuleEvaluator.windowIndices(entries).map { entries[$0] }
        let matcher = ListeningRuleMatcher(words: rule.words)
        return Matches(matched: window.filter { matcher.matches(title: $0.title, summary: $0.summary) }, window: window.count)
    }

    /// Each followed show as the evaluator reads it, with its stored episodes.
    public static func shows(subscriptions: [FeedSubscription], entries: [FeedEntry]) -> [ListeningRuleShow] {
        let bySubscription = Dictionary(grouping: entries, by: \.subscriptionId)
        return subscriptions.map {
            ListeningRuleShow(id: $0.id, member: FollowListEditing.member(for: $0), entries: bySubscription[$0.id] ?? [])
        }
    }

    // MARK: The New rule form

    public enum ActionChoice: String, CaseIterable, Identifiable, Sendable {
        case skip, pick
        public var id: String { rawValue }
        public var label: String { self == .skip ? "Skip" : "Mark as a pick" }
        public var action: ListeningRuleAction { self == .skip ? .skip : .more }
    }

    public struct ScopeChoice: Equatable, Hashable, Identifiable, Sendable {
        public var scope: ListeningRuleScope
        public var label: String
        public var id: String {
            switch scope {
            case .any: "any"
            case .list(let id): "list:\(id)"
            case .show(let member): "show:\(member.feedKey)"
            }
        }
    }

    /// "From": Any show, then the lists (chip order), then the followed shows (alphabetical).
    public static func scopeChoices(
        lists: [FollowList], subscriptions: [FeedSubscription]
    ) -> (any: ScopeChoice, lists: [ScopeChoice], shows: [ScopeChoice]) {
        let listChoices = FollowListName.chipOrder(lists).map { ScopeChoice(scope: .list($0.id), label: $0.name) }
        var seen = Set<ListMember>()
        let showChoices = subscriptions
            .map { (member: FollowListEditing.member(for: $0), title: FollowingShowRows.displayTitle(of: $0)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .filter { seen.insert($0.member).inserted }
            .map { ScopeChoice(scope: .show($0.member), label: $0.title) }
        return (ScopeChoice(scope: .any, label: "Any show"), listChoices, showChoices)
    }

    /// The form's words problem to show under the field, nil while the field is still empty (Save is disabled then, with
    /// nothing to scold) or the words are fine.
    public static func wordsProblem(_ field: String) -> ListeningRuleWords.Problem? {
        guard case .invalid(let problem) = ListeningRuleWords.validate(ListeningRuleWords.split(field)) else { return nil }
        return problem == .noWords ? nil : problem
    }

    /// Save is enabled once the field holds at least one valid word.
    public static func canSave(wordsField: String) -> Bool {
        if case .valid = ListeningRuleWords.validate(ListeningRuleWords.split(wordsField)) { return true }
        return false
    }

    /// The Rule screen's Words field, as the stored words joined back with commas.
    public static func wordsField(for rule: ListeningRule) -> String { rule.words.joined(separator: ", ") }

    // MARK: The Show screen

    /// "Skipped by your rules (<n>)".
    public static func skippedHeader(count: Int) -> String { "Skipped by your rules (\(count))" }

    /// "Skipped: about “crypto”".
    public static func skippedLine(word: String) -> String { "Skipped: about “\(word)”" }

    // MARK: Helpers

    static func showTitle(for scope: ListeningRuleScope, subscriptions: [FeedSubscription]) -> String? {
        guard case .show(let member) = scope else { return nil }
        return subscriptions.first {
            let candidate = FollowListEditing.member(for: $0)
            return member.matches(feedKey: candidate.feedKey, podcastGUID: candidate.podcastGUID)
        }.map(FollowingShowRows.displayTitle(of:))
    }

    static func listName(for scope: ListeningRuleScope, lists: [FollowList]) -> String? {
        guard case .list(let id) = scope else { return nil }
        return lists.first { $0.id == id }?.name
    }
}
