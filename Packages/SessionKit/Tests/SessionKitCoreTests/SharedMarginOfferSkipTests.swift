import XCTest
import SessionKit

/// The "crossed, not offered, why" event for a friend's Margin the source crossed while the offer slot was busy (#4109).
final class SharedMarginOfferSkipTests: XCTestCase {
    func testAMarginCrossedThisTickIsCounted() {
        XCTAssertEqual(count(prompts(["a": 100, "b": 110, "c": 900]), from: 90, to: 200), 2)
    }

    func testNothingCrossedCountsNothing() {
        XCTAssertEqual(count(prompts(["a": 1_000]), from: 0, to: 500), 0)
        XCTAssertEqual(count([], from: 0, to: 500), 0)
    }

    /// The queue still finds a Margin on a forward jump (a Lock Screen skip, a long gap between ticks), and loses it when
    /// the slot is busy, so the event counts it (#4109 audit).
    func testAForwardJumpAcrossAMarginIsStillACrossing() {
        XCTAssertEqual(count(prompts(["a": 100_000]), from: 95_000, to: 125_000), 1, "a 30 s skip passes the Margin at 100 s")
    }

    func testARewindCrossesNothing() {
        XCTAssertEqual(count(prompts(["a": 100]), from: 200, to: 50), 0)
    }

    /// A Margin that plays after the others is queued for the end of the episode, not dropped, so it is not reported.
    func testAMarginThatPlaysAfterTheOthersIsNotCountedAtTheEndOfTheEpisode() {
        let late = afterOthersPrompt("late")
        XCTAssertEqual(late.plan, .afterOthers)
        var previous = snapshot(0), current = snapshot(0)
        previous.sessionId = "s"; current.sessionId = "s"
        previous.currentPlaybackProgressPercent = 90; current.currentPlaybackProgressPercent = 100
        XCTAssertEqual(
            SharedMarginOfferSkip.crossedCount(previous: previous, current: current, selectedItemID: "item", prompts: [late]), 0)
        var queue = SharedMarginOfferQueue()
        _ = queue.nextOffer(previous: previous, current: current, selectedItemID: "item", canOffer: false, prompts: [late])
        XCTAssertEqual(queue.waitingIDs, ["late"], "the busy-slot queue keeps it, as the count assumes")
    }

    /// The class of finding: the count and the queue must agree on every tick. For each pair of positions, the count
    /// equals the number of Margins the queue offers or queues when the slot is free, and when the slot is busy it
    /// is exactly the number of Margins the queue announces nothing for and loses.
    func testTheCountAgreesWithTheQueueOnEveryTick() {
        let all = prompts(["a": 100, "b": 5_000, "c": 40_000, "d": 90_000])
        let positions = [0, 50, 100, 4_000, 5_000, 20_000, 39_000, 40_000, 95_000, 120_000]
        for from in positions {
            for to in positions {
                var free = SharedMarginOfferQueue()
                let first = free.nextOffer(previous: snapshot(from), current: snapshot(to), selectedItemID: "item", canOffer: true, prompts: all)
                let offered = (first == nil ? 0 : 1) + free.waitingIDs.count
                var busy = SharedMarginOfferQueue()
                _ = busy.nextOffer(previous: snapshot(from), current: snapshot(to), selectedItemID: "item", canOffer: false, prompts: all)
                XCTAssertEqual(count(all, from: from, to: to), offered, "\(from) to \(to)")
                XCTAssertTrue(busy.announcedIDs.isEmpty && busy.waitingIDs.isEmpty, "a busy slot loses them: \(from) to \(to)")
            }
        }
    }

    func testAnotherItemThanTheSelectedOneCountsNothing() {
        let skipped = SharedMarginOfferSkip.crossedCount(
            previous: snapshot(90, item: "other"), current: snapshot(200, item: "other"), selectedItemID: "item",
            prompts: prompts(["a": 100]))
        XCTAssertEqual(skipped, 0)
    }

    func testAMarginInFreshRevealModeIsNeverOfferedSoNeverCounted() {
        XCTAssertEqual(count([prompt("a", media: 100, reveal: .fresh)], from: 90, to: 200), 0)
    }

