import XCTest
@testable import SessionKit

/// #3788, Design "Starting states": the friend's intro and both choices exist on the first read of a just-opened
/// packet, in every history the item can have. These guard existing types (`SharedMarginReview`, `FriendMarginsIntro`,
/// `ItemListeningChoices`), so a later change to them can't bring back the wait for placement.
final class FriendArrivalFirstReadTests: XCTestCase {
    
    /// A packet just opened on an episode that isn't downloaded gives the intro and both choices on the first read,
    /// whatever the listener's history with the item: first run, returning, finished, marked complete, 99%.
    func testTheIntroAndBothChoicesExistOnTheFirstReadInEveryStartingState() throws {
        let packet = SharedMarginReview.entries(
            layers: [layer(finishedPass: false)],
            records: ["layer": [margin(id: "web", sender: 134_000), margin(id: "none", sender: nil)]])
        let waiting = packet.map(\.waitingMargin)
        XCTAssertEqual(waiting.count, 2)
        for finished in [false, true] {
            for continuing in [false, true] {
                for preparing in [false, true] {
                    let state = "finished \(finished), continuing \(continuing), preparing \(preparing)"
                    let intro = try XCTUnwrap(FriendMarginsIntro(unheardFriendMargins: waiting), state)
                    XCTAssertEqual(intro.senderLine, "From Cole", state)
                    let choices = ItemListeningChoices(
                        unheardFriendMargins: waiting, hasFinishedSession: finished,
                        hasContinuationSession: continuing, isPreparingAudio: preparing)
                    XCTAssertEqual(choices.primaryTitle, "Play", state)
                    XCTAssertTrue(choices.secondaryTitle?.hasPrefix("Skip to Cole's Margins") == true, state)
                }
            }
        }
    }

    func testAMarginBehindTheListenersPlaceStillMakesTheIntro() throws {
        var unheard = margin(id: "behind", sender: 5_000)
        unheard.firstHeardAt = nil
        let entries = SharedMarginReview.entries(layers: [layer(finishedPass: true)], records: ["layer": [unheard]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(FriendMarginsIntro(unheardFriendMargins: entries.map(\.waitingMargin)))
        var heard = unheard
        heard.firstHeardAt = Date(timeIntervalSince1970: 1)
        XCTAssertTrue(SharedMarginReview.entries(layers: [layer(finishedPass: true)], records: ["layer": [heard]]).isEmpty)
    }

    func testAWrongEpisodeGivesNoIntroAndNoSkipMinutes() {
        var other = layer(finishedPass: false)
        other.sourceResolutionStatus = .wrongSource
        let entries = SharedMarginReview.entries(layers: [other], records: ["layer": [margin(id: "m", sender: 5_000)]])
        XCTAssertTrue(entries.isEmpty)
        XCTAssertNil(FriendMarginsIntro(unheardFriendMargins: entries.map(\.waitingMargin)))
        let choices = ItemListeningChoices(
            unheardFriendMargins: entries.map(\.waitingMargin), hasFinishedSession: false,
            hasContinuationSession: false, isPreparingAudio: false)
        XCTAssertNil(choices.secondaryTitle, "no Skip button, so no minutes")
    }

    // MARK: Helpers

    private func layer(finishedPass: Bool) -> ImportedCommentaryLayer {
        var value = ImportedCommentaryLayer(id: "layer", itemId: "item", packageDigest: "d", packageId: "p",
                                            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode"),
                                            displayLabel: "Cole", importedAt: Date(timeIntervalSince1970: 0),
                                            sourceResolutionStatus: .resolved, isEnabled: true)
        if finishedPass { value.resolvedRecipientEditionSHA256 = "digest" }
        return value
    }

    private func margin(id: String, sender: Int?) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: id, layerId: "layer", packageScopedId: "packet-\(id)", createdAt: Date(timeIntervalSince1970: 0),
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: sender),
            approvedTranscript: "Words",
            resolution: ImportedAnchorResolution(evidenceClass: .unresolved, localMediaTimeMs: nil, isAmbiguous: false))
    }
}
