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

    /// Stores a list's shows and returns the links that were new (already waiting, already followed and not-a-feed links
    /// are skipped), so an Undo can take back exactly those and not a show an earlier arrival of the same list suggested.
    @discardableResult
    func merge(urls: [String], listKey: String, listTitle: String?, followed: Set<String>, now: Date = Date()) -> [String] {
        let before = Set(store.all().compactMap { FeedURLKey.make($0.url) })
        store.merge(urls: urls, listKey: listKey, listTitle: listTitle, addedAt: now, followed: followed)
        reload()
        let after = Set(store.all().compactMap { FeedURLKey.make($0.url) })
        var seen = Set<String>()
        return urls.filter { url in
            guard let key = FeedURLKey.make(url), after.contains(key), !before.contains(key) else { return false }
            return seen.insert(key).inserted
        }
    }

    /// Undo of an arrival: the shows it suggested go back out.
    func remove(urls: [String]) {
        store.remove(urls: urls)
        reload()
    }

    func reload() {
        let stored = store.all()
        if stored != suggestions { suggestions = stored }
    }
}
