import XCTest
@testable import SessionKit

/// #4046 PR 9: what rules do to a show's episodes. One evaluator; every surface reads it.
final class ListeningRuleEvaluatorTests: XCTestCase {
    private let showA = ListMember(feedKey: "https://a.example/feed", podcastGUID: "guid-a")
    private let showB = ListMember(feedKey: "https://b.example/feed")

    private func entry(_ id: String, _ title: String, day: Int, summary: String? = nil) -> FeedEntry {
        FeedEntry(id: id, subscriptionId: "sub", canonicalURL: "https://x.example/\(id)", title: title, summary: summary,
                  publishedAt: Date(timeIntervalSince1970: Double(day) * 86_400))
    }

    private func rule(_ id: String, _ action: ListeningRuleAction, _ words: [String], scope: ListeningRuleScope = .any, isOn: Bool = true) -> ListeningRule {
        ListeningRule(id: id, action: action, words: words, scope: scope, isOn: isOn, createdAt: Date(timeIntervalSince1970: 0))
    }

    private func rule(_ id: String, _ words: [String], scope: ListeningRuleScope = .any, isOn: Bool = true) -> ListeningRule {
        rule(id, .skip, words, scope: scope, isOn: isOn)
    }

    private func evaluate(
        _ shows: [ListeningRuleShow], rules: [ListeningRule], lists: [FollowList] = [], marks: [ShowLessMark] = [], protected: Set<String> = []
    ) -> ListeningRuleEvaluation {
        ListeningRuleEvaluator.evaluate(entriesByShow: shows, rules: rules, lists: lists, marks: marks, protected: protected)
    }

    private var mixedShow: ListeningRuleShow {
        ListeningRuleShow(id: "a", member: showA, entries: [
            entry("e1", "Crypto crash", day: 10), entry("e2", "Gardening", day: 9), entry("e3", "More crypto", day: 8),
            entry("e4", "Cooking", day: 7), entry("e5", "Baking bread", day: 6), entry("e6", "Walking", day: 5),
        ])
    }

    func testASkipRuleSetsAsideMatchesAndNothingElse() {
        let outcome = evaluate([mixedShow], rules: [rule("r", ["crypto"])]).outcome(for: "a")
        XCTAssertEqual(outcome.setAside, ["e1", "e3"])
        XCTAssertEqual(outcome.skippedByWord, ["e1": "crypto", "e3": "crypto"])
        XCTAssertTrue(outcome.picks.isEmpty)
        XCTAssertTrue(outcome.pausedRuleIds.isEmpty)
    }

    func testNoRulesAndNoMarksChangeNothing() {
        XCTAssertEqual(evaluate([mixedShow], rules: []), ListeningRuleEvaluation())
        XCTAssertEqual(evaluate([mixedShow], rules: [rule("r", ["crypto"], isOn: false)]), ListeningRuleEvaluation(), "a rule that is off does nothing")
        XCTAssertTrue(evaluate([mixedShow], rules: []).outcome(for: "a").isEmpty)
        XCTAssertTrue(evaluate([mixedShow], rules: []).setAsideEntryIds.isEmpty)
    }

    func testSwitchingARuleOffBringsEpisodesBack() {
        let on = evaluate([mixedShow], rules: [rule("r", ["crypto"])]).setAsideEntryIds
        let off = evaluate([mixedShow], rules: [rule("r", ["crypto"], isOn: false)]).setAsideEntryIds
        XCTAssertEqual(on, ["e1", "e3"])
        XCTAssertTrue(off.isEmpty)
    }

    func testAPickRuleLabelsAndNeverSetsAside() {
        let outcome = evaluate([mixedShow], rules: [rule("r", .more, ["baking", "walking"])]).outcome(for: "a")
        XCTAssertEqual(outcome.picks, ["e5", "e6"])
        XCTAssertTrue(outcome.setAside.isEmpty)
    }

    func testASetAsideEpisodeIsNotAlsoAPick() {
        let outcome = evaluate([mixedShow], rules: [rule("skip", ["crypto"]), rule("pick", .more, ["crash", "gardening"])]).outcome(for: "a")
        XCTAssertEqual(outcome.setAside, ["e1", "e3"])
        XCTAssertEqual(outcome.picks, ["e2"], "e1 matches the pick rule too, but a skip wins")
    }

    // MARK: protected

