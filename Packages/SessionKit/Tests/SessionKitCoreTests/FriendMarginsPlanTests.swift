import XCTest
@testable import SessionKit

/// #4347 (audit findings 1 and 2 on #4248): a friend's podcast Margin that plays after the others plays when the
/// episode ends, and every surface agrees whether a start would skip it.
final class FriendMarginsPlanTests: XCTestCase {
    private let end = 1_800_000

    // MARK: finding 2: the Library row and the item screen agree

    /// The Library row of a never-started item, with every unheard Margin playing after the others, used to ask "Hear
    /// first?": the review's placeholder time for them is 0 when the episode's length isn't known, and 0 counted as
    /// behind a start at 0. The item screen showed plain Play for the same item.
    func testTheLibraryRowDoesNotAskAboutAMarginThatWaitsForTheEndWhenStartingFromZero() {
        let waiting = entries(unplaced: ["none"], durationMs: nil)
        XCTAssertEqual(waiting.map(\.mediaTimeMs), [0], "the placeholder the audit found")
        let outcome = PlayRule.decide(PlayRule.Context(itemId: "item", surface: .libraryRow, newMargins: waiting))
        XCTAssertEqual(outcome, .play(.beginning))
    }

    /// Every place a start can be at, against every kind of Margin: the Library row's question and the item screen's
    /// two choices name the same Margins, so the two screens cannot disagree about an item (#4097).
    func testTheLibraryRowAndTheItemScreenNameTheSameMarginsEverywhere() {
        let all = entries(placed: ["early": 60_000, "late": 1_500_000], unplaced: ["none", "past"], senderOverrides: ["past": end + 60_000])
        XCTAssertEqual(all.filter(\.playsAfterOthers).count, 2)
        let table: [(String, [Session], [String])] = [
            ("never started", [], []),
            ("early in the episode", [session("a", percent: 3, mediaTimeMs: 90_000)], ["early"]),
            ("mid-way", [session("a", percent: 33, mediaTimeMs: 600_000)], ["early"]),
            ("late, past the late Margin", [session("a", percent: 90, mediaTimeMs: 1_620_000)], ["early", "late"]),
            ("left at the end, 99%", [session("a", percent: 99, mediaTimeMs: end - 5_000)], ["early", "late", "none", "past"]),
            ("finished, Play starts over", [session("a", status: "finished", phase: .finished, percent: 100, mediaTimeMs: end)], []),
        ]
        for (name, sessions, expected) in table {
            let open = PlayRule.OpenItem(id: "item", sessions: sessions, addedAgainAt: nil)
            let libraryRow = PlayRule.decide(PlayRule.Context(itemId: "item", surface: .libraryRow, openItem: open, newMargins: all))
            let rowIDs: [String]
            if case .askFirst(let asked) = libraryRow { rowIDs = asked.map(\.interjection.id) } else { rowIDs = [] }
            let screenIDs = PlayRule.itemScreenMarginsBehind(
                all, itemId: "item", sessions: sessions, addedAgainAt: nil, declined: NewMarginsOfferMemory()).map(\.interjection.id)
            XCTAssertEqual(rowIDs, screenIDs, "\(name): the row and the screen agree")
            XCTAssertEqual(Set(rowIDs), Set(expected), name)
        }
    }

    func testTheRulePerKindOfPlaceAndMargin() {
        let all = entries(placed: ["at60": 60_000], unplaced: ["none"])
        let table: [(String, FriendMarginsPlan.Place, [String])] = [
            ("start", .known(mediaTimeMs: 0, isAtEnd: false), []),
            ("exactly at a Margin", .known(mediaTimeMs: 60_000, isAtEnd: false), []),
            ("past a Margin", .known(mediaTimeMs: 60_001, isAtEnd: false), ["at60"]),
            ("short of the end, the length unknown", .known(mediaTimeMs: 9_000_000, isAtEnd: false), ["at60"]),
            ("at the end", .known(mediaTimeMs: end, isAtEnd: true), ["at60", "none"]),
            ("unknown: none can be ruled out", .unknown, ["at60", "none"]),
        ]
        for (name, place, expected) in table {
            let split = FriendMarginsPlan.split(all, place: place)
            XCTAssertEqual(split.behind.map(\.interjection.id), expected, name)
            XCTAssertEqual(split.behind.count + split.ahead.count, all.count, "\(name): every Margin is one or the other")
            XCTAssertEqual(split.playAtEnd.map(\.interjection.id), ["none"], "\(name): it waits for the end")
        }
        XCTAssertEqual(SharedMarginReview.entriesBehind(all, placeMs: 9_000_000).map(\.interjection.id), ["at60"])
        XCTAssertEqual(SharedMarginReview.entriesBehind(all, placeMs: end, placeIsAtEnd: true).count, 2)
    }

