import Foundation
import SessionKit

// Sharing and importing lists with what they carry beyond shows (#4046 PR 5, 8, 13): the lists a file includes by web
// address, the rules it carries in our namespace, the import button's words, and one list written out with its includes and,
// when the listener switched it on, its rules. Nothing here fetches or follows.

/// A list the file includes by its web address (`type="include"`), as the import screen offers it: "<title> updates from
/// its web address", with a switch that starts on.
public struct OPMLPlannedInclude: Equatable, Sendable, Identifiable {
    /// Stable within one preview ("include:0"...).
    public var id: String
    public var title: String
    public var url: String
    /// The shows the file says came in through this list (`sm:via` with its title), so the friend's copy starts with them
    /// accepted and the next check offers only what changed since.
    public var members: [ListMember]

    public var rowText: String { "\(title) updates from its web address" }
}

enum OPMLIncludePlanner {
    static func plan(_ document: OPMLDocument) -> [OPMLPlannedInclude] {
        var seen = Set<String>()
        var planned: [OPMLPlannedInclude] = []
        for include in document.includes {
            guard let key = FeedURLKey.make(include.url), seen.insert(key).inserted else { continue }
            let members = document.feeds.compactMap { feed -> ListMember? in
                guard let via = feed.sm.via, FollowListName.sameName(via, include.title),
                      let feedKey = FeedURLKey.make(feed.feedURL) else { return nil }
                return ListMember(feedKey: feedKey, podcastGUID: feed.podcastGUID)
            }
            planned.append(OPMLPlannedInclude(id: "include:\(planned.count)", title: include.title, url: include.url, members: members))
        }
        return planned
    }
}

/// A rule a file carries for one show (`sm:skip` or `sm:more`). It arrives switched off.
public struct OPMLPlannedRule: Equatable, Sendable {
    public var member: ListMember
    public var action: ListeningRuleAction
    /// Valid words (`ListeningRuleWords.validate`); a row whose words are all invalid carries no rule.
    public var words: [String]
    /// The list it came from, for the origin line "From <list>": the show's first list in the file, else the file's title.
    public var listName: String
}

enum OPMLRulePlanner {
    static func plan(_ document: OPMLDocument) -> [OPMLPlannedRule] {
        var planned: [OPMLPlannedRule] = []
        var seenKeys = Set<String>()
        for feed in document.feeds {
            guard let key = FeedURLKey.make(feed.feedURL), seenKeys.insert(key).inserted else { continue }
            let member = ListMember(feedKey: key, podcastGUID: feed.podcastGUID)
            let name = feed.listNames.first.map(OPMLListPlanner.cut) ?? document.title.map(OPMLListPlanner.cut) ?? ""
            let listName = name.isEmpty ? "a shared list" : name
            for (action, raw) in [(ListeningRuleAction.skip, feed.sm.skip), (.more, feed.sm.more)] where !raw.isEmpty {
                guard case .valid(let words) = ListeningRuleWords.validate(raw) else { continue }
                planned.append(OPMLPlannedRule(member: member, action: action, words: words, listName: listName))
            }
        }
        return planned
    }
}

extension OPMLImportPreview {
    /// "This file has <n> rules. They arrive switched off. Turn them on in Rules."; nil when it has none.
    public var rulesLine: String? {
        guard !rules.isEmpty else { return nil }
        let count = rules.count == 1 ? "1 rule" : "\(rules.count) rules"
        return "This file has \(count). They arrive switched off. Turn them on in Rules."
    }
}

/// The import screen's words for lists (#4046 PR 5).
public enum OPMLImportListWords {
    public static let sectionTitle = "Lists in this file"
    public static let footer = "Each list is your own copy. It won’t change when the sender changes theirs."
    public static let includesTitle = "Lists that update"

    /// "Commute · 3 shows".
    public static func row(_ list: OPMLPlannedList) -> String { "\(list.name) · \(FollowListWords.showCount(list.showCount))" }

    /// "Adds to your list Commute", when the listener already has a list by that name.
    public static func mergeLine(_ list: OPMLPlannedList, existing: [FollowList]) -> String? {
        guard let id = list.mergesIntoListId, let name = existing.first(where: { $0.id == id })?.name else { return nil }
        return "Adds to your list \(name)"
    }

