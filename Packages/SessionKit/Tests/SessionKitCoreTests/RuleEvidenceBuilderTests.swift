import XCTest
@testable import SessionKit

/// #4046 PR 11: what the learner knows about each episode, built from the listener's own items, sessions, Margins and marks.
final class RuleEvidenceBuilderTests: XCTestCase {
    private let feed = "https://a.example/feed"
    private let now = Date(timeIntervalSince1970: 100 * 86_400)

    private func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func item(_ id: String, addedDaysAgo: Double = 1, completed: Date? = nil, addedAgain: Date? = nil, deleted: Bool = false) -> Item {
        var item = Item(id: id, title: "Item \(id)", mediaType: "text", text: "Body", externalReference: nil, status: "ready",
                        deletedAt: deleted ? ago(days: 0.5) : nil, createdAt: ago(days: addedDaysAgo))
        item.sourceCompletedAt = completed
        item.addedAgainAt = addedAgain
        return item
    }

    private func episode(_ item: Item, entryId: String? = nil, title: String = "Crypto crash") -> RuleEvidenceEpisode {
        RuleEvidenceEpisode(item: item, feedKey: feed, entryId: entryId, title: title)
    }

    private func session(_ itemId: String, percent: Int = 40, last: Date, finished: Bool = false) -> Session {
        Session(id: "s-\(itemId)-\(last.timeIntervalSince1970)", itemId: itemId, createdAt: last, updatedAt: last,
                completedAt: finished ? last : nil, status: finished ? "finished" : "in_progress",
                phase: finished ? .finished : .itemPlayback, currentTargetType: .itemTextTTS, currentTargetId: itemId,
                position: Position(), completionPercent: percent, playbackRate: 1)
    }

    private func margin(_ itemId: String, status: String = "active", sharedAs: [MarginPacketIdentity]? = nil, at: Date? = nil) -> Interjection {
        Interjection(
            id: "m-\(itemId)-\(status)", itemId: itemId, sessionId: "s", targetType: .item, targetId: itemId, createdAt: at ?? ago(days: 3),
            roughPercent: 0, anchor: Anchor(anchorType: .text, startChar: 0, endChar: 1, anchorBefore: "", anchorAfter: ""),
            audioPath: nil, audioStatus: "none", transcriptionStatus: "complete", transcript: nil, cleanedTranscript: nil,
            displayText: "A thought", status: status, sharedAs: sharedAs
        )
    }

    private func build(_ episodes: [RuleEvidenceEpisode], sessions: [Session] = [], margins: [Interjection] = [], marks: [ShowLessMark] = []) -> [EpisodeEvidence] {
        RuleEvidenceBuilder.build(episodes: episodes, sessions: sessions, margins: margins, marks: marks, now: now)
    }

    // MARK: Show less marks