    // MARK: finding 1: the Margin plays when the episode ends

    func testAMarginWithNoUsableTimeIsCrossedWhenTheEpisodeEndsAndOnlyThen() {
        let prompts = prompts(unplaced: ["none"], durationMs: end)
        XCTAssertEqual(prompts.map(\.plan), [.afterOthers])
        func tick(_ from: Int, _ to: Int, item: String? = "item", session: String? = "s") -> [String] {
            SharedMarginPrompts.crossed(
                prompts: prompts, previous: snapshot(percent: from), current: snapshot(percent: to, item: item, session: session)
            ).map(\.interjection.id)
        }
        XCTAssertEqual(tick(99, 100), ["none"], "the tick the episode reaches its end")
        XCTAssertEqual(tick(40, 41), [], "listening on")
        XCTAssertEqual(tick(60, 99), [], "a seek short of the end")
        XCTAssertEqual(tick(100, 100), [], "the next tick, still at the end: once only")
        XCTAssertEqual(tick(100, 0), [], "a Replay starts at 0")
        XCTAssertEqual(tick(99, 100, item: "other"), [], "opening another item that is finished says nothing")
        XCTAssertEqual(tick(99, 100, session: "t"), [], "a different session says nothing")
        XCTAssertEqual(tick(0, 100), ["none"], "a skip to the end plays what waits for it, as it plays the ones it crossed")
    }

    /// The end-of-episode Margins join the same queue as the others, so they are offered one at a time, in order,
    /// after the ones in place (they sort last), and once.
    func testTheOfferQueueOffersWhatWaitsForTheEndOnceAndOneAtATime() {
        let all = prompts(unplaced: ["a", "b"], durationMs: end)
        var queue = SharedMarginOfferQueue()
        let offered = queue.nextOffer(
            previous: snapshot(percent: 99), current: snapshot(percent: 100), selectedItemID: "item", canOffer: true, prompts: all)
        XCTAssertEqual(offered?.interjection.id, "a")
        XCTAssertEqual(queue.waitingIDs, ["b"], "the second waits its turn")
        XCTAssertEqual(queue.next(from: all)?.interjection.id, "b")
        let unannounced = all.filter { !queue.announcedIDs.contains($0.id) }
        let again = queue.nextOffer(
            previous: snapshot(percent: 100), current: snapshot(percent: 100), selectedItemID: "item", canOffer: true,
            prompts: unannounced)
        XCTAssertNil(again)
    }

    /// A card or a Margin voice holds the slot when the episode ends: the Margins that wait for the end are queued,
    /// not dropped with the tick, and are offered once the slot is free.
    func testTheEndOfTheEpisodeWhileACardIsUpQueuesWhatWaitsForIt() {
        let all = prompts(unplaced: ["a"], durationMs: end)
        var queue = SharedMarginOfferQueue()
        let held = queue.nextOffer(
            previous: snapshot(percent: 99), current: snapshot(percent: 100), selectedItemID: "item", canOffer: false, prompts: all)
        XCTAssertNil(held)
        XCTAssertEqual(queue.waitingIDs, ["a"])
        // No later tick comes in the app, so what is queued is drained by `nextWaitingAtEpisodeEnd` (the tests below).
        var otherItem = SharedMarginOfferQueue()
        _ = otherItem.nextOffer(
            previous: snapshot(percent: 99), current: snapshot(percent: 100), selectedItemID: "elsewhere", canOffer: false, prompts: all)
        XCTAssertTrue(otherItem.isEmpty, "the open item isn't the one that ended")
    }

    /// The audit of 8957d00: ticks stop when the source stops, so after the end only a call when a Margin's voice
    /// ends or a card is let go can offer the next one. Drives the queue the way the app does, with no second tick.
    func testEveryMarginThatWaitsForTheEndIsOfferedWithNoTickAfterTheEnd() {
        let all = prompts(unplaced: ["a", "b", "c"], durationMs: end)
        var queue = SharedMarginOfferQueue()
        var ended = snapshot(percent: 100)
        ended.status = .paused
        var playing = snapshot(percent: 99)
        playing.status = .playing
        var heard: [String] = []
        if let first = queue.nextOffer(previous: playing, current: ended, selectedItemID: "item", canOffer: true, prompts: all) {
            heard.append(first.interjection.id)
        }
        XCTAssertNil(queue.nextWaitingAtEpisodeEnd(snapshot: ended, selectedItemID: "item", slotIsFree: false, offerable: all),
                     "a card or voice still has the slot")
        while let next = queue.nextWaitingAtEpisodeEnd(snapshot: ended, selectedItemID: "item", slotIsFree: true, offerable: all) {
            heard.append(next.interjection.id)
        }
        XCTAssertEqual(heard, ["a", "b", "c"], "one at a time, in order, each once")
        XCTAssertTrue(queue.isEmpty)
    }

