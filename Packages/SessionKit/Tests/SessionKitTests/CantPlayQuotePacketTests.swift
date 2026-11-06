import Foundation
@testable import SessionKit
@testable import SessionKitAudio
import SessionKitSharing
import XCTest

/// #3392: the words the voice reads when a friend's episode can't play are the words the packet already carries. A podcast
/// Margin has no quote of its own; the words just before the moment travel as `prefix`. If a packet stopped carrying them,
/// the can't-play listening would fall to its place line for every Margin without anything failing, so this builds a
/// packet, reads it back as a recipient and plans the listening from it.
final class CantPlayQuotePacketTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_777_000_000)
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CantPlayQuotePacketTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func record(before: String) throws -> PortableAnchorEvidence {
        let item = SharedItemIdentity(itemType: .podcast, title: "A Useful Episode", durationMs: 3_600_000)
        let revision = InterjectionShareRevision(
            id: "revision", interjectionId: "private", itemId: "private-item", sessionId: "private-session",
            createdAt: created, approvedTranscript: "A thought.", cleanedAudioPath: nil, cleanedAudioDurationMs: nil,
            anchorBefore: before, anchorAfter: "", status: .senderApproved
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-cant-play", createdAt: created, item: item, itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001", revision: revision,
                anchor: .init(anchorType: .media, mediaTimeMs: 720_000), representation: .textOnly
            )]
        )
        let url = root.appendingPathComponent("packet.spokenmargins")
        try exportPacket(prepared, to: url)
        let packet = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("assets"))
        return try XCTUnwrap(packet.commentaryLayers.flatMap(\.interjections).first).anchor
    }

    func testThePodcastMarginsWordsBeforeTheMomentTravelAsTheQuoteTheVoiceReads() throws {
        let anchor = try record(before: "and that is why the harbour matters")
        XCTAssertEqual(anchor.prefix, "and that is why the harbour matters")
        XCTAssertNil(anchor.exactText, "a podcast Margin has no quote of its own: the words before it are the quote")
        let words = CantPlayListening.readableQuote(of: anchor, voiceFor: { $0 }, defaultVoice: { "default" })
        XCTAssertEqual(words, "and that is why the harbour matters")
    }

    func testAPodcastMarginSentWithNoWordsBeforeItFallsToItsPlaceNotToSilence() throws {
        let anchor = try record(before: "")
        XCTAssertNil(anchor.prefix)
        XCTAssertNil(CantPlayListening.readableQuote(of: anchor, voiceFor: { $0 }, defaultVoice: { "default" }))
    }
}
