import XCTest
@testable import SessionKit

/// #4175: the pinned card's line while it counts down to a friend's podcast Margin. The Test Desk found the copy-length
/// note from #5010 never showed in ordinary playback (J5 step 2): the line read the Margin's place only inside a Margin
/// moment, and a plain Play or "Skip to just before Ben" counts down without one.
final class PinnedMarginCardDetailTests: XCTestCase {
    private let caution = SharedMarginPlacementWording.approximatePositionNote
    private let playsByItself = "Plays by itself when you get there."
    /// The Desk's packet: HPR4736 (5:14) with the layer's length raised by 33 s (the helper's default lengths).
    private let senderMs = 347_184

    // MARK: Ordinary playback, no Margin moment (J5 step 2)

    func testACountdownToAFriendsMarginAtTheSendersClockSaysHowFarApartTheCopiesAre() {
        let line = line(upNext(.playsByItself), target: target(evidence: .timestampFallback))
        XCTAssertEqual(line, "Your copy is about 35 seconds shorter than Ben's, so Margins may be that far off.")
        // A Margin the pass could not place plays at the sender's clock too.
        XCTAssertEqual(self.line(upNext(.playsByItself), target: target(evidence: .unresolved)), line)
    }

    func testACountdownWithNothingToSayAboutTheLengthsKeepsTheCaution() {
        XCTAssertEqual(line(upNext(.playsByItself), target: target(evidence: .timestampFallback, sender: nil)), caution)
        XCTAssertEqual(line(upNext(.playsByItself), target: target(evidence: .timestampFallback, listener: nil)), caution,
                       "the player has not reported a length yet")
        XCTAssertEqual(line(upNext(.playsByItself), target: target(evidence: .timestampFallback, listener: senderMs - 5_000)), caution,
                       "under 10 s apart")
        XCTAssertEqual(line(upNext(.playsByItself), target: target(evidence: .mapInterpolated, placedAt: 60_000)), caution,
                       "shifted by its matched neighbours: the ad difference is taken out already")
    }

    func testACountdownKeepsItsOwnLineWhenThePlaceIsNotAGuess() {
        XCTAssertEqual(line(upNext(.playsByItself), target: target(evidence: .acousticVerified, placedAt: 60_000)), playsByItself)
        XCTAssertEqual(line(upNext(.playsByItself), target: target(evidence: .timestampFallback, type: .text)), playsByItself,
                       "a text item has no copy length")
        XCTAssertEqual(line(upNext(.playsByItself), target: nil), playsByItself)
    }

    /// A tone, or a Margin that won't play by itself, tells the listener what to do: that line stays.
    func testALineThatSaysWhatToDoIsNeverReplaced() {
        let rough = target(evidence: .timestampFallback)
        for arrival in [PinnedMarginCard.Arrival.toneThenTap, .announcedUnheard, .onRequest, .waitsForYou] {
            let card = upNext(arrival)
            XCTAssertEqual(line(card, target: rough), card.detail, "\(arrival)")
        }
        let yours = PinnedMarginCard(subject: .yours, stage: .upNext(msRemaining: nil, arrival: .playsByItself))
        XCTAssertEqual(line(yours, target: rough), playsByItself, "your own Margin has no sender copy")
    }

    // MARK: A Margin moment (a review, J14 step 3) keeps its order

    func testAMomentCountingDownSaysTheNoteAndAPlayingOneKeepsItsStage() {
        let coming = PinnedMarginCard(subject: .friend("Ben"), stage: .comingUp(msRemaining: 20_000), run: .review)
        let rough = target(evidence: .timestampFallback)
        XCTAssertEqual(line(coming, moment: moment(), target: rough),
                       "Your copy is about 35 seconds shorter than Ben's, so Margins may be that far off.")
        let speaking = PinnedMarginCard(subject: .friend("Ben"), stage: .speaking, run: .review)
        XCTAssertEqual(line(speaking, moment: moment(playing: true), target: rough), speaking.detail)
        XCTAssertEqual(line(coming, moment: moment(caption: "Replying to you"), target: rough), "Replying to you")
        XCTAssertEqual(line(coming, moment: moment(approximate: true), target: nil), caution)
        XCTAssertEqual(line(coming, moment: moment(), target: nil), coming.detail)
        let placing = PinnedMarginCardDetail.Target(isPodcast: false, placementLine: nil, placingDescription: "Placing…")
        XCTAssertEqual(line(coming, moment: moment(), target: placing), "Placing…")
    }

    // MARK: Helpers

    private func line(_ card: PinnedMarginCard, moment: PinnedMarginCardDetail.Moment? = nil,
                      target: PinnedMarginCardDetail.Target?) -> String {
        PinnedMarginCardDetail.line(for: card, moment: moment, target: target)
    }

    private func upNext(_ arrival: PinnedMarginCard.Arrival) -> PinnedMarginCard {
        PinnedMarginCard(subject: .friend("Ben"), stage: .upNext(msRemaining: 3_000, arrival: arrival))
    }

    private func moment(playing: Bool = false, caption: String? = nil, approximate: Bool = false) -> PinnedMarginCardDetail.Moment {
        PinnedMarginCardDetail.Moment(isPlayingMargin: playing, caption: caption, isApproximate: approximate)
    }

    /// The target as the app builds it from a real prompt: the layer, the Margin and the plan `SharedMarginPrompts` gives.
    private func target(
        evidence: AnchorResolutionEvidenceClass, placedAt: Int? = nil, sender: Int? = 347_184, listener: Int? = 314_184,
        type: SharedItemType = .podcast
    ) -> PinnedMarginCardDetail.Target {
        var layer = ImportedCommentaryLayer(
            id: "layer", itemId: "item", packageDigest: "d", packageId: "p",
            itemIdentity: SharedItemIdentity(itemType: type, title: "HPR4736", durationMs: sender),
            displayLabel: "Ben", importedAt: Date(timeIntervalSince1970: 0), sourceResolutionStatus: .resolved, isEnabled: true)
        layer.resolvedRecipientEditionSHA256 = "digest"
        let margin = ImportedCommentaryInterjection(
            id: "ij-001", layerId: "layer", packageScopedId: "packet-ij-001", createdAt: Date(timeIntervalSince1970: 0),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 60_000),
            approvedTranscript: "Words",
            resolution: ImportedAnchorResolution(evidenceClass: evidence, localMediaTimeMs: placedAt))
        let copyMs = listener
        let prompt = ImportedCommentaryPrompt(layer: layer, interjection: margin, index: 0, count: 1, durationMs: copyMs)
        return PinnedMarginCardDetail.Target(
            interjection: margin, layer: layer, plan: prompt.plan, placingDescription: nil, listenerCopyMs: copyMs,
            subject: .friend("Ben"))
    }
}
