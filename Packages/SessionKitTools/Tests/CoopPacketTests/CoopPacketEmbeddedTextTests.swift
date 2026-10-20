import Foundation
import SessionKitSharing
@testable import CoopPacket
import XCTest

/// #1849: `coop-packet build` with `embeddedText` wrote a packet its own reader refused ("embedded item transport
/// is inconsistent"): it labelled the text `text/plain` where the reader requires the item's type, and left the
/// item's hashes as the plan gave them. These build real packets from real plans and read them back through the
/// production reader.
final class CoopPacketEmbeddedTextTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CoopPacketEmbeddedTextTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let article = "The harbour was quiet. Nobody had rung the bell since the storm.\nA second paragraph follows it."

    private func plan(itemType: String = "text", text: String, extraItem: String = "") throws -> URL {
        let quote = "Nobody had rung the bell"
        var margin: [String: Any] = ["id": "m-1", "text": "A note.", "spoken": false]
        margin["quote"] = quote
        let body: [String: Any] = [
            "sender": "synthetic test",
            "packageId": "package-embedded-\(UUID().uuidString.lowercased())",
            "createdAt": "2026-10-17T12:00:00Z",
            "item": try XCTUnwrap(JSONSerialization.jsonObject(with: Data(
                #"{"itemType":"\#(itemType)","title":"Harbour"\#(extraItem)}"#.utf8
            )) as? [String: Any]),
            "embeddedText": text,
            "margins": [margin]
        ]
        let url = root.appending(path: "plan-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: body).write(to: url)
        return url
    }

    private func buildAndRead(_ planURL: URL) async throws -> (built: PacketBuilder.Built, packet: VerifiedSpokenMarginsPackage) {
        let built = try await PacketBuilder.build(planURL: planURL, outDirectory: root)
        let packet = try SpokenMarginsPackageArchive.read(
            from: built.url, extractingAssetsTo: root.appending(path: "assets-\(UUID().uuidString)")
        )
        return (built, packet)
    }

    private func assertRoundTrips(_ text: String, itemType: String = "text", file: StaticString = #filePath, line: UInt = #line) async throws {
        let (built, packet) = try await buildAndRead(try plan(itemType: itemType, text: text))
        let embedded = try XCTUnwrap(packet.embeddedTextItems.first, file: file, line: line)
        XCTAssertEqual(packet.embeddedTextItems.count, 1, file: file, line: line)
        // Swift treats NFC and NFD spellings as equal, so compare the scalars themselves.
        XCTAssertEqual(Array(embedded.text.unicodeScalars), Array(text.unicodeScalars), file: file, line: line)
        XCTAssertEqual(embedded.originalMediaType, itemType, file: file, line: line)
        XCTAssertEqual(packet.manifest.itemTransport.kind, .embeddedText, file: file, line: line)
        XCTAssertEqual(packet.manifest.item.exactEditionSHA256, PortableArticleAnchorResolver.exactEditionSHA256(text), file: file, line: line)
        XCTAssertEqual(packet.manifest.item.normalizedContentSHA256, PortableArticleAnchorResolver.normalizedContentSHA256(text), file: file, line: line)
        XCTAssertEqual(packet.manifest.contentDigest, built.digest, file: file, line: line)
        XCTAssertEqual(built.marginCount, 1, file: file, line: line)
    }

    func testAnEmbeddedTextPacketIsReadBackWithItsItemTextAndDigest() async throws {
        try await assertRoundTrips(article)
    }

    func testEmbeddedTextRoundTripsForEveryItemTypeThatMayCarryIt() async throws {
        for itemType in ["text", "pdf", "epub", "other"] {
            try await assertRoundTrips(article, itemType: itemType)
        }
    }

    // The exact hash is over the text as written, so the two spellings of "é" are different editions.
    func testEmbeddedTextKeepsItsUnicodeSpellingAndHashesEachSpellingAsWritten() async throws {
        let composed = "Caf\u{00E9} by the harbour. Nobody had rung the bell."
        let decomposed = "Cafe\u{0301} by the harbour. Nobody had rung the bell."
        XCTAssertNotEqual(Array(composed.unicodeScalars), Array(decomposed.unicodeScalars))
        try await assertRoundTrips(composed)
        try await assertRoundTrips(decomposed)
        XCTAssertNotEqual(
            PortableArticleAnchorResolver.exactEditionSHA256(composed),
            PortableArticleAnchorResolver.exactEditionSHA256(decomposed)
        )
    }

    func testAVeryLongEmbeddedTextRoundTrips() async throws {
        // About 2 MB of words that don't repeat, so the packet stays under the reader's compression-ratio limit.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var words: [String] = ["Nobody", "had", "rung", "the", "bell"]
        while words.count < 170_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            words.append(String(state >> 20, radix: 36))
        }
        try await assertRoundTrips(words.joined(separator: " "))
    }

    func testTheItemsOwnHashesAreReplacedByTheTextsHashes() async throws {
        let stale = String(repeating: "0", count: 64)
        let url = try plan(text: article, extraItem: #","exactEditionSHA256":"\#(stale)","normalizedContentSHA256":"\#(stale)""#)
        let (_, packet) = try await buildAndRead(url)
        XCTAssertEqual(packet.manifest.item.exactEditionSHA256, PortableArticleAnchorResolver.exactEditionSHA256(article))
        XCTAssertEqual(packet.manifest.item.normalizedContentSHA256, PortableArticleAnchorResolver.normalizedContentSHA256(article))
    }

    func testEmbeddedTextThatCannotBeReadBackIsRefusedWithItsReason() async throws {
        let refused = [
            ("empty text", try plan(text: ""), "embeddedText has no words"),
            ("whitespace only", try plan(text: " \n\t "), "embeddedText has no words"),
            ("a podcast item", try plan(itemType: "podcast", text: article), "can't stand in for a podcast"),
            ("an item that keeps its link", try plan(text: article, extraItem: #","canonicalURL":"https://example.com/harbour""#), "no canonicalURL")
        ]
        for (name, planURL, expected) in refused {
            do {
                _ = try await PacketBuilder.build(planURL: planURL, outDirectory: root)
                XCTFail("\(name): the builder wrote a packet the reader would refuse")
            } catch let error as PacketBuilder.PlanError {
                XCTAssertTrue(error.description.contains(expected), "\(name): \(error.description)")
            }
        }
    }
}