    /// A card was up at the end (nothing could be offered): when it is let go, what was queued is offered.
    func testWhatWasQueuedBehindACardAtTheEndIsOfferedWhenTheCardIsLetGo() {
        let all = prompts(unplaced: ["a", "b"], durationMs: end)
        var queue = SharedMarginOfferQueue()
        var ended = snapshot(percent: 100)
        ended.status = .paused
        var playing = snapshot(percent: 99)
        playing.status = .playing
        XCTAssertNil(queue.nextOffer(previous: playing, current: ended, selectedItemID: "item", canOffer: false, prompts: all))
        XCTAssertEqual(queue.waitingIDs, ["a", "b"])
        XCTAssertEqual(queue.nextWaitingAtEpisodeEnd(snapshot: ended, selectedItemID: "item", slotIsFree: true, offerable: all)?.interjection.id, "a")
        XCTAssertEqual(queue.nextWaitingAtEpisodeEnd(snapshot: ended, selectedItemID: "item", slotIsFree: true, offerable: all)?.interjection.id, "b")
    }

    /// Only after the end, on the open item, with the source stopped: anywhere else the ticks do the offering.
    func testNothingIsOfferedThisWayMidEpisodeOrWhileTheSourcePlaysOrOnAnotherItem() {
        let all = prompts(unplaced: ["a"], durationMs: end)
        var waiting = SharedMarginOfferQueue()
        waiting.append(all)
        var stoppedAtEnd = snapshot(percent: 100)
        stoppedAtEnd.status = .paused
        var midway = snapshot(percent: 60)
        midway.status = .paused
        var playingAtEnd = snapshot(percent: 100)
        playingAtEnd.status = .playing
        for (name, snap, item) in [("mid-episode", midway, "item"), ("source playing", playingAtEnd, "item"), ("another item", stoppedAtEnd, "other")] {
            XCTAssertNil(waiting.nextWaitingAtEpisodeEnd(snapshot: snap, selectedItemID: item, slotIsFree: true, offerable: all), name)
            XCTAssertEqual(waiting.waitingIDs, ["a"], "\(name): nothing was taken")
        }
        XCTAssertEqual(waiting.nextWaitingAtEpisodeEnd(snapshot: stoppedAtEnd, selectedItemID: "item", slotIsFree: true, offerable: all)?.interjection.id, "a")
        XCTAssertNil(waiting.nextWaitingAtEpisodeEnd(snapshot: stoppedAtEnd, selectedItemID: "item", slotIsFree: true, offerable: all), "empty")
    }

    func testAFriendsMarginInPlaceStillPlaysWhereItIsAndNotAtTheEnd() {
        let all = prompts(placed: ["early": 60_000], unplaced: ["none"], durationMs: end)
        let midway = SharedMarginPrompts.crossed(
            prompts: all, previous: mediaSnapshot(percent: 2, ms: 59_000), current: mediaSnapshot(percent: 3, ms: 61_000))
        XCTAssertEqual(midway.map(\.interjection.id), ["early"])
        let atEnd = SharedMarginPrompts.crossed(prompts: all, previous: snapshot(percent: 99), current: snapshot(percent: 100))
        XCTAssertEqual(atEnd.map(\.interjection.id), ["none"])
    }

    // MARK: finding 1, second part: a sender time past the end of this copy

    func testASenderTimePastTheCopysEndPlaysAfterTheOthersOnceTheLengthIsKnown() {
        let overrides = ["past": end + 60_000]
        let known = prompts(unplaced: ["past"], senderOverrides: overrides, durationMs: end)
        XCTAssertEqual(known.map(\.plan), [.afterOthers])
        XCTAssertNil(known[0].mediaTimeMs, "no clock time to jump to or to cross in place")
        let unknown = prompts(unplaced: ["past"], senderOverrides: overrides, durationMs: nil)
        XCTAssertEqual(unknown.map(\.plan), [.roughly(mediaTimeMs: end + 60_000)], "length unknown: the sender time is trusted")
        let nearEnd = SharedMarginPrompts.crossed(
            prompts: known, previous: mediaSnapshot(percent: 98, ms: end - 30_000), current: mediaSnapshot(percent: 99, ms: end - 1_000))
        XCTAssertTrue(nearEnd.isEmpty, "it is not crossed in place just before the end")
        XCTAssertEqual(SharedMarginPrompts.crossed(prompts: known, previous: snapshot(percent: 99), current: snapshot(percent: 100)).count, 1)
    }

