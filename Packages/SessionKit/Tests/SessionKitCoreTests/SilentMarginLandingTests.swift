import XCTest
@testable import SessionKit

/// #4934: how long the card for a Margin the listener went to stays, and where the next Skim press starts from.
final class SilentMarginLandingTests: XCTestCase {
    private func landing(
        at position: Int, unit: SkimStops.PositionUnit = .milliseconds, words: String? = "A thought.",
        isApproximate: Bool = false
    ) -> SilentMarginLanding {
        SilentMarginLanding(
            itemId: "item-1", marginId: "s", subject: .friend("Sam"), words: words, isApproximate: isApproximate,
            position: position, unit: unit)
    }

    func testTheWindowRunsFromTwoSecondsBeforeToThirtySecondsAfterInMilliseconds() {
        let place = landing(at: 300_000)
        XCTAssertFalse(place.isShowing(playhead: 297_999))
        XCTAssertTrue(place.isShowing(playhead: 298_000), "the seek can land 2 s short")
        XCTAssertTrue(place.isShowing(playhead: 300_000))
        XCTAssertTrue(place.isShowing(playhead: 330_000))
        XCTAssertFalse(place.isShowing(playhead: 330_001))
    }

    func testTheWindowForTextUsesTheUnitsOwnRateWithNoClamp() {
        let place = landing(at: 1_000, unit: .characters(perSecond: 10))
        XCTAssertFalse(place.isShowing(playhead: 979))
        XCTAssertTrue(place.isShowing(playhead: 980), "2 s at 10 characters a second is 20 characters")
        XCTAssertTrue(place.isShowing(playhead: 1_300), "30 s is 300 characters")
        XCTAssertFalse(place.isShowing(playhead: 1_301))
        // A lead-in's 30 s floor would have stretched the 2 s slack to 300 characters.
        XCTAssertFalse(landing(at: 1_000, unit: .characters(perSecond: 10)).isShowing(playhead: 900))
    }

    func testTheWindowNearTheStartDoesNotGoNegative() {
        let place = landing(at: 500)
        XCTAssertTrue(place.isShowing(playhead: 0))
        XCTAssertEqual(landing(at: -5).position, 0)
    }

    func testAPressInsideTheWindowNeverReturnsTheLandingsOwnStopAndOutsideItMay() {
        let stops = SkimStops(chapters: [chapter("c0", 0), chapter("c1", 600_000)], margins: [silent("s", 300_000)])
        let place = landing(at: 300_000)
        XCTAssertEqual(place.skimTarget(direction: .backward, playhead: 305_000, in: stops)?.stop.id, "c0")
        XCTAssertEqual(place.skimTarget(direction: .backward, playhead: 299_000, in: stops)?.stop.id, "c0", "short of the place")
        XCTAssertEqual(place.skimTarget(direction: .forward, playhead: 299_000, in: stops)?.stop.id, "c1")
        XCTAssertEqual(place.skimTarget(direction: .forward, playhead: 305_000, in: stops)?.stop.id, "c1")
        XCTAssertEqual(place.skimTarget(direction: .backward, playhead: 340_000, in: stops)?.stop.id, "s", "outside the window")
        XCTAssertEqual(place.skimTarget(direction: .forward, playhead: 200_000, in: stops)?.stop.id, "s")
    }

    func testTheWindowEdgesAgreeWithThePressInText() {
        let unit = SkimStops.PositionUnit.characters(perSecond: 10)
        let stops = SkimStops(chapters: [chapter("c0", 0), chapter("c1", 5_000)], margins: [silent("s", 1_000)], unit: unit)
        let place = landing(at: 1_000, unit: unit)
        XCTAssertEqual(place.skimTarget(direction: .forward, playhead: 985, in: stops)?.stop.id, "c1")
        XCTAssertEqual(place.skimTarget(direction: .forward, playhead: 970, in: stops)?.stop.id, "s", "before the window")
        XCTAssertEqual(place.skimTarget(direction: .backward, playhead: 1_300, in: stops)?.stop.id, "c0")
        XCTAssertEqual(place.skimTarget(direction: .backward, playhead: 1_400, in: stops)?.stop.id, "s", "past the window")
    }

    func testTheLandingsOwnIdMatchesOnlyItsOwnStop() {
        // Another silent stop at the same distance is a different stop: it is still the answer.
        let stops = SkimStops(chapters: [], margins: [silent("other", 250_000), silent("s", 300_000)])
        XCTAssertEqual(landing(at: 300_000).skimTarget(direction: .backward, playhead: 301_000, in: stops)?.stop.id, "other")
    }

