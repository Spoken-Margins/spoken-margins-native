import XCTest
@testable import SessionKit

/// #4683, Design section 2h: Following's "Suggested by your AI" row, and which suggestions a closed preview settles.
final class AIFollowSuggestionsRowTests: XCTestCase {
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_795_435_200 + seconds) }

    private func suggestion(_ url: String, list: String = "L1", title: String?, at seconds: TimeInterval) -> AIFollowSuggestions.Suggestion {
        AIFollowSuggestions.Suggestion(url: url, listKey: list, listTitle: title, addedAt: at(seconds))
    }

    func testNoRowWhenNothingIsPending() {
        XCTAssertNil(AIFollowSuggestionsRow.make(pending: []))
    }

    func testTheRowCountsShowsAndNamesTheNewestList() {
        let rows: [(pending: [AIFollowSuggestions.Suggestion], detail: String, label: String)] = [
            ([suggestion("https://a.example/feed", title: "Morning brief, November 23", at: 1)],
             "1 show · Morning brief, November 23", "Suggested by your AI, 1 show, from Morning brief, November 23"),
            ([suggestion("https://a.example/feed", list: "old", title: "Old brief", at: 1),
              suggestion("https://b.example/feed", list: "new", title: "Morning brief, November 23", at: 9)],
             "2 shows · Morning brief, November 23", "Suggested by your AI, 2 shows, from Morning brief, November 23"),
            // The newest list had no title: no title is borrowed from an older one.
            ([suggestion("https://a.example/feed", list: "old", title: "Old brief", at: 1),
              suggestion("https://b.example/feed", list: "new", title: nil, at: 9)],
             "2 shows", "Suggested by your AI, 2 shows"),
            // A blank or multi-line title reads as one line, or as none.
            ([suggestion("https://a.example/feed", title: "  \n ", at: 1)], "1 show", "Suggested by your AI, 1 show"),
            ([suggestion("https://a.example/feed", title: "Morning\nbrief", at: 1)], "1 show · Morning brief", "Suggested by your AI, 1 show, from Morning brief"),
        ]
        for row in rows {
            let made = AIFollowSuggestionsRow.make(pending: row.pending)
            XCTAssertEqual(made?.detail, row.detail)
            XCTAssertEqual(made?.accessibilityLabel, row.label)
            XCTAssertEqual(made?.feedLinks, row.pending.map(\.url))
        }
    }

    func testTheWords() {
        XCTAssertEqual(AIFollowSuggestionsRow.title, "Suggested by your AI")
        XCTAssertEqual(AIFollowSuggestionsRow.accessibilityHint, "Opens a preview. Nothing is followed until you tap Follow.")
        XCTAssertEqual(AIFollowSuggestionsRow.stillFollowingMessage, "Still following the last shows. Try again in a moment.")
    }

    func testAClosedPreviewSettlesWhatItFollowedAndWhatItDidNotOffer() {
        let passed = [
            "http://a.example/feed",              // offered (as https), followed
            "https://b.example/feed",             // offered, left unticked
            "https://c.example/feed",             // already followed, so not offered
            "https://podcasts.apple.com/us/podcast/id1", // not a feed the preview can use
            "https://d.example/feed/",            // offered as d.example/feed, failed to follow
        ]
        let offered = ["https://a.example/feed", "https://b.example/feed", "https://d.example/feed"]
        let settled = AIFollowSuggestionsRow.settled(passed: passed, offered: offered, followed: ["https://a.example/feed"])
        XCTAssertEqual(settled, ["http://a.example/feed", "https://c.example/feed", "https://podcasts.apple.com/us/podcast/id1"])
    }

    func testClosingWithoutFollowingKeepsEveryOfferedShow() {
        let passed = ["https://a.example/feed", "https://b.example/feed"]
        XCTAssertEqual(AIFollowSuggestionsRow.settled(passed: passed, offered: passed, followed: []), [])
    }

    func testAListThePreviewCouldNotReadIsSettledWhole() {
        // The preview refused the list (too large, too many lines): nothing in it can be followed from here.
        let passed = ["https://a.example/feed", "not a link"]
        XCTAssertEqual(AIFollowSuggestionsRow.settled(passed: passed, offered: [], followed: []), passed)
    }

    func testSettledLinksLeaveTheStoreByFeedURLKey() {
        let suite = "AIFollowSuggestionsRowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = AIFollowSuggestions(defaults: defaults)
        store.merge(urls: ["http://a.example/feed", "https://b.example/feed"], listKey: "L1", listTitle: "Brief", addedAt: at(1))
        store.remove(urls: AIFollowSuggestionsRow.settled(
            passed: store.all().map(\.url), offered: ["https://a.example/feed", "https://b.example/feed"], followed: ["https://a.example/feed"]))
        XCTAssertEqual(store.all().map(\.url), ["https://b.example/feed"])
    }
}
