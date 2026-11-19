import XCTest
@testable import SessionKit

/// #3782 step 2: the card on the first-launch sheet for a friend who installed from a link. When it shows, and what a
/// paste into it does, one row per case of the Design's tables.
final class FirstLaunchFriendLinkCardTests: XCTestCase {
    private let id = String(repeating: "ab12", count: 8)
    private var key: String { ShareLinkSealing.Key.random().fragment }
    private var host: String { ShareLinkURL.shareHosts[0] }

    private func layer(deleted: Bool = false, enabled: Bool = true) -> ImportedCommentaryLayer {
        var layer = ImportedCommentaryLayer(
            id: UUID().uuidString, itemId: "item", packageDigest: "digest", packageId: "package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, canonicalURL: "https://podcasts.example.com/e/1", title: "Episode"),
            importedAt: Date(timeIntervalSince1970: 1_700_000_000), deletedAt: deleted ? Date(timeIntervalSince1970: 1_700_000_100) : nil
        )
        layer.isEnabled = enabled
        return layer
    }

    // MARK: When the card shows

    func testItShowsOnTheFirstLaunchSheetWhileTheLibraryHoldsNoFriendsPacket() {
        XCTAssertTrue(FirstLaunchFriendLinkCard.isShown(isFirstRunOpening: true, libraryHoldsFriendPacket: false))
    }

    func testItNeverShowsOnALaterVisitToTheDrawer() {
        XCTAssertFalse(FirstLaunchFriendLinkCard.isShown(isFirstRunOpening: false, libraryHoldsFriendPacket: false))
    }

    func testItIsHiddenOnceAPacketHasBeenImported() {
        XCTAssertFalse(FirstLaunchFriendLinkCard.isShown(isFirstRunOpening: true, libraryHoldsFriendPacket: true))
    }

    func testAnyLiveLayerCountsWhateverItsStateAndASoleDeletedOneDoesNot() {
        XCTAssertFalse(FirstLaunchFriendLinkCard.libraryHoldsFriendPacket(layers: []))
        XCTAssertFalse(FirstLaunchFriendLinkCard.libraryHoldsFriendPacket(layers: [layer(deleted: true)]))
        XCTAssertTrue(FirstLaunchFriendLinkCard.libraryHoldsFriendPacket(layers: [layer()]))
        XCTAssertTrue(FirstLaunchFriendLinkCard.libraryHoldsFriendPacket(layers: [layer(enabled: false)]))
        XCTAssertTrue(FirstLaunchFriendLinkCard.libraryHoldsFriendPacket(layers: [layer(deleted: true), layer()]))
    }

    // MARK: What a paste does

    func testAShareLinkOpens() {
        let link = "https://\(host)/l/\(id)#\(key)"
        XCTAssertEqual(FirstLaunchFriendLinkCard.pasteResult(for: link), .open(URL(string: link)!))
    }

    func testALinkInsideTheWholeMessageAndACutShortLinkStillOpen() {
        let link = "https://\(host)/l/\(id)#\(key)"
        XCTAssertEqual(FirstLaunchFriendLinkCard.pasteResult(for: "Sam sent you Margins: \(link) Hear them!"), .open(URL(string: link)!))
        let cut = "https://\(host)/l/\(id.prefix(12))"
        XCTAssertEqual(FirstLaunchFriendLinkCard.pasteResult(for: cut), .open(URL(string: cut)!)) // the failure sheet says it is cut off
    }

    func testTheJoinPageAnArticleAndEmptyTextGetTheLineAndOpenNothing() {
        let line = FirstLaunchFriendLinkCard.notAFriendLinkLine
        for pasted: String? in ["https://spokenmargins.com/join", "https://example.com/an-article", "just some words", "", nil] {
            XCTAssertEqual(FirstLaunchFriendLinkCard.pasteResult(for: pasted), .notAFriendLink(line), String(describing: pasted))
        }
    }

    func testTheDesignsWords() {
        XCTAssertEqual(FirstLaunchFriendLinkCard.headline, "Got a link from a friend?")
        XCTAssertEqual(FirstLaunchFriendLinkCard.line, "Tap it again in your message. It opens here now. Or copy it and paste it here.")
        XCTAssertEqual(FirstLaunchFriendLinkCard.notAFriendLinkLine,
                       "This isn't a link to a friend's Margins. Copy the whole link from the message and try again.")
    }
}
