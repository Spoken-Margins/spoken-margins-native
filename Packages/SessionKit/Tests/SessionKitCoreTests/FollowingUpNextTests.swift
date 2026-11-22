import XCTest
@testable import SessionKit

/// #3863 PR 1: the show's Up next pick and its description, shared by the Following row and the show screen's card.
final class FollowingUpNextTests: XCTestCase {
    private let followed = Date(timeIntervalSince1970: 1_700_000_000)
    private let now = Date(timeIntervalSince1970: 1_700_000_000 + 30 * 86_400)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ n: Int) -> Date { followed.addingTimeInterval(Double(n) * 86_400) }

    private var show: FeedSubscription {
        FeedSubscription(
            id: "s", source: SourceIdentity(id: "source-s", kind: .podcastFeed, canonicalURL: "https://example.com/s.xml", host: "example.com", title: "Show"),
            state: .active, createdAt: followed)
    }

    private func entry(
        _ id: String, day published: Int?, state: FeedEntryState = .unseen, summary: String? = nil, fullBody: String? = nil,
        seenOnly: Bool = false
    ) -> FeedEntry {
        FeedEntry(
            id: id, subscriptionId: "s", canonicalURL: "https://example.com/\(id)", audioURL: "https://example.com/\(id).mp3",
            title: "Episode \(id)", summary: summary, publishedAt: seenOnly ? nil : published.map(day), state: state, fullBody: fullBody,
            firstSeenAt: published.map(day))
    }

    private func library(_ id: String, finished: Bool) -> [String: FollowingLibraryEpisode] {
        [id: FollowingLibraryEpisode(itemID: "item-\(id)", isFinished: finished)]
    }

    private func row(_ entries: [FeedEntry], library: [String: FollowingLibraryEpisode] = [:]) -> FollowingShowRow? {
        FollowingShowRows.build(
            subscriptions: [show], entries: entries, libraryEpisodes: library,
            now: now, calendar: calendar, locale: Locale(identifier: "en_US")).rows.first
    }

    // MARK: Starting states

    func testFirstRunTheNewestEpisodeIsUpNext() {
        let entries = [entry("old", day: 1), entry("new", day: 9), entry("mid", day: 5)]
        XCTAssertEqual(FollowingUpNext.pick(entries: entries)?.id, "new")
    }

    func testAFinishedNewestEpisodeGivesWayToTheNextUnheardOne() {
        let entries = [entry("new", day: 9, state: .imported), entry("mid", day: 5), entry("old", day: 1)]
        XCTAssertEqual(FollowingUpNext.pick(entries: entries, libraryEpisodes: library("new", finished: true))?.id, "mid")
    }

    func testAnImportedEpisodeWithNoLibraryItemCountsAsFinished() {
        let entries = [entry("new", day: 9, state: .imported), entry("mid", day: 5)]
        XCTAssertEqual(FollowingUpNext.pick(entries: entries)?.id, "mid")
    }

    func testEveryEpisodeHeardGivesNoPickAndNoCard() {
        let entries = [entry("a", day: 9, state: .imported), entry("b", day: 5, state: .dismissed)]
        XCTAssertNil(FollowingUpNext.pick(entries: entries, libraryEpisodes: library("a", finished: true)))
        XCTAssertNil(FollowingUpNext.card(entries: entries, libraryEpisodes: library("a", finished: true)))
    }

    func testAShowWithNoEpisodesGivesNoCard() {
        XCTAssertNil(FollowingUpNext.pick(entries: []))
        XCTAssertNil(FollowingUpNext.card(entries: []))
    }

    func testAPartlyHeardLibraryEpisodeIsUpNextWithInLibraryAndItsItem() {
        let entries = [entry("new", day: 9, state: .imported), entry("old", day: 1)]
        let card = FollowingUpNext.card(entries: entries, libraryEpisodes: library("new", finished: false))
        XCTAssertEqual(card?.entry.id, "new")
        XCTAssertEqual(card?.isInLibrary, true)
        XCTAssertEqual(card?.libraryItemID, "item-new")
    }

    func testANewestEpisodeNotInTheLibraryHasNoItem() {
        let card = FollowingUpNext.card(entries: [entry("new", day: 9)])
        XCTAssertEqual(card?.isInLibrary, false)
        XCTAssertNil(card?.libraryItemID)
    }

    func testADismissedNewestEpisodeIsSkipped() {
        let entries = [entry("new", day: 9, state: .dismissed), entry("mid", day: 5)]
        XCTAssertEqual(FollowingUpNext.pick(entries: entries)?.id, "mid")
    }

    func testEntriesWithNoDateSortLastAndTiesBreakByID() {
        XCTAssertEqual(FollowingUpNext.pick(entries: [entry("undated", day: nil), entry("dated", day: 1)])?.id, "dated")
        XCTAssertEqual(FollowingUpNext.pick(entries: [entry("b", day: 3), entry("a", day: 3)])?.id, "a")
    }

    // MARK: The row and the card agree

    func testTheRowsPlayButtonAndTheCardNameTheSameEpisodeForEveryFixture() {
        let fixtures: [(name: String, entries: [FeedEntry], library: [String: FollowingLibraryEpisode])] = [
            ("first run", [entry("a", day: 1), entry("b", day: 9)], [:]),
            ("finished newest", [entry("a", day: 1), entry("b", day: 9, state: .imported)], library("b", finished: true)),
            ("partly heard newest", [entry("a", day: 1), entry("b", day: 9, state: .imported)], library("b", finished: false)),
            ("dismissed newest", [entry("a", day: 1), entry("b", day: 9, state: .dismissed)], [:]),
            ("all heard", [entry("a", day: 1, state: .imported), entry("b", day: 9, state: .imported)], library("a", finished: true)),
            ("seen not played", [entry("a", day: 4, state: .seen), entry("b", day: 2)], [:]),
            ("no publish date, first seen only", [entry("a", day: 4, seenOnly: true), entry("b", day: 2)], [:]),
            ("undated and dated", [entry("a", day: nil), entry("b", day: 2)], [:]),
            ("same date, id breaks the tie", [entry("b", day: 3), entry("a", day: 3)], [:]),
            ("nothing hearable, newest dismissed and rest heard", [entry("a", day: 1, state: .imported), entry("b", day: 9, state: .dismissed)], library("a", finished: true)),
        ]
        for fixture in fixtures {
            let card = FollowingUpNext.card(entries: fixture.entries, libraryEpisodes: fixture.library)
            let row = row(fixture.entries, library: fixture.library)
            XCTAssertEqual(row?.playEntryID, card?.entry.id, fixture.name)
            XCTAssertEqual(row?.playItemID, card?.libraryItemID, fixture.name)
        }
    }

    func testTheRowFallsBackToTheNewestEpisodeButOffersNoPlayWhenNothingIsHearable() {
        let entries = [entry("a", day: 1, state: .imported), entry("b", day: 9, state: .imported)]
        let row = row(entries, library: library("b", finished: true))
        XCTAssertNil(row?.playEntryID)
        XCTAssertNil(row?.playItemID)
        XCTAssertEqual(row?.newestEntryID, "b")
        XCTAssertEqual(row?.accessibilityLabel.contains("Newest: Episode b"), true)
    }

    func testAnEntryWithOnlyAFirstSeenDateStillOrdersByIt() {
        let entries = [entry("old", day: 2), entry("seen", day: 8, seenOnly: true)]
        XCTAssertEqual(FollowingUpNext.pick(entries: entries)?.id, "seen")
    }

    // MARK: Description

    func testTheSummaryIsTheDescription() {
        let card = FollowingUpNext.card(entries: [entry("a", day: 1, summary: "<p>Noah &amp; Brad talk <em>trade</em>.</p>")])
        XCTAssertEqual(card?.description, "Noah & Brad talk trade.")
    }

    func testAnEmptySummaryFallsBackToTheBodysOpening() {
        let body = "<p>First paragraph of the post.</p><p>Second paragraph.</p>"
        for summary in [nil, "", "   ", "<p></p>"] as [String?] {
            let card = FollowingUpNext.card(entries: [entry("a", day: 1, summary: summary, fullBody: body)])
            XCTAssertEqual(card?.description?.hasPrefix("First paragraph of the post."), true, "summary \(String(describing: summary))")
        }
    }

    func testNoSummaryAndNoBodyGivesNoDescriptionAndStillACard() {
        let card = FollowingUpNext.card(entries: [entry("a", day: 1)])
        XCTAssertNotNil(card)
        XCTAssertNil(card?.description)
    }

    func testAFiftyThousandCharacterBodyIsCutAtTheDescriptionLimit() {
        let body = "<p>" + String(repeating: "word ", count: 10_000) + "</p>"
        let text = FollowingUpNext.descriptionText(of: entry("a", day: 1, fullBody: body))
        XCTAssertNotNil(text)
        XCTAssertLessThanOrEqual((text ?? "").count, ItemMetadata.descriptionLimit + 1)
    }

    func testSummaryWinsOverBodyWhenBothAreThere() {
        let text = FollowingUpNext.descriptionText(of: entry("a", day: 1, summary: "Short.", fullBody: "<p>Long body.</p>"))
        XCTAssertEqual(text, "Short.")
    }
}
