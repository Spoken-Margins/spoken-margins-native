import Foundation
import XCTest
import SessionKit
@testable import SessionKitSharing

/// A re-added article keeps its older copy, so one work can sit in the Library as several editions (#1257).
final class SharedPacketEditionMatchTests: XCTestCase {
    private static let url = "https://news.example.com/story"
    private static let original = "The story, as first saved. It runs two short paragraphs."
    private static let revised = "The story, as corrected later. It runs two short paragraphs, plus a note."
    private static let third = "The story, rewritten again. Nothing here matches either earlier copy."

    private func article(_ id: String, text: String, added: TimeInterval?, url: String? = url, mediaType: String = "text") -> Item {
        Item(id: id, title: "A story", mediaType: mediaType, text: text, externalReference: url, status: "ready",
             createdAt: added.map { Date(timeIntervalSince1970: $0) })
    }

    private func packet(
        carrying text: String?, type: SharedItemType = .text, url: String? = url
    ) -> SharedItemIdentity {
        SharedItemIdentity(
            itemType: type, canonicalURL: url, originalURL: url, title: "A story",
            normalizedContentSHA256: text.map(PortableArticleAnchorResolver.normalizedContentSHA256),
            exactEditionSHA256: text.map(PortableArticleAnchorResolver.exactEditionSHA256)
        )
    }

    private func match(_ packet: SharedItemIdentity, _ items: [Item]) -> String? {
        SharedPacketItemMatcher.matchingItemId(for: packet, among: items)
    }

    func testThePacketsExactEditionWinsOverTheNewerCopyAtTheSameAddress() {
        let old = article("old", text: Self.original, added: 100)
        let new = article("new", text: Self.revised, added: 200)
        XCTAssertEqual(match(packet(carrying: Self.original), [old, new]), "old")
        XCTAssertEqual(match(packet(carrying: Self.original), [new, old]), "old", "whatever order the Library lists them")
        XCTAssertEqual(match(packet(carrying: Self.revised), [old, new]), "new")
    }

    func testAPacketForNeitherEditionLandsOnTheMostRecentlyAddedCopyInsteadOfFetchingAThird() {
        let old = article("old", text: Self.original, added: 100)
        let new = article("new", text: Self.revised, added: 200)
        XCTAssertEqual(match(packet(carrying: Self.third), [old, new]), "new")
        XCTAssertEqual(match(packet(carrying: Self.third), [new, old]), "new")
        XCTAssertEqual(match(packet(carrying: nil), [old, new]), "new", "a packet with no digests, only the address")
    }

    func testSameTextWithDifferentWhitespaceCountsAsTheSameEditionBeforeTheAddressDoes() {
        let spaced = article("spaced", text: Self.original.replacingOccurrences(of: ". ", with: ".  "), added: 100)
        let other = article("other", text: Self.revised, added: 200)
        XCTAssertEqual(match(packet(carrying: Self.original), [spaced, other]), "spaced")
    }

    func testTwoCopiesOfTheSameTextTieOnTheNewerOneEveryTime() {
        let first = article("a", text: Self.original, added: 100)
        let second = article("b", text: Self.original, added: 100)
        let undated = article("c", text: Self.original, added: nil)
        XCTAssertEqual(match(packet(carrying: Self.original), [first, second]), "b")
        XCTAssertEqual(match(packet(carrying: Self.original), [second, first]), "b")
        XCTAssertEqual(match(packet(carrying: Self.original), [undated, first]), "a", "an undated copy is the oldest")
    }

    func testOtherAddressesAndOtherKindsOfItemAreStillNotThisWork() {
        let old = article("old", text: Self.original, added: 100)
        let new = article("new", text: Self.revised, added: 200)
        let elsewhere = article("elsewhere", text: Self.third, added: 300, url: "https://news.example.com/other")
        XCTAssertEqual(match(packet(carrying: Self.third), [old, new, elsewhere]), "elsewhere", "its own exact copy")
        XCTAssertNil(match(packet(carrying: Self.third, url: "https://other.example.com/x"), [old, new]))
        XCTAssertNil(match(packet(carrying: Self.original), []))
    }

    func testTheSameAddressHeldAsAPodcastOrAudioFileStaysAmbiguous() {
        let first = article("one", text: Self.original, added: 100)
        let second = article("two", text: Self.revised, added: 200)
        // Only an article, PDF or EPUB packet picks between copies; a podcast packet with two candidates still reports none.
        let podcast = SharedItemIdentity(itemType: .podcast, canonicalURL: Self.url, originalURL: Self.url, title: "A story")
        XCTAssertNil(match(podcast, [first, second]))
    }

    func testAPDFPacketPicksTheExactEditionToo() {
        let old = article("old", text: Self.original, added: 100, mediaType: "pdf")
        let new = article("new", text: Self.revised, added: 200, mediaType: "pdf")
        XCTAssertEqual(match(packet(carrying: Self.original, type: .pdf), [old, new]), "old")
        XCTAssertEqual(match(packet(carrying: Self.third, type: .pdf), [old, new]), "new")
    }
}