    func testProtectedEpisodesAreNeverSetAside() {
        // finished, part played (99%), in the Library, and holding a friend's Margins: the caller puts all of them in `protected`.
        let outcome = evaluate([mixedShow], rules: [rule("r", ["crypto"])], protected: ["e1"]).outcome(for: "a")
        XCTAssertEqual(outcome.setAside, ["e3"], "e1 matches the rule and stays listed")
        XCTAssertNil(outcome.skippedByWord["e1"])
        let everything = evaluate([mixedShow], rules: [rule("r", ["crypto"])], protected: ["e1", "e3"])
        XCTAssertTrue(everything.setAsideEntryIds.isEmpty)
    }

    func testAProtectedEpisodeCanStillBeAPick() {
        let outcome = evaluate([mixedShow], rules: [rule("r", .more, ["crypto"])], protected: ["e1"]).outcome(for: "a")
        XCTAssertEqual(outcome.picks, ["e1", "e3"])
    }

    // MARK: Show less marks

    func testAShowLessMarkSetsTheEpisodeAsideWithNoRule() {
        let marks = [ShowLessMark(feedKey: showA.feedKey, entryId: "e2", title: "Gardening")]
        let outcome = evaluate([mixedShow], rules: [], marks: marks).outcome(for: "a")
        XCTAssertEqual(outcome.setAside, ["e2"])
        XCTAssertEqual(outcome.markedShowLess, ["e2"])
        XCTAssertTrue(outcome.skippedByWord.isEmpty)
    }

    func testAMarkedAndMatchingEpisodeCountsAsMarked() {
        let marks = [ShowLessMark(feedKey: showA.feedKey, entryId: "e1", title: "Crypto crash")]
        let outcome = evaluate([mixedShow], rules: [rule("r", ["crypto"])], marks: marks).outcome(for: "a")
        XCTAssertEqual(outcome.setAside, ["e1", "e3"])
        XCTAssertEqual(outcome.markedShowLess, ["e1"])
        XCTAssertEqual(outcome.skippedByWord, ["e3": "crypto"])
    }

    func testAProtectedEpisodeIsNotSetAsideByAMarkEither() {
        let marks = [ShowLessMark(feedKey: showA.feedKey, entryId: "e2", title: "Gardening")]
        XCTAssertTrue(evaluate([mixedShow], rules: [], marks: marks, protected: ["e2"]).setAsideEntryIds.isEmpty, "a played episode never vanishes")
    }

    func testAProtectedMarkedEpisodeCanStillBeAPick() {
        let marks = [ShowLessMark(feedKey: showA.feedKey, entryId: "e2", title: "Gardening")]
        let outcome = evaluate([mixedShow], rules: [rule("r", .more, ["gardening"])], marks: marks, protected: ["e2"]).outcome(for: "a")
        XCTAssertTrue(outcome.setAside.isEmpty)
        XCTAssertEqual(outcome.picks, ["e2"], "protected, so listed, and it matches the pick rule like any other protected episode")
    }

    func testAMarkWithOnlyAnItemIdDoesNotTouchEntries() {
        let marks = [ShowLessMark(feedKey: showA.feedKey, itemId: "item-1", title: "Gardening")]
        XCTAssertTrue(evaluate([mixedShow], rules: [], marks: marks).setAsideEntryIds.isEmpty)
    }

    func testTheSameMarkFromTwoEntryPointsHasOneId() {
        let fromShowScreen = ShowLessMark(feedKey: showA.feedKey, entryId: "e2", itemId: nil, title: "Gardening")
        let fromItemScreen = ShowLessMark(feedKey: showA.feedKey, entryId: "e2", itemId: "item-9", title: "Gardening")
        XCTAssertEqual(fromShowScreen.id, fromItemScreen.id)
        XCTAssertEqual(ShowLessMark(feedKey: "k", itemId: "item-9", title: "t").id, "item-9", "no entry, the item id")
        XCTAssertEqual(ShowLessMark(feedKey: "k", entryId: "", itemId: "item-9", title: "t").id, "item-9", "a blank entry id is none")
    }

    // MARK: scope

    func testScopeAnyShowAndList() {
        let b = ListeningRuleShow(id: "b", member: showB, entries: [entry("b1", "Crypto talk", day: 3), entry("b2", "Other", day: 2)])
        let list = FollowList(id: "L", name: "News", members: [showB])
        let shows = [mixedShow, b]

        let any = evaluate(shows, rules: [rule("r", ["crypto"])])
        XCTAssertEqual(any.outcome(for: "a").setAside, ["e1", "e3"])
        XCTAssertEqual(any.outcome(for: "b").setAside, ["b1"])

        let onlyA = evaluate(shows, rules: [rule("r", ["crypto"], scope: .show(showA))])
        XCTAssertEqual(onlyA.outcome(for: "a").setAside, ["e1", "e3"])
        XCTAssertTrue(onlyA.outcome(for: "b").isEmpty)

        let onlyList = evaluate(shows, rules: [rule("r", ["crypto"], scope: .list("L"))], lists: [list])
        XCTAssertTrue(onlyList.outcome(for: "a").isEmpty, "A is not in the list")
        XCTAssertEqual(onlyList.outcome(for: "b").setAside, ["b1"])

        let listGone = evaluate(shows, rules: [rule("r", ["crypto"], scope: .list("missing"))], lists: [list])
        XCTAssertTrue(listGone.setAsideEntryIds.isEmpty, "a rule for a list that no longer exists applies to nothing")
    }

