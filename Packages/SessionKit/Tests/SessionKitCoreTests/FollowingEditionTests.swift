import Foundation
import XCTest
@testable import SessionKit

/// Today's picks (#774): which eight, the per-show caps, what folds into "Also new", and that a
/// rebuild never reorders the picks on screen.
final class FollowingEditionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86_400

    private func show(_ id: String, title: String? = nil, state: FeedSubscriptionState = .active, policy: FeedNewItemPolicy? = nil, followedDaysAgo: Double = 90) -> FeedSubscription {
        FeedSubscription(
            id: "sub-\(id)",
            source: SourceIdentity(id: "src-\(id)", kind: .podcastFeed, canonicalURL: "https://\(id).example/feed", host: "\(id).example", title: title ?? id),
            state: state,
            createdAt: now.addingTimeInterval(-followedDaysAgo * day),
            newItemPolicy: policy
        )
    }

    private func entry(_ id: String, show: String, daysAgo: Double?, state: FeedEntryState = .unseen, minutes: Int? = nil) -> FeedEntry {
        FeedEntry(
            id: id, subscriptionId: "sub-\(show)", canonicalURL: "https://\(show).example/\(id)", title: id,
            publishedAt: daysAgo.map { now.addingTimeInterval(-$0 * day) }, state: state,
            audioDurationMs: minutes.map { $0 * 60_000 }
        )
    }

    private func build(_ entries: [FeedEntry], _ subscriptions: [FeedSubscription], pinned: Set<String> = [], less: Set<String> = [], scores: [String: Double] = [:], notToday: Set<String> = [], inLibrary: Set<String> = [], length: FollowingLengthFilter = .any, folder: Int = 0, at time: Date? = nil, previous: FollowingEdition? = nil) -> FollowingEdition {
        FollowingEdition.build(
            entries: entries, subscriptions: subscriptions,
            pinnedSourceIDs: Set(pinned.map { "src-\($0)" }), lessOfSourceIDs: Set(less.map { "src-\($0)" }),
            scores: scores, notToday: notToday, inLibrary: inLibrary, lengthFilter: length,
            quickFolderNewFileCount: folder, now: time ?? now, previous: previous
        )
    }

    func testADailyShowAndAMonthlyShowBothGetASlot() {
        let daily = (0..<20).map { entry("daily-\($0)", show: "daily", daysAgo: Double($0)) }
        let monthly = [entry("monthly-1", show: "monthly", daysAgo: 25)]
        let edition = build(daily + monthly, [show("daily"), show("monthly")])
        XCTAssertEqual(edition.picks.map(\.id), ["daily-0", "monthly-1"])
        XCTAssertEqual(edition.alsoNew.map(\.subscriptionID), ["sub-daily"])
        XCTAssertEqual(edition.alsoNew.first?.count, 19)
        XCTAssertEqual(edition.alsoNew.first?.text, "19 new")
    }

    func testPinnedShowsComeFirstAndMayGiveTwoPicks() {
        let entries = [
            entry("a-1", show: "a", daysAgo: 0), entry("p-1", show: "p", daysAgo: 5),
            entry("p-2", show: "p", daysAgo: 6), entry("p-3", show: "p", daysAgo: 7),
            entry("b-1", show: "b", daysAgo: 1),
        ]
        let edition = build(entries, [show("a"), show("b"), show("p")], pinned: ["p"])
        XCTAssertEqual(edition.picks.map(\.id), ["p-1", "a-1", "b-1", "p-2"])
        XCTAssertEqual(edition.picks.map(\.reason), [.pinned, .newToday, .newToday, .pinned])
        XCTAssertEqual(edition.alsoNew.map(\.count), [1], "the pinned show's third episode folds into Also new")
    }

    func testLessOfShowsOnlyFillWhatIsLeft() {
        let less = [entry("less-1", show: "less", daysAgo: 0)]
        let few = (0..<3).map { entry("o\($0)-1", show: "o\($0)", daysAgo: 2) }
        let fewShows = (0..<3).map { show("o\($0)") }
        XCTAssertEqual(build(less + few, fewShows + [show("less")], less: ["less"]).picks.last?.id, "less-1",
                       "with fewer than eight others, a Less-of show still gives a pick, after them")

        let many = (0..<8).map { entry("o\($0)-1", show: "o\($0)", daysAgo: 2) }
        let manyShows = (0..<8).map { show("o\($0)") }
        let full = build(less + many, manyShows + [show("less")], less: ["less"])
        XCTAssertEqual(full.picks.count, 8)
        XCTAssertFalse(full.picks.contains { $0.id == "less-1" })
        XCTAssertTrue(full.alsoNew.contains { $0.subscriptionID == "sub-less" && $0.count == 1 })
    }

    func testEntriesOlderThanThirtyDaysNeverBecomePicks() {
        let entries = [entry("old", show: "a", daysAgo: 31), entry("undated", show: "b", daysAgo: nil), entry("recent", show: "c", daysAgo: 29)]
        let edition = build(entries, [show("a"), show("b"), show("c")])
        XCTAssertEqual(edition.picks.map(\.id), ["recent"])
        XCTAssertEqual(edition.picks.first?.reason, .youFollowThis)
        // Back catalogue isn't new; an undated entry still waits on its show's page.
        XCTAssertEqual(edition.alsoNew.map(\.subscriptionID), ["sub-b"])
    }

    func testAJustFollowedShowWithAnOldBackCatalogueGivesAtMostItsNewest() {
        let backCatalogue = (0..<25).map { entry("new-show-\($0)", show: "new", daysAgo: Double($0) * 7 + 3) }
        let edition = build(backCatalogue, [show("new", followedDaysAgo: 0.1)])
        XCTAssertEqual(edition.picks.map(\.id), ["new-show-0"])
        XCTAssertEqual(edition.picks.first?.reason, .justFollowed)
        XCTAssertEqual(edition.alsoNew, [], "the rest is back catalogue, not new")

        // An episode published after the follow is new as usual.
        let withNew = backCatalogue + [entry("new-show-fresh", show: "new", daysAgo: 0.01)]
        let later = build(withNew, [show("new", followedDaysAgo: 0.1)])
        XCTAssertEqual(later.picks.map(\.id), ["new-show-fresh"])
        XCTAssertEqual(later.alsoNew, [])
    }

    func testMutedAddEveryLibraryAndNotTodayEntriesAreNotPicks() {
        let entries = [
            entry("muted-1", show: "muted", daysAgo: 0),
            entry("auto-1", show: "auto", daysAgo: 0, state: .imported),
            entry("auto-2", show: "auto", daysAgo: 1, state: .imported),
            entry("auto-old", show: "auto", daysAgo: 0.5),
            entry("lib-1", show: "a", daysAgo: 0),
            entry("imported-1", show: "a", daysAgo: 0, state: .imported),
            entry("dismissed-1", show: "a", daysAgo: 0, state: .dismissed),
            entry("passed-1", show: "b", daysAgo: 0),
            entry("orphan-1", show: "gone", daysAgo: 0),
        ]
        let subscriptions = [show("muted", state: .muted), show("auto", policy: .addEveryNewItem), show("a"), show("b")]
        let edition = build(entries, subscriptions, notToday: ["passed-1"], inLibrary: ["lib-1"])
        XCTAssertEqual(edition.picks, [])
        // A muted show isn't listed, an "Add every new item" show counts what it added, and a
        // passed pick stays new on its show's page.
        XCTAssertEqual(edition.alsoNew.map(\.subscriptionID), ["sub-auto", "sub-b"])
        XCTAssertEqual(edition.alsoNew.map(\.text), ["2 added to Library", "1 new"])
    }

    func testEmptyInputGivesAnEmptyEdition() {
        let edition = build([], [])
        XCTAssertEqual(edition.picks, [])
        XCTAssertEqual(edition.alsoNew, [])
        XCTAssertNil(edition.folderRow)
        XCTAssertEqual(edition.pendingArrivals, [])
    }

    func testQuickFolderFilesAreOneRow() {
        XCTAssertEqual(build([], [], folder: 1).folderRow?.text, "From your folder · 1 new file")
        XCTAssertEqual(build([], [], folder: 2).folderRow?.text, "From your folder · 2 new files")
    }

    func testSixtyShowsWithTwoHundredEntriesGiveEightPicksAndAtMostSixtyRows() {
        let subscriptions = (0..<60).map { show("s\($0)") }
        let entries = (0..<200).map { entry("e\($0)", show: "s\($0 % 60)", daysAgo: Double($0) / 10) }
        let edition = build(entries, subscriptions)
        XCTAssertEqual(edition.picks.count, 8)
        XCTAssertEqual(Set(edition.picks.map(\.subscriptionID)).count, 8, "one pick per show")
        XCTAssertLessThanOrEqual(edition.alsoNew.count, 60)
        XCTAssertEqual(Set(edition.alsoNew.map(\.subscriptionID)).count, edition.alsoNew.count, "one row per show")
        XCTAssertEqual(edition.alsoNew.reduce(0) { $0 + $1.count } + edition.picks.count, 200)
    }

    func testScoresOrderPicksWhenPresent() {
        let entries = [entry("a-1", show: "a", daysAgo: 0), entry("b-1", show: "b", daysAgo: 3), entry("c-1", show: "c", daysAgo: 1)]
        let subscriptions = [show("a"), show("b"), show("c")]
        XCTAssertEqual(build(entries, subscriptions).picks.map(\.id), ["a-1", "c-1", "b-1"])
        XCTAssertEqual(build(entries, subscriptions, scores: ["b-1": 2, "c-1": 1]).picks.map(\.id), ["b-1", "c-1", "a-1"])
    }

    func testEachPickHasOneRecencyReasonWithoutSignals() {
        let entries = [entry("today", show: "a", daysAgo: 0.5), entry("week", show: "b", daysAgo: 4), entry("month", show: "c", daysAgo: 20)]
        let edition = build(entries, [show("a"), show("b"), show("c")])
        XCTAssertEqual(edition.picks.map(\.reason.text), ["New today", "New this week", "You follow this"])
    }

    func testTheLengthFilterKeepsUnknownLengthsUnderAnyOnly() {
        let entries = [entry("short", show: "a", daysAgo: 0, minutes: 12), entry("mid", show: "b", daysAgo: 0, minutes: 42),
                       entry("long", show: "c", daysAgo: 0, minutes: 95), entry("unknown", show: "d", daysAgo: 0)]
        let subscriptions = [show("a"), show("b"), show("c"), show("d")]
        XCTAssertEqual(build(entries, subscriptions).picks.count, 4)
        XCTAssertEqual(build(entries, subscriptions, length: .under20).picks.map(\.id), ["short"])
        XCTAssertEqual(build(entries, subscriptions, length: .twentyToSixty).picks.map(\.id), ["mid"])
        XCTAssertEqual(build(entries, subscriptions, length: .overAnHour).picks.map(\.id), ["long"])
    }

    /// The buckets meet at exactly 20 and 60 minutes: 20 is "20-60" and not "under 20", 60 is "20-60"
    /// and not "over an hour". The test above uses 12, 42 and 95, which no boundary change can move.
    func testTheLengthFilterBucketsMeetAtExactlyTwentyAndSixtyMinutes() {
        let entries = [entry("e19", show: "a", daysAgo: 0, minutes: 19), entry("e20", show: "b", daysAgo: 0, minutes: 20),
                       entry("e60", show: "c", daysAgo: 0, minutes: 60), entry("e61", show: "d", daysAgo: 0, minutes: 61)]
        let subscriptions = [show("a"), show("b"), show("c"), show("d")]
        func ids(_ length: FollowingLengthFilter) -> [String] { build(entries, subscriptions, length: length).picks.map(\.id).sorted() }
        XCTAssertEqual(ids(.under20), ["e19"])
        XCTAssertEqual(ids(.twentyToSixty), ["e20", "e60"])
        XCTAssertEqual(ids(.overAnHour), ["e61"])

        XCTAssertTrue(FollowingLengthFilter.under20.includes(minutes: 19.99))
        XCTAssertFalse(FollowingLengthFilter.under20.includes(minutes: 20))
        XCTAssertFalse(FollowingLengthFilter.twentyToSixty.includes(minutes: 19.99))
        XCTAssertTrue(FollowingLengthFilter.twentyToSixty.includes(minutes: 20))
        XCTAssertTrue(FollowingLengthFilter.twentyToSixty.includes(minutes: 60))
        XCTAssertFalse(FollowingLengthFilter.twentyToSixty.includes(minutes: 60.01))
        XCTAssertFalse(FollowingLengthFilter.overAnHour.includes(minutes: 60))
        XCTAssertTrue(FollowingLengthFilter.overAnHour.includes(minutes: 60.01))
    }

    /// Also new lists the show with the newest waiting episode first. The two-row test above has both shows
    /// at "0 days ago", so the rows tie on date and fall to the id order, and the date never decides.
    /// Here the order by date is the opposite of the order by id, and the show's date is the newest of its
    /// folded episodes, not the oldest.
    func testAlsoNewListsTheShowWithTheNewestFoldedEpisodeFirst() {
        let entries = [
            entry("a-1", show: "a", daysAgo: 10), entry("a-2", show: "a", daysAgo: 12),
            entry("b-1", show: "b", daysAgo: 2), entry("b-2", show: "b", daysAgo: 5),
            entry("c-1", show: "c", daysAgo: 1), entry("c-2", show: "c", daysAgo: 4), entry("c-3", show: "c", daysAgo: 20),
        ]
        let edition = build(entries, [show("a"), show("b"), show("c")])
        XCTAssertEqual(edition.picks.map(\.id), ["c-1", "b-1", "a-1"])
        XCTAssertEqual(edition.alsoNew.map(\.subscriptionID), ["sub-c", "sub-b", "sub-a"])
        XCTAssertEqual(edition.alsoNew.map(\.count), [2, 1, 1])
    }

    func testARebuildKeepsThePicksAndHoldsNewArrivalsApart() {
        let subscriptions = [show("a"), show("b"), show("c")]
        let first = [entry("a-1", show: "a", daysAgo: 2), entry("b-1", show: "b", daysAgo: 3)]
        let edition = build(first, subscriptions)
        XCTAssertEqual(edition.picks.map(\.id), ["a-1", "b-1"])

        // Later: a newer episode from a new show and one from show b, and a-1 was played.
        var played = first
        played[0].state = .imported
        let later = played + [entry("c-1", show: "c", daysAgo: 0), entry("b-2", show: "b", daysAgo: 0)]
        let rebuilt = build(later, subscriptions, at: now.addingTimeInterval(600), previous: edition)
        XCTAssertEqual(rebuilt.picks.map(\.id), ["a-1", "b-1"], "nothing reorders under the listener's thumb")
        XCTAssertEqual(rebuilt.pendingArrivals.map(\.id), ["b-2", "c-1"])
        XCTAssertEqual(rebuilt.builtAt, edition.builtAt)

        // Still pending on a second quiet rebuild; joining is a fresh build.
        XCTAssertEqual(Set(build(later, subscriptions, previous: rebuilt).pendingArrivals.map(\.id)), ["c-1", "b-2"])
        let fresh = build(later, subscriptions, at: now.addingTimeInterval(700))
        XCTAssertEqual(Set(fresh.picks.map(\.id)), ["c-1", "b-2"])
        XCTAssertEqual(fresh.pendingArrivals, [])
    }

    func testARebuildDropsPassedPicksWithoutMovingOthersUp() {
        let subscriptions = [show("a"), show("b"), show("c")]
        let entries = [entry("a-1", show: "a", daysAgo: 1), entry("b-1", show: "b", daysAgo: 2), entry("c-1", show: "c", daysAgo: 3)]
        let edition = build(entries, subscriptions)
        let rebuilt = build(entries, subscriptions, notToday: ["a-1"], previous: edition)
        XCTAssertEqual(rebuilt.picks.map(\.id), ["b-1", "c-1"])
        XCTAssertEqual(rebuilt.pendingArrivals, [], "a known entry is never an arrival")
    }

    func testARebuildDropsAPickWhoseShowNowAddsEveryItem() {
        let entries = [entry("a-1", show: "a", daysAgo: 1), entry("b-1", show: "b", daysAgo: 2)]
        let edition = build(entries, [show("a"), show("b")])
        var imported = entries
        imported[0].state = .imported
        let rebuilt = build(imported, [show("a", policy: .addEveryNewItem), show("b")], previous: edition)
        XCTAssertEqual(rebuilt.picks.map(\.id), ["b-1"])
        XCTAssertEqual(rebuilt.alsoNew.map(\.text), ["1 added to Library"], "counted once, as added")
    }
}
