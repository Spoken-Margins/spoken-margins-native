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

    func testAPlayheadJumpIsNotACrossing() {
        XCTAssertEqual(count(prompts(["a": 100_000]), from: 0, to: 200_000), 0, "a seek is not listening past the Margin")
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

    private func snapshot(_ media: Int, item: String = "item") -> SessionSnapshot {
        var value = SessionSnapshot()
        value.itemId = item
        value.currentMediaTimeMs = media
        return value
    }
}
