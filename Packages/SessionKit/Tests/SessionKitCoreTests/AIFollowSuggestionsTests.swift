import XCTest
@testable import SessionKit

/// #4683, Design section 2h: the shows a listener's own AI suggested, waiting on Following.
final class AIFollowSuggestionsTests: XCTestCase {
    private func makeStore() -> (AIFollowSuggestions, UserDefaults) {
        let suite = "AIFollowSuggestionsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (AIFollowSuggestions(defaults: defaults), defaults)
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_795_435_200 + seconds) }

    func testConstants() {
        XCTAssertEqual(AIFollowSuggestions.maxSuggestions, 20)
        XCTAssertEqual(AIFollowSuggestions.defaultsKey, "aiFollowSuggestionsV1")
    }

    func testMergeStoresRecordsOldestFirstAndSurvivesANewInstance() {
        let (store, defaults) = makeStore()
        XCTAssertEqual(store.all(), [])
        XCTAssertEqual(store.merge(urls: ["https://a.example/feed", "https://b.example/feed"], listKey: "L1", listTitle: "Brief", addedAt: at(10)), 2)
        XCTAssertEqual(store.merge(urls: ["https://c.example/feed"], listKey: "L0", listTitle: nil, addedAt: at(5)), 1)
        // Ordered by addedAt, not by when they were merged.
        XCTAssertEqual(store.all().map(\.url), ["https://c.example/feed", "https://a.example/feed", "https://b.example/feed"])
        XCTAssertEqual(store.all().map(\.listKey), ["L0", "L1", "L1"])
        XCTAssertEqual(AIFollowSuggestions(defaults: defaults).all(), store.all())
    }

    func testMergeDropsDuplicatesByFeedURLKey() {
        let (store, _) = makeStore()
        store.merge(urls: ["https://A.example/feed/"], listKey: "L1", listTitle: "First", addedAt: at(1))
        // Same feed: other case in the host, a trailing slash, a fragment, a repeat inside one list.
        let added = store.merge(
            urls: ["https://a.example/feed", "https://a.example/feed#top", "https://A.EXAMPLE/feed/", "https://d.example/feed", "https://d.example/feed/"],
            listKey: "L2", listTitle: "Second", addedAt: at(2))
        XCTAssertEqual(added, 1)
        XCTAssertEqual(store.all().map(\.url), ["https://A.example/feed/", "https://d.example/feed"])
        XCTAssertEqual(store.all().first?.listKey, "L1", "the first record keeps its list")
        XCTAssertEqual(store.merge(urls: ["https://a.example/feed"], listKey: "L3", listTitle: nil, addedAt: at(3)), 0)
    }

    func testMergeSkipsFollowedFeedsAndThingsThatAreNotLinks() {
        let (store, _) = makeStore()
        let followed: Set<String> = [FeedURLKey.make("https://followed.example/feed")!]
        let added = store.merge(
            urls: ["https://followed.example/feed/", "https://FOLLOWED.example/feed", "not a link", "", "https://new.example/feed"],
            listKey: "L1", listTitle: "Brief", addedAt: at(1), followed: followed)
        XCTAssertEqual(added, 1)
        XCTAssertEqual(store.all().map(\.url), ["https://new.example/feed"])
    }

    func testCapOfTwentyDropsTheOldestFirst() {
        let (store, _) = makeStore()
        for list in 0..<3 {
            let urls = (0..<10).map { "https://show\(list)-\($0).example/feed" }
            store.merge(urls: urls, listKey: "L\(list)", listTitle: "List \(list)", addedAt: at(TimeInterval(list)))
        }
        let all = store.all()
        XCTAssertEqual(all.count, 20)
        XCTAssertEqual(all.first?.url, "https://show1-0.example/feed", "list 0 went first")
        XCTAssertEqual(all.last?.url, "https://show2-9.example/feed")
        XCTAssertEqual(Set(all.map(\.listKey)), ["L1", "L2"])

        // One list at the cap on its own: all 10 of the newest list stay, and 10 of the older ones.
        store.merge(urls: ["https://extra.example/feed"], listKey: "L3", listTitle: nil, addedAt: at(9))
        XCTAssertEqual(store.all().count, 20)
        XCTAssertEqual(store.all().last?.url, "https://extra.example/feed")
        XCTAssertEqual(store.all().first?.url, "https://show1-1.example/feed")
    }

    func testRemoveByURLMatchesByFeedKeyAndKeepsTheRest() {
        let (store, _) = makeStore()
        store.merge(urls: ["https://a.example/feed", "https://b.example/feed", "https://c.example/feed"], listKey: "L", listTitle: "T", addedAt: at(1))
        store.remove(urls: ["https://A.example/feed/", "https://c.example/feed#x", "not a link", "https://missing.example/feed"])
        XCTAssertEqual(store.all().map(\.url), ["https://b.example/feed"])
        store.remove(urls: [])
        XCTAssertEqual(store.all().count, 1)
    }

    func testRemoveByListKeyTakesOnlyThatList() {
        let (store, _) = makeStore()
        store.merge(urls: ["https://a.example/feed", "https://b.example/feed"], listKey: "L1", listTitle: "One", addedAt: at(1))
        store.merge(urls: ["https://c.example/feed"], listKey: "L2", listTitle: "Two", addedAt: at(2))
        store.remove(listKey: "L1")
        XCTAssertEqual(store.all().map(\.url), ["https://c.example/feed"])
        store.remove(listKey: "never")
        XCTAssertEqual(store.all().count, 1)
    }

    func testPendingExcludesFollowedAndDropFollowedRemovesThem() {
        let (store, _) = makeStore()
        store.merge(urls: ["https://a.example/feed", "https://b.example/feed"], listKey: "L", listTitle: "T", addedAt: at(1))
        let followed: Set<String> = [FeedURLKey.make("https://b.example/feed/")!]
        XCTAssertEqual(store.pending(excluding: followed).map(\.url), ["https://a.example/feed"])
        XCTAssertEqual(store.all().count, 2, "pending reads only")
        store.dropFollowed(followed)
        XCTAssertEqual(store.all().map(\.url), ["https://a.example/feed"])
        store.dropFollowed([])
        XCTAssertEqual(store.all().count, 1)
    }

    func testDismissAllAndRestorePutBackTheWholeArray() {
        let (store, _) = makeStore()
        store.merge(urls: ["https://a.example/feed", "https://b.example/feed"], listKey: "L1", listTitle: "One", addedAt: at(1))
        store.merge(urls: ["https://c.example/feed"], listKey: "L2", listTitle: nil, addedAt: at(2))
        let before = store.all()
        let dismissed = store.dismissAll()
        XCTAssertEqual(dismissed, before)
        XCTAssertEqual(store.all(), [])
        store.restore(dismissed)
        XCTAssertEqual(store.all(), before)
    }

    func testRestoreKeepsAListThatArrivedAfterTheDismiss() {
        let (store, _) = makeStore()
        store.merge(urls: ["https://a.example/feed"], listKey: "L1", listTitle: "One", addedAt: at(1))
        let dismissed = store.dismissAll()
        store.merge(urls: ["https://new.example/feed", "https://a.example/feed"], listKey: "L2", listTitle: "Two", addedAt: at(2))
        store.restore(dismissed)
        XCTAssertEqual(store.all().map(\.url), ["https://a.example/feed", "https://new.example/feed"])
        XCTAssertEqual(store.all().first?.listKey, "L1", "the restored record, not the duplicate that arrived")
    }

    func testRestoreOverTheCapKeepsTheNewestTwenty() {
        let (store, _) = makeStore()
        store.merge(urls: (0..<15).map { "https://old\($0).example/feed" }, listKey: "L1", listTitle: "Old", addedAt: at(1))
        let dismissed = store.dismissAll()
        store.merge(urls: (0..<10).map { "https://new\($0).example/feed" }, listKey: "L2", listTitle: "New", addedAt: at(2))
        store.restore(dismissed)
        let all = store.all()
        XCTAssertEqual(all.count, 20)
        XCTAssertEqual(all.filter { $0.listKey == "L2" }.count, 10, "the list that arrived later is whole")
        XCTAssertEqual(all.filter { $0.listKey == "L1" }.count, 10, "the oldest restored ones went first")
        XCTAssertEqual(all.first?.url, "https://old5.example/feed")
    }

    func testNewestListTitle() {
        let (store, _) = makeStore()
        XCTAssertNil(AIFollowSuggestions.newestListTitle(in: []))
        store.merge(urls: ["https://a.example/feed"], listKey: "L1", listTitle: "Old brief", addedAt: at(1))
        store.merge(urls: ["https://b.example/feed"], listKey: "L2", listTitle: "New brief", addedAt: at(2))
        XCTAssertEqual(AIFollowSuggestions.newestListTitle(in: store.all()), "New brief")
        store.merge(urls: ["https://c.example/feed"], listKey: "L3", listTitle: nil, addedAt: at(3))
        XCTAssertNil(AIFollowSuggestions.newestListTitle(in: store.all()), "the newest list had no title")
        // Same time: the last stored wins.
        let tie = [
            AIFollowSuggestions.Suggestion(url: "https://x.example/feed", listKey: "A", listTitle: "A", addedAt: at(1)),
            AIFollowSuggestions.Suggestion(url: "https://y.example/feed", listKey: "B", listTitle: "B", addedAt: at(1)),
        ]
        XCTAssertEqual(AIFollowSuggestions.newestListTitle(in: tie), "B")
    }

    func testUnreadableStoredDataIsEmptyAndTheNextWriteReplacesIt() {
        let (store, defaults) = makeStore()
        defaults.set(Data("not json".utf8), forKey: AIFollowSuggestions.defaultsKey)
        XCTAssertEqual(store.all(), [])
        XCTAssertEqual(store.merge(urls: ["https://a.example/feed"], listKey: "L", listTitle: "T", addedAt: at(1)), 1)
        XCTAssertEqual(store.all().count, 1)
        defaults.set("a string", forKey: AIFollowSuggestions.defaultsKey)
        XCTAssertEqual(store.all(), [])
    }

    func testEmptyStoreLeavesNoKeyBehind() {
        let (store, defaults) = makeStore()
        store.merge(urls: ["https://a.example/feed"], listKey: "L", listTitle: "T", addedAt: at(1))
        XCTAssertNotNil(defaults.data(forKey: AIFollowSuggestions.defaultsKey))
        store.dismissAll()
        XCTAssertNil(defaults.object(forKey: AIFollowSuggestions.defaultsKey))
    }
}