    /// The import button. "Follow 3" while shows are ticked; "Add lists" when nothing needs following but a list that is
    /// on holds a show the listener already follows, so a friend's list of shows they follow can still be imported; else
    /// "Follow", disabled.
    public static func primaryButton(
        ticked: Int, preview: OPMLImportPreview, listsOn: Set<String>
    ) -> (title: String, isEnabled: Bool) {
        if ticked > 0 { return ("Follow \(ticked)", true) }
        let followed = Set(preview.alreadyFollowed.compactMap { FeedURLKey.make($0.feedURL) })
        let addsToAList = preview.lists.contains { list in
            listsOn.contains(list.id) && list.members.contains { followed.contains($0.feedKey) }
        }
        return addsToAList ? ("Add lists", true) : ("Follow", false)
    }

    /// The line after an import that saved lists: "Added 2 lists.", "Added shows to 1 list you had.", or
    /// "Added 2 lists, and shows to 1 list you had."; nil when no list changed.
    public static func resultLine(_ result: OPMLListImportResult) -> String? {
        func lists(_ count: Int) -> String { count == 1 ? "1 list" : "\(count) lists" }
        switch (result.createdCount, result.mergedCount) {
        case (0, 0): return nil
        case (let created, 0): return "Added \(lists(created))."
        case (0, let merged): return "Added shows to \(lists(merged)) you had."
        case (let created, let merged): return "Added \(lists(created)), and shows to \(lists(merged)) you had."
        }
    }
}

/// What importing a file's includes does (#4046 PR 8): each include switched on becomes an include link on the list the
/// file was shared from. The imported list is the friend's own copy; only the included part updates.
public enum OPMLIncludeImporter {
    /// The list the includes attach to, among the lists the import just saved or added to: the one named like the file's
    /// title (a shared list is titled with its name), else the only list switched on. nil when neither fits, and then the
    /// include rows are not offered.
    public static func targetList(preview: OPMLImportPreview, listsOn: Set<String>) -> OPMLPlannedList? {
        let on = preview.lists.filter { listsOn.contains($0.id) }
        if let title = preview.documentTitle, let named = on.first(where: { FollowListName.sameName($0.name, title) }) { return named }
        return on.count == 1 ? on.first : nil
    }

    /// The include links to save. Each starts with the shows the file said came through it, those that ended up followed,
    /// as accepted, and is read for the first time on the listener's next check.
    public static func links(
        _ includes: [OPMLPlannedInclude],
        switchedOn: Set<String>,
        listID: String,
        followedFeedKeys: Set<String>,
        existing: [ListLink],
        makeId: () -> String = { UUID().uuidString }
    ) -> [ListLink] {
        includes.filter { switchedOn.contains($0.id) }.compactMap { include in
            let key = FeedURLKey.make(include.url)
            // The same address already included in this list: nothing new.
            guard !existing.contains(where: { $0.listId == listID && FeedURLKey.make($0.url) == key }) else { return nil }
            return ListLink(
                id: makeId(), listId: listID, url: include.url, title: include.title, role: .include,
                acceptedMembers: include.members.filter { followedFeedKeys.contains($0.feedKey) })
        }
    }
}

/// What importing a file's rules does (#4046 PR 13): a show-scoped rule per show and action, switched off, from "<list>",
/// only for shows the listener ends up following. A rule the listener already has is not added twice, and the 200-rule
/// limit holds.
public enum OPMLRulesImporter {
    public static func rules(
        _ planned: [OPMLPlannedRule],
        followedFeedKeys: Set<String>,
        existing: [ListeningRule],
        now: Date = Date(),
        makeId: () -> String = { UUID().uuidString }
    ) -> [ListeningRule] {
        var kept = existing.count
        var made: [ListeningRule] = []
        for plan in planned where followedFeedKeys.contains(plan.member.feedKey) {
            let scope = ListeningRuleScope.show(plan.member)
            let duplicate = (existing + made).contains { rule in
                rule.action == plan.action && rule.scope == scope && Self.signature(rule.words) == Self.signature(plan.words)
            }
            guard !duplicate, ListeningRuleWords.hasRoom(forRulesAlreadyKept: kept) else { continue }
            made.append(ListeningRule(
                id: makeId(), action: plan.action, words: plan.words, scope: scope, origin: .list(plan.listName),
                isOn: false, createdAt: now))
            kept += 1
        }
        return made
    }

    static func signature(_ words: [String]) -> Set<String> { Set(words.map(OPMLExporter.foldedWord)) }
}

/// A show's rule words for an export (`sm:skip`, `sm:more`).
public struct OPMLExportRuleWords: Equatable, Sendable {
    public var skip: [String]
    public var more: [String]

    public init(skip: [String] = [], more: [String] = []) {
        self.skip = skip
        self.more = more
    }
}

