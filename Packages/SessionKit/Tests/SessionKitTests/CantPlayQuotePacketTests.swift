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

    /// A podcast that never downloaded: its Margins import with no placement, so `entries` (which needs one) offers
    /// none, and the listener would get the plain failure. The can't-play entries use the sender's time.
    private func importedUnplaced() throws -> (layers: [ImportedCommentaryLayer], records: [String: [ImportedCommentaryInterjection]]) {
        let item = SharedItemIdentity(itemType: .podcast, title: "A Useful Episode", durationMs: 3_600_000)
        let revision = InterjectionShareRevision(
            id: "revision", interjectionId: "private", itemId: "private-item", sessionId: "private-session",
            createdAt: created, approvedTranscript: "A thought.", cleanedAudioPath: nil, cleanedAudioDurationMs: nil,
            anchorBefore: "and that is why the harbour matters", anchorAfter: "", status: .senderApproved
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-unplaced", createdAt: created, item: item, itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001", revision: revision,
                anchor: .init(anchorType: .media, mediaTimeMs: 720_000), representation: .textOnly
            )]
        )
        let url = root.appendingPathComponent("unplaced.spokenmargins")
        try exportPacket(prepared, to: url)
        let verified = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("unplaced-assets"))
        let repository = InMemorySessionRepository()
        _ = try SpokenMarginsPackageImporter.importPackage(
            verified, itemId: "recipient-item", importedAt: created, repository: repository,
            makeLocalID: { kind, packageID in "recipient-\(kind)-\(packageID)" }
        )
        let layers = try repository.loadImportedCommentaryLayers(itemId: "recipient-item")
        var records: [String: [ImportedCommentaryInterjection]] = [:]
        for layer in layers { records[layer.id] = try repository.loadImportedCommentaryInterjections(layerId: layer.id) }
        return (layers, records)
    }

    func testAnEpisodeNeverDownloadedStillOffersItsMarginsAtTheSendersTime() throws {
        let (layers, records) = try importedUnplaced()
        // #4097: the ordinary entries no longer need a placement either. While the layer awaits its pass they read the
        // sender's time, as the prompts do, so a just-imported packet offers its Margins before the pass has run.
        XCTAssertEqual(SharedMarginReview.entries(layers: layers, records: records).map(\.mediaTimeMs), [720_000])
        let entries = SharedMarginReview.entriesWithoutEpisode(layers: layers, records: records, asking: false)
        XCTAssertEqual(entries.map(\.mediaTimeMs), [720_000])
        XCTAssertTrue(entries.allSatisfy(\.isApproximate), "the sender's time, not a placement")
        let beats = CantPlayListening.plan(entries: entries, episodeTitle: "A Useful Episode")
        XCTAssertEqual(beats.first?.context, .quote("and that is why the harbour matters"))
    }

    func testAMarginSetNotToPlayByItselfIsHeardOnlyWhenTheListenerAsks() throws {
        var (layers, records) = try importedUnplaced()
        XCTAssertEqual(layers.first?.revealMode, .guided, "a packet arrives set to play in place")
        layers[0].revealMode = .companion
        XCTAssertEqual(SharedMarginReview.entriesWithoutEpisode(layers: layers, records: records, asking: false), [], "auto-play off: a failed Play starts nothing")
        XCTAssertEqual(SharedMarginReview.entriesWithoutEpisode(layers: layers, records: records, asking: true).count, 1, "a Review tap asks")
        layers[0].revealMode = nil
        XCTAssertEqual(SharedMarginReview.entriesWithoutEpisode(layers: layers, records: records, asking: false), [], "no mode is not auto-play")
    }
}
