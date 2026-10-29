import Foundation
import XCTest
import SessionKit
import SessionKitPersistence
@testable import SessionKitSharing

/// #2506: the matcher compares the digests of an article's text, which the store keeps beside the item, so it no
/// longer reads and hashes every article to place one packet. The answer must not change.
final class SharedPacketTextDigestTests: XCTestCase {
    private static let url = "https://news.example.com/story"
    private static let original = "The story, as first saved. It runs two short paragraphs."
    private static let revised = "The story, as corrected later. It runs two short paragraphs, plus a note."
    private static let third = "The story, rewritten again. Nothing here matches either earlier copy."
    private var directories: [URL] = []

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        super.tearDown()
    }

    private func article(_ id: String, text: String?, added: TimeInterval?, url: String? = url) -> Item {
        Item(id: id, title: "A story", mediaType: "text", text: text, externalReference: url, status: "ready",
             createdAt: added.map { Date(timeIntervalSince1970: $0) })
    }

    private func podcast(_ id: String, guid: String) -> Item {
        var item = Item(id: id, title: "Episode", mediaType: "audio", text: nil, externalReference: nil, status: "ready",
                        media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/\(id).mp3"))
        item.episodeGUID = guid
        item.showTitle = "The Show"
        return item
    }

    private func packet(carrying text: String?, type: SharedItemType = .text, url: String? = url) -> SharedItemIdentity {
        SharedItemIdentity(
            itemType: type, canonicalURL: url, originalURL: url, title: "A story",
            normalizedContentSHA256: text.map(PortableArticleAnchorResolver.normalizedContentSHA256),
            exactEditionSHA256: text.map(PortableArticleAnchorResolver.exactEditionSHA256))
    }

    private func openStore(with items: [Item]) throws -> SQLiteSessionStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("digest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let store = try SQLiteSessionStore(path: directory.appendingPathComponent("library.sqlite").path)
        for item in items { try store.saveItem(item) }
        return store
    }

    /// The matcher's answer from the store's kept digests, with no item's text in hand.
    private func matchedWithoutText(_ packet: SharedItemIdentity, in store: SQLiteSessionStore) throws -> String? {
        let rows = try store.listItemsForMatching(
            format: PortableArticleAnchorResolver.itemTextDigestFormat,
            needsDigests: SharedItemIdentityBuilder.isMatchedByItsText,
            digests: PortableArticleAnchorResolver.itemTextDigests)
        XCTAssertTrue(rows.allSatisfy { $0.item.text == nil })
        let digests = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.textDigests.map { (row.item.id, $0) } })
        return SharedPacketItemMatcher.matchingItemId(for: packet, among: rows.map(\.item), textDigests: { digests[$0.id] })
    }

    func testTheDigestsAreTheTwoHashesAndTheirFormatNamesTheSystem() {
        // Known SHA-256 values: the format ("1-<system>") has to change if either of these ever does.
        let digests = PortableArticleAnchorResolver.itemTextDigests("Hello, World!")
        XCTAssertEqual(digests.exactEditionSHA256, "dffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f")
        XCTAssertEqual(digests.normalizedContentSHA256, "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
        XCTAssertEqual(digests.normalizedContentSHA256, PortableArticleAnchorResolver.normalizedContentSHA256("Hello, World!"))
        XCTAssertTrue(PortableArticleAnchorResolver.itemTextDigestFormat.hasPrefix("1-"))
    }

    func testMatchingByKeptDigestsGivesTheAnswerMatchingByTextGives() throws {
        let old = article("old", text: Self.original, added: 100)
        let new = article("new", text: Self.revised, added: 200)
        let elsewhere = article("elsewhere", text: Self.third, added: 300, url: "https://news.example.com/other")
        let bare = article("bare", text: nil, added: 50, url: nil)
        let spaced = article("spaced", text: Self.original.replacingOccurrences(of: ". ", with: ".  "), added: 10, url: nil)
        let episode = podcast("episode", guid: "guid-1")
        let items = [old, new, elsewhere, bare, spaced, episode]
        let store = try openStore(with: items)
        let packets = [
            packet(carrying: Self.original), packet(carrying: Self.revised), packet(carrying: Self.third),
            packet(carrying: nil), packet(carrying: Self.third, url: "https://other.example.com/x"),
            packet(carrying: "A text nobody has", url: nil),
            packet(carrying: Self.original, url: nil),
            packet(carrying: "", url: nil),
            SharedItemIdentity(itemType: .podcast, canonicalURL: nil, originalURL: nil, title: "Episode", showTitle: "The Show",
                               episodeGUID: "guid-1"),
        ]

        for packet in packets {
            let byText = SharedPacketItemMatcher.matchingItemId(for: packet, among: items)
            XCTAssertEqual(try matchedWithoutText(packet, in: store), byText, "\(packet.title) \(packet.exactEditionSHA256 ?? "no digest")")
            // And again, from the digests the first call kept.
            XCTAssertEqual(try matchedWithoutText(packet, in: store), byText)
        }
    }

    func testAnEpisodeIsNotHashedAndAnArticleIs() throws {
        let store = try openStore(with: [article("a", text: Self.original, added: 1), podcast("p", guid: "g")])
        let rows = try store.listItemsForMatching(
            format: "t", needsDigests: SharedItemIdentityBuilder.isMatchedByItsText,
            digests: PortableArticleAnchorResolver.itemTextDigests)

        XCTAssertEqual(rows.first { $0.item.id == "a" }?.textDigests, PortableArticleAnchorResolver.itemTextDigests(Self.original))
        XCTAssertNil(rows.first { $0.item.id == "p" }?.textDigests)
    }

    func testAnEditedArticleMatchesItsNewTextAndNotItsOld() throws {
        let item = article("a", text: Self.original, added: 1)
        let store = try openStore(with: [item])
        XCTAssertEqual(try matchedWithoutText(packet(carrying: Self.original, url: nil), in: store), "a")
        var edited = item
        edited.text = Self.revised
        try store.saveItem(edited)

        XCTAssertNil(try matchedWithoutText(packet(carrying: Self.original, url: nil), in: store))
        XCTAssertEqual(try matchedWithoutText(packet(carrying: Self.revised, url: nil), in: store), "a")
    }

    func testTheIdentityStepOfAMapPacketAgreesWithTheWholeMatcher() {
        let pdf = Item(id: "pdf", title: "A paper", mediaType: "pdf", text: Self.original, externalReference: "https://x.example.com/p.pdf", status: "ready")
        let article = article("art", text: Self.revised, added: 1, url: nil)
        let trashed = Item(id: "gone", title: "A paper", mediaType: "pdf", text: Self.third, externalReference: nil, status: "ready",
                           deletedAt: Date())
        let items = [pdf, article, trashed]
        let slim = items.map { item -> Item in var copy = item; copy.text = nil; return copy }
        let digests = Dictionary(uniqueKeysWithValues: items.map { ($0.id, PortableArticleAnchorResolver.itemTextDigests($0.text ?? "")) })

        for text in [Self.original, Self.revised, Self.third, "nothing"] {
            let packet = packet(carrying: text, type: .pdf, url: nil)
            XCTAssertEqual(
                ListeningMapPacketItemMatcher.identityMatch(packetItem: packet, among: slim, textDigests: { digests[$0.id] }),
                ListeningMapPacketItemMatcher.identityMatch(packetItem: packet, among: items), text)
        }
        XCTAssertEqual(ListeningMapPacketItemMatcher.identityMatch(packetItem: packet(carrying: Self.original, type: .pdf, url: nil),
                                                                  among: slim, textDigests: { digests[$0.id] }), "pdf")
        XCTAssertNil(ListeningMapPacketItemMatcher.identityMatch(packetItem: packet(carrying: Self.third, type: .pdf, url: nil),
                                                                among: slim, textDigests: { digests[$0.id] }), "a trashed document never matches")
    }
}
