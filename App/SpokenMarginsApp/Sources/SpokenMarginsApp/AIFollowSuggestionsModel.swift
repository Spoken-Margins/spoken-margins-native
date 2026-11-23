import Foundation
import SessionKit

/// The shows the listener's own AI suggested following, as the app holds them (#4683, Design section 2h). The store is
/// `AIFollowSuggestions` in SessionKit; this keeps what it holds in a published array so Following can draw a count and a
/// title from it. The row itself is PR 3c; until then a link list's follow entries are only stored here.
@MainActor
final class AIFollowSuggestionsModel: ObservableObject {
    let store: AIFollowSuggestions
    @Published private(set) var suggestions: [AIFollowSuggestions.Suggestion]

    init(store: AIFollowSuggestions = AIFollowSuggestions()) {
        self.store = store
        suggestions = store.all()
    }

    /// Stores a list's shows and returns how many were new (already waiting, already followed and not-a-feed links are skipped).
    @discardableResult
    func merge(urls: [String], listKey: String, listTitle: String?, followed: Set<String>, now: Date = Date()) -> Int {
        let added = store.merge(urls: urls, listKey: listKey, listTitle: listTitle, addedAt: now, followed: followed)
        reload()
        return added
    }

    /// Undo of an arrival: the suggestions that list brought go back out.
    func remove(listKey: String) {
        store.remove(listKey: listKey)
        reload()
    }

    func reload() {
        let stored = store.all()
        if stored != suggestions { suggestions = stored }
    }
}
