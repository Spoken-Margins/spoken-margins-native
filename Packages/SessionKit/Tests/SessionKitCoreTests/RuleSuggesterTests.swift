import XCTest
@testable import SessionKit
@testable import SessionKitPersistence

/// #4046 PR 11: the on-device learner offers a skip rule for a word the listener keeps passing over in one show.
final class RuleSuggesterTests: XCTestCase {
    private let feed = "https://a.example/feed"
    private let member = ListMember(feedKey: "https://a.example/feed")
    private let now = Date(timeIntervalSince1970: 200 * 86_400)

    private func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func quiet(_ id: String, _ title: String, days: Double = 10, feedKey: String? = nil) -> EpisodeEvidence {
        EpisodeEvidence(id: id, feedKey: feedKey ?? feed, title: title, at: ago(days: days), finishedNoMargin: true)
    }

    private func marked(_ id: String, _ title: String, days: Double = 10) -> EpisodeEvidence {
        EpisodeEvidence(id: id, feedKey: feed, title: title, at: ago(days: days), showLess: true)
    }

    private func positive(_ id: String, _ title: String, days: Double = 10) -> EpisodeEvidence {
        EpisodeEvidence(id: id, feedKey: feed, title: title, at: ago(days: days), positive: true)
    }

    /// Ten episodes about nothing in particular: the learner needs a show's episodes to judge how often a word comes up.
    private var quietEntries: [FeedEntry] { (1...10).map { entry($0, "Harbour notes \($0)") } }

    private func show(title: String = "Daily Dispatch", entries: [FeedEntry]? = nil) -> RuleSuggestionShow {
        RuleSuggestionShow(id: "show-a", member: member, title: title, entries: entries ?? quietEntries)
    }

    private func entry(_ id: Int, _ title: String) -> FeedEntry {
        FeedEntry(id: "e\(id)", subscriptionId: "sub", canonicalURL: "https://a.example/\(id)", title: title,
                  publishedAt: Date(timeIntervalSince1970: Double(id) * 86_400))
    }

    private func suggest(
        _ evidence: [EpisodeEvidence], show: RuleSuggestionShow? = nil, rules: [ListeningRule] = [], states: [RuleSuggestionState] = [],
        lists: [FollowList] = []
    ) -> [RuleSuggestion] {
        RuleSuggester.suggest(evidence: evidence, shows: [show ?? self.show()], rules: rules, states: states, lists: lists, now: now)
    }

    private var fourQuiet: [EpisodeEvidence] {
        [quiet("1", "Crypto crash"), quiet("2", "Why crypto wins"), quiet("3", "Crypto again"), quiet("4", "Crypto, still")]
    }

    // MARK: The threshold

    func testAWeightOfFourOverThreeEpisodesIsJustEnoughAndThreeIsNot() {
        XCTAssertEqual(suggest(fourQuiet).map(\.word), ["crypto"], "4 episodes at weight 1: weight 4")
        XCTAssertTrue(suggest(Array(fourQuiet.prefix(3))).isEmpty, "3 episodes at weight 1: weight 3, one short")
        // Weight 5 over three episodes, one of them marked.
        let withMark = [marked("1", "Crypto crash"), quiet("2", "Why crypto wins"), quiet("3", "Crypto again")]
        XCTAssertEqual(suggest(withMark).first?.strength, 5)
        // Two marks are weight 6 but only two episodes.
        XCTAssertTrue(suggest([marked("1", "Crypto crash"), marked("2", "Why crypto wins")]).isEmpty, "needs 3 episodes")
        // Weight 4 from three episodes, one of them carrying two quiet signals at once.
        let three = [
            EpisodeEvidence(id: "1", feedKey: feed, title: "Crypto crash", at: ago(days: 5), finishedNoMargin: true, addedNeverPlayed: true),
            quiet("2", "Why crypto wins"), quiet("3", "Crypto again"),
        ]
        XCTAssertEqual(suggest(three).first?.strength, 4)
    }

    func testAnEpisodeWithoutTheWordDoesNotCount() {
        XCTAssertTrue(suggest(Array(fourQuiet.prefix(3)) + [quiet("5", "Gardening")]).isEmpty)
    }

    func testAPositiveEpisodeBlocksItsWordOnly() {
        let blocked = suggest(fourQuiet + [positive("p", "Crypto, a good one")])
        XCTAssertTrue(blocked.isEmpty)
        // A positive episode about something else doesn't block.
        XCTAssertEqual(suggest(fourQuiet + [positive("p", "Gardening")]).map(\.word), ["crypto"])
        // A Margin left long ago still vetoes: the window limits what argues for a rule, not what argues against.
        XCTAssertTrue(suggest(fourQuiet + [positive("p", "Crypto, a good one", days: 400)]).isEmpty)
    }