    private func chapter(_ id: String, _ position: Int) -> SkimStop { SkimStop(kind: .chapter, id: id, position: position) }
    private func silent(_ id: String, _ position: Int) -> SkimStop { SkimStop(kind: .margin, id: id, position: position, isSilent: true) }

    func testTheCardIsTheSilentHereStageForTheLandingsSubject() {
        let card = landing(at: 5_000, words: "Look at this.", isApproximate: true).card(noun: .episode)
        XCTAssertEqual(card.stage, .silentHere(words: "Look at this.", isApproximate: true))
        XCTAssertEqual(card.headline, "Margin from Sam is about here")
        XCTAssertEqual(card.detail, "Look at this.")
    }

    // MARK: A landing made from the Skim stop (#4934)

    private func friend(id: String = "s", mediaMs: Int? = 300_000, char: Int? = nil) -> ImportedCommentaryInterjection {
        let resolution = mediaMs.map { ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: $0, confidence: 1) }
            ?? ImportedAnchorResolution(evidenceClass: .articleTextVerified, localStartChar: char, localEndChar: char.map { $0 + 10 })
        return ImportedCommentaryInterjection(
            id: id, layerId: "layer-1", packageScopedId: "pkg::\(id)", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            anchorEvidence: PortableAnchorEvidence(anchorType: mediaMs == nil ? .text : .media, mediaTimeMs: mediaMs),
            approvedTranscript: "  Look at this.  ", resolution: resolution, senderReadAloud: false)
    }

    private let layer = ImportedCommentaryLayer(
        id: "layer-1", itemId: "item-1", packageDigest: "d", packageId: "p",
        itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"), displayLabel: "Sam",
        importedAt: Date(timeIntervalSince1970: 1_790_000_000), sourceResolutionStatus: .resolved)

    func testALandingFromAStopKeepsTheStopsOwnPlaceAndUnit() throws {
        let margin = friend()
        let stop = try XCTUnwrap(SkimStop.silentMargin(margin, unit: .milliseconds))
        let made = try XCTUnwrap(SilentMarginLanding(skipping: stop, margin: margin, in: layer, itemId: "item-1", unit: .milliseconds))
        XCTAssertEqual(made.position, stop.position)
        XCTAssertEqual(made.unit, .milliseconds)
        XCTAssertEqual(made.marginId, "s")
        XCTAssertEqual(made.words, "Look at this.", "the words are trimmed")
        XCTAssertFalse(made.isApproximate)
        let text = SkimStops.PositionUnit.characters(perSecond: 15)
        let passage = friend(id: "p", mediaMs: nil, char: 1_200)
        let textStop = try XCTUnwrap(SkimStop.silentMargin(passage, unit: text))
        let fromText = try XCTUnwrap(SilentMarginLanding(skipping: textStop, margin: passage, in: layer, itemId: "item-1", unit: text))
        XCTAssertEqual(fromText.position, 1_200)
        XCTAssertEqual(fromText.unit, text)
        XCTAssertFalse(fromText.isApproximate)
    }

    func testALandingFromAStopNeedsASilentMarginStopOfThatMargin() throws {
        let margin = friend()
        let silentStop = try XCTUnwrap(SkimStop.silentMargin(margin, unit: .milliseconds))
        XCTAssertNil(SilentMarginLanding(skipping: SkimStop(kind: .margin, id: "s", position: 300_000), margin: margin, in: layer, itemId: "item-1", unit: .milliseconds),
                     "a voiced stop is not a landing")
        XCTAssertNil(SilentMarginLanding(skipping: SkimStop(kind: .chapter, id: "s", position: 300_000, isSilent: true), margin: margin, in: layer, itemId: "item-1", unit: .milliseconds),
                     "a chapter is not a Margin")
        XCTAssertNil(SilentMarginLanding(skipping: silentStop, margin: friend(id: "other"), in: layer, itemId: "item-1", unit: .milliseconds),
                     "another Margin's stop")
    }

    func testAnApproximatePlaceSaysSoOnTheCard() throws {
        let rough = ImportedCommentaryInterjection(
            id: "r", layerId: "layer-1", packageScopedId: "pkg::r", createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: 90_000), approvedTranscript: "Hm.",
            resolution: .init(evidenceClass: .unresolved), senderReadAloud: false)
        let stop = try XCTUnwrap(SkimStop.silentMargin(rough, unit: .milliseconds))
        let made = try XCTUnwrap(SilentMarginLanding(skipping: stop, margin: rough, in: layer, itemId: "item-1", unit: .milliseconds))
        XCTAssertTrue(made.isApproximate)
        XCTAssertEqual(made.card(noun: .episode).headline, "Margin from Sam is about here")
    }
}
