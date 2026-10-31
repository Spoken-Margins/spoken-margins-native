import Foundation
import XCTest
import SessionKit
@testable import SessionKitSharing

/// #2506: the Share sheet reads an item summary, not the article, so the type a packet carries for it must be the one
/// the whole item gives.
final class SharedItemTypeSummaryTests: XCTestCase {
    func testASummaryGivesTheSameItemTypeAsTheWholeItem() {
        let streams = ItemMedia(sourceType: .remoteStream, url: "https://x.example/a.mp3")
        let file = ItemMedia(sourceType: .nativeMediaFile, url: "file:///a.m4a")
        let narration = ItemMedia(sourceType: .generatedTTSPrerendered, url: "file:///n.caf")
        func item(_ id: String, _ mediaType: String, text: String?, reference: String? = nil, media: ItemMedia? = nil) -> Item {
            Item(id: id, title: id, mediaType: mediaType, text: text, externalReference: reference, status: "ready", media: media)
        }
        let cases: [(String, Item)] = [
            ("an article", item("a", "text", text: "Words.", reference: "https://example.com/a")),
            ("an article with narration", item("b", "text", text: "Words.", media: narration)),
            ("a pdf", item("c", "text", text: "Words.", reference: "/files/Paper.PDF")),
            ("an epub", item("d", "text", text: "Words.", reference: "/files/book.epub")),
            ("a streamed episode", item("e", "podcast", text: nil, media: streams)),
            ("an imported recording", item("f", "podcast", text: nil, media: file)),
            ("an audiobook", item("g", "audiobook", text: nil, media: file)),
            ("no text, no address", item("h", "text", text: " \n"))
        ]
        for (name, item) in cases {
            let summary = LibraryItemSummary(item)
            XCTAssertEqual(SharedPacketItemMatcher.itemType(for: summary), SharedPacketItemMatcher.itemType(for: item), name)
            XCTAssertEqual(SharedItemIdentityBuilder.itemType(for: summary), SharedItemIdentityBuilder.itemType(for: item), name)
        }
    }
}