    func testTheNinetyDayWindowKeepsDayNinetyAndDropsDayNinetyOne() {
        let atEdge = [quiet("1", "Crypto crash", days: 90), quiet("2", "Why crypto wins"), quiet("3", "Crypto again"), quiet("4", "Crypto, still")]
        XCTAssertEqual(suggest(atEdge).map(\.word), ["crypto"])
        let pastEdge = [quiet("1", "Crypto crash", days: 91), quiet("2", "Why crypto wins"), quiet("3", "Crypto again"), quiet("4", "Crypto, still")]
        XCTAssertTrue(suggest(pastEdge).isEmpty)
    }

    func testEvidenceFromAnotherShowIsNotMixedIn() {
        let mixed = [quiet("1", "Crypto crash"), quiet("2", "Why crypto wins"), quiet("3", "Crypto again", feedKey: "https://b.example/feed"),
                     quiet("4", "Crypto, still", feedKey: "https://b.example/feed")]
        XCTAssertTrue(suggest(mixed).isEmpty)
    }

    // MARK: The half-the-show guard

    func testAWordTheShowSaysInHalfItsLastThirtyEpisodesIsStillOfferedAndMoreIsNot() {
        func entries(matching count: Int) -> [FeedEntry] {
            (1...30).map { entry($0, $0 <= count ? "Crypto number \($0)" : "Gardening number \($0)") }
        }
        XCTAssertEqual(suggest(fourQuiet, show: show(entries: entries(matching: 15))).map(\.word), ["crypto"], "15 of 30 is half")
        XCTAssertTrue(suggest(fourQuiet, show: show(entries: entries(matching: 16))).isEmpty, "16 of 30 is more than half")
    }