extension OPMLExporter {
    /// One list as a file, with what makes it more than a snapshot (#4046 PR 8, 13):
    /// - each list it includes is written as an include row, and the shows taken from it carry `sm:via`;
    /// - a list that updates from its own address is written as an include row of that address, with its current shows as
    ///   `sm:via` rows, so a friend gets the live list and a reader that ignores includes still gets every show;
    /// - with `rules` (the share switch on), the rules that are on and scoped to the list or one of its shows are written on
    ///   each show as `sm:skip` and `sm:more`. A list rule goes on every show in the list; words are merged without case and
    ///   without repeats.
    public static func exportList(
        _ list: FollowList,
        subscriptions: [FeedSubscription],
        links: [ListLink],
        rules: [ListeningRule]? = nil,
        podcastGUIDs: [String: String] = [:],
        createdAt: Date = Date()
    ) -> OPMLExport {
        let members = subscriptions.filter { list.contains(feedKey: key(of: $0), podcastGUID: guid(of: $0, podcastGUIDs)) }
        let listLinks = ListLinkScreens.links(ofList: list.id, in: links)
        let includes = listLinks.map { OPMLExportInclude(title: $0.title, url: $0.url) }
        var via: [String: String] = [:]
        for subscription in members {
            let member = FollowListEditing.member(for: subscription, podcastGUID: guid(of: subscription, podcastGUIDs))
            if let title = ListLinkScreens.viaTitle(for: member, listID: list.id, links: links) { via[subscription.id] = title }
        }
        let words = rules.map { ruleWords(for: list, members: members, rules: $0, podcastGUIDs: podcastGUIDs) } ?? [:]
        return export(
            members, title: list.name, createdAt: createdAt, lists: [list], podcastGUIDs: podcastGUIDs,
            includes: includes, includedVia: via, ruleWords: words)
    }

    /// How many rules the share switch would carry: rules that are on and scoped to the list or one of its followed shows.
    public static func shareableRuleCount(_ list: FollowList, subscriptions: [FeedSubscription], rules: [ListeningRule]) -> Int {
        let members = subscriptions.filter { list.contains(feedKey: key(of: $0)) }.map { FollowListEditing.member(for: $0) }
        return rules.filter { rule in rule.isOn && covered(rule.scope, list: list, members: members) }.count
    }

    static func ruleWords(
        for list: FollowList, members: [FeedSubscription], rules: [ListeningRule], podcastGUIDs: [String: String]
    ) -> [String: OPMLExportRuleWords] {
        var result: [String: OPMLExportRuleWords] = [:]
        for subscription in members {
            let member = FollowListEditing.member(for: subscription, podcastGUID: guid(of: subscription, podcastGUIDs))
            var words = OPMLExportRuleWords()
            for rule in rules where rule.isOn {
                let applies: Bool
                switch rule.scope {
                case .list(let id): applies = id == list.id
                case .show(let scoped): applies = scoped.matches(feedKey: member.feedKey, podcastGUID: member.podcastGUID)
                case .any: applies = false
                }
                guard applies else { continue }
                if rule.action == .skip { merge(rule.words, into: &words.skip) } else { merge(rule.words, into: &words.more) }
            }
            if !words.skip.isEmpty || !words.more.isEmpty { result[subscription.id] = words }
        }
        return result
    }

    private static func covered(_ scope: ListeningRuleScope, list: FollowList, members: [ListMember]) -> Bool {
        switch scope {
        case .list(let id): return id == list.id
        case .show(let scoped): return members.contains { scoped.matches(feedKey: $0.feedKey, podcastGUID: $0.podcastGUID) }
        case .any: return false
        }
    }

    private static func merge(_ words: [String], into kept: inout [String]) {
        for word in words {
            let folded = foldedWord(word)
            guard !folded.isEmpty, !word.contains(","), !kept.contains(where: { foldedWord($0) == folded }) else { continue }
            kept.append(word.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// A word compared without case or diacritics, so "Crypto" and "crypto" are one.
    static func foldedWord(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func key(of subscription: FeedSubscription) -> String {
        FeedURLKey.make(subscription.source.canonicalURL) ?? subscription.source.canonicalURL
    }

    private static func guid(of subscription: FeedSubscription, _ podcastGUIDs: [String: String]) -> String? {
        OPMLListNames.normalizedGUID(ShareableLinkPolicy.shareableEpisodeGUID(OPMLListNames.normalizedGUID(podcastGUIDs[subscription.id])))
    }
}
