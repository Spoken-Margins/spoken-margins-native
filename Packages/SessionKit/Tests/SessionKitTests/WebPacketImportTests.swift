import AVFoundation
import Foundation
import SessionKit
import SessionKitAudio
import SessionKitSharing
import SessionKitTestInputs
import ShippedPacketReader
import XCTest

/// The web app writes `.spokenmargins` packets in TypeScript (`Web/src/packet/write.ts`, #2984). These are its three
/// fixtures, made by `node Web/src/packet/fixtures.ts`; each must import through this build's reader and importer and
/// through Build 29's frozen one, with the Margins at the sender's times and the voice audio readable at its length.
/// With `SM_SHIPPED_PACKETS_DIR` set, Builds 32 and 34 open them too (`keepForLaterShippedBuilds`).
final class WebPacketImportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebPacketImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func importFixture(_ name: String) throws -> (VerifiedSpokenMarginsPackage, [ImportedCommentaryInterjection]) {
        let (contents, _, margins) = try importFixtureWithLayer(name)
        return (contents, margins)
    }

    private func importFixtureWithLayer(
        _ name: String
    ) throws -> (VerifiedSpokenMarginsPackage, ImportedCommentaryLayer, [ImportedCommentaryInterjection]) {
        let url = try TestInputs.url(.contracts, "fixtures/web-packets/\(name)")
        let contents = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent(name))
        let repository = InMemorySessionRepository()
        let disposition = try SpokenMarginsPackageImporter.importPackage(contents, repository: repository)
        guard case .imported = disposition else { throw XCTSkip("unreachable: \(disposition)") }
        let layer = try XCTUnwrap(repository.loadImportedCommentaryLayer(packageDigest: XCTUnwrap(contents.manifest.contentDigest)))
        let margins = try repository.loadImportedCommentaryInterjections(layerId: layer.id)
            .sorted { $0.packageScopedId < $1.packageScopedId }

        let shippedIDs = try ShippedPacketReader.importPacket(at: url)
        XCTAssertEqual(shippedIDs.sorted(), margins.map(\.packageScopedId), "Build 29's reader reads every Margin")
        try keepForLaterShippedBuilds(url, sent: margins.map(\.packageScopedId))
        return (contents, layer, margins)
    }

    func testWrittenMarginsImportAtTheSendersTimes() throws {
        let (contents, margins) = try importFixture("web-written.spokenmargins")
        XCTAssertEqual(contents.manifest.item.itemType, .podcast)
        XCTAssertEqual(contents.manifest.item.episodeGUID, "example-episode-guid-1")
        XCTAssertEqual(contents.manifest.item.enclosureURL, "https://example.com/podcast/episode-1.mp3")
        XCTAssertEqual(contents.manifest.senderDisplayLabel, "Web fixture")
        XCTAssertEqual(margins.map(\.approvedTranscript), ["A written Margin from the web, 1:05 in.", "Another at ten minutes."])
        XCTAssertEqual(margins.map(\.anchorEvidence.mediaTimeMs), [65_000, 600_400])
        XCTAssertEqual(margins.map(\.anchorEvidence.anchorType), [.media, .media])
        XCTAssertTrue(margins.allSatisfy { $0.audioPath == nil })
    }

    func testVoiceMarginImportsWithReadableAudioOfItsLength() throws {
        let (contents, margins) = try importFixture("web-voice.spokenmargins")
        XCTAssertEqual(margins.map(\.anchorEvidence.mediaTimeMs), [30_000, 125_250])
        XCTAssertNil(margins[0].audioPath)
        let voice = margins[1]
        XCTAssertEqual(voice.approvedTranscript, "This is a web Margin, recorded for the packet test.")
        let declared = try XCTUnwrap(voice.audioDurationMs)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: XCTUnwrap(voice.audioPath)))
        XCTAssertEqual(file.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        let decodedMs = Int((Double(file.length) / file.processingFormat.sampleRate * 1000).rounded())
        // The web writer counts whole AAC frames; AVFoundation drops the encoder's priming, about two frames.
        XCTAssertGreaterThan(decodedMs, 2_500)
        XCTAssertLessThanOrEqual(abs(decodedMs - declared), 150, "declared \(declared) ms, decoded \(decodedMs) ms")
        XCTAssertEqual(contents.manifest.assets.map(\.mimeType), ["audio/mp4"])
    }

    /// The owner's report on Build 35 (#3041): a web packet imported fine and its Margin played when tapped, but never
    /// during playback. A web packet's Margins carry only the sender's clock time, and the placement pass left them
    /// unplaced. Run this fixture through the pass's own steps (the acoustic resolver on a stand-in file, fusion,
    /// apply) and check that every Margin plays during playback, at the sender's time, marked approximate.
    func testWebMarginsArePlacedAtTheSendersTimesAndPlayDuringPlayback() async throws {
        let (_, importedLayer, records) = try importFixtureWithLayer("web-voice.spokenmargins")
        var layer = importedLayer
        XCTAssertTrue(records.allSatisfy { !$0.sentPositionEvidence(in: layer) }, "a web packet sends only clock times")

        let listenersCopy = root.appendingPathComponent("episode.mp3")
        try Data("not the sender's file".utf8).write(to: listenersCopy)
        let queries = records.map {
            PodcastPortableAnchorQuery(packageScopedId: $0.packageScopedId, senderMediaTimeMs: $0.anchorEvidence.mediaTimeMs,
                                       evidence: [], evidenceWasDeclared: !$0.anchorEvidence.machineEvidenceAssetIds.isEmpty)
        }
        let acoustic = try await PodcastAcousticAnchorResolver.resolve(
            queries: queries, recipientAudioURL: listenersCopy, senderExactEditionSHA256: layer.itemIdentity.exactEditionSHA256,
            senderDurationMs: layer.itemIdentity.durationMs, strongSourceIdentity: true)
        let fused = ImportedPodcastPlacement.fuse(
            queries: queries, records: records, acoustic: acoustic, recipientTranscript: nil)
        let placed = ImportedPodcastPlacement.apply(
            fused, to: records, layer: &layer, recipientDigest: String(repeating: "c", count: 64), hasTranscript: false,
            recipientDurationMs: 3_600_000)

        XCTAssertEqual(placed.map(\.resolution.evidenceClass), [.timestampFallback, .timestampFallback])
        XCTAssertEqual(placed.map(\.resolution.localMediaTimeMs), [30_000, 125_250])
        let prompts = SharedMarginPrompts.prompts(
            layers: [layer], recordsByLayerID: [layer.id: placed], announcedIDs: [], includeAnnounced: false)
        XCTAssertEqual(prompts.map(\.interjection.packageScopedId), placed.map(\.packageScopedId), "both play during playback")
        let review = SharedMarginReview.entries(layers: [layer], records: [layer.id: placed])
        XCTAssertEqual(review.map(\.mediaTimeMs), [125_250], "the voice Margin is offered, at the sender's time")
        XCTAssertTrue(review.allSatisfy(\.isApproximate), "a clock placement is never shown as a verified one")
    }

    /// A voice Margin the web listener left without words travels with placeholder words in its transcript (#3025),
    /// so every reader back to Build 29, which rejects an empty transcript, imports it with its voice.
    func testWordlessVoiceMarginImportsWithPlaceholderWordsAndItsVoice() throws {
        let (_, margins) = try importFixture("web-voice-placeholder.spokenmargins")
        XCTAssertEqual(margins.count, 1)
        let voice = try XCTUnwrap(margins.first)
        XCTAssertEqual(voice.approvedTranscript, "Voice Margin at 0:45 in “Episode 1 (example episode)”, recorded 30 Oct 2026")
        XCTAssertEqual(voice.anchorEvidence.mediaTimeMs, 45_000)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: XCTUnwrap(voice.audioPath)))
        XCTAssertEqual(file.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
    }
}
