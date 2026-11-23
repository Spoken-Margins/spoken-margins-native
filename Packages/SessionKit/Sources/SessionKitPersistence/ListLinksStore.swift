import Foundation
import SessionKit

/// List links (#4046 PR 6) read and written off the main thread. The checker reaches the store only through this actor,
/// so a check that finishes while the listener edits the link writes through `ListLink.merging`, never over their change.
public actor ListLinksStore: ListLinkStoring {
    private let store: SQLiteSessionStore

    public init(store: SQLiteSessionStore) {
        self.store = store
    }

    public func listLinks() throws -> [ListLink] {
        try store.loadListLinks()
    }

    public func existingListIDs() throws -> Set<String> {
        Set(try store.loadFollowLists().map(\.id))
    }

    public func saveChecked(_ link: ListLink) throws {
        try store.saveCheckedListLink(link)
    }

    /// A list added from its address (#4046 PR 7a): the list, named so it never merges into one of the listener's, and its
    /// own link, saved together. The name is worked out here from the lists as stored now.
    /// - Returns: the lists and links as they now are, and the new list's id.
    public func addList(
        title: String,
        members: [ListMember],
        link: @Sendable (_ listID: String) -> ListLink,
        listID: String = UUID().uuidString,
        now: Date = Date()
    ) throws -> (lists: [FollowList], links: [ListLink], listID: String) {
        try store.withTransaction {
            let name = ListLinkNaming.name(forTitle: title, existing: try store.loadFollowLists())
            try store.saveFollowList(FollowList(id: listID, name: name, createdAt: now, members: members))
            try store.saveListLink(link(listID))
        }
        return (try store.loadFollowLists(), try store.loadListLinks(), listID)
    }

    /// Another list included in one of the listener's own (#4046 PR 8): its shows join the list and its link is saved. A
    /// list deleted meanwhile is left alone.
    public func addInclude(_ link: ListLink, members: [ListMember]) throws -> (lists: [FollowList], links: [ListLink]) {
        try store.withTransaction {
            guard var list = try store.loadFollowList(id: link.listId) else { return }
            for member in members { list.add(member) }
            try store.saveFollowList(list)
            try store.saveListLink(link)
        }
        return (try store.loadFollowLists(), try store.loadListLinks())
    }

    /// Links that arrived in a friend's file (#4046 PR 8), saved as they are.
    public func save(_ links: [ListLink]) throws -> [ListLink] {
        try store.withTransaction {
            for link in links { try store.saveListLink(link) }
        }
        return try store.loadListLinks()
    }

    /// **Apply** on the "Changes to <list>" sheet (#4046 PR 7b), against the link and list as stored now. Nothing changes
    /// when the change shown is no longer the one waiting (`ListLinkEdits.applying`), so a double tap applies once.
    public func apply(
        linkID: String, reviewed: Date, tickedAdded: Set<String>, tickedRemoved: Set<String>, followedFeedKeys: Set<String>
    ) throws -> (lists: [FollowList], links: [ListLink]) {
        try store.withTransaction {
            guard let link = try store.loadListLink(id: linkID), let list = try store.loadFollowList(id: link.listId),
                  let applied = ListLinkEdits.applying(
                    link: link, list: list, reviewed: reviewed, tickedAdded: tickedAdded,
                    tickedRemoved: tickedRemoved, followedFeedKeys: followedFeedKeys)
            else { return }
            try store.saveFollowList(applied.list)
            try store.saveListLink(applied.link)
        }
        return (try store.loadFollowLists(), try store.loadListLinks())
    }

    /// **Stop updates and keep as mine** and **Stop including**: the link goes, and the list keeps every show it has.
    public func delete(linkID: String) throws -> [ListLink] {
        try store.deleteListLink(id: linkID)
        return try store.loadListLinks()
    }

    /// A show taken out of a list by hand (`listID`), or unfollowed (nil: every link): the links that had accepted it now
    /// have it as turned down, so no check offers it back.
    public func reject(_ member: ListMember, listID: String? = nil) throws -> [ListLink] {
        try store.withTransaction {
            for link in ListLinkEdits.rejecting(member, in: try store.loadListLinks(), listID: listID) {
                try store.saveListLink(link)
            }
        }
        return try store.loadListLinks()
    }
}
