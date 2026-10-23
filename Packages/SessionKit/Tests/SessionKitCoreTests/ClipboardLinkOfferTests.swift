import XCTest
@testable import SessionKit

/// #1379: the Library offers a copied link once per copy, and never decides from the clipboard's text.
final class ClipboardLinkOfferTests: XCTestCase {
    func testNothingIsOfferedBeforeTheFirstCheck() {
        XCTAssertFalse(ClipboardLinkOffer().isOffered)
    }

    func testACopiedLinkIsOffered() {
        var offer = ClipboardLinkOffer()
        offer.observe(changeCount: 7, holdsProbableLink: true)
        XCTAssertTrue(offer.isOffered)
    }

    func testAClipboardWithoutALinkIsNeverOffered() {
        var offer = ClipboardLinkOffer()
        offer.observe(changeCount: 7, holdsProbableLink: false)
        XCTAssertFalse(offer.isOffered)
    }

    func testDismissingHidesTheOfferForThatCopyAcrossForegroundChecks() {
        var offer = ClipboardLinkOffer()
        offer.observe(changeCount: 7, holdsProbableLink: true)
        offer.markHandled()
        XCTAssertFalse(offer.isOffered)
        // Returning to the app checks again; nothing was copied since.
        offer.observe(changeCount: 7, holdsProbableLink: true)
        XCTAssertFalse(offer.isOffered)
    }

    func testANewCopyIsOfferedAfterADismissal() {
        var offer = ClipboardLinkOffer()
        offer.observe(changeCount: 7, holdsProbableLink: true)
        offer.markHandled()
        offer.observe(changeCount: 8, holdsProbableLink: true)
        XCTAssertTrue(offer.isOffered)
    }

    func testCopyingTheSameLinkAgainIsANewCopy() {
        var offer = ClipboardLinkOffer()
        offer.observe(changeCount: 7, holdsProbableLink: true)
        offer.markHandled()
        offer.observe(changeCount: 8, holdsProbableLink: true)
        XCTAssertTrue(offer.isOffered, "a new copy bumps the change count even when the link is the same")
    }

    func testCopyingTextAfterALinkHidesTheOffer() {
        var offer = ClipboardLinkOffer()
        offer.observe(changeCount: 7, holdsProbableLink: true)
        offer.observe(changeCount: 8, holdsProbableLink: false)
        XCTAssertFalse(offer.isOffered)
    }

    func testAHandledCountSurvivesARelaunch() {
        var offer = ClipboardLinkOffer(handledChangeCount: 7)
        offer.observe(changeCount: 7, holdsProbableLink: true)
        XCTAssertFalse(offer.isOffered)
        offer.observe(changeCount: 9, holdsProbableLink: true)
        XCTAssertTrue(offer.isOffered)
    }

    func testMarkingHandledBeforeAnyCheckChangesNothing() {
        var offer = ClipboardLinkOffer()
        offer.markHandled()
        offer.observe(changeCount: 1, holdsProbableLink: true)
        XCTAssertTrue(offer.isOffered)
    }
}