    func testAShowScopeFindsTheShowByGUIDAfterAFeedMove() {
        let moved = ListeningRuleShow(id: "a", member: ListMember(feedKey: "https://new-host.example/feed", podcastGUID: "GUID-A"), entries: mixedShow.entries)
        let outcome = evaluate([moved], rules: [rule("r", ["crypto"], scope: .show(showA))]).outcome(for: "a")
        XCTAssertEqual(outcome.setAside, ["e1", "e3"])
    }

    func testAListRuleFollowsTheListAsItChanges() {
        var list = FollowList(id: "L", name: "News", members: [])
        let rules = [rule("r", ["crypto"], scope: .list("L"))]
        XCTAssertTrue(evaluate([mixedShow], rules: rules, lists: [list]).setAsideEntryIds.isEmpty)
        list.add(showA)
        XCTAssertEqual(evaluate([mixedShow], rules: rules, lists: [list]).outcome(for: "a").setAside, ["e1", "e3"])
    }

    // MARK: the guard

    private func showWith(matching: Int, of total: Int) -> ListeningRuleShow {
        let entries = (0..<total).map { index in entry("g\(index)", index < matching ? "Crypto \(index)" : "Other \(index)", day: 100 - index) }
        return ListeningRuleShow(id: "g", member: showA, entries: entries)
    }

    func testTheGuardAt89And90Percent() {
        let r = rule("r", ["crypto"])
        // 30 episodes: 26 is 86.7%, 27 is exactly 90%.
        let at26 = evaluate([showWith(matching: 26, of: 30)], rules: [r]).outcome(for: "g")
        XCTAssertEqual(at26.setAside.count, 26)
        XCTAssertTrue(at26.pausedRuleIds.isEmpty)
        let at27 = evaluate([showWith(matching: 27, of: 30)], rules: [r]).outcome(for: "g")
        XCTAssertTrue(at27.setAside.isEmpty, "a paused rule doesn't apply to the show")
        XCTAssertEqual(at27.pausedRuleIds, ["r"])
        // 100 episodes: only the newest 30 count. 89 matches overall, all in the window would be too broad, so put 26 in it.
        let long = showWith(matching: 26, of: 100)
        XCTAssertEqual(evaluate([long], rules: [r]).outcome(for: "g").setAside.count, 26)
    }

    func testTheGuardNeedsAtLeastFiveMatches() {
        let r = rule("r", ["crypto"])
        // 4 of 4 is 100%, but under 5 matches.
        let four = evaluate([showWith(matching: 4, of: 4)], rules: [r]).outcome(for: "g")
        XCTAssertEqual(four.setAside.count, 4)
        XCTAssertTrue(four.pausedRuleIds.isEmpty)
        // 5 of 5 is too broad.
        XCTAssertEqual(evaluate([showWith(matching: 5, of: 5)], rules: [r]).outcome(for: "g").pausedRuleIds, ["r"])
        // 5 of 6 is 83%: fine.
        XCTAssertTrue(evaluate([showWith(matching: 5, of: 6)], rules: [r]).outcome(for: "g").pausedRuleIds.isEmpty)
    }

    func testTheGuardLooksAtTheNewestThirtyOnly() {
        // The newest 30 all match; 20 older ones don't. The window is too broad, so the rule is paused for the show.
        var entries = (0..<30).map { entry("n\($0)", "Crypto \($0)", day: 200 - $0) }
        entries += (0..<20).map { entry("o\($0)", "Other \($0)", day: 100 - $0) }
        let show = ListeningRuleShow(id: "g", member: showA, entries: entries.shuffled())
        XCTAssertEqual(evaluate([show], rules: [rule("r", ["crypto"])]).outcome(for: "g").pausedRuleIds, ["r"])
        // And the other way round: old matches outside the window don't count.
        var flipped = (0..<30).map { entry("n\($0)", "Other \($0)", day: 200 - $0) }
        flipped += (0..<20).map { entry("o\($0)", "Crypto \($0)", day: 100 - $0) }
        let quiet = ListeningRuleShow(id: "g", member: showA, entries: flipped)
        let outcome = evaluate([quiet], rules: [rule("r", ["crypto"])]).outcome(for: "g")
        XCTAssertTrue(outcome.pausedRuleIds.isEmpty)
        XCTAssertEqual(outcome.setAside.count, 20, "the rule still sets aside the old matches")
    }

