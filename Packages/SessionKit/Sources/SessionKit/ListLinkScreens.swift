import Foundation

// A list added by its web address (#4046 PR 7a, 7b, 8): the words the Follow sheet, the "Add <list>" preview, a list's
// Updates section, the change card and the "Changes to <list>" sheet show, and the rules for naming such a list, applying a
// reviewed change and turning a show down. Pure, so every string and every case is a host test; the SwiftUI only draws it.

/// The words of lists that update from a web address.
public enum ListLinkWords {
    // MARK: Follow sheet (PR 7a)

    public static let pasteLabel = "Paste a link to a show or a list"
    public static let pasteHint = "Follows the show, or opens the list, from the link you copied."
    public static let fieldFooter = "Or type a link to a show’s feed or to a list of shows."
    public static let unreachable = "Couldn’t reach that address. Check the link, or try again when you’re online."
    public static let notAListOrFeed = "That link isn’t a show’s feed or a list of shows."
    public static let tooBigToAdd = "That list is too big to add (more than 500 shows)."

    // MARK: "Add <list title>" preview (PR 7a), and including a list (PR 8)

    public static func previewTitle(_ title: String) -> String { "Add \(title)" }
    public static func includeTitle(_ title: String) -> String { "Include \(title)" }

    public static func previewDetail(host: String) -> String {
        "From \(host). Spoken Margins checks this address when you check for new episodes, and asks you before anything changes."
    }

    public static let fetching = "Fetching the list…"
    public static let leftOut = "Some included lists were left out: they went deeper than 3 levels or repeated."

    /// "Add list and follow 3", or "Add list" when every show is already followed or none is ticked. Including a list in
    /// one of the listener's own reads "Include list and follow 3" and "Include list".
    public static func addButton(toFollow: Int, including: Bool = false) -> String {
        let verb = including ? "Include list" : "Add list"
        return toFollow > 0 ? "\(verb) and follow \(toFollow)" : verb
    }

    public static func viaLine(_ title: String) -> String { "via \(title)" }

    /// The list's title: the file's `<head><title>`, else its file name without `.opml`, else the host.
    public static func listTitle(documentTitle: String?, url: String) -> String {
        if let title = documentTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        let components = URLComponents(string: url)
        let last = (components?.path ?? "").split(separator: "/").last.map(String.init)?.removingPercentEncoding ?? ""
        var name = last
        if name.lowercased().hasSuffix(".opml") { name = String(name.dropLast(5)) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return host(url)
    }

    /// The web address a pasted or typed link names, for the list probe: http or https with a host that has a dot. A link
    /// with no scheme is read as https. Anything else (another scheme, words, a bare name) is nil, and the follow path
    /// handles it as before.
    public static func webURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: withScheme),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, host.contains("."), let url = components.url else { return nil }
        return url
    }

    /// The address's host without a leading `www.`, or the text itself when it has none.
    public static func host(_ url: String) -> String {
        guard let host = URLComponents(string: url)?.host, !host.isEmpty else { return url }
        return host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The address as the Updates section shows it: host and path, with no scheme, query or trailing slash
    /// ("github.com/sam/lists/commute.opml"). A query can hold a token, so it is never shown.
    public static func address(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host, !host.isEmpty else { return url }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        return host.lowercased() + path
    }

    // MARK: A list's Updates section (PR 7a)

    public static let updatesHeader = "Updates"
    public static let checking = "Checking…"
    public static let checkNow = "Check now"
    public static let stopUpdates = "Stop updates and keep as mine"
    public static let stopIncluding = "Stop including"
    public static let stopUpdatesButton = "Stop updates"

    /// One status line per link.
    public static func statusLine(
        for link: ListLink,
        isChecking: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        if isChecking { return checking }
        func time(_ date: Date?) -> String? {
            date.map { ListStatusWords.time($0, now: now, calendar: calendar, locale: locale) }
        }
        let keep = " Your shows stay as they are."
        switch link.status {
        case .ok:
            guard let checked = time(link.lastCheckedAt) else { return "Not checked yet" }
            return "Checked \(checked)"
        case .unreachable:
            guard let at = time(link.statusAt) else { return "Couldn’t reach it." + keep }
            return "Couldn’t reach it \(at)." + keep
        case .gone: return "This list is no longer at its address." + keep
        case .notAList: return "This address isn’t a list of shows any more." + keep
        case .tooBig: return "This list is too big to read (over 4 MB)." + keep
        }
    }

    public static func stopUpdatesQuestion(listName: String) -> String { "Stop updates to \(listName)?" }
    public static func stopUpdatesMessage(host: String) -> String { "You keep its shows. Changes at \(host) won’t reach you." }
    public static func stopIncludingQuestion(title: String) -> String { "Stop including \(title)?" }
    public static func stopIncludingMessage(listName: String) -> String { "Its shows stay in \(listName)." }

    // MARK: Lists screen and chips

    /// VoiceOver for a chip whose list updates from a link.
    public static func chipAccessibilityLabel(listName: String) -> String { "\(listName), updates from its link" }

    /// The Lists screen row's second line for a list that updates: "3 shows · Updates from github.com".
    public static func overviewSubtitle(showCount: String, ownLink: ListLink?) -> String {
        guard let ownLink else { return showCount }
        return "\(showCount) · Updates from \(host(ownLink.url))"
    }

    public static let addListByLink = "Add a list by link"
    public static let includeListByLink = "Include a list by link"
    public static let includeAddressTitle = "Include a list"
    public static let includeAddressMessage = "Paste the web address of a list of shows."

    // MARK: Change card and "Changes to <list>" sheet (PR 7b)

    /// "Commute changed: 3 added, 1 removed". A side that is zero is left out, and one show is singular.
    public static func changeCard(listName: String, proposal: ListProposal) -> String {
        var parts: [String] = []
        if !proposal.added.isEmpty { parts.append("\(proposal.added.count) added") }
        if !proposal.removed.isEmpty { parts.append("\(proposal.removed.count) removed") }
        return "\(listName) changed: " + parts.joined(separator: ", ")
    }

    /// "2 lists changed", for two or more.
    public static func changeCard(listCount: Int) -> String { "\(listCount) lists changed" }

    public static let review = "Review"

    public static func changesTitle(listName: String) -> String { "Changes to \(listName)" }

    public static func changesHeader(
        host: String, checkedAt: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        "From \(host) · checked \(ListStatusWords.time(checkedAt, now: now, calendar: calendar, locale: locale))"
    }

    public static func addedHeader(_ count: Int) -> String { "Added (\(count))" }
    public static func removedHeader(_ count: Int) -> String { "Removed (\(count))" }
    public static let addedFooter = "Ticked shows are followed and put in this list. Unticked ones won’t be offered again."
    public static let removedFooter = "Ticked shows leave this list. You keep following them."
    public static let tickAll = "Tick all"
    public static let apply = "Apply"

    // MARK: Sharing (PR 5)

    public static let shareList = "Share list"
    public static let exportAllFollows = "Export all follows"
    public static let shareListFooter = "Sends a file any podcast app can open. To keep friends up to date, put the file at a web address you control, such as GitHub or your own site, and send them the link. After you change the list, share it again and replace the file."
    public static let exportAllFooter = "For you or another podcast app. Private feeds are left out: their links work like a password."

    /// The switch above Share when the list has rules (PR 13), off by default.
    public static func includeRulesSwitch(_ count: Int) -> String { "Include this list’s rules (\(count))" }
}

