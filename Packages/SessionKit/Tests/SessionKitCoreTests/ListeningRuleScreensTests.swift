import XCTest
@testable import SessionKit

/// #4046 PR 10b: the words and rows the Rules screens, the Show screen's Skipped group and Following's badge draw.
final class ListeningRuleScreensTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func show(_ id: String, title: String) -> FeedSubscription {
        FeedSubscription(
            id: id,
            source: SourceIdentity(id: "source-\(id)", kind: .podcastFeed, canonicalURL: "https://example.com/\(id).xml", host: "example.com", title: title),
            createdAt: base
        )
    }

    private func entry(_ id: String, in show: String, day: Int, title: String, summary: String? = nil) -> FeedEntry {
        FeedEntry(id: id, subscriptionId: show, canonicalURL: "https://example.com/\(id)", title: title, summary: summary,
                  publishedAt: base.addingTimeInterval(Double(day) * 86_400), state: .unseen)
    }

    private func member(_ subscription: FeedSubscription) -> ListMember { FollowListEditing.member(for: subscription) }

    // MARK: Sentences

    func testWordListQuotesAndJoinsWithOr() {
        XCTAssertEqual(ListeningRuleScreens.wordList([]), "")
        XCTAssertEqual(ListeningRuleScreens.wordList(["a"]), "“a”")
        XCTAssertEqual(ListeningRuleScreens.wordList(["a", "b"]), "“a” or “b”")
        XCTAssertEqual(ListeningRuleScreens.wordList(["a", "b", "c"]), "“a”, “b” or “c”")
    }

    func testTheSixSentencesAndTheirMissingShowAndListForms() {
        let money = show("m", title: "Planet Money")
        let list = FollowList(id: "L", name: "Commute", createdAt: base)
        let subs = [money]
        func text(_ action: ListeningRuleAction, _ scope: ListeningRuleScope, lists: [FollowList] = [list], subs: [FeedSubscription] = subs) -> String {
            ListeningRuleScreens.sentence(for: ListeningRule(action: action, words: ["a", "b"], scope: scope), subscriptions: subs, lists: lists)
        }
        XCTAssertEqual(text(.skip, .show(member(money))), "Skip Planet Money episodes about “a” or “b”")
        XCTAssertEqual(text(.skip, .list("L")), "Skip episodes about “a” or “b” in Commute")
        XCTAssertEqual(text(.skip, .any), "Skip episodes about “a” or “b” from any show")
        XCTAssertEqual(text(.more, .show(member(money))), "Mark Planet Money episodes about “a” or “b” as picks")
        XCTAssertEqual(text(.more, .list("L")), "Mark episodes about “a” or “b” in Commute as picks")
        XCTAssertEqual(text(.more, .any), "Mark episodes about “a” or “b” from any show as picks")
        XCTAssertEqual(text(.skip, .show(member(money)), subs: []), "Skip episodes about “a” or “b” from a show you no longer follow")
        XCTAssertEqual(text(.skip, .list("L"), lists: []), "Skip episodes about “a” or “b” in a deleted list")
    }

    func testOriginLinesAndThePausedLineOnlyForARuleThatIsOn() {
        var rule = ListeningRule(action: .skip, words: ["a"], isOn: true)
        XCTAssertEqual(ListeningRuleScreens.originLine(for: rule), "You wrote this")
        rule.origin = .suggested
        XCTAssertEqual(ListeningRuleScreens.originLine(for: rule), "Suggested from your Show less marks")
        rule.origin = .list("Sam’s picks")
        XCTAssertEqual(ListeningRuleScreens.originLine(for: rule), "From Sam’s picks")
        XCTAssertEqual(ListeningRuleScreens.originLine(for: rule, pausedFor: ["Planet Money"]),
                       "Paused for Planet Money: it matched almost every recent episode.")
        XCTAssertEqual(ListeningRuleScreens.originLine(for: rule, pausedFor: ["A", "B"]),
                       "Paused for A and 1 more show: it matched almost every recent episode.")
        XCTAssertEqual(ListeningRuleScreens.originLine(for: rule, pausedFor: ["A", "B", "C"]),
                       "Paused for A and 2 more shows: it matched almost every recent episode.")
        rule.isOn = false
        XCTAssertEqual(ListeningRuleScreens.originLine(for: rule, pausedFor: ["A"]), "From Sam’s picks", "an off rule is not paused")
    }

    func testTheAIOriginCarriesItsDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let rule = ListeningRule(action: .skip, words: ["a"], origin: .ai(base))
        let line = ListeningRuleScreens.originLine(
            for: rule, now: base.addingTimeInterval(10 * 86_400), calendar: calendar, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(line, "From your AI · Nov 14")
    }

    // MARK: Sections and the Rules row

    func testSectionsSplitOnAndOffAndFilterToOneList() {
        let rules = [
            ListeningRule(id: "1", action: .skip, words: ["a"], scope: .list("L"), isOn: true, createdAt: base),
            ListeningRule(id: "2", action: .more, words: ["b"], scope: .any, isOn: false, createdAt: base),
            ListeningRule(id: "3", action: .skip, words: ["c"], scope: .list("L"), isOn: false, createdAt: base),
        ]
        let lists = [FollowList(id: "L", name: "News", createdAt: base)]
        let all = ListeningRuleScreens.sections(rules: rules, lists: lists, subscriptions: [], pausedShowTitles: ["1": ["X"]])
        XCTAssertEqual(all.on.map(\.id), ["1"])
        XCTAssertEqual(all.off.map(\.id), ["2", "3"])
        XCTAssertTrue(all.on[0].isPaused)
        XCTAssertEqual(all.on[0].accessibilityLabel, "Skip episodes about “a” in News. Paused for X: it matched almost every recent episode.")
        XCTAssertEqual(all.off[0].accessibilityLabel, "Mark episodes about “b” from any show as picks. You wrote this.")

        let one = ListeningRuleScreens.sections(rules: rules, lists: lists, subscriptions: [], onlyList: "L")
        XCTAssertEqual((one.on + one.off).map(\.id), ["1", "3"])
        XCTAssertTrue(ListeningRuleScreens.sections(rules: rules, lists: lists, subscriptions: [], onlyList: "other").isEmpty)

        XCTAssertEqual(ListeningRuleScreens.rowValue(rules: []), "None yet")
        XCTAssertEqual(ListeningRuleScreens.rowValue(rules: rules), "1 on")
        XCTAssertEqual(ListeningRuleScreens.rowValue(rules: rules, onlyList: "L"), "1 on")
        XCTAssertEqual(ListeningRuleScreens.rowValue(rules: [rules[1]]), "0 on")
        XCTAssertEqual(ListeningRuleScreens.rowValue(rules: rules, onlyList: "other"), "None yet")
    }

    func testPausedShowTitlesComeFromTheEvaluation() {
        let a = show("a", title: "Alpha"), b = show("b", title: "Beta")
        let entries = (0..<6).map { entry("a\($0)", in: "a", day: $0, title: "Crypto \($0)") }
            + [entry("b0", in: "b", day: 0, title: "Crypto"), entry("b1", in: "b", day: 1, title: "Gardens")]
        let rule = ListeningRule(id: "r", action: .skip, words: ["crypto"], isOn: true)
        let evaluation = FollowingRuleEvaluation.evaluate(
            subscriptions: [a, b], entries: entries, inputs: FollowingRuleInputs(rules: [rule]))
        XCTAssertEqual(ListeningRuleScreens.pausedShowTitles(in: evaluation, subscriptions: [a, b]), ["r": ["Alpha"]])
    }

    // MARK: Turning on

    func testATooBroadSkipRuleIsRefusedWithTheShowAndCountsAndAPickRuleNever() {
        let a = show("a", title: "Alpha")
        let entries = (0..<5).map { entry("a\($0)", in: "a", day: $0, title: "Crypto \($0)") }
        let shows = ListeningRuleScreens.shows(subscriptions: [a], entries: entries)
        let skip = ListeningRule(action: .skip, words: ["crypto"])
        let refusal = ListeningRuleScreens.refusal(for: skip, shows: shows, lists: [], showTitles: ["a": "Alpha"])
        XCTAssertEqual(refusal?.title, "This rule would skip almost everything")
        XCTAssertEqual(refusal?.message, "It matches 5 of the last 5 episodes from Alpha. To hear less of a whole show, set it to Quiet on its page.")
        XCTAssertNil(ListeningRuleScreens.refusal(for: ListeningRule(action: .more, words: ["crypto"]), shows: shows, lists: [], showTitles: [:]))
        let four = ListeningRuleScreens.shows(subscriptions: [a], entries: Array(entries.prefix(4)))
        XCTAssertNil(ListeningRuleScreens.refusal(for: skip, shows: four, lists: [], showTitles: [:]), "fewer than 5 matches is never too broad")
    }

    // MARK: The Rule screen

    func testMatchesCountTheLastThirtyInScopeAcrossShowsNewestFirst() {
        let a = show("a", title: "Alpha"), b = show("b", title: "Beta")
        var entries = (0..<20).map { entry("a\($0)", in: "a", day: $0, title: $0 % 2 == 0 ? "Crypto \($0)" : "Gardens \($0)") }
        entries += (0..<20).map { entry("b\($0)", in: "b", day: 100 + $0, title: "Other \($0)", summary: $0 == 19 ? "about crypto" : nil) }
        let shows = ListeningRuleScreens.shows(subscriptions: [a, b], entries: entries)
        let any = ListeningRuleScreens.matches(for: ListeningRule(action: .skip, words: ["crypto"]), shows: shows, lists: [])
        XCTAssertEqual(any.window, 30)
        // The newest 30: all 20 of Beta, then Alpha's days 19 to 10, of which 18, 16, 14, 12 and 10 match.
        XCTAssertEqual(any.matched.map(\.id), ["b19", "a18", "a16", "a14", "a12", "a10"])
        XCTAssertEqual(any.summary, "Matches 6 of the last 30 episodes")

        let onlyA = ListeningRuleScreens.matches(
            for: ListeningRule(action: .skip, words: ["crypto"], scope: .show(member(a))), shows: shows, lists: [])
        XCTAssertEqual(onlyA.window, 20)
        XCTAssertEqual(onlyA.matched.count, 10)

        let one = ListeningRuleScreens.matches(
            for: ListeningRule(action: .skip, words: ["x"]), shows: ListeningRuleScreens.shows(subscriptions: [a], entries: [entries[0]]), lists: [])
        XCTAssertEqual(one.summary, "Matches 0 of the last 1 episode")
        XCTAssertEqual(ListeningRuleScreens.matches(for: ListeningRule(action: .skip, words: ["x"]), shows: [], lists: []).summary,
                       "No episodes to check yet")
    }

    // MARK: The New rule form

    func testScopeChoicesAreAnyThenListsThenShowsAlphabetical() {
        let lists = [FollowList(id: "2", name: "work", createdAt: base), FollowList(id: "1", name: "Commute", createdAt: base)]
        let subs = [show("z", title: "zebra talk"), show("a", title: "Alpha")]
        let choices = ListeningRuleScreens.scopeChoices(lists: lists, subscriptions: subs)
        XCTAssertEqual(choices.any.label, "Any show")
        XCTAssertEqual(choices.any.scope, .any)
        XCTAssertEqual(choices.lists.map(\.label), ["Commute", "work"])
        XCTAssertEqual(choices.shows.map(\.label), ["Alpha", "zebra talk"])
        XCTAssertEqual(choices.shows[0].scope, .show(member(subs[1])))
        XCTAssertEqual(Set((choices.lists + choices.shows + [choices.any]).map(\.id)).count, 5, "ids are distinct for the picker")
    }

    func testSaveNeedsAWordAndTheFormSaysWhatIsWrongOnlyOnceSomethingIsTyped() {
        XCTAssertFalse(ListeningRuleScreens.canSave(wordsField: ""))
        XCTAssertFalse(ListeningRuleScreens.canSave(wordsField: " , ,"))
        XCTAssertNil(ListeningRuleScreens.wordsProblem(""))
        XCTAssertNil(ListeningRuleScreens.wordsProblem(" , "))
        XCTAssertTrue(ListeningRuleScreens.canSave(wordsField: "crypto, bitcoin*"))
        XCTAssertNil(ListeningRuleScreens.wordsProblem("crypto"))
        let long = String(repeating: "x", count: 61)
        XCTAssertFalse(ListeningRuleScreens.canSave(wordsField: long))
        XCTAssertEqual(ListeningRuleScreens.wordsProblem(long), .wordTooLong(long))
        let many = (0...20).map { "w\($0)" }.joined(separator: ",")
        XCTAssertEqual(ListeningRuleScreens.wordsProblem(many), .tooManyWords)
        XCTAssertEqual(ListeningRuleScreens.wordsField(for: ListeningRule(action: .skip, words: ["a", "b c"])), "a, b c")
    }

    // MARK: The Show screen and Following

    func testSkippedEpisodesCarryTheirWordAndPicksReadOnTheBadge() {
        let a = show("a", title: "Alpha")
        let entries = [
            entry("e1", in: "a", day: 3, title: "Crypto winter"),
            entry("e2", in: "a", day: 2, title: "Gardens"),
            entry("e3", in: "a", day: 1, title: "Soil and gardens"),
        ]
        let inputs = FollowingRuleInputs(rules: [
            ListeningRule(id: "s", action: .skip, words: ["crypto*"], isOn: true),
            ListeningRule(id: "p", action: .more, words: ["gardens"], isOn: true),
        ])
        let evaluation = FollowingRuleEvaluation.evaluate(subscriptions: [a], entries: entries, inputs: inputs)
        let episodes = FollowingShowRows.episodes(of: a, in: entries, rules: evaluation)
        XCTAssertEqual(episodes.first { $0.id == "e1" }?.skippedWord, "crypto*")
        XCTAssertNil(episodes.first { $0.id == "e2" }?.skippedWord)
        XCTAssertEqual(ListeningRuleScreens.skippedLine(word: "crypto*"), "Skipped: about “crypto*”")
        XCTAssertEqual(ListeningRuleScreens.skippedHeader(count: 1), "Skipped by your rules (1)")

        let row = FollowingShowRows.build(subscriptions: [a], entries: entries, rules: evaluation).rows[0]
        XCTAssertEqual(row.countLabel, "2 new · 2 picks")
        var single = row
        single.pickCount = 1
        XCTAssertEqual(single.countLabel, "2 new · 1 pick")
        single.pickCount = 0
        XCTAssertEqual(single.countLabel, "2 new")
        single.newCount = 0
        XCTAssertNil(single.countLabel)
    }
}