    func testTheGuardCountsMatchesNotSetAsides() {
        // Protected episodes still count as matches, so protecting them can't hide a too-broad rule.
        let show = showWith(matching: 30, of: 30)
        let outcome = evaluate([show], rules: [rule("r", ["crypto"])], protected: Set(show.entries.map(\.id))).outcome(for: "g")
        XCTAssertEqual(outcome.pausedRuleIds, ["r"])
    }

    func testAPickRuleIsNeverPaused() {
        let outcome = evaluate([showWith(matching: 30, of: 30)], rules: [rule("r", .more, ["crypto"])]).outcome(for: "g")
        XCTAssertEqual(outcome.picks.count, 30)
        XCTAssertTrue(outcome.pausedRuleIds.isEmpty)
    }

    func testPausingOneRuleLeavesTheOthers() {
        let outcome = evaluate([showWith(matching: 30, of: 30)], rules: [rule("broad", ["crypto"]), rule("narrow", ["crypto 3"])]).outcome(for: "g")
        XCTAssertEqual(outcome.pausedRuleIds, ["broad"])
        XCTAssertEqual(outcome.setAside, ["g3"])
    }

    func testTurningOnIsRefusedWhenTooBroadForAnyShowInScope() {
        let broad = showWith(matching: 30, of: 30)
        let fine = ListeningRuleShow(id: "b", member: showB, entries: [entry("b1", "Crypto", day: 1), entry("b2", "Other", day: 2)])
        let skip = rule("r", ["crypto"], isOn: false)
        XCTAssertEqual(ListeningRuleEvaluator.tooBroadShows(for: skip, shows: [broad, fine], lists: []),
                       [ListeningRuleBroadness(showId: "g", matched: 30, window: 30)])
        XCTAssertTrue(ListeningRuleEvaluator.tooBroadShows(for: rule("r", ["crypto"], scope: .show(showB), isOn: false), shows: [broad, fine], lists: []).isEmpty,
                      "only shows in the rule's scope count")
        XCTAssertTrue(ListeningRuleEvaluator.tooBroadShows(for: rule("r", .more, ["crypto"], isOn: false), shows: [broad], lists: []).isEmpty)
        XCTAssertFalse(ListeningRuleEvaluator.isTooBroad(matched: 4, window: 4))
        XCTAssertTrue(ListeningRuleEvaluator.isTooBroad(matched: 27, window: 30))
        XCTAssertFalse(ListeningRuleEvaluator.isTooBroad(matched: 26, window: 30))
    }

    // MARK: determinism and size

    func testTheResultDoesNotDependOnEntryOrder() {
        let forward = evaluate([mixedShow], rules: [rule("r", ["crypto"])])
        var reversed = mixedShow
        reversed.entries.reverse()
        XCTAssertEqual(forward, evaluate([reversed], rules: [rule("r", ["crypto"])]))
    }

    func testTwoHundredRulesOverFiveThousandEpisodes() {
        let rules = (0..<200).map { rule("r\($0)", $0 % 5 == 0 ? .more : .skip, ["zzword\($0)", "phrase\($0) tail*"], scope: .any) }
        let shows = (0..<10).map { showIndex in
            ListeningRuleShow(id: "s\(showIndex)", member: ListMember(feedKey: "https://s\(showIndex).example/feed"), entries: (0..<500).map {
                entry("s\(showIndex)-\($0)", $0 == 7 ? "Episode zzword3 here" : "Episode number \($0) about gardening and cooking", day: $0,
                      summary: "A long summary about many things that happened this week in the world of food and plants")
            })
        }
        let started = Date()
        let evaluation = evaluate(shows, rules: rules)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(evaluation.outcome(for: "s0").setAside, ["s0-7"])
        // Performance budget (#4573, scripts/test_clock_ceilings_allowlist.json): about 1.2 s on a Mac in a debug build (2026-11-20), against
        // the 100 ms the release build must meet. Each ceiling is at least 5x the typical time and guards an evaluation
        // that grows faster than rules times episodes.
        #if DEBUG
        let budget = 10.0
        #else
        let budget = 0.5
        #endif
        XCTAssertLessThan(elapsed, budget, "200 rules over 5,000 episodes took \(elapsed) s")
    }
}
