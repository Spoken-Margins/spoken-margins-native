import Foundation
@testable import SessionKit
import XCTest

/// A listener can report a received share link from the app (#2846, Apple agreement 10(v)).
final class ShareLinkReportTests: XCTestCase {
    private let id = "0123456789abcdef0123456789abcdef"

    func testTheReportPageIsTheSharePageOfThatLinkAndNothingMore() throws {
        let url = try XCTUnwrap(ShareLinkReport.pageURL(forLinkId: id))

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, BridgeManifestPolicy.production.trustedHost)
        XCTAssertEqual(url.path, "/l/\(id)")
        XCTAssertNil(url.fragment, "the key from the link never goes into the address")
        XCTAssertNil(url.query)
        XCTAssertNotNil(ShareLinkURL(url: url), "the page is a link the app itself recognises")
    }

    /// Every value that is not exactly a link id gets no address, so a damaged saved value can't send the
    /// listener elsewhere.
    func testOnlyARealLinkIdGetsAReportPage() {
        let notIds = [
            "", " ", String(id.dropLast()), id + "0", id.uppercased(), "0123456789abcdef0123456789abcdeg",
            "../evil", "\(id)/packet", "\(id)?x=1", "\(id)#key", " \(id)", "\(id)\n", "http://evil.example/\(id)",
            "ｆ123456789abcdef0123456789abcdef", // a full-width letter that looks like hex
            String(repeating: "a", count: 4_096),
        ]
        for text in notIds {
            XCTAssertNil(ShareLinkReport.pageURL(forLinkId: text), "\(text.prefix(40).debugDescription)")
        }
    }

    func testALinkOpenedFromTheOldHostReportsToTheCurrentOne() throws {
        let opened = try XCTUnwrap(URL(string: "https://spokenmargins.proximitytoprogress.com/l/\(id)#abc"))
        let link = try XCTUnwrap(ShareLinkURL(url: opened))

        let page = try XCTUnwrap(ShareLinkReport.pageURL(forLinkId: link.id))

        XCTAssertEqual(page.host, BridgeManifestPolicy.production.trustedHost)
        XCTAssertEqual(page.path, "/l/\(id)")
    }

    func testALayerRemembersItsLinkAndOldRowsDecodeWithoutOne() throws {
        let item = SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/a", title: "A")
        var layer = ImportedCommentaryLayer(
            id: "layer-1", packageDigest: "digest", packageId: "package", itemIdentity: item,
            importedAt: Date(timeIntervalSince1970: 1_777_000_000), shareLinkId: id
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let withLink = try encoder.encode(layer)
        XCTAssertEqual(try decoder.decode(ImportedCommentaryLayer.self, from: withLink).shareLinkId, id)

        layer.shareLinkId = nil
        let without = try encoder.encode(layer)
        XCTAssertFalse(String(decoding: without, as: UTF8.self).contains("shareLinkId"), "a layer from a file adds nothing to its row")
        XCTAssertNil(try decoder.decode(ImportedCommentaryLayer.self, from: without).shareLinkId)
    }

    // MARK: The item's ⋯ menu (#2239)

    private func layer(_ n: Int, link: String?, label: String? = "Ana", deleted: Bool = false) -> ImportedCommentaryLayer {
        let item = SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/a", title: "A")
        return ImportedCommentaryLayer(
            id: "layer-\(n)", packageDigest: "digest\(n)", packageId: "package\(n)", itemIdentity: item,
            displayLabel: label, importedAt: Date(timeIntervalSince1970: 1_777_000_000),
            deletedAt: deleted ? Date(timeIntervalSince1970: 1_777_000_100) : nil, shareLinkId: link
        )
    }

    private func linkId(_ n: Int) -> String { String(format: "%032x", n) }

    func testAnItemWithOneLinkOffersOneReportAndAnItemWithNoneOffersNothing() throws {
        XCTAssertEqual(ShareLinkReport.entries(for: []), [])
        XCTAssertEqual(ShareLinkReport.entries(for: [layer(1, link: nil)]), [], "Margins from a file have no page to report")

        let entries = ShareLinkReport.entries(for: [layer(1, link: id)])

        XCTAssertEqual(entries.map(\.title), ["Report this link"])
        XCTAssertEqual(entries.first?.url, ShareLinkReport.pageURL(forLinkId: id))
        XCTAssertEqual(entries.first?.id, id)
    }

    /// Neighbouring inputs: a file layer, a deleted layer, damaged ids and the same link kept by two layers.
    func testOnlyLiveLayersWithARealLinkOfferAReport() {
        let layers = [
            layer(1, link: nil),
            layer(2, link: linkId(2), deleted: true),
            layer(3, link: "not-a-link-id"),
            layer(4, link: linkId(0xabcd).uppercased()),
            layer(5, link: linkId(5) + "/packet"),
            layer(6, link: linkId(6)),
            layer(7, link: linkId(6), label: "Ben"), // a second layer kept the same link
        ]

        let entries = ShareLinkReport.entries(for: layers)

        XCTAssertEqual(entries.map(\.id), [linkId(6)], "one entry per link, and nothing for a layer that has no live link")
        XCTAssertEqual(entries.map(\.title), ["Report this link"])
    }

    func testSeveralLinksAreToldApartBySenderAndThenByNumber() {
        let layers = [
            layer(1, link: linkId(1), label: "Ana"),
            layer(2, link: linkId(2), label: "Ben"),
            layer(3, link: linkId(3), label: "  ana "),
            layer(4, link: linkId(4), label: nil),
            layer(5, link: linkId(5), label: SharedPacketArrival.unsignedSenderLabel),
        ]

        let titles = ShareLinkReport.entries(for: layers).map(\.title)

        XCTAssertEqual(titles, [
            "Report Ana\u{2019}s link", "Report Ben\u{2019}s link", "Report ana\u{2019}s link",
            "Report a link (1)", "Report a link (2)",
        ])
        XCTAssertFalse(titles.contains { $0.contains("Unsigned") }, "a stand-in label is never a name (#3247)")
    }

    func testTwoLinksFromOneFriendAreNumberedInOrder() {
        let titles = ShareLinkReport.entries(for: [layer(1, link: linkId(1)), layer(2, link: linkId(2))]).map(\.title)

        XCTAssertEqual(titles, ["Report Ana\u{2019}s link (1)", "Report Ana\u{2019}s link (2)"])
    }

    func testNoEntryAddressCarriesAKeyOrAnythingButTheLinkId() {
        for entry in ShareLinkReport.entries(for: [layer(1, link: id), layer(2, link: linkId(2))]) {
            XCTAssertNil(entry.url.fragment)
            XCTAssertNil(entry.url.query)
            XCTAssertEqual(entry.url.path, "/l/\(entry.id)")
        }
    }

    func testALaterLayerOfTheSameLinkCanNameTheSender() {
        let layers = [
            layer(1, link: linkId(1), label: nil), layer(2, link: linkId(1), label: "Ana"),
            layer(3, link: linkId(2), label: "Ben"),
        ]

        XCTAssertEqual(ShareLinkReport.entries(for: layers).map(\.title), ["Report Ana\u{2019}s link", "Report Ben\u{2019}s link"])
    }
}
