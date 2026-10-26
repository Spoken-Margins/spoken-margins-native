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

    // MARK: Likely-link signals (#2697)

    private func signals(url: Bool = true, hasURLs: Bool = true, strings: Bool = true, items: Int = 1) -> ClipboardLinkOffer.Signals {
        .init(probableWebURL: url, hasURLs: hasURLs, hasStrings: strings, itemCount: items)
    }

    func testSignalTable() {
        XCTAssertTrue(signals().looksLikeLink, "a copied URL item")
        XCTAssertTrue(signals(hasURLs: false).looksLikeLink, "a string such as 'Title https://...' from a share sheet")
        XCTAssertFalse(signals(url: false).looksLikeLink, "no probable web link")
        XCTAssertFalse(signals(items: 2).looksLikeLink, "several items")
        XCTAssertFalse(signals(items: 0).looksLikeLink, "empty clipboard")
        XCTAssertFalse(signals(hasURLs: false, strings: false).looksLikeLink, "an image or file")
    }

    func testTypeSignalTable() {
        func link(_ types: [String], strings: Bool = true) -> Bool {
            ClipboardLinkOffer.Signals(probableWebURL: true, hasURLs: types.contains("public.url"), hasStrings: strings,
                                       itemCount: 1, types: types).looksLikeLink
        }
        XCTAssertFalse(link(["public.utf8-plain-text", "public.html"]), "a long web selection")
        XCTAssertFalse(link(["public.utf8-plain-text", "public.rtf"]), "a Notes or Pages selection")
        XCTAssertFalse(link(["public.utf8-plain-text", "com.apple.webarchive"]))
        XCTAssertFalse(link(["public.utf8-plain-text", "com.apple.flat-rtfd"]))
        XCTAssertTrue(link(["public.url", "public.utf8-plain-text"]), "an address-bar copy")
        XCTAssertTrue(link(["public.url", "public.html", "public.utf8-plain-text"]), "a copied link that also carries HTML")
        XCTAssertTrue(link(["public.utf8-plain-text"]), "a plain 'Title https://...' string")
        XCTAssertTrue(link(["public.url"], strings: false))
    }

    func testObserveUsesTheSignals() {
        var offer = ClipboardLinkOffer()
        offer.observe(changeCount: 3, signals: signals(items: 2))
        XCTAssertFalse(offer.isOffered)
        offer.observe(changeCount: 4, signals: signals())
        XCTAssertTrue(offer.isOffered)
    }

    func testPasteOutcomeTable() {
        let article = String(repeating: "A sentence about things. ", count: 200) + "Read more at https://example.com/post today."
        let cases: [(String?, ClipboardLinkOffer.PasteOutcome)] = [
            ("https://example.com/post", .addLink),
            ("  https://example.com/post\n", .addLink),
            ("Episode title https://example.com/ep/1", .addLink),
            ("example.com/post", .addLink),
            (article, .notALink),
            ("a few words with no link", .notALink),
            ("https://a.com/x and https://b.com/y", .notALink),
            ("", .notALink),
            (nil, .notALink),
            (String(repeating: "x", count: 100_000), .notALink),
            ("mailto:me@example.com", .notALink),
            ("ftp://example.com/file", .notALink),
        ]
        for (content, expected) in cases {
            XCTAssertEqual(ClipboardLinkOffer.pasteOutcome(for: content), expected, "\(String(describing: content?.prefix(40)))")
        }
    }

    // MARK: Auto-dismiss (#2696)

    func testTimeoutsArePinned() {
        XCTAssertEqual(ClipboardLinkOffer.autoDismissDelay, 6)
        XCTAssertEqual(ClipboardLinkOffer.autoDismissDelay(voiceOverRunning: false), 6)
        XCTAssertEqual(ClipboardLinkOffer.autoDismissDelay(voiceOverRunning: true), 15)
    }

    func testNeverAutoDismissesWhileBusyOrShowingAnError() {
        XCTAssertTrue(ClipboardLinkOffer.mayAutoDismiss(isAdding: false, isResolvingSourceLink: false, showsError: false))
        XCTAssertFalse(ClipboardLinkOffer.mayAutoDismiss(isAdding: true, isResolvingSourceLink: false, showsError: false))
        XCTAssertFalse(ClipboardLinkOffer.mayAutoDismiss(isAdding: false, isResolvingSourceLink: true, showsError: false))
        XCTAssertFalse(ClipboardLinkOffer.mayAutoDismiss(isAdding: false, isResolvingSourceLink: false, showsError: true))
    }
}