/// The name a list added by its web address gets (#4046 PR 7a). It never merges into a list of the same name, so the
/// address can never take over the listener's own shows (Default 20): a taken name becomes "<title> (2)", "<title> (3)" and
/// so on. Commas become spaces, slashes stay, and the name fits in 40 characters with its number.
public enum ListLinkNaming {
    public static func name(forTitle raw: String, existing: [FollowList]) -> String {
        var base = FollowListName.cleaned(raw.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "，", with: " "))
        if base.isEmpty { base = "List" }
        let first = cut(base, toFit: 0)
        guard existing.contains(where: { FollowListName.sameName($0.name, first) }) else { return first }
        var number = 2
        while true {
            let suffix = " (\(number))"
            let candidate = cut(base, toFit: suffix.count) + suffix
            if !existing.contains(where: { FollowListName.sameName($0.name, candidate) }) { return candidate }
            number += 1
        }
    }

    /// `name` cut so that it and `reserved` more characters fit in `FollowListName.maxLength`, without a trailing space.
    private static func cut(_ name: String, toFit reserved: Int) -> String {
        let room = max(1, FollowListName.maxLength - reserved)
        guard name.count > room else { return name }
        return FollowListName.cleaned(String(name.prefix(room)))
    }
}

/// One row of the "Add <list>" preview.
public struct ListLinkPreviewRow: Equatable, Sendable, Identifiable {
    /// Stable within one preview ("show:0", "show:1"...), so the screen can keep a tick per row.
    public let id: String
    public let show: ProposedShow
}

/// What the "Add <list>" preview offers (#4046 PR 7a, and PR 8 for including a list): the shows to follow, ticked, and
/// the ones already followed, which join the list without a tick.
public struct ListLinkPreviewPlan: Equatable, Sendable {
    public var title: String
    public var host: String
    public var toFollow: [ListLinkPreviewRow]
    public var alreadyFollowed: [ListLinkPreviewRow]
    /// Some included list was left out (deeper than three levels, repeated, or unreadable).
    public var leftOut: Bool

