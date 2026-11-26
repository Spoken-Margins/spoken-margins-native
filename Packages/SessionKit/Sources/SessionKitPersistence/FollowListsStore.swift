import Foundation
import SessionKit

/// Follow lists (#4046 PR 2) read and written off the main thread. The app's screens never call the synchronous
/// store for lists: each edit is one call here, which loads the lists as stored, applies `FollowListEditing`, saves,
/// and answers with the lists as they now are. One actor per store, so two quick taps run one after the other and the
/// second sees the first's result.
public actor FollowListsStore {
    /// The lists after a change, and why a name was refused (nil when the change was made).
    public struct Change: Equatable, Sendable {
        public var lists: [FollowList]
        public var problem: FollowListName.Problem?
        /// The list that was created or renamed.
        public var changedListID: String?
    }

    private let store: SQLiteSessionStore

    public init(store: SQLiteSessionStore) {
        self.store = store
    }

    public func lists() throws -> [FollowList] {
        try store.loadFollowLists()
    }

    /// A new list. `member` is ticked in it from the start when the listener made it from a show's sheet.
    public func create(
        name: String,
        adding member: ListMember? = nil,
        id: String = UUID().uuidString,
        now: Date = Date()
    ) throws -> Change {
        let existing = try store.loadFollowLists()
        switch FollowListEditing.creating(name: name, adding: member, existing: existing, id: id, now: now) {
        case .invalid(let problem):
            return Change(lists: existing, problem: problem, changedListID: nil)
        case .created(let list):
            try store.saveFollowList(list)
            return Change(lists: try store.loadFollowLists(), problem: nil, changedListID: list.id)
        }
    }

    public func rename(id: String, to name: String) throws -> Change {
        let existing = try store.loadFollowLists()
        switch FollowListEditing.renaming(id: id, to: name, in: existing) {
        case .missing:
            return Change(lists: existing, problem: nil, changedListID: nil)
        case .invalid(let problem):
            return Change(lists: existing, problem: problem, changedListID: nil)
        case .renamed(let list):
            try store.saveFollowList(list)
            return Change(lists: try store.loadFollowLists(), problem: nil, changedListID: list.id)
        }
    }

    /// Deleting a list never unfollows a show.
    public func delete(id: String) throws -> [FollowList] {
        try store.deleteFollowList(id: id)
        return try store.loadFollowLists()
    }

    /// Ticks or unticks a show in one list. A list that no longer exists is left alone.
    public func setMembership(of member: ListMember, inList listID: String, isMember: Bool) throws -> [FollowList] {
        if var list = try store.loadFollowList(id: listID) {
            let changed = isMember
                ? list.add(member)
                : list.remove(feedKey: member.feedKey, podcastGUID: member.podcastGUID)
            if changed { try store.saveFollowList(list) }
        }
        return try store.loadFollowLists()
    }

    /// Puts a show back in the lists it was in (Undo after an unfollow). A list deleted since is skipped.
    public func restore(member: ListMember, toLists listIDs: [String]) throws -> [FollowList] {
        for id in listIDs {
            guard var list = try store.loadFollowList(id: id) else { continue }
            if list.add(member) { try store.saveFollowList(list) }
        }
        return try store.loadFollowLists()
    }

    /// An edit worked out from the lists as stored now, in one step on this actor, so a list made meanwhile is seen (an
    /// import's "Lists in this file" merges into it instead of duplicating it, #4046 PR 5). `change` gets the stored lists
    /// and returns the lists to save (new or changed) and a value for the caller.
    public func update<Value: Sendable>(
        _ change: @Sendable ([FollowList]) -> (save: [FollowList], value: Value)
    ) throws -> (lists: [FollowList], value: Value) {
        let made = change(try store.loadFollowLists())
        try store.withTransaction {
            for list in made.save { try store.saveFollowList(list) }
        }
        return (try store.loadFollowLists(), made.value)
    }

    /// Unfollow: the show leaves every list. Returns the lists it was in (for Undo) and the lists as they now are.
    public func removeFromAllLists(feedKey: String?, podcastGUID: String? = nil) throws -> (leftIDs: [String], lists: [FollowList]) {
        let left = try store.removeFromFollowLists(feedKey: feedKey, podcastGUID: podcastGUID)
        return (left, try store.loadFollowLists())
    }
}
