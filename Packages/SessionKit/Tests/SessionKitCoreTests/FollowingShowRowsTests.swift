import XCTest
@testable import SessionKit

final class FollowingShowRowsTests: XCTestCase {
    private let followed = Date(timeIntervalSince1970: 1_700_000_000)
    private let now = Date(timeIntervalSince1970: 1_700_000_000 + 30 * 86_400)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ n: Int) -> Date { followed.addingTimeInterval(Double(n) * 86_400) }

    private func show(_ id: String, title: String? = nil, muted: Bool = false, createdAt: Date? = nil) -> FeedSubscription {
        FeedSubscription(
            id: id,
            source: SourceIdentity(id: "source-\(id)", kind: .podcastFeed, canonicalURL: "https://example.com/\(id).xml", host: "example.com", title: title ?? "Show \(id)"),
            state: muted ? .muted : .active,
            createdAt: createdAt ?? followed
        )
    }

    private func entry(_ id: String, in show: String, day published: Int?, state: FeedEntryState = .unseen, seenDay: Int? = nil, title: String? = nil) -> FeedEntry {
        FeedEntry(
            id: id, subscriptionId: show, canonicalURL: "https://example.com/\(id)", audioURL: "https://example.com/\(id).mp3",
            title: title ?? "Episode \(id)", publishedAt: published.map(day), state: state,
            firstSeenAt: seenDay.map(day) ?? published.map(day)
        )
    }

    private func build(_ subscriptions: [FeedSubscription], _ entries: [FeedEntry], looked: [String: Date] = [:]) -> FollowingShowList {
        FollowingShowRows.build(subscriptions: subscriptions, entries: entries, lookedAt: looked, now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
    }

    // MARK: Ordering

    func testShowsAreSortedByNewestEpisodeNotByFollowOrFeedOrder() {
        let list = build(
            [show("a"), show("b"), show("c")],
            [entry("a1", in: "a", day: 3), entry("b1", in: "b", day: 9), entry("b0", in: "b", day: 1), entry("c1", in: "c", day: 5)]
        )
        XCTAssertEqual(list.rows.map(\.id), ["b", "c", "a"])
        XCTAssertEqual(list.rows.first?.newestEpisodeTitle, "Episode b1")
    }

    func testAShowWithNoEpisodesSinksBelowShowsWithEpisodesAndNewestFollowedFirstAmongThem() {
        let list = build(
            [show("old", createdAt: day(1)), show("fresh", createdAt: day(8)), show("busy")],
            [entry("busy1", in: "busy", day: 2)]
        )
        XCTAssertEqual(list.rows.map(\.id), ["busy", "fresh", "old"])
        XCTAssertNil(list.rows[1].newestEpisodeTitle)
        XCTAssertNil(list.rows[1].playEntryID)
        XCTAssertNil(list.rows[1].newLabel)
    }

    func testTiesBreakByNameThenId() {
        let list = build([show("z", title: "Zed"), show("a", title: "Alpha")], [])
        XCTAssertEqual(list.rows.map(\.id), ["a", "z"])
    }

    // MARK: Counts

    func testCountIsEpisodesWaitingAfterTheFollowBaseline() {
        let list = build(
            [show("a")],
            [
                entry("back", in: "a", day: -5),
                entry("n1", in: "a", day: 2),
                entry("n2", in: "a", day: 4),
                entry("played", in: "a", day: 6, state: .imported),
                entry("gone", in: "a", day: 7, state: .dismissed),
            ]
        )
        XCTAssertEqual(list.rows[0].newCount, 2)
        XCTAssertEqual(list.rows[0].newLabel, "2 new")
    }

    func testCountIsSinceTheListenerLastLooked() {
        let entries = [entry("n1", in: "a", day: 2), entry("n2", in: "a", day: 4), entry("n3", in: "a", day: 6)]
        XCTAssertEqual(build([show("a")], entries).rows[0].newCount, 3)
        XCTAssertEqual(build([show("a")], entries, looked: ["a": day(3)]).rows[0].newCount, 2)
        XCTAssertEqual(build([show("a")], entries, looked: ["a": day(10)]).rows[0].newCount, 0)
    }

    func testAnotherShowsLookedMarkerDoesNotClearThisShow() {
        let entries = [entry("n1", in: "a", day: 2)]
        XCTAssertEqual(build([show("a"), show("b")], entries, looked: ["b": day(20)]).rows.first { $0.id == "a" }?.newCount, 1)
    }

    func testAnEntryWithoutAFirstSeenStampFallsBackToItsPublishDate() {
        var legacy = entry("n1", in: "a", day: 4)
        legacy.firstSeenAt = nil
        XCTAssertEqual(build([show("a")], [legacy], looked: ["a": day(3)]).rows[0].newCount, 1)
        XCTAssertEqual(build([show("a")], [legacy], looked: ["a": day(5)]).rows[0].newCount, 0)
    }

    func testANoisyShowIsOneRowWithABiggerNumber() {
        let noisy = (1...40).map { entry("n\($0)", in: "a", day: $0 % 20 + 1) }
        let list = build([show("a")], noisy)
        XCTAssertEqual(list.rows.count, 1)
        XCTAssertEqual(list.rows[0].newCount, 40)
    }

    // MARK: Play

    func testPlayTargetIsTheNewestUnplayedEpisode() {
        let list = build(
            [show("a")],
            [
                entry("newest-played", in: "a", day: 9, state: .imported),
                entry("newest-gone", in: "a", day: 8, state: .dismissed),
                entry("target", in: "a", day: 6, state: .seen),
                entry("older", in: "a", day: 3),
            ]
        )
        XCTAssertEqual(list.rows[0].playEntryID, "target")
        XCTAssertEqual(list.rows[0].newestEpisodeTitle, "Episode newest-played", "the row names the newest episode even when it was played")
    }

    func testNothingToPlayWhenEveryEpisodeIsPlayed() {
        let list = build([show("a")], [entry("e", in: "a", day: 3, state: .imported)])
        XCTAssertNil(list.rows[0].playEntryID)
        XCTAssertEqual(list.rows[0].newCount, 0)
    }

    func testBackCatalogueCanStillBePlayedButIsNotNew() {
        let list = build([show("a")], [entry("old", in: "a", day: -3)])
        XCTAssertEqual(list.rows[0].playEntryID, "old")
        XCTAssertEqual(list.rows[0].newCount, 0)
    }

    // MARK: Quiet

    func testQuietShowsLeaveTheListAndSinkToTheQuietGroupWithNoCount() {
        let list = build(
            [show("loud"), show("hush", muted: true), show("hush2", muted: true)],
            [entry("l1", in: "loud", day: 1), entry("h1", in: "hush", day: 9), entry("h2", in: "hush2", day: 5)]
        )
        XCTAssertEqual(list.rows.map(\.id), ["loud"])
        XCTAssertEqual(list.quiet.map(\.id), ["hush", "hush2"])
        XCTAssertEqual(list.quietTitle, "Quiet (2)")
        XCTAssertTrue(list.quiet.allSatisfy { $0.isQuiet && $0.newCount == 0 && $0.newLabel == nil })
        XCTAssertEqual(list.quiet[0].playEntryID, "h1", "a Quiet show can still be played from its screen")
    }

    func testMutingAShowMovesItAndUnmutingBringsItBackInOrder() {
        let entries = [entry("a1", in: "a", day: 9), entry("b1", in: "b", day: 2)]
        XCTAssertEqual(build([show("a"), show("b")], entries).rows.map(\.id), ["a", "b"])
        let muted = build([show("a", muted: true), show("b")], entries)
        XCTAssertEqual(muted.rows.map(\.id), ["b"])
        XCTAssertEqual(muted.quiet.map(\.id), ["a"])
        XCTAssertEqual(build([show("a"), show("b")], entries).rows.map(\.id), ["a", "b"])
    }

    func testNoQuietShowsGivesAnEmptyGroup() {
        let list = build([show("a")], [])
        XCTAssertTrue(list.quiet.isEmpty)
        XCTAssertEqual(list.quietTitle, "Quiet (0)")
    }

    // MARK: Labels

    func testDateAndAccessibilityLabelNameShowCountAndNewestEpisode() {
        let list = build([show("a", title: "  The   Daily ")], [entry("e", in: "a", day: 3, title: "Salt")])
        let row = list.rows[0]
        XCTAssertEqual(row.title, "The Daily")
        XCTAssertEqual(row.dateLabel, "Nov 17")
        XCTAssertTrue(row.accessibilityLabel.hasPrefix("The Daily."))
        XCTAssertTrue(row.accessibilityLabel.contains("1 new."))
        XCTAssertTrue(row.accessibilityLabel.contains("Newest: Salt."))
    }

    func testAShowWithoutATitleIsNamedByItsHost() {
        var untitled = show("a")
        untitled.source.title = nil
        XCTAssertEqual(build([untitled], []).rows[0].title, "example.com")
    }

    func testEntriesOfShowsNoLongerFollowedAreIgnored() {
        XCTAssertEqual(build([show("a")], [entry("x", in: "ghost", day: 5)]).rows[0].newestEpisodeTitle, nil)
    }

    // MARK: Show screen

    func testEpisodesAreNewestFirstWithoutDismissedAndMarkNewAndInLibrary() {
        let subscription = show("a")
        let episodes = FollowingShowRows.episodes(
            of: subscription,
            in: [
                entry("mid", in: "a", day: 4), entry("top", in: "a", day: 8, state: .imported), entry("gone", in: "a", day: 9, state: .dismissed),
                entry("low", in: "a", day: 1), entry("other", in: "b", day: 12),
            ],
            lookedAt: day(2)
        )
        XCTAssertEqual(episodes.map(\.id), ["top", "mid", "low"])
        XCTAssertEqual(episodes.map(\.isNew), [false, true, false])
        XCTAssertEqual(episodes.map(\.isInLibrary), [true, false, false])
    }

    // MARK: Looked markers

    func testMarkersRoundTripThroughAFileAndAMissingOrBrokenFileIsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("looked-\(UUID().uuidString)/\(FollowingLookedMarkers.fileName)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(FollowingLookedMarkers.load(from: url), FollowingLookedMarkers())
        var markers = FollowingLookedMarkers()
        markers.markLooked("a", at: day(3))
        try markers.save(to: url)
        XCTAssertEqual(FollowingLookedMarkers.load(from: url).lookedAt, ["a": day(3)])
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(FollowingLookedMarkers.load(from: url), FollowingLookedMarkers())
    }

    func testMergeKeepsTheNewerDatePerShow() {
        var memory = FollowingLookedMarkers(lookedAt: ["a": Date(timeIntervalSince1970: 200), "b": Date(timeIntervalSince1970: 50)])
        let disk = FollowingLookedMarkers(lookedAt: ["a": Date(timeIntervalSince1970: 100), "b": Date(timeIntervalSince1970: 90), "c": Date(timeIntervalSince1970: 10)])
        memory.merge(disk)
        XCTAssertEqual(memory.lookedAt["a"], Date(timeIntervalSince1970: 200))
        XCTAssertEqual(memory.lookedAt["b"], Date(timeIntervalSince1970: 90))
        XCTAssertEqual(memory.lookedAt["c"], Date(timeIntervalSince1970: 10))
    }

    func testPruneDropsOnlyUnfollowedShows() {
        var markers = FollowingLookedMarkers(lookedAt: ["a": day(1), "gone": day(2)])
        XCTAssertTrue(markers.prune(keeping: ["a", "b"]))
        XCTAssertEqual(markers.lookedAt.keys.sorted(), ["a"])
        XCTAssertFalse(markers.prune(keeping: ["a"]))
    }

    func testFirstRunSeedsEveryFollowedShowSoNothingIsNewUntilARefreshBringsEpisodes() {
        var markers = FollowingLookedMarkers()
        markers.seed(["a", "b"], at: day(20))
        let waiting = [entry("n1", in: "a", day: 5), entry("n2", in: "b", day: 6)]
        XCTAssertEqual(build([show("a"), show("b")], waiting, looked: markers.lookedAt).rows.map(\.newCount), [0, 0])
        let later = waiting + [entry("n3", in: "a", day: 22)]
        XCTAssertEqual(build([show("a"), show("b")], later, looked: markers.lookedAt).rows.first { $0.id == "a" }?.newCount, 1)
    }

    func testSeedingKeepsExistingMarkersAndRemoveForgetsAShow() {
        var markers = FollowingLookedMarkers(lookedAt: ["a": day(1)])
        markers.seed(["a", "b"], at: day(9))
        XCTAssertEqual(markers.lookedAt, ["a": day(1), "b": day(9)])
        markers.remove("a")
        XCTAssertEqual(markers.lookedAt.keys.sorted(), ["b"])
    }

    func testAMissingOrCorruptFileIsNilSoTheCallerSeeds() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("looked-\(UUID().uuidString)/\(FollowingLookedMarkers.fileName)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertNil(FollowingLookedMarkers.loadIfPresent(from: url))
        try FollowingLookedMarkers().save(to: url)
        XCTAssertNotNil(FollowingLookedMarkers.loadIfPresent(from: url))
        try Data("{".utf8).write(to: url)
        XCTAssertNil(FollowingLookedMarkers.loadIfPresent(from: url))
    }

    func testSubSecondPrecisionSurvivesTheFileSoAnEntrySeenJustBeforeTheOpenIsNotNew() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("looked-\(UUID().uuidString)/\(FollowingLookedMarkers.fileName)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let opened = day(5).addingTimeInterval(0.9)
        var markers = FollowingLookedMarkers()
        markers.markLooked("a", at: opened)
        try markers.save(to: url)
        let loaded = FollowingLookedMarkers.load(from: url)
        XCTAssertEqual(loaded.lookedAt["a"], opened)
        var seenJustBefore = entry("e", in: "a", day: 4)
        seenJustBefore.firstSeenAt = day(5).addingTimeInterval(0.4)
        XCTAssertEqual(build([show("a")], [seenJustBefore], looked: loaded.lookedAt).rows[0].newCount, 0)
    }

    /// #2690 audits: Following opened before the first feed refresh, while the model's list of followed shows was
    /// still empty. Settling against that list saved an empty file, and the next launch counted every episode as
    /// new. Settling against the store's list, across two launches, keeps every followed show marked.
    func testTheFirstLoadSettlesMarkersAgainstTheStoresFollowedShowsAcrossLaunches() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("looked-\(UUID().uuidString)/\(FollowingLookedMarkers.fileName)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = FollowingLookedMarkers.afterFirstLoad(inMemory: FollowingLookedMarkers(), saved: FollowingLookedMarkers.loadIfPresent(from: url),
                                                          followed: ["a", "b"], now: day(1))
        XCTAssertEqual(first.lookedAt, ["a": day(1), "b": day(1)], "the first run stamps every followed show")
        try first.save(to: url)

        let second = FollowingLookedMarkers.afterFirstLoad(inMemory: FollowingLookedMarkers(), saved: FollowingLookedMarkers.loadIfPresent(from: url),
                                                           followed: ["a", "b"], now: day(5))
        XCTAssertEqual(second.lookedAt, ["a": day(1), "b": day(1)], "the next launch keeps the saved times")
    }

    /// #2690 audit on c79b872: a show followed after the file existed, never opened, has no marker and counts
    /// what arrived since it was followed. The next launch must not stamp it, or "2 new" becomes "0 new".
    func testAShowFollowedButNeverOpenedKeepsItsNewCountAcrossALaunch() {
        let fileFromAnEarlierLaunch = FollowingLookedMarkers(lookedAt: ["a": day(1)])
        let next = FollowingLookedMarkers.afterFirstLoad(inMemory: FollowingLookedMarkers(), saved: fileFromAnEarlierLaunch,
                                                         followed: ["a", "x"], now: day(6))
        XCTAssertEqual(next.lookedAt, ["a": day(1)], "x, followed and never opened, gets no marker")
        XCTAssertNil(next.lookedAt["x"])
    }

    func testTheFirstLoadKeepsTheNewerDateAndDropsUnfollowedShows() {
        var memory = FollowingLookedMarkers()
        memory.markLooked("a", at: day(4))
        let saved = FollowingLookedMarkers(lookedAt: ["a": day(3), "gone": day(1)])
        XCTAssertEqual(FollowingLookedMarkers.afterFirstLoad(inMemory: memory, saved: saved, followed: ["a"], now: day(9)).lookedAt,
                       ["a": day(4)], "the newer date wins and an unfollowed show's marker goes")
    }

}