    func testTheEventFieldNamesAndValuesArePinned() {
        let fields = SharedMarginOfferSkip.eventFields(
            crossed: 2, slot: .init(pendingCard: true, playingVoice: false, reviewRunning: false, momentVoice: true),
            appState: "background", sourcePlaying: true)
        XCTAssertEqual(fields, [
            "crossed": "2", "slotPendingCard": "true", "slotPlayingVoice": "false", "slotReview": "false",
            "slotMomentVoice": "true", "appState": "background", "sourcePlaying": "true",
        ])
        XCTAssertEqual(
            SharedMarginOfferSkip.diagnosticsLine(fields),
            "appState=background;crossed=2;slotMomentVoice=true;slotPendingCard=true;slotPlayingVoice=false;slotReview=false;sourcePlaying=true")
    }

    func testTheEventCarriesNoTextOrIdentifier() {
        let fields = SharedMarginOfferSkip.eventFields(
            crossed: 1, slot: .init(pendingCard: false, playingVoice: true, reviewRunning: false, momentVoice: false),
            appState: "foreground", sourcePlaying: false)
        let joined = fields.values.joined(separator: " ")
        XCTAssertFalse(joined.contains("Words"))
        XCTAssertFalse(joined.contains("Episode"))
        XCTAssertEqual(Set(fields.keys).count, 7, "counts and flags only")
    }

    /// The count agrees with what `nextOffer` would have offered had the slot been free, so the event names a Margin that
    /// really was lost.
    func testTheCountMatchesWhatTheQueueWouldHaveOffered() {
        let all = prompts(["a": 100, "b": 110])
        var queue = SharedMarginOfferQueue()
        let offered = queue.nextOffer(
            previous: snapshot(90), current: snapshot(200), selectedItemID: "item", canOffer: true, prompts: all)
        XCTAssertNotNil(offered)
        XCTAssertEqual(count(all, from: 90, to: 200), 2)
    }

    private func count(_ all: [ImportedCommentaryPrompt], from: Int, to: Int) -> Int {
        SharedMarginOfferSkip.crossedCount(previous: snapshot(from), current: snapshot(to), selectedItemID: "item", prompts: all)
    }

    private func prompts(_ media: KeyValuePairs<String, Int>) -> [ImportedCommentaryPrompt] {
        media.map { prompt($0.key, media: $0.value) }
    }

    private func prompt(_ id: String, media: Int, reveal: ImportedCommentaryRevealMode = .companion) -> ImportedCommentaryPrompt {
        var layer = ImportedCommentaryLayer(id: "layer", itemId: "item", packageDigest: "digest", packageId: "package",
                                            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
                                            importedAt: Date(timeIntervalSince1970: 0),
                                            sourceResolutionStatus: .resolved, isEnabled: true)
        layer.revealMode = reveal
        let record = ImportedCommentaryInterjection(
            id: id, layerId: layer.id, packageScopedId: "packet-\(id)", createdAt: Date(timeIntervalSince1970: 0),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Words",
            resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: media))
        return ImportedCommentaryPrompt(layer: layer, interjection: record, index: 1, count: 1)
    }

    private func afterOthersPrompt(_ id: String) -> ImportedCommentaryPrompt {
        let layer = ImportedCommentaryLayer(id: "layer", itemId: "item", packageDigest: "digest", packageId: "package",
                                            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
                                            importedAt: Date(timeIntervalSince1970: 0),
                                            sourceResolutionStatus: .resolved, isEnabled: true)
        let record = ImportedCommentaryInterjection(
            id: id, layerId: layer.id, packageScopedId: "packet-\(id)", createdAt: Date(timeIntervalSince1970: 0),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Words",
            resolution: ImportedAnchorResolution(evidenceClass: .absentFromRecipientEdition))
        return ImportedCommentaryPrompt(layer: layer, interjection: record, index: 1, count: 1)
    }

    private func snapshot(_ media: Int, item: String = "item") -> SessionSnapshot {
        var value = SessionSnapshot()
        value.itemId = item
        value.currentMediaTimeMs = media
        return value
    }
}