    func testTheGuardReadsOnlyTheLastThirtyEpisodes() {
        // 40 entries: the newest 30 hold the word 15 times; the 10 oldest hold it too, which doesn't count.
        let all = (1...40).map { entry($0, $0 > 25 && $0 <= 40 || $0 <= 10 ? "Crypto number \($0)" : "Gardening number \($0)") }
        let newest30 = all.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }.prefix(30)
        XCTAssertEqual(newest30.filter { $0.title.hasPrefix("Crypto") }.count, 15)
        XCTAssertEqual(suggest(fourQuiet, show: show(entries: all)).map(\.word), ["crypto"])
    }

    func testTheGuardMatchesTheSummaryToo() {
        let entries = (1...10).map { id in
            FeedEntry(id: "e\(id)", subscriptionId: "sub", canonicalURL: "https://a.example/\(id)", title: "Number \(id)",
                      summary: "All about crypto", publishedAt: Date(timeIntervalSince1970: Double(id) * 86_400))
        }
        XCTAssertTrue(suggest(fourQuiet, show: show(entries: entries)).isEmpty, "the rule would skip every one of them")
    }

    // MARK: Which words are candidates

    func testWordsOfTheShowsOwnTitleAreNeverOffered() {
        let titled = [quiet("1", "Money crash"), quiet("2", "Why money wins"), quiet("3", "Money again"), quiet("4", "Money, still")]
        XCTAssertTrue(suggest(titled, show: show(title: "Planet Money")).isEmpty)
        XCTAssertEqual(suggest(titled, show: show(title: "Daily Dispatch")).map(\.word), ["money"])
        XCTAssertTrue(suggest(titled, show: show(title: "MONEY!")).isEmpty, "case and punctuation of the show title don't matter")
    }

    func testCandidateWordTable() {
        let words = RuleSuggester.candidateWords(in: "Crypto, ART & Café: Trump's 2024 episode! Weekly don't AI x-ray 比特币 Évolution CRYPTO")
        XCTAssertEqual(words, ["crypto", "cafe", "evolution"], "folded, deduplicated, letters only; stopwords, short words, numbers and apostrophe words out")
        // Whatever the learner offers, a skip rule on it matches the title it came from.
        for word in words {
            XCTAssertTrue(ListeningRuleMatcher(words: [word]).matches(title: "Crypto, ART & Café: Évolution"), word)
        }
        XCTAssertTrue(RuleSuggester.candidateWords(in: "").isEmpty)
        XCTAssertTrue(RuleSuggester.candidateWords(in: "The and for with").isEmpty)
        XCTAssertEqual(RuleSuggester.candidateWords(in: "word"), ["word"], "exactly four letters")
        XCTAssertTrue(RuleSuggester.candidateWords(in: "abc").isEmpty, "three letters")
        XCTAssertEqual(RuleSuggester.candidateWords(in: "CAFÉ café Cafe"), ["cafe"], "the same word from another source folds to one")
        XCTAssertEqual(RuleSuggester.candidateWords(in: String(repeating: "a", count: 200)).count, 1, "length is checked when a rule is made, not here")
    }

    func testPossessiveTitlesAreNotOfferedBecauseARuleOnTheBareWordWouldSkipNothing() {
        let evidence = [quiet("1", "Trump's trial"), quiet("2", "Trump's tariffs"), quiet("3", "Trump's deal"), quiet("4", "Trump's wall")]
        XCTAssertFalse(ListeningRuleMatcher(words: ["trump"]).matches(title: "Trump's trial"), "the premise")
        XCTAssertTrue(suggest(evidence).isEmpty)
        XCTAssertTrue(suggest(evidence, show: show(title: "Trump's Pod")).isEmpty)
    }

    func testAShowWhoseEpisodesAreNotKnownGetsNoSuggestion() {
        XCTAssertTrue(suggest(fourQuiet, show: show(entries: [])).isEmpty, "no way to tell how often the show says the word")
        XCTAssertEqual(suggest(fourQuiet).map(\.word), ["crypto"])
    }

    func testAVeryLongWordIsNeverOfferedBecauseARuleCouldNotHoldIt() {
        let long = String(repeating: "a", count: 61)
        let evidence = [quiet("1", long), quiet("2", long), quiet("3", long), quiet("4", long)]
        XCTAssertTrue(suggest(evidence).isEmpty)
    }

    func testWordsCarryTheirDiacriticsOutSoARuleMatchesTheEpisodesTheListenerMeant() {
        let evidence = [quiet("1", "Café culture"), quiet("2", "Why café wins"), quiet("3", "Cafe again"), quiet("4", "CAFÉ, still")]
        let found = suggest(evidence)
        XCTAssertEqual(found.map(\.word), ["cafe"])
        XCTAssertTrue(ListeningRuleMatcher(words: ["cafe"]).matches(title: "Café culture"))
    }

    // MARK: Snooze and never

    func testNotNowSnoozesForThirtyDaysAndNeverIsForever() {
        let key = RuleSuggestionState.key(feedKey: feed, word: "crypto")
        XCTAssertEqual(suggest(fourQuiet, states: [RuleSuggestionState.snoozed(key: key, now: now)]).count, 0)
        let snoozed = RuleSuggestionState.snoozed(key: key, now: now)
        XCTAssertEqual(snoozed.snoozedUntil, now.addingTimeInterval(30 * 86_400))
        let almost = RuleSuggester.suggest(evidence: fourQuiet, shows: [show()], rules: [], states: [snoozed], now: now.addingTimeInterval(30 * 86_400 - 1))
        XCTAssertTrue(almost.isEmpty, "still snoozed one second before")
        let after = RuleSuggester.suggest(evidence: fourQuiet, shows: [show()], rules: [], states: [snoozed], now: now.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(after.map(\.word), ["crypto"], "snooze over: it comes back")
        XCTAssertTrue(suggest(fourQuiet, states: [.refused(key: key)]).isEmpty)
        // Never is never: a year later, with evidence from that week, it stays quiet.
        let later = now.addingTimeInterval(400 * 86_400)
        let fresh = fourQuiet.map { EpisodeEvidence(id: $0.id, feedKey: $0.feedKey, title: $0.title, at: later.addingTimeInterval(-86_400), finishedNoMargin: true) }
        XCTAssertEqual(RuleSuggester.suggest(evidence: fresh, shows: [show()], rules: [], states: [], now: later).map(\.word), ["crypto"])
        XCTAssertTrue(RuleSuggester.suggest(evidence: fresh, shows: [show()], rules: [], states: [.refused(key: key)], now: later).isEmpty)
        // A state for another show or another word leaves this one alone.
        let other = RuleSuggestionState.refused(key: RuleSuggestionState.key(feedKey: "https://b.example/feed", word: "crypto"))
        let otherWord = RuleSuggestionState.refused(key: RuleSuggestionState.key(feedKey: feed, word: "bitcoin"))
        XCTAssertEqual(suggest(fourQuiet, states: [other, otherWord]).map(\.word), ["crypto"])
    }

    // MARK: Rules the listener already has

    func testARuleThatAlreadyCoversTheWordSilencesIt() {
        func rule(_ words: [String], action: ListeningRuleAction = .skip, scope: ListeningRuleScope = .any, isOn: Bool = true) -> ListeningRule {
            ListeningRule(id: UUID().uuidString, action: action, words: words, scope: scope, isOn: isOn, createdAt: now)
        }
        XCTAssertTrue(suggest(fourQuiet, rules: [rule(["crypto"])]).isEmpty)
        XCTAssertTrue(suggest(fourQuiet, rules: [rule(["Crypto*"])]).isEmpty, "a prefix rule covers it, whatever its case")
        XCTAssertTrue(suggest(fourQuiet, rules: [rule(["crypto"], scope: .show(member))]).isEmpty)
        XCTAssertTrue(suggest(fourQuiet, rules: [rule(["crypto"], isOn: false)]).isEmpty, "a rule the listener switched off isn't offered again")
        let list = FollowList(id: "L", name: "News", createdAt: now, members: [member])
        XCTAssertTrue(suggest(fourQuiet, rules: [rule(["crypto"], scope: .list("L"))], lists: [list]).isEmpty)
        XCTAssertEqual(suggest(fourQuiet, rules: [rule(["crypto"], scope: .list("L"))], lists: []).map(\.word), ["crypto"], "a list that is gone covers nothing")
        XCTAssertEqual(suggest(fourQuiet, rules: [rule(["crypto"], scope: .show(ListMember(feedKey: "https://b.example/feed")))]).map(\.word), ["crypto"])
        XCTAssertEqual(suggest(fourQuiet, rules: [rule(["crypto"], action: .more)]).map(\.word), ["crypto"], "a pick rule says nothing about skipping")
        XCTAssertEqual(suggest(fourQuiet, rules: [rule(["bitcoin"])]).map(\.word), ["crypto"])
        XCTAssertEqual(suggest(fourQuiet, rules: [rule(["crypto currency"])]).map(\.word), ["crypto"], "a phrase is not the word")
    }

    // MARK: Order and reason

    func testStrongestComesFirstAndTiesGoByEpisodesThenName() {
        let evidence = fourQuiet
            + [marked("m1", "Gardening tips"), marked("m2", "Gardening again"), marked("m3", "Gardening, still")]
            + [quiet("b1", "Baking one"), quiet("b2", "Baking two"), quiet("b3", "Baking three"), quiet("b4", "Baking four")]
        let found = suggest(evidence)
        XCTAssertEqual(found.map(\.word), ["gardening", "baking", "crypto"], "9, then 4 by name, then 4")
        XCTAssertEqual(found.map(\.strength), [9, 4, 4])
    }

    func testTheReasonLineSaysMarkedWhenAnyMarkExistsAndQuietOtherwise() {
        let withMarks = suggest([marked("1", "Crypto crash"), marked("2", "Why crypto wins"), quiet("3", "Crypto again")])
        XCTAssertEqual(withMarks.first?.reason, .marked(2))
        XCTAssertEqual(withMarks.first?.reasonLine, "You marked 2 like this Show less.")
        let quietOnly = suggest(fourQuiet)
        XCTAssertEqual(quietOnly.first?.reason, .quiet(4))
        XCTAssertEqual(quietOnly.first?.reasonLine, "You didn’t leave a Margin on 4 like this.")
        XCTAssertEqual(quietOnly.first?.episodeCount, 4)
        XCTAssertEqual(quietOnly.first?.key, "crypto|https://a.example/feed")
        XCTAssertEqual(quietOnly.first?.showId, "show-a")
    }

    func testNoEvidenceNoSuggestionAndTheSameInputsGiveTheSameAnswer() {
        XCTAssertTrue(suggest([]).isEmpty)
        XCTAssertEqual(suggest(fourQuiet), suggest(fourQuiet.reversed()))
    }

    func testEveryShowGetsItsOwnSuggestions() {
        let second = RuleSuggestionShow(id: "show-b", member: ListMember(feedKey: "https://b.example/feed"), title: "Other", entries: quietEntries)
        let evidence = fourQuiet + [
            quiet("b1", "Baking one", feedKey: "https://b.example/feed"), quiet("b2", "Baking two", feedKey: "https://b.example/feed"),
            quiet("b3", "Baking three", feedKey: "https://b.example/feed"), quiet("b4", "Baking four", feedKey: "https://b.example/feed"),
        ]
        let found = RuleSuggester.suggest(evidence: evidence, shows: [show(), second], rules: [], states: [], now: now)
        XCTAssertEqual(Set(found.map(\.showId)), ["show-a", "show-b"])
        XCTAssertEqual(found.first { $0.showId == "show-b" }?.word, "baking")
    }

    // MARK: Builder and suggester together

    func testQuietSignalsFromTheBuilderLeadToASuggestionAndAMarginVetoesIt() {
        let day = 86_400.0
        func item(_ id: String, addedDaysAgo: Double) -> Item {
            Item(id: id, title: "Item \(id)", mediaType: "text", text: "Body", externalReference: nil, status: "ready", createdAt: now.addingTimeInterval(-day * addedDaysAgo))
        }
        func played(_ id: String, daysAgo: Double, finished: Bool) -> Session {
            let last = now.addingTimeInterval(-day * daysAgo)
            return Session(id: "s-\(id)", itemId: id, createdAt: last, updatedAt: last, completedAt: finished ? last : nil,
                           status: finished ? "finished" : "in_progress", phase: finished ? .finished : .itemPlayback,
                           currentTargetType: .itemTextTTS, currentTargetId: id, position: Position(), completionPercent: finished ? 100 : 30, playbackRate: 1)
        }
        let episodes = [
            RuleEvidenceEpisode(item: item("f", addedDaysAgo: 30), feedKey: feed, title: "Crypto crash"),
            RuleEvidenceEpisode(item: item("s", addedDaysAgo: 30), feedKey: feed, title: "Why crypto wins"),
            RuleEvidenceEpisode(item: item("n", addedDaysAgo: 30), feedKey: feed, title: "Crypto again"),
            RuleEvidenceEpisode(item: item("m", addedDaysAgo: 30), feedKey: feed, title: "Crypto, still"),
        ]
        let sessions = [played("f", daysAgo: 20, finished: true), played("s", daysAgo: 20, finished: false)]
        let evidence = RuleEvidenceBuilder.build(episodes: episodes, sessions: sessions, margins: [], marks: [], now: now)
        XCTAssertEqual(evidence.filter { $0.finishedNoMargin }.count, 1)
        XCTAssertEqual(evidence.filter { $0.stoppedEarly }.count, 1)
        XCTAssertEqual(evidence.filter { $0.addedNeverPlayed }.count, 2)
        let found = suggest(evidence)
        XCTAssertEqual(found.map(\.word), ["crypto"])
        XCTAssertEqual(found.first?.reason, .quiet(4))

        let margin = Interjection(
            id: "m1", itemId: "m", sessionId: "s", targetType: .item, targetId: "m", createdAt: now.addingTimeInterval(-day * 2), roughPercent: 0,
            anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: ""), audioPath: nil, audioStatus: "none",
            transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil, displayText: "Worth hearing", status: "active"
        )
        let vetoed = RuleEvidenceBuilder.build(episodes: episodes, sessions: sessions, margins: [margin], marks: [], now: now)
        XCTAssertTrue(suggest(vetoed).isEmpty, "a Margin on one of them says the listener did want something from this word")
    }

    func testMarksFromTheBuilderLeadToASuggestion() {
        let day = 86_400.0
        let titles = ["Crypto crash", "Crypto boom", "Crypto winter"]
        let marks = titles.enumerated().map { ShowLessMark(feedKey: feed, entryId: "m\($0.offset)", title: $0.element, markedAt: now.addingTimeInterval(-day * Double($0.offset + 1))) }
        let evidence = RuleEvidenceBuilder.build(episodes: [], sessions: [], margins: [], marks: marks, now: now)
        XCTAssertEqual(evidence.count, 3)
        XCTAssertEqual(suggest(evidence).first?.reason, .marked(3))
    }

    // MARK: Store

    func testStatesSurviveAReopenAndPuttingOffTwiceKeepsOneRecord() throws {
        let path = NSTemporaryDirectory() + "rule-suggestion-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let key = RuleSuggestionState.key(feedKey: feed, word: "crypto")
        let refused = RuleSuggestionState.refused(key: RuleSuggestionState.key(feedKey: feed, word: "bitcoin"))
        do {
            let store = try SQLiteSessionStore(path: path)
            try store.saveRuleSuggestionState(RuleSuggestionState.snoozed(key: key, now: now))
            try store.saveRuleSuggestionState(RuleSuggestionState.snoozed(key: key, now: now.addingTimeInterval(86_400)))
            try store.saveRuleSuggestionState(refused)
        }
        let store = try SQLiteSessionStore(path: path)
        let loaded = try store.loadRuleSuggestionStates()
        XCTAssertEqual(loaded.map(\.key), ["bitcoin|https://a.example/feed", "crypto|https://a.example/feed"])
        XCTAssertEqual(loaded.first { $0.key == key }?.snoozedUntil, now.addingTimeInterval(86_400 + 30 * 86_400))
        XCTAssertEqual(loaded.first { $0.key == refused.key }?.never, true)
        try store.deleteRuleSuggestionState(key: key)
        XCTAssertEqual(try store.loadRuleSuggestionStates().map(\.key), [refused.key])
    }
}
