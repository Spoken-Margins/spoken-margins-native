import XCTest
import SessionKit

final class SharedMarginOfferQueueTests: XCTestCase {
    func testSeveralMarginsCrossedTogetherAreOfferedOneAfterAnotherInListeningOrder() {
        let all = prompts(["first": 100, "second": 100, "third": 300])
        var queue = SharedMarginOfferQueue()

        XCTAssertEqual(tick(&queue, all, from: 90, to: 400)?.id, "first")
        // Nothing new crosses on the following ticks; the others are still owed.
        XCTAssertEqual(tick(&queue, all, from: 400, to: 400)?.id, "second")
        XCTAssertEqual(tick(&queue, all, from: 400, to: 400)?.id, "third")
        XCTAssertNil(tick(&queue, all, from: 400, to: 400))
        XCTAssertTrue(queue.isEmpty)
    }

    func testNothingIsOfferedWhenNothingCrossedAndNothingWaits() {
        var queue = SharedMarginOfferQueue()
        XCTAssertNil(tick(&queue, prompts(["a": 1_000]), from: 0, to: 500))
        XCTAssertTrue(queue.announcedIDs.isEmpty)
    }

    func testMarginsWaitingKeepTheirPlaceAheadOfALaterCrossing() {
        let all = prompts(["a": 100, "b": 110, "c": 500])
        var queue = SharedMarginOfferQueue()
        XCTAssertEqual(tick(&queue, all, from: 90, to: 200)?.id, "a")
        XCTAssertEqual(tick(&queue, all, from: 200, to: 600)?.id, "b")
        XCTAssertEqual(tick(&queue, all, from: 600, to: 600)?.id, "c")
    }

    func testNothingIsOfferedWhileAnotherMarginIsPendingOrPlayingAndNothingIsLostFromTheQueue() {
        let all = prompts(["a": 100, "b": 110])
        var queue = SharedMarginOfferQueue()
        XCTAssertEqual(tick(&queue, all, from: 90, to: 200)?.id, "a")
        XCTAssertNil(tick(&queue, all, from: 200, to: 200, canOffer: false))
        XCTAssertEqual(queue.waitingIDs, ["b"])
        XCTAssertEqual(tick(&queue, all, from: 200, to: 200)?.id, "b")
    }

    func testACrossedMarginIsAnnouncedOnceAndNotCrossedAgain() {
        let all = prompts(["a": 100])
        var queue = SharedMarginOfferQueue()
        XCTAssertEqual(tick(&queue, all, from: 90, to: 110)?.id, "a")
        XCTAssertEqual(queue.announcedIDs, ["a"])
        // Playing back over the same spot within the jump limit does not offer it again.
        XCTAssertNil(tick(&queue, all, from: 95, to: 110))
        XCTAssertNil(tick(&queue, all, from: 90, to: 110))
    }

    func testAMarginAlreadyWaitingIsNotQueuedTwice() {
        let all = prompts(["a": 100, "b": 110])
        var queue = SharedMarginOfferQueue()
        queue.append(all)
        queue.append(all)
        XCTAssertEqual(queue.waitingIDs, ["a", "b"])
    }

    func testAMarginThatWentAwayWhileWaitingIsSkippedNotOffered() {
        let all = prompts(["a": 100, "b": 110, "c": 120])
        var queue = SharedMarginOfferQueue()
        XCTAssertEqual(tick(&queue, all, from: 90, to: 200)?.id, "a")
        // b's layer was turned off or deleted while a played.
        let stillOfferable = all.filter { $0.id != "b" }
        XCTAssertEqual(tick(&queue, stillOfferable, from: 200, to: 200)?.id, "c")
        XCTAssertNil(tick(&queue, stillOfferable, from: 200, to: 200))
    }

    func testFreshRevealMarginsAreAnnouncedButNeverQueuedOrOffered() {
        let all = [prompt("fresh", media: 100, reveal: .fresh), prompt("companion", media: 110, reveal: .companion)]
        var queue = SharedMarginOfferQueue()
        XCTAssertEqual(tick(&queue, all, from: 90, to: 200)?.id, "companion")
        XCTAssertNil(tick(&queue, all, from: 200, to: 200))
        XCTAssertEqual(queue.announcedIDs, ["fresh", "companion"])
    }

    func testASeekDropsTheMarginsWaitingFromBeforeIt() {
        let all = prompts(["a": 100, "b": 110, "c": 150_000])
        var queue = SharedMarginOfferQueue()
        XCTAssertEqual(tick(&queue, all, from: 90, to: 200)?.id, "a")
        XCTAssertEqual(queue.waitingIDs, ["b"])
        // The listener seeks far away; b belongs to the old position.
        XCTAssertNil(tick(&queue, all, from: 200, to: 80_000))
        XCTAssertTrue(queue.isEmpty)
        // c is still offered when the source reaches it.
        XCTAssertEqual(tick(&queue, all, from: 149_800, to: 150_200)?.id, "c")
    }

