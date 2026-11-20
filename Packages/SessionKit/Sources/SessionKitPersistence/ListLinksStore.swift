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
}
