import XCTest
import SessionKit

final class SharedMarginOfferQueueTests: XCTestCase {
    func testSeveralMarginsCrossedTogetherAreOfferedOneAfterAnotherInListeningOrder() {
        let all = prompts(["first": 100, "second": 100, "third": 300])
        let crossed = SharedMarginPrompts.crossed(prompts: all, previous: snapshot(90), current: snapshot(400))
        var queue = SharedMarginOfferQueue()

        XCTAssertEqual(queue.nextOffer(crossed: crossed, announced: all)?.id, "first")
        // Nothing new crosses on the following ticks; the others are still owed.
        XCTAssertEqual(queue.nextOffer(crossed: [], announced: all)?.id, "second")
        XCTAssertEqual(queue.nextOffer(crossed: [], announced: all)?.id, "third")
        XCTAssertNil(queue.nextOffer(crossed: [], announced: all))
        XCTAssertTrue(queue.isEmpty)
    }

    func testAnEmptyQueueOffersNothingWhenNothingCrossed() {
        var queue = SharedMarginOfferQueue()
        XCTAssertNil(queue.nextOffer(crossed: [], announced: prompts(["a": 1])))
    }

    func testMarginsWaitingKeepTheirPlaceAheadOfALaterCrossing() {
        let all = prompts(["a": 100, "b": 110, "c": 500])
        var queue = SharedMarginOfferQueue()
        XCTAssertEqual(queue.nextOffer(crossed: Array(all[0...1]), announced: all)?.id, "a")
        XCTAssertEqual(queue.nextOffer(crossed: [all[2]], announced: all)?.id, "b")
        XCTAssertEqual(queue.nextOffer(crossed: [], announced: all)?.id, "c")
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
        queue.append(all)
        // b's layer was turned off or deleted while a played.
        let stillOfferable = all.filter { $0.id != "b" }
        XCTAssertEqual(queue.next(from: stillOfferable)?.id, "a")
        XCTAssertEqual(queue.next(from: stillOfferable)?.id, "c")
        XCTAssertNil(queue.next(from: stillOfferable))
    }

    func testFreshRevealMarginsAreNeverQueuedOrOffered() {
        let fresh = prompt("fresh", media: 100, reveal: .fresh)
        let companion = prompt("companion", media: 110, reveal: .companion)
        var queue = SharedMarginOfferQueue()
        XCTAssertEqual(queue.nextOffer(crossed: [fresh, companion], announced: [fresh, companion])?.id, "companion")
        XCTAssertNil(queue.nextOffer(crossed: [], announced: [fresh, companion]))
    }

    func testClearingDropsEveryWaitingMargin() {
        let all = prompts(["a": 1, "b": 2])
        var queue = SharedMarginOfferQueue()
        queue.append(all)
        queue.removeAll()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.next(from: all))
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

    private func snapshot(_ media: Int) -> SessionSnapshot {
        var value = SessionSnapshot()
        value.currentMediaTimeMs = media
        return value
    }
}