    public init(
        shows: [ProposedShow], documentTitle: String?, url: String, leftOut: Bool, subscriptions: [FeedSubscription]
    ) {
        title = ListLinkWords.listTitle(documentTitle: documentTitle, url: url)
        host = ListLinkWords.host(url)
        self.leftOut = leftOut
        let followed = subscriptions.map { FollowListEditing.member(for: $0) }
        var toFollow: [ListLinkPreviewRow] = []
        var already: [ListLinkPreviewRow] = []
        for (index, show) in shows.enumerated() {
            let row = ListLinkPreviewRow(id: "show:\(index)", show: show)
            if followed.contains(where: { show.member.matches(feedKey: $0.feedKey, podcastGUID: $0.podcastGUID) }) {
                already.append(row)
            } else {
                toFollow.append(row)
            }
        }
        self.toFollow = toFollow
        alreadyFollowed = already
    }

    /// Every row starts ticked.
    public var defaultSelection: Set<String> { Set(toFollow.map(\.id)) }

    /// What adding the list leaves behind once the ticked shows were followed.
    public struct Outcome: Equatable, Sendable {
        /// The list's shows: those already followed and those that ended up followed, in file order.
        public var members: [ListMember]
        /// What the link remembers as taken from it: the same shows.
        public var accepted: [ListMember]
        /// Unticked shows, never offered again from this address. A show whose follow failed is in neither set, so the
        /// next check offers it again.
        public var rejected: [ListMember]
    }

    /// - Parameters:
    ///   - ticked: the ids of the ticked rows.
    ///   - followedFeedKeys: the feed keys of the ticked shows that ended up followed.
    public func outcome(ticked: Set<String>, followedFeedKeys: Set<String>) -> Outcome {
        var members: [ListMember] = []
        var rejected: [ListMember] = []
        let order = (toFollow + alreadyFollowed).sorted { Self.index($0.id) < Self.index($1.id) }
        for row in order {
            if alreadyFollowed.contains(where: { $0.id == row.id }) {
                members.append(row.show.member)
            } else if !ticked.contains(row.id) {
                rejected.append(row.show.member)
            } else if followedFeedKeys.contains(row.show.member.feedKey) {
                members.append(row.show.member)
            }
        }
        return Outcome(members: members, accepted: members, rejected: rejected)
    }

    private static func index(_ id: String) -> Int { Int(id.split(separator: ":").last ?? "") ?? 0 }
}

/// Applying a reviewed change from a list's address (#4046 PR 7b), and the other edits that teach a link what the listener
/// accepted or turned down. Pure: the store saves what these return.
public enum ListLinkEdits {
    /// The link and its list after **Apply** on the "Changes to <list>" sheet.
    /// - Parameters:
    ///   - tickedAdded: feed keys of the added shows the listener ticked.
    ///   - tickedRemoved: feed keys of the removed shows the listener ticked.
    ///   - followedFeedKeys: the ticked added shows that ended up followed. A ticked show whose follow failed is neither
    ///     accepted nor turned down, so the next check offers it again.
    ///   - reviewed: the proposal's `checkedAt` as the sheet showed it. When the stored proposal is another one (a newer check
    ///     replaced it, or a second tap already applied it), nothing changes, so a double tap applies once.
    /// - Returns: nil when there is nothing to apply.
    public static func applying(
        link: ListLink,
        list: FollowList,
        reviewed: Date,
        tickedAdded: Set<String>,
        tickedRemoved: Set<String>,
        followedFeedKeys: Set<String>
    ) -> (link: ListLink, list: FollowList)? {
        guard let proposal = link.pending, proposal.checkedAt == reviewed else { return nil }
        var link = link
        var list = list
        for show in proposal.added {
            let member = show.member
            if !tickedAdded.contains(member.feedKey) {
                appendOnce(member, to: &link.rejectedMembers)
            } else if followedFeedKeys.contains(member.feedKey) {
                list.add(member)
                appendOnce(member, to: &link.acceptedMembers)
            }
        }
        for member in proposal.removed {
            // Either way it is no longer a show taken from this address: ticked, it leaves the list; unticked, the listener
            // keeps it as their own, so the address can't offer to remove it again.
            link.acceptedMembers.removeAll { $0.matches(feedKey: member.feedKey, podcastGUID: member.podcastGUID) }
            if tickedRemoved.contains(member.feedKey) {
                list.remove(feedKey: member.feedKey, podcastGUID: member.podcastGUID)
            }
        }
        link.pending = nil
        return (link, list)
    }