    func testAChangeOfItemDropsEveryWaitingMargin() {
        let all = prompts(["a": 100, "b": 110])
        var queue = SharedMarginOfferQueue()
        XCTAssertEqual(tick(&queue, all, from: 90, to: 200)?.id, "a")
        XCTAssertNil(queue.nextOffer(previous: snapshot(200), current: snapshot(200, item: "other"),
                                     selectedItemID: "item", canOffer: true, prompts: all))
        XCTAssertTrue(queue.isEmpty)
    }

    func testAMarginOfferedSomeOtherWayNoLongerWaits() {
        let all = prompts(["a": 100, "b": 110, "c": 120])
        var queue = SharedMarginOfferQueue()
        queue.append(all)
        queue.markAnnounced("b")
        XCTAssertEqual(queue.waitingIDs, ["a", "c"])
        XCTAssertEqual(queue.announcedIDs, ["b"])
        queue.remove(id: "c")
        queue.remove(id: "missing")
        XCTAssertEqual(queue.waitingIDs, ["a"])
        XCTAssertEqual(queue.announcedIDs, ["b"], "playing it from the list does not announce it")
    }

    func testAMarginAReviewGaveBackIsOfferedWhenTheSourceCrossesIt() {
        let all = prompts(["a": 100, "b": 110])
        var queue = SharedMarginOfferQueue()
        queue.markAnnounced("a")
        queue.markAnnounced("b")
        XCTAssertNil(tick(&queue, all, from: 90, to: 200), "a review announced both")
        queue.markUnannounced(["b", "missing"])
        XCTAssertEqual(queue.announcedIDs, ["a"])
        XCTAssertEqual(tick(&queue, all, from: 90, to: 200)?.id, "b")
    }

    func testStartingASessionClearsAnnouncedAndWaiting() {
        let all = prompts(["a": 100, "b": 110])
        var queue = SharedMarginOfferQueue()
        XCTAssertEqual(tick(&queue, all, from: 90, to: 200)?.id, "a")
        queue.removeAll()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertTrue(queue.announcedIDs.isEmpty)
        XCTAssertEqual(tick(&queue, all, from: 90, to: 200)?.id, "a")
    }

    func testOnlyASeekOrRewindCountsAsAPlayheadJump() {
        func jump(_ before: Int?, _ after: Int?, text: (Int, Int)? = nil) -> Bool {
            var previous = snapshot(before ?? 0), current = snapshot(after ?? 0)
            previous.currentMediaTimeMs = before
            current.currentMediaTimeMs = after
            previous.currentTextStart = text?.0
            current.currentTextStart = text?.1
            return SharedMarginOfferQueue.isPlayheadJump(previous: previous, current: current)
        }
        XCTAssertFalse(jump(100_000, 100_500), "an ordinary tick")
        XCTAssertFalse(jump(100_000, 101_500), "a tick at 3x")
        XCTAssertFalse(jump(100_000, 100_000), "paused")
        XCTAssertFalse(jump(100_000, 110_000), "exactly the limit")
        XCTAssertTrue(jump(100_000, 110_001), "a skip forward")
        XCTAssertTrue(jump(100_000, 99_999), "a rewind")
        XCTAssertTrue(jump(100_000, 40_000), "a seek back")
        XCTAssertFalse(jump(nil, nil), "no position at all")
        XCTAssertFalse(jump(nil, 5_000), "no earlier position to compare")
        XCTAssertFalse(jump(nil, nil, text: (500, 620)), "text moving a sentence")
        XCTAssertTrue(jump(nil, nil, text: (500, 4_000)), "text seek forward")
        XCTAssertTrue(jump(nil, nil, text: (500, 100)), "text seek back")
    }

    /// One tick of playback from `from` to `to` ms on the selected item. The step is not limited
    /// here, so a long step stands for several ticks of one crossing; use a seek test for jumps.
    private func tick(_ queue: inout SharedMarginOfferQueue, _ all: [ImportedCommentaryPrompt],
                      from: Int, to: Int, canOffer: Bool = true) -> ImportedCommentaryPrompt? {
        queue.nextOffer(previous: snapshot(from), current: snapshot(to), selectedItemID: "item",
                        canOffer: canOffer, prompts: all)
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

    private func snapshot(_ media: Int, item: String = "item") -> SessionSnapshot {
        var value = SessionSnapshot()
        value.itemId = item
        value.currentMediaTimeMs = media
        return value
    }
}
