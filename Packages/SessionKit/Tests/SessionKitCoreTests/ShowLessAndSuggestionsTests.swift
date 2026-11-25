import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #4046 PR 12: Show less from either menu writes one mark, the learner reads what the device holds, and the suggestion
/// card's buttons are store calls over a real temporary SQLite file.
final class ShowLessAndSuggestionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 200 * 86_400)
    private let feedURL = "https://a.example/feed"

    private func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private var subscription: FeedSubscription {
        FeedSubscription(
            id: "sub", source: SourceIdentity(id: "s", kind: .podcastFeed, canonicalURL: feedURL, host: "a.example", title: "Daily Dispatch"),
            state: .active, createdAt: ago(days: 100))
    }

    private var feedKey: String { FollowListEditing.member(for: subscription).feedKey }

    private func entry(_ n: Int, _ title: String) -> FeedEntry {
        FeedEntry(id: "e\(n)", subscriptionId: "sub", canonicalURL: "https://a.example/\(n)", title: title,
                  publishedAt: ago(days: Double(30 - n)))
    }

    private var entries: [FeedEntry] {
        [entry(1, "Crypto crash"), entry(2, "Why crypto wins"), entry(3, "Crypto again")]
            + (4...10).map { entry($0, "Harbour notes \($0)") }
    }

    private func item(_ id: String, addedDaysAgo: Double = 1) -> Item {
        Item(id: id, title: "Item \(id)", mediaType: "audio", text: "", externalReference: nil, status: "ready",
             deletedAt: nil, createdAt: ago(days: addedDaysAgo))
    }

    private func temporaryStore() throws -> SQLiteSessionStore {
        try SQLiteSessionStore(path: FileManager.default.temporaryDirectory.appending(path: "show-less-\(UUID().uuidString).sqlite").path)
    }

    // MARK: Both menus write one mark

    func testTheShowScreenAndTheItemScreenWriteTheSameMark() {
        let fromShow = ShowLessMarking.mark(entry: entries[0], subscription: subscription, now: now)
        let fromItem = ShowLessMarking.mark(item: item("i1"), subscription: subscription, entryId: "e1", now: now)
        XCTAssertEqual(fromShow.id, fromItem.id, "one episode, one mark, whichever menu marked it")
        XCTAssertEqual(fromShow.feedKey, fromItem.feedKey)
        let itemOnly = ShowLessMarking.mark(item: item("i2"), subscription: subscription, entryId: nil, now: now)
        XCTAssertEqual(itemOnly.id, "i2")
        XCTAssertEqual(ShowLessMarking.existing(entryId: "e1", itemId: "other", in: [fromShow])?.id, "e1")
        XCTAssertEqual(ShowLessMarking.existing(entryId: nil, itemId: "i2", in: [itemOnly])?.id, "i2")
        XCTAssertNil(ShowLessMarking.existing(entryId: "", itemId: "", in: [itemOnly]), "blank ids match nothing")
        XCTAssertEqual(ShowLessWords.menuTitle(isMarked: false), "Show less like this")
        XCTAssertEqual(ShowLessWords.menuTitle(isMarked: true), "Undo Show less")
    }

    func testFollowedShowMatchNamesTheShowTheSignalLogWould() {
        var episode = item("i1")
        episode.sourceURL = feedURL + "/"
        XCTAssertEqual(FollowedShowMatch.subscription(for: episode, subscriptions: [subscription])?.id, "sub")
        XCTAssertEqual(FollowedShowMatch.entryId(
            for: episode, subscription: subscription, entries: entries,
            importedEntryIds: [ListeningSignalImportedEntries.itemKey("i1"): "e2"]), "e2")
        XCTAssertNil(FollowedShowMatch.subscription(for: item("loose"), subscriptions: [subscription]))
    }

    // MARK: PR 11 audit: two Library copies of one episode

    func testAMarkNamingTheSecondCopyOfAnEpisodeCountsOnceForThatEpisode() {
        // Both copies came from entry e1; the mark was made on the second copy's Item screen, which found no entry.
        let first = RuleEvidenceEpisode(item: item("copy1", addedDaysAgo: 20), feedKey: feedKey, entryId: "e1", title: "Crypto crash")
        let second = RuleEvidenceEpisode(item: item("copy2", addedDaysAgo: 20), feedKey: feedKey, entryId: "e1", title: "Crypto crash")
        let mark = ShowLessMark(feedKey: feedKey, itemId: "copy2", title: "Crypto crash", markedAt: ago(days: 1))
        let evidence = RuleEvidenceBuilder.build(episodes: [first, second], sessions: [], margins: [], marks: [mark], now: now)
        XCTAssertEqual(evidence.map(\.id), ["e1"], "one episode, never also a row of its own for the mark")
        XCTAssertEqual(evidence.first?.showLess, true)
        XCTAssertEqual(evidence.first?.addedNeverPlayed, true)
    }

    // MARK: Words

    func testSuggestionWordsAndTheRuleTurnOnSaves() {
        let suggestion = RuleSuggestion(
            key: RuleSuggestionState.key(feedKey: feedKey, word: "crypto"), showId: "sub", member: ListMember(feedKey: feedKey),
            showTitle: "Planet Money", word: "crypto", strength: 9, episodeCount: 3, reason: .marked(3))
        XCTAssertEqual(RuleSuggestionWords.title(suggestion), "Skip Planet Money episodes about “crypto”?")
        XCTAssertEqual(RuleSuggestionWords.turnedOn(suggestion), "Rule on: Planet Money episodes about “crypto” are skipped.")
        let rule = RuleSuggestionWords.rule(for: suggestion, id: "r", now: now)
        XCTAssertEqual(rule.action, .skip)
        XCTAssertEqual(rule.words, ["crypto"])
        XCTAssertEqual(rule.scope, .show(ListMember(feedKey: feedKey)))
        XCTAssertEqual(rule.origin, .suggested)
        XCTAssertTrue(rule.isOn)
    }

    // MARK: From the store

    private func seededStore() throws -> SQLiteSessionStore {
        let store = try temporaryStore()
        try store.saveFeedSubscription(subscription)
        for entry in entries { try store.saveFeedEntry(entry) }
        return store
    }

    func testThreeMarksFromTheShowScreenOfferARuleAndTheCardButtonsWork() async throws {
        let store = try seededStore()
        let rules = ListeningRulesStore(store: store)
        for entry in entries.prefix(3) {
            _ = try await rules.markShowLess(ShowLessMarking.mark(entry: entry, subscription: subscription, now: ago(days: 2)))
        }
        // Marking again replaces the mark.
        let marks = try await rules.markShowLess(ShowLessMarking.mark(entry: entries[0], subscription: subscription, now: ago(days: 1)))
        XCTAssertEqual(marks.count, 3)

        let suggestions = RuleSuggestionsLoader.load(store: store, now: now)
        let suggestion = try XCTUnwrap(suggestions.first)
        XCTAssertEqual(suggestion.word, "crypto")
        XCTAssertEqual(suggestion.showTitle, "Daily Dispatch")

        _ = try await rules.putOff(key: suggestion.key, now: now)
        XCTAssertTrue(RuleSuggestionsLoader.load(store: store, now: now).isEmpty, "Not now: quiet")
        XCTAssertEqual(RuleSuggestionsLoader.load(store: store, now: now.addingTimeInterval(31 * 86_400)).first?.key, suggestion.key)
        _ = try await rules.refuse(key: suggestion.key)
        XCTAssertTrue(RuleSuggestionsLoader.load(store: store, now: now.addingTimeInterval(400 * 86_400)).isEmpty, "never again")
        _ = try await rules.clearState(key: suggestion.key)
        XCTAssertFalse(RuleSuggestionsLoader.load(store: store, now: now).isEmpty, "Undo brings it back")

        let change = try await rules.turnOn(suggestion, id: "r1", now: now)
        XCTAssertNil(change.refusal)
        XCTAssertEqual(change.rules.map(\.id), ["r1"])
        XCTAssertEqual(change.rules.first?.isOn, true)
        let again = try await rules.turnOn(suggestion, id: "r1", now: now)
        XCTAssertEqual(again.rules.count, 1, "a double tap makes one rule")
        XCTAssertTrue(RuleSuggestionsLoader.load(store: store, now: now).isEmpty, "a rule that covers it ends the suggestion")

        let after = try await rules.unmarkShowLess(entryId: nil, itemId: nil)
        XCTAssertEqual(after.count, 3, "nothing named, nothing undone")
        let undone = try await rules.unmarkShowLess(entryId: "e2", itemId: "unrelated")
        XCTAssertEqual(undone.map(\.id).sorted(), ["e1", "e3"])
    }

    func testImportedRulesAreSavedSwitchedOffWithinTheLimit() async throws {
        let store = try temporaryStore()
        let rules = ListeningRulesStore(store: store)
        let incoming = (0..<3).map { n in
            ListeningRule(id: "in\(n)", action: .skip, words: ["w\(n)x"], scope: .show(ListMember(feedKey: feedKey)),
                          origin: .list("Commute"), isOn: true, createdAt: now)
        }
        let saved = try await rules.importRules(incoming)
        XCTAssertEqual(saved.map(\.id), ["in0", "in1", "in2"])
        XCTAssertTrue(try store.loadListeningRules().allSatisfy { !$0.isOn }, "a friend's rule never acts until you turn it on")
    }

    func testAnUnreadableStoreOffersNoSuggestion() throws {
        let store = try temporaryStore()
        XCTAssertTrue(RuleSuggestionsLoader.load(store: store, now: now).isEmpty, "nothing followed: nothing to suggest")
    }
}