    /// A show taken out of a list by hand, or unfollowed: each link that had it as accepted now has it as turned down, so
    /// the next check doesn't offer it back. Returns only the links that changed.
    /// - Parameter listID: only that list's links (removing from one list); nil for every link (unfollow).
    public static func rejecting(_ member: ListMember, in links: [ListLink], listID: String? = nil) -> [ListLink] {
        links.compactMap { link in
            guard listID == nil || link.listId == listID,
                  link.acceptedMembers.contains(where: { $0.matches(feedKey: member.feedKey, podcastGUID: member.podcastGUID) })
            else { return nil }
            var changed = link
            changed.acceptedMembers.removeAll { $0.matches(feedKey: member.feedKey, podcastGUID: member.podcastGUID) }
            appendOnce(member, to: &changed.rejectedMembers)
            if var pending = changed.pending {
                pending.removed.removeAll { $0.matches(feedKey: member.feedKey, podcastGUID: member.podcastGUID) }
                changed.pending = pending.isEmpty ? nil : pending
            }
            return changed
        }
    }

    private static func appendOnce(_ member: ListMember, to members: inout [ListMember]) {
        guard !members.contains(where: { $0.matches(feedKey: member.feedKey, podcastGUID: member.podcastGUID) }) else { return }
        members.append(member)
    }
}

/// Which lists' addresses have a change waiting, for the card on Following (#4046 PR 7b).
public enum ListChangeCard {
    /// The links with a waiting change whose list still exists, in the chips' order of their lists (alphabetical), so
    /// **Review** opens them one after another in that order.
    public static func waiting(links: [ListLink], lists: [FollowList]) -> [ListLink] {
        let ordered = FollowListName.chipOrder(lists)
        return links
            .filter { link in link.pending.map { !$0.isEmpty } ?? false }
            .compactMap { link -> (Int, ListLink)? in
                guard let position = ordered.firstIndex(where: { $0.id == link.listId }) else { return nil }
                return (position, link)
            }
            .sorted { $0.0 == $1.0 ? $0.1.id < $1.1.id : $0.0 < $1.0 }
            .map(\.1)
    }

    /// The card's line, or nil with nothing waiting: one list names it and its counts; two or more say how many lists.
    public static func text(links: [ListLink], lists: [FollowList]) -> String? {
        let waiting = waiting(links: links, lists: lists)
        guard let first = waiting.first, let proposal = first.pending else { return nil }
        let listIDs = Set(waiting.map(\.listId))
        if listIDs.count > 1 { return ListLinkWords.changeCard(listCount: listIDs.count) }
        guard waiting.count == 1 else { return ListLinkWords.changeCard(listCount: waiting.count) }
        let name = lists.first { $0.id == first.listId }?.name ?? first.title
        return ListLinkWords.changeCard(listName: name, proposal: proposal)
    }
}

/// What a list's own screen shows about its addresses (#4046 PR 7a, 8).
public enum ListLinkScreens {
    /// The list's links: its own address first, then the lists it includes, oldest first.
    public static func links(ofList listID: String, in links: [ListLink]) -> [ListLink] {
        links.filter { $0.listId == listID }.sorted { lhs, rhs in
            if lhs.role != rhs.role { return lhs.role == .own }
            return lhs.id < rhs.id
        }
    }

    /// The list's own address, when it updates from one.
    public static func ownLink(ofList listID: String, in links: [ListLink]) -> ListLink? {
        links.first { $0.listId == listID && $0.role == .own }
    }

    /// "via <list title>" for a show the list took from one of its addresses; nil for a show the listener put there.
    public static func viaTitle(for member: ListMember, listID: String, links: [ListLink]) -> String? {
        self.links(ofList: listID, in: links).first { link in
            link.acceptedMembers.contains { $0.matches(feedKey: member.feedKey, podcastGUID: member.podcastGUID) }
        }?.title
    }

    /// The ids of the lists that update from their own address, for the chips' link mark.
    public static func updatingListIDs(_ links: [ListLink]) -> Set<String> {
        Set(links.filter { $0.role == .own }.map(\.listId))
    }

    /// A new link record for a list just added or included from its address.
    public static func link(
        id: String = UUID().uuidString,
        listID: String,
        url: String,
        title: String,
        role: ListLink.Role,
        etag: String?,
        lastModified: String?,
        accepted: [ListMember],
        rejected: [ListMember],
        now: Date
    ) -> ListLink {
        ListLink(
            id: id, listId: listID, url: url, title: title, role: role, etag: etag, lastModified: lastModified,
            lastCheckedAt: now, status: .ok, statusAt: now, acceptedMembers: accepted, rejectedMembers: rejected)
    }
}

/// Which opened files are lists of shows (#4046 PR 5). The app declares `org.opml.opml` (`.opml`), so Files, Mail and
/// AirDrop offer Spoken Margins for one; such a file opens the import preview, never the Library.
public enum OPMLOpenRouter {
    public static let fileExtension = "opml"

    public static func opens(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == fileExtension
    }
}
