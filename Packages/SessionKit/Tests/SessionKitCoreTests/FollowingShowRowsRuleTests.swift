import XCTest
@testable import SessionKit

/// #4046 PR 10a: the evaluator read by the Following rows and the show's episode list. With no rule on and nothing marked,
/// nothing changes; once one is, every part of a row describes the same episode, the newest one not set aside.
final class FollowingShowRowsRuleTests: XCTestCase {
    private let followed = Date(timeIntervalSince1970: 1_700_000_000)
    private let now = Date(timeIntervalSince1970: 1_700_000_000 + 30 * 86_400)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ n: Int) -> Date { followed.addingTimeInterval(Double(n) * 86_400) }

    private func show(_ id: String, muted: Bool = false) -> FeedSubscription {
        FeedSubscription(
            id: id,
            source: SourceIdentity(id: "source-\(id)", kind: .podcastFeed, canonicalURL: "https://example.com/\(id).xml", host: "example.com", title: "Show \(id)"),
            state: muted ? .muted : .active,
            createdAt: followed
        )
    }

    private func entry(_ id: String, in show: String, day published: Int, title: String, state: FeedEntryState = .unseen) -> FeedEntry {
        FeedEntry(
            id: id, subscriptionId: show, canonicalURL: "https://example.com/\(id)", audioURL: "https://example.com/\(id).mp3",
            title: title, publishedAt: day(published), state: state, firstSeenAt: day(published)
        )
    }

    private func skip(_ words: String..., scope: ListeningRuleScope = .any, on: Bool = true) -> ListeningRule {
        ListeningRule(id: "skip-\(words.joined())", action: .skip, words: words, scope: scope, isOn: on)
    }

    private func more(_ words: String...) -> ListeningRule {
        ListeningRule(id: "more-\(words.joined())", action: .more, words: words, scope: .any, isOn: true)
    }

    private func rows(
        _ subscriptions: [FeedSubscription], _ entries: [FeedEntry], inputs: FollowingRuleInputs = FollowingRuleInputs(),
        looked: [String: Date] = [:], library: [String: FollowingLibraryEpisode] = [:]
    ) -> FollowingShowList {
        let evaluation = FollowingRuleEvaluation.evaluate(
            subscriptions: subscriptions, entries: entries, inputs: inputs, libraryEpisodes: library)
        return FollowingShowRows.build(
            subscriptions: subscriptions, entries: entries, lookedAt: looked, libraryEpisodes: library,
            rules: evaluation, now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
    }

    private var fixtureShows: [FeedSubscription] { [show("a"), show("b"), show("q", muted: true)] }

    private var fixtureEntries: [FeedEntry] {
        [
            entry("a3", in: "a", day: 12, title: "Crypto weekly"), entry("a2", in: "a", day: 10, title: "Gardening notes"),
            entry("a1", in: "a", day: 5, title: "Old news", state: .imported),
            entry("b2", in: "b", day: 11, title: "Maps and more"), entry("b1", in: "b", day: 3, title: "Early days", state: .dismissed),
            entry("q1", in: "q", day: 9, title: "Crypto quiet"),
        ]
    }

    // MARK: Nothing on, nothing changes

    func testWithNoRulesAndNoMarksTheRowsMatchTheRowsBuiltBeforeTheChange() {
        let before = FollowingShowRows.build(
            subscriptions: fixtureShows, entries: fixtureEntries, now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
        let inertInputs: [(String, FollowingRuleInputs)] = [
            ("nothing at all", FollowingRuleInputs()),
            ("a rule switched off", FollowingRuleInputs(rules: [skip("crypto", on: false)])),
            ("a list and no rules", FollowingRuleInputs(lists: [FollowList(name: "News")])),
        ]
        for (name, inputs) in inertInputs {
            XCTAssertTrue(inputs.isInert, name)
            XCTAssertEqual(rows(fixtureShows, fixtureEntries, inputs: inputs), before, name)
        }
        XCTAssertEqual(before.rows.first?.pickCount, 0)
        XCTAssertNil(before.rows.first?.pickLabel)
        // The rows themselves, pinned: newest episode first, and each row on its own newest episode.
        XCTAssertEqual(before.rows.map(\.id), ["a", "b"])
        XCTAssertEqual(before.rows.map(\.newestEntryID), ["a3", "b2"])
        XCTAssertEqual(before.rows.map(\.playEntryID), ["a3", "b2"])
        XCTAssertEqual(before.rows.map(\.newCount), [2, 1])
        XCTAssertEqual(before.quiet.map(\.newestEntryID), ["q1"])
    }

    func testEpisodesCarryNoFlagsWithNoRules() {
        let episodes = FollowingShowRows.episodes(of: show("a"), in: fixtureEntries, lookedAt: nil)
        XCTAssertEqual(episodes.map(\.id), ["a3", "a2", "a1"])
        XCTAssertTrue(episodes.allSatisfy { !$0.isSetAside && !$0.isPick })
    }

    // MARK: A skip rule

    func testASkippedEpisodeIsGoneFromEveryPartOfTheRow() {
        let inputs = FollowingRuleInputs(rules: [skip("crypto")])
        let list = rows(fixtureShows, fixtureEntries, inputs: inputs)
        let row = try! XCTUnwrap(list.rows.first { $0.id == "a" })
        // a3 is the newest and matches; the row describes a2 everywhere.
        XCTAssertEqual(row.newestEpisodeTitle, "Gardening notes")
        XCTAssertEqual(row.newestEpisodeDate, day(10))
        XCTAssertEqual(row.newestEntryID, "a2")
        XCTAssertEqual(row.playEntryID, "a2")
        XCTAssertEqual(row.addEntryID, "a2")
        XCTAssertEqual(row.newCount, 1)
        XCTAssertEqual(row.newLabel, "1 new")
        XCTAssertTrue(row.accessibilityLabel.contains("Gardening notes"))
        XCTAssertFalse(row.accessibilityLabel.contains("Crypto"))
        // Show b's newest is day 11, a's is now day 10: b sorts first.
        XCTAssertEqual(list.rows.map(\.id), ["b", "a"])
    }

    func testTheRowAndTheEpisodeListAgreeOnWhatIsSetAside() {
        let inputs = FollowingRuleInputs(rules: [skip("crypto")])
        let evaluation = FollowingRuleEvaluation.evaluate(subscriptions: fixtureShows, entries: fixtureEntries, inputs: inputs)
        let episodes = FollowingShowRows.episodes(of: show("a"), in: fixtureEntries, lookedAt: nil, rules: evaluation)
        XCTAssertEqual(episodes.map(\.id), ["a3", "a2", "a1"], "set-aside episodes stay on the show's own screen")
        XCTAssertEqual(episodes.filter(\.isSetAside).map(\.id), ["a3"])
        XCTAssertFalse(episodes[0].isNew, "a set-aside episode is never new")
        XCTAssertTrue(episodes[1].isNew)
        let newInList = episodes.filter(\.isNew).count
        XCTAssertEqual(newInList, rows(fixtureShows, fixtureEntries, inputs: inputs).rows.first { $0.id == "a" }?.newCount)
    }

    func testAShowLessMarkSetsAnEpisodeAsideWithNoRule() {
        let mark = ShowLessMark(feedKey: "example.com/a.xml", entryId: "a3", title: "Crypto weekly")
        let inputs = FollowingRuleInputs(marks: [mark])
        XCTAssertFalse(inputs.isInert)
        let row = try! XCTUnwrap(rows(fixtureShows, fixtureEntries, inputs: inputs).rows.first { $0.id == "a" })
        XCTAssertEqual(row.newestEntryID, "a2")
        XCTAssertEqual(row.playEntryID, "a2")
    }

    func testAnEpisodeInTheLibraryIsNeverSetAside() {
        // a3 matches the rule but is in the Library; so does b1... only a3 is a hit.
        var entries = fixtureEntries
        entries[0].state = .imported
        let row = try! XCTUnwrap(rows(fixtureShows, entries, inputs: FollowingRuleInputs(rules: [skip("crypto")]), library: [
            "a3": FollowingLibraryEpisode(itemID: "item-a3", isFinished: false),
        ]).rows.first { $0.id == "a" })
        XCTAssertEqual(row.newestEntryID, "a3")
        XCTAssertEqual(row.playItemID, "item-a3")
    }

    func testAnEntryWithALibraryItemIsProtectedEvenWhenItsStateIsBehind() {
        let protected = FollowingRuleEvaluation.protectedEntryIds(
            entries: fixtureEntries, libraryEpisodes: ["a2": FollowingLibraryEpisode(itemID: "i", isFinished: true)])
        XCTAssertEqual(protected, ["a1", "a2"])
    }

    func testSwitchingTheRuleOffBringsTheEpisodeBack() {
        let on = rows(fixtureShows, fixtureEntries, inputs: FollowingRuleInputs(rules: [skip("crypto")]))
        let off = rows(fixtureShows, fixtureEntries, inputs: FollowingRuleInputs(rules: [skip("crypto", on: false)]))
        XCTAssertNotEqual(on, off)
        XCTAssertEqual(off, rows(fixtureShows, fixtureEntries))
        XCTAssertEqual(off.rows.first { $0.id == "a" }?.newestEntryID, "a3")
    }

    func testAShowScopedRuleOnlyTouchesItsShow() {
        let member = FollowListEditing.member(for: show("b"))
        let inputs = FollowingRuleInputs(rules: [skip("crypto", scope: .show(member))])
        let list = rows(fixtureShows, fixtureEntries, inputs: inputs)
        XCTAssertEqual(list.rows.first { $0.id == "a" }?.newestEntryID, "a3", "the rule is scoped to show b")
        let list2 = FollowingRuleInputs(rules: [skip("crypto", scope: .show(FollowListEditing.member(for: show("a"))))])
        XCTAssertEqual(rows(fixtureShows, fixtureEntries, inputs: list2).rows.first { $0.id == "a" }?.newestEntryID, "a2")
    }

    func testAListScopedRuleFollowsTheListsMembers() {
        let news = FollowList(id: "news", name: "News", members: [FollowListEditing.member(for: show("a"))])
        let inputs = FollowingRuleInputs(rules: [skip("crypto", scope: .list("news"))], lists: [news])
        let list = rows(fixtureShows, fixtureEntries, inputs: inputs)
        XCTAssertEqual(list.rows.first { $0.id == "a" }?.newestEntryID, "a2")
        XCTAssertEqual(list.quiet.first?.newestEntryID, "q1", "show q is not in the list")
    }

    func testEveryEpisodeSetAsideLeavesTheShowWithNothingToPreview() {
        let row = try! XCTUnwrap(rows([show("b")], fixtureEntries.filter { $0.subscriptionId == "b" },
                                      inputs: FollowingRuleInputs(rules: [skip("maps")])).rows.first)
        XCTAssertNil(row.newestEntryID)
        XCTAssertNil(row.playEntryID)
        XCTAssertNil(row.addEntryID)
        XCTAssertEqual(row.newCount, 0)
    }

    // MARK: Picks

    func testPicksAreCountedAmongNewEpisodesOnly() {
        let entries = [
            entry("p3", in: "a", day: 12, title: "Maps deep dive"), entry("p2", in: "a", day: 11, title: "Maps again"),
            entry("p1", in: "a", day: 10, title: "Maps played", state: .imported), entry("p0", in: "a", day: 9, title: "Weather"),
        ]
        let list = rows([show("a")], entries, inputs: FollowingRuleInputs(rules: [more("maps")]), looked: ["a": day(0)])
        let row = try! XCTUnwrap(list.rows.first)
        XCTAssertEqual(row.newCount, 3)
        XCTAssertEqual(row.pickCount, 2)
        XCTAssertEqual(row.pickLabel, "2 picks")
        XCTAssertTrue(row.accessibilityLabel.contains("3 new. 2 picks."), row.accessibilityLabel)
        XCTAssertEqual(row.newestEntryID, "p3", "a pick rule never reorders")
    }

    func testOnePickReadsSingular() {
        let list = rows([show("a")], [entry("p1", in: "a", day: 10, title: "Maps")], inputs: FollowingRuleInputs(rules: [more("maps")]))
        XCTAssertEqual(list.rows.first?.pickLabel, "1 pick")
    }

    func testAQuietShowCountsNoPicks() {
        let list = rows([show("q", muted: true)], [entry("q1", in: "q", day: 9, title: "Maps")], inputs: FollowingRuleInputs(rules: [more("maps")]))
        XCTAssertEqual(list.quiet.first?.pickCount, 0)
    }

    func testAnEpisodeIsFlaggedAPickOnTheShowsOwnList() {
        let entries = [entry("p2", in: "a", day: 11, title: "Maps"), entry("p1", in: "a", day: 10, title: "Weather")]
        let inputs = FollowingRuleInputs(rules: [more("maps")])
        let evaluation = FollowingRuleEvaluation.evaluate(subscriptions: [show("a")], entries: entries, inputs: inputs)
        let episodes = FollowingShowRows.episodes(of: show("a"), in: entries, rules: evaluation)
        XCTAssertEqual(episodes.filter(\.isPick).map(\.id), ["p2"])
    }

    // MARK: The set-aside set for "Add everything new"

    func testSetAsideForOneShowIsWhatTheRowsDrop() {
        let inputs = FollowingRuleInputs(rules: [skip("crypto")])
        XCTAssertEqual(FollowingRuleEvaluation.setAside(entries: fixtureEntries.filter { $0.subscriptionId == "a" }, subscription: show("a"), inputs: inputs), ["a3"])
        XCTAssertEqual(FollowingRuleEvaluation.setAside(entries: fixtureEntries, subscription: show("b"), inputs: inputs), [])
        XCTAssertEqual(FollowingRuleEvaluation.setAside(entries: fixtureEntries, subscription: show("a"), inputs: FollowingRuleInputs()), [])
    }

    func testEntriesOfOtherShowsAreIgnored() {
        let evaluation = FollowingRuleEvaluation.evaluate(
            subscriptions: [show("a")], entries: fixtureEntries, inputs: FollowingRuleInputs(rules: [skip("crypto")]))
        XCTAssertEqual(evaluation.setAsideEntryIds, ["a3"], "q1 matches the rule but belongs to a show that was not asked about")
    }

    func testTwoHundredRulesOverFiveThousandEpisodesAreFast() {
        let shows = (0..<50).map { show("s\($0)") }
        var entries: [FeedEntry] = []
        for subscription in shows { for n in 0..<100 { entries.append(entry("\(subscription.id)-\(n)", in: subscription.id, day: n % 28, title: "Episode \(n) about topic\(n % 17)")) } }
        let rules = (0..<200).map { ListeningRule(id: "r\($0)", action: .skip, words: ["zzword\($0)"], isOn: true) }
        let inputs = FollowingRuleInputs(rules: rules)
        let started = Date()
        let evaluation = FollowingRuleEvaluation.evaluate(subscriptions: shows, entries: entries, inputs: inputs)
        XCTAssertEqual(evaluation.setAsideEntryIds, [])
        // The Design's budget is 100 ms on the host; the ceiling here is generous so a busy runner doesn't fail it.
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
