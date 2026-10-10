import Foundation
@testable import SessionKit
import SessionKitSharing
import XCTest

/// A packet's Margin carries the sender's words before and after the quote (PKT-07 of the #1039 audit).
/// `PortableAnchorEvidence.bounded` is unit-tested, and placement is tested with hand-built anchors, but nothing
/// built a packet from a revision and read the context back out, so swapping or dropping it was invisible.
final class PacketAnchorContextTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_777_000_000)
    private let quote = "The durable idea that prompted this note."
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PacketAnchorContextTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var item: SharedItemIdentity {
        SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article")
    }

    private func revision(
        _ id: String, transcript: String, cleanedAudioPath: String? = nil, cleanedAudioDurationMs: Int? = nil,
        before: String = "Before this passage.", after: String = "After this passage."
    ) -> InterjectionShareRevision {
        InterjectionShareRevision(
            id: "revision-\(id)", interjectionId: "private-\(id)", itemId: "private-item", sessionId: "private-session",
            createdAt: created, approvedTranscript: transcript, cleanedAudioPath: cleanedAudioPath,
            cleanedAudioDurationMs: cleanedAudioDurationMs, anchorBefore: before, anchorAfter: after,
            status: .senderApproved
        )
    }

    private func packet(from prepared: PreparedSpokenMarginsPackage, name: String) throws -> VerifiedSpokenMarginsPackage {
        let url = root.appendingPathComponent("\(name).spokenmargins")
        try exportPacket(prepared, to: url)
        return try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("\(name)-assets"))
    }

    // MARK: PKT-07: the sender's words before and after travel with the Margin

    private let repeatedText = "Alpha opening line. The durable idea that prompted this note. Alpha closing line. "
        + "Beta opening line. The durable idea that prompted this note. Beta closing line."

    func testTheSendersWordsBeforeAndAfterTheQuoteArriveInTheOrderTheyWereSent() throws {
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-context", createdAt: created, item: item, itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001",
                revision: revision("context", transcript: "A thought.", before: "Beta opening line.", after: "Beta closing line."),
                anchor: .init(anchorType: .text, exactText: quote), representation: .textOnly
            )]
        )
        let record = try XCTUnwrap(try packet(from: prepared, name: "context").commentaryLayers.flatMap(\.interjections).first)
        XCTAssertEqual(record.anchor.prefix, "Beta opening line.", "the words before the quote")
        XCTAssertEqual(record.anchor.suffix, "Beta closing line.", "the words after the quote")
        XCTAssertEqual(record.anchor.exactText, quote)
    }

    func testAMarginWithNoSurroundingWordsSendsNoContextInsteadOfEmptyStrings() throws {
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-bare", createdAt: created, item: item, itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001", revision: revision("bare", transcript: "A thought.", before: "", after: "  \n "),
                anchor: .init(anchorType: .text, exactText: quote), representation: .textOnly
            )]
        )
        let record = try XCTUnwrap(try packet(from: prepared, name: "bare").commentaryLayers.flatMap(\.interjections).first)
        XCTAssertNil(record.anchor.prefix)
        XCTAssertNil(record.anchor.suffix)
    }

    func testARecipientWhoHasTheQuoteTwiceIsPlacedAtTheOccurrenceTheSenderMeant() throws {
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-pick", createdAt: created, item: item, itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001",
                revision: revision("pick", transcript: "A thought.", before: "Beta opening line.", after: "Beta closing line."),
                anchor: .init(anchorType: .text, exactText: quote), representation: .textOnly
            )]
        )
        let verified = try packet(from: prepared, name: "pick")
        let resolved = ImportedItemResolver.resolve(
            item: verified.manifest.item,
            interjections: verified.commentaryLayers.flatMap(\.interjections),
            against: item,
            itemText: repeatedText
        )
        XCTAssertEqual(resolved.status, .resolved)
        let secondCopy = "Alpha opening line. \(quote) Alpha closing line. Beta opening line. ".count
        XCTAssertEqual(resolved.anchorsByPackageScopedId["margin-001"]?.localStartChar, secondCopy,
                       "the sender's own words picked the second copy, not the first")
    }
}