    func testAMarkOnAnEpisodeNeverAddedToTheLibraryIsEvidenceOfItsOwn() {
        let mark = ShowLessMark(feedKey: feed, entryId: "e1", title: "Crypto crash", markedAt: ago(days: 2))
        let evidence = build([], marks: [mark])
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence[0].id, "e1")
        XCTAssertEqual(evidence[0].feedKey, feed)
        XCTAssertEqual(evidence[0].title, "Crypto crash")
        XCTAssertTrue(evidence[0].showLess)
        XCTAssertEqual(evidence[0].at, ago(days: 2))
        XCTAssertEqual(evidence[0].weight, RuleEvidenceBuilder.showLessWeight)
    }

    func testAMarkAndItsLibraryItemAreOneEpisodeWhetherTheMarkNamesTheEntryOrTheItem() {
        let i = item("i1")
        let byEntry = ShowLessMark(feedKey: feed, entryId: "e1", title: "Crypto crash", markedAt: ago(days: 2))
        XCTAssertEqual(build([episode(i, entryId: "e1")], marks: [byEntry]).map(\.id), ["e1"])
        let byItem = ShowLessMark(feedKey: feed, itemId: "i1", title: "Crypto crash", markedAt: ago(days: 2))
        let evidence = build([episode(i)], marks: [byItem])
        XCTAssertEqual(evidence.map(\.id), ["i1"])
        XCTAssertTrue(evidence[0].showLess)
        // A mark for another episode of the same show stays its own row.
        let other = ShowLessMark(feedKey: feed, entryId: "e9", title: "Other", markedAt: ago(days: 1))
        XCTAssertEqual(Set(build([episode(i, entryId: "e1")], marks: [byEntry, other]).map(\.id)), ["e1", "e9"])
    }

    func testAMarkMadeFromTheShowScreenFindsTheItemEvenWhenTheCallerFoundNoEntry() {
        // The item has no matched entry, the mark names one: the same feed and the same title are the same episode.
        let i = item("i1", addedDaysAgo: 30)
        let mark = ShowLessMark(feedKey: feed, entryId: "e1", title: "  CRYPTO crash ", markedAt: ago(days: 2))
        let evidence = build([episode(i, entryId: nil, title: "Crypto Crash")], marks: [mark])
        XCTAssertEqual(evidence.count, 1, "one episode, not a mark row plus an item row")
        XCTAssertTrue(evidence[0].showLess)
        XCTAssertTrue(evidence[0].addedNeverPlayed)
        XCTAssertEqual(evidence[0].weight, RuleEvidenceBuilder.showLessWeight + RuleEvidenceBuilder.quietWeight)
        // Another show's episode with the same title, or another title, is not it.
        let otherShow = ShowLessMark(feedKey: "https://b.example/feed", entryId: "e1", title: "Crypto crash", markedAt: ago(days: 2))
        XCTAssertEqual(build([episode(i, title: "Crypto crash")], marks: [otherShow]).count, 2)
        let otherTitle = ShowLessMark(feedKey: feed, entryId: "e2", title: "Gardening", markedAt: ago(days: 2))
        XCTAssertEqual(build([episode(i, title: "Crypto crash")], marks: [otherTitle]).count, 2)
    }

    func testOneMarkIsAboutOneEpisodeEvenWhenARerunSharesItsTitle() {
        // An encore: the same title under a new entry id, both copies in the Library. The listener marked only e1.
        let a = episode(item("a", addedDaysAgo: 30), entryId: "e1", title: "Crypto Q and A")
        let b = episode(item("b", addedDaysAgo: 30), entryId: "e2", title: "Crypto Q and A")
        let mark = ShowLessMark(feedKey: feed, entryId: "e1", title: "Crypto Q and A", markedAt: ago(days: 2))
        let evidence = build([a, b], marks: [mark])
        XCTAssertEqual(evidence.filter(\.showLess).map(\.id), ["e1"], "only the episode the mark names")
        XCTAssertEqual(evidence.reduce(0) { $0 + $1.weight }, 3 + 1 + 1, "one mark, plus a quiet signal on each copy")
        // With the order reversed the answer is the same: the mark names its entry, not whichever copy comes first.
        XCTAssertEqual(build([b, a], marks: [mark]).filter(\.showLess).map(\.id), ["e1"])
    }

    func testTheTitleFallbackIsOnlyForAnEpisodeWithNoEntryAndOnlyForOneOfThem() {
        // Two Library copies of one episode, neither matched to an entry: the one mark counts on the first only.
        let first = episode(item("a", addedDaysAgo: 30), title: "Crypto crash")
        let second = episode(item("b", addedDaysAgo: 30), title: "Crypto crash")
        let mark = ShowLessMark(feedKey: feed, entryId: "e1", title: "Crypto crash", markedAt: ago(days: 2))
        XCTAssertEqual(build([first, second], marks: [mark]).filter(\.showLess).map(\.id), ["a"])
        // A mark that names an episode with an entry is never moved to an entryless copy of it.
        let named = episode(item("n", addedDaysAgo: 30), entryId: "e1", title: "Crypto crash")
        XCTAssertEqual(build([first, named], marks: [mark]).filter(\.showLess).map(\.id), ["e1"])
    }

    func testAMarkMadeFromAnItemNeverAttachesToAnotherItemByTitle() {
        let marked = ShowLessMark(feedKey: feed, itemId: "gone", title: "Crypto crash", markedAt: ago(days: 2))
        let other = episode(item("other", addedDaysAgo: 30), title: "Crypto crash")
        let evidence = build([other], marks: [marked])
        XCTAssertEqual(evidence.count, 2, "its own row, and the other item's quiet row")
        XCTAssertEqual(evidence.filter(\.showLess).map(\.id), ["gone"])
    }

    func testAnEpisodeWithNoSignalLeavesNoEvidence() {
        XCTAssertTrue(build([episode(item("i1", addedDaysAgo: 1))]).isEmpty, "added yesterday: not yet 14 days")
    }

    // MARK: Quiet signals

    func testFinishedWithNoMarginCountsAndAMarginMakesItPositiveInstead() {
        let i = item("i1")
        let finished = session("i1", percent: 100, last: ago(days: 5), finished: true)
        let quiet = build([episode(i)], sessions: [finished])
        XCTAssertEqual(quiet.count, 1)
        XCTAssertTrue(quiet[0].finishedNoMargin)
        XCTAssertFalse(quiet[0].positive)
        XCTAssertEqual(quiet[0].weight, RuleEvidenceBuilder.quietWeight)
        XCTAssertEqual(quiet[0].at, ago(days: 5))

        let withMargin = build([episode(i)], sessions: [finished], margins: [margin("i1", at: ago(days: 4))])
        XCTAssertTrue(withMargin[0].positive)
        XCTAssertFalse(withMargin[0].finishedNoMargin)
        XCTAssertEqual(withMargin[0].weight, 0)
        XCTAssertEqual(withMargin[0].at, ago(days: 4))
    }

    func testFinishedByTheListenersMarkCountsToo() {
        let marked = item("i1", completed: ago(days: 3))
        XCTAssertTrue(build([episode(marked)])[0].finishedNoMargin)
    }

    func testADeletedMarginIsNotPositiveUnlessItWasShared() {
        let i = item("i1")
        let finished = session("i1", percent: 100, last: ago(days: 5), finished: true)
        XCTAssertTrue(build([episode(i)], sessions: [finished], margins: [margin("i1", status: "deleted")])[0].finishedNoMargin)
        let identity = MarginPacketIdentity(packageDigest: String(repeating: "a", count: 64), packageScopedId: "a-1")
        let shared = build([episode(i)], sessions: [finished], margins: [margin("i1", status: "deleted", sharedAs: [identity])])
        XCTAssertTrue(shared[0].positive, "a share is a signal even after the Margin is deleted")
        XCTAssertFalse(shared[0].finishedNoMargin)
    }

    func testStoppedEarlyNeedsSevenDaysOfSilence() {
        let i = item("i1")
        XCTAssertTrue(build([episode(i)], sessions: [session("i1", last: ago(days: 7))])[0].stoppedEarly, "exactly 7 days")
        XCTAssertTrue(build([episode(i)], sessions: [session("i1", last: ago(days: 30))])[0].stoppedEarly)
        XCTAssertTrue(build([episode(i)], sessions: [session("i1", last: ago(days: 6.9))]).isEmpty, "played this week")
        let stopped = build([episode(i)], sessions: [session("i1", last: ago(days: 8))])[0]
        XCTAssertEqual(stopped.at, ago(days: 8))
        XCTAssertFalse(stopped.finishedNoMargin)
        XCTAssertTrue(build([episode(i)], sessions: [session("i1", last: ago(days: 8))], margins: [margin("i1")])[0].positive)
        XCTAssertFalse(build([episode(i)], sessions: [session("i1", last: ago(days: 8))], margins: [margin("i1")])[0].stoppedEarly)
    }

    func testAddedNeverPlayedNeedsFourteenDaysAndNoListening() {
        XCTAssertTrue(build([episode(item("i1", addedDaysAgo: 14))])[0].addedNeverPlayed, "exactly 14 days")
        XCTAssertTrue(build([episode(item("i1", addedDaysAgo: 13.9))]).isEmpty)
        XCTAssertTrue(build([episode(item("i1", addedDaysAgo: 40, deleted: true))]).isEmpty, "in Recently Deleted: the listener already said no")
        let played = build([episode(item("i1", addedDaysAgo: 40))], sessions: [session("i1", last: ago(days: 2))])
        XCTAssertTrue(played.isEmpty, "played 2 days ago: not stopped for 7 days, so no signal, and not never played")
        XCTAssertTrue(build([episode(item("i1", addedDaysAgo: 40))], margins: [margin("i1")])[0].positive)
    }

    func testAddingAgainStartsTheClocksOver() {
        // Played to the end long ago, added again yesterday: the old listening no longer counts, so it reads as a fresh add.
        let again = item("i1", addedDaysAgo: 60, addedAgain: ago(days: 1))
        let old = session("i1", percent: 100, last: ago(days: 50), finished: true)
        XCTAssertTrue(build([episode(again)], sessions: [old]).isEmpty)
        // Added again 20 days ago and never played since: never played.
        let stale = item("i1", addedDaysAgo: 60, addedAgain: ago(days: 20))
        let evidence = build([episode(stale)], sessions: [old])
        XCTAssertEqual(evidence.count, 1)
        XCTAssertTrue(evidence[0].addedNeverPlayed)
        XCTAssertEqual(evidence[0].at, ago(days: 20))
    }

    func testSeveralSignalsOnOneEpisodeAddUpAndTheNewestDateWins() {
        let i = item("i1")
        let finished = session("i1", percent: 100, last: ago(days: 5), finished: true)
        let mark = ShowLessMark(feedKey: feed, itemId: "i1", title: "Crypto crash", markedAt: ago(days: 2))
        let evidence = build([episode(i)], sessions: [finished], marks: [mark])
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence[0].weight, RuleEvidenceBuilder.showLessWeight + RuleEvidenceBuilder.quietWeight)
        XCTAssertEqual(evidence[0].at, ago(days: 2))
    }

    func testTheItemTitleIsTheFallbackAndOrderIsNewestFirstThenById() {
        let a = RuleEvidenceEpisode(item: item("i1", addedDaysAgo: 20), feedKey: feed, entryId: "b", title: nil)
        XCTAssertEqual(build([a])[0].title, "Item i1", "no entry title: the item's")
        let first = RuleEvidenceEpisode(item: item("i2", addedDaysAgo: 30), feedKey: feed, entryId: "z", title: "Entry title")
        let second = RuleEvidenceEpisode(item: item("i3", addedDaysAgo: 30), feedKey: feed, entryId: "y", title: "Same day")
        let ordered = build([first, a, second])
        XCTAssertEqual(ordered.map(\.id), ["b", "y", "z"], "newest first; a tie goes by id")
        XCTAssertEqual(ordered.last?.title, "Entry title")
    }

    func testTheSameEpisodeTwiceCountsOnce() {
        let i = item("i1", addedDaysAgo: 30)
        XCTAssertEqual(build([episode(i, entryId: "e1"), episode(i, entryId: "e1")]).count, 1)
    }
}
