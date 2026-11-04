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
}