    func testTheEndOfTheEpisodeIsOneTickAtOneHundredPercentOfTheSameSession() {
        let table: [(String, Int, Int, Bool)] = [
            ("99 to 100", 99, 100, true), ("0 to 100", 0, 100, true), ("98 to 99", 98, 99, false),
            ("100 to 100", 100, 100, false), ("100 to 99", 100, 99, false),
        ]
        for (name, from, to, expected) in table {
            XCTAssertEqual(FriendMarginsPlan.episodeEndReached(previous: snapshot(percent: from), current: snapshot(percent: to)), expected, name)
        }
        XCTAssertFalse(FriendMarginsPlan.episodeEndReached(previous: SessionSnapshot(), current: snapshot(percent: 100)), "no item before")
        // A seek writes the snapshot at 100% before the next tick, which then sees the source stop.
        var playing = snapshot(percent: 100)
        playing.status = .playing
        var stopped = snapshot(percent: 100)
        stopped.status = .paused
        XCTAssertTrue(FriendMarginsPlan.episodeEndReached(previous: playing, current: stopped), "the source stops at the end")
        XCTAssertFalse(FriendMarginsPlan.episodeEndReached(previous: stopped, current: stopped), "already stopped: once only")
        XCTAssertFalse(FriendMarginsPlan.episodeEndReached(previous: playing, current: playing), "still playing at 100%")
        var elsewhere = stopped
        elsewhere.sessionId = "t"
        XCTAssertFalse(FriendMarginsPlan.episodeEndReached(previous: playing, current: elsewhere), "another session")
    }

    // MARK: helpers

    private func snapshot(percent: Int, item: String? = "item", session: String? = "s") -> SessionSnapshot {
        var value = SessionSnapshot()
        value.itemId = item
        value.sessionId = session
        value.currentPlaybackProgressPercent = percent
        return value
    }

    private func mediaSnapshot(percent: Int, ms: Int) -> SessionSnapshot {
        var value = snapshot(percent: percent)
        value.currentMediaTimeMs = ms
        return value
    }

    private func session(
        _ id: String, status: String = "in_progress", phase: SessionPhase = .itemPlayback, percent: Int, mediaTimeMs: Int?
    ) -> Session {
        Session(
            id: id, itemId: "item", updatedAt: Date(timeIntervalSince1970: 1), status: status, phase: phase,
            currentTargetType: .itemTextTTS, currentTargetId: "item",
            position: Position(charOffset: 0, mediaTimeMs: mediaTimeMs), completionPercent: percent, playbackRate: 1)
    }

    private var layer: ImportedCommentaryLayer {
        var value = ImportedCommentaryLayer(
            id: "layer", itemId: "item", packageDigest: "d", packageId: "p",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"), displayLabel: "Ana",
            importedAt: Date(timeIntervalSince1970: 0), sourceResolutionStatus: .resolved, isEnabled: true)
        value.resolvedRecipientEditionSHA256 = "digest"
        return value
    }

    /// Placed Margins (id to place) and Margins the pass couldn't place (sender time none, unless overridden).
    private func records(placed: [String: Int], unplaced: [String], senderOverrides: [String: Int]) -> [ImportedCommentaryInterjection] {
        func record(_ id: String, sender: Int?, resolution: ImportedAnchorResolution) -> ImportedCommentaryInterjection {
            ImportedCommentaryInterjection(
                id: id, layerId: "layer", packageScopedId: "packet-\(id)", createdAt: Date(timeIntervalSince1970: 0),
                anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: sender),
                approvedTranscript: "Words", resolution: resolution)
        }
        let placedRecords = placed.sorted { $0.value < $1.value }.map {
            record($0.key, sender: $0.value, resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: $0.value))
        }
        let unplacedRecords = unplaced.map {
            record($0, sender: senderOverrides[$0], resolution: ImportedAnchorResolution(evidenceClass: .unresolved))
        }
        return placedRecords + unplacedRecords
    }

    private func entries(
        placed: [String: Int] = [:], unplaced: [String] = [], senderOverrides: [String: Int] = [:], durationMs: Int? = 1_800_000
    ) -> [SharedMarginReview.Entry] {
        SharedMarginReview.entries(
            layers: [layer], records: ["layer": records(placed: placed, unplaced: unplaced, senderOverrides: senderOverrides)],
            durationMs: durationMs)
    }

    private func prompts(
        placed: [String: Int] = [:], unplaced: [String] = [], senderOverrides: [String: Int] = [:], durationMs: Int?
    ) -> [ImportedCommentaryPrompt] {
        SharedMarginPrompts.prompts(
            layers: [layer], recordsByLayerID: ["layer": records(placed: placed, unplaced: unplaced, senderOverrides: senderOverrides)],
            announcedIDs: [], includeAnnounced: true, durationMs: durationMs)
    }
}
