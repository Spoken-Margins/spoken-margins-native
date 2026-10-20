import Foundation
import SessionKit
import SessionKitAudio
import SessionKitPersistence
import SessionKitSharing
import XCTest
#if canImport(AVFoundation)
import AVFoundation
#endif

/// #2118: sending 6 Margins from one item failed with "The package manifest is too large." The manifest is the
/// packet's index, capped at 1 MB by every reader, and a normal one is about 3 KB. It grows only when the export lists
/// an unbounded per-item collection, one descriptor per entry. These tests fill each such collection from a realistic
/// store state and check the packet stays small, and that Build 29's reader (exportPacket) still imports it.
final class ManifestBoundTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_777_000_000)
    private let manifestLimit = 1_024 * 1_024

    /// A podcast heard many times keeps adding observed landmarks to its spine, each with its own signature file.
    /// The spine is spread to 500 landmarks on export (#536), but every stored landmark's signature was still packed
    /// as an asset: 4,000 landmarks made about 4,000 asset descriptors and a manifest over 1 MB.
    func testALongCapturedSpineOnlyPacksTheSignaturesItsLandmarksKeep() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try await generatedEvidence(in: root)
        let landmarkCount = 4_000
        let signatures = (0..<landmarkCount).map { index in
            ReviewedMachineEvidenceAsset(
                id: "episode-signature-\(index)", path: "assets/evidence/episode-signature-\(index).shazamsignature",
                sourceURL: evidence.fileURL, durationMs: evidence.durationMs, anchorOffsetMs: 0,
                provenance: PodcastAnchorEvidenceProvenance.decodedPlaybackStream.rawValue
            )
        }
        let landmarks = (0..<landmarkCount).map { index in
            EpisodeFingerprintLandmark(
                id: "landmark-\(index)", order: index,
                sourceMediaStartMs: index * 900, sourceMediaEndMs: index * 900 + 11_000,
                anchorMediaTimeMs: index * 900 + 5_500, continuityEpoch: index / 40,
                trigger: .periodicPlayback, provenance: .observedDecodedPlayback, signatureAssetId: signatures[index].id
            )
        }
        let spine = EditionFingerprintSpineArtifact(
            id: "episode-spine-long", itemId: "item-long", canonicalURL: "https://example.com/episodes/one",
            episodeGUID: "episode-one", producingEditionDurationMs: 3_600_000, createdAt: fixedDate, landmarks: landmarks
        )
        let marginEvidence = ReviewedMachineEvidenceAsset(
            id: evidence.id, path: evidence.archivePath, sourceURL: evidence.fileURL,
            durationMs: evidence.durationMs, anchorOffsetMs: evidence.anchorOffsetMs,
            provenance: PodcastAnchorEvidenceProvenance.decodedPlaybackStream.rawValue
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "long-spine-package", createdAt: fixedDate, item: podcastItem(), itemTransportSelection: .reference,
            selections: sixMargins(evidenceID: evidence.id),
            fingerprintSpines: [spine],
            // The app appends every stored landmark's signature; a landmark sharing a signature repeats it.
            machineEvidence: [marginEvidence] + signatures + [signatures[7]]
        )
        let url = root.appendingPathComponent("long-spine.spokenmargins")
        let manifest = try exportPacket(prepared, to: url)

        let signatureAssets = manifest.assets.filter { $0.role == SpokenMarginsAssetRole.acousticSignature }
        XCTAssertEqual(signatureAssets.count, FingerprintSpineExportRepair.maximumLandmarks + 1,
                       "the Margins' own evidence plus one signature per kept landmark")
        XCTAssertTrue(signatureAssets.contains { $0.id == evidence.id })
        XCTAssertLessThan(try SpokenMarginsPackageArchive.encodeManifest(manifest).count, manifestLimit / 4)
    }

    /// Each Listening Edition revision was stored as its own `edition-map-<revision>` proposal and every stored
    /// proposal became an artifact. Saving a revision now replaces the superseded ones, in the existing record kind.
    func testSavingAnEditionRevisionReplacesTheSupersededOnes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appending(path: "library.sqlite").path)
        let community = proposal(id: "community-map-friend", at: 0)
        try store.savePortableListeningMapProposal(community, itemId: "item-edition")
        try store.savePortableListeningMapProposal(proposal(id: "episode-map-proposal-other", at: 0), itemId: "item-other")
        for revision in 0..<40 {
            try store.savePortableListeningMapProposal(proposal(id: "edition-map-rev\(revision)", at: revision + 1), itemId: "item-edition")
        }
        let stored = try store.loadPortableListeningMapProposals(itemId: "item-edition")
        XCTAssertEqual(Set(stored.map(\.id)), ["community-map-friend", "edition-map-rev39"])
        XCTAssertEqual(try store.loadPortableListeningMapProposals(itemId: "item-other").count, 1, "other items keep theirs")

        let memory = InMemorySessionRepository()
        for revision in 0..<3 {
            try memory.savePortableListeningMapProposal(proposal(id: "edition-map-rev\(revision)", at: revision), itemId: "item-edition")
        }
        XCTAssertEqual(try memory.loadPortableListeningMapProposals(itemId: "item-edition").map(\.id), ["edition-map-rev2"])
    }

    /// A Library that already holds many proposals for one item (from older builds, or friends' maps) shares one:
    /// the map the item plays, or else the newest.
    func testAnItemWithManyStoredProposalsSharesOnlyItsCurrentMap() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = (0..<5_000).map { proposal(id: "edition-map-rev\($0)", at: $0) }
        XCTAssertEqual(SharedMarginExport.mapProposals(stored, currentProposalID: "edition-map-rev17").map(\.id), ["edition-map-rev17"])
        XCTAssertEqual(SharedMarginExport.mapProposals(stored, currentProposalID: "gone").map(\.id), ["edition-map-rev4999"])
        XCTAssertEqual(SharedMarginExport.mapProposals(stored, currentProposalID: nil).map(\.id), ["edition-map-rev4999"])
        XCTAssertTrue(SharedMarginExport.mapProposals([], currentProposalID: nil).isEmpty)

        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "many-proposals-package", createdAt: fixedDate, item: podcastItem(), itemTransportSelection: .reference,
            selections: sixMargins(evidenceID: nil),
            mapProposals: SharedMarginExport.mapProposals(stored, currentProposalID: nil)
        )
        let manifest = try exportPacket(prepared, to: root.appendingPathComponent("many-proposals.spokenmargins"))
        XCTAssertEqual(manifest.artifacts.filter { $0.kind == SpokenMarginsArtifactKind.listeningMapProposal }.count, 1)
    }

    /// Identity links were checked for their scheme only. A link longer than any real page address is dropped, as
    /// the other identity fields are bounded; with no link left the recipient supplies the item from their copy.
    func testOverLongIdentityLinksAreLeftOut() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let long = "https://example.com/a?" + String(repeating: "q", count: 1_100_000)
        let item = SharedItemIdentity(
            itemType: .podcast, canonicalURL: long, originalURL: long, title: "Episode One", episodeGUID: "episode-one",
            enclosureURL: long, durationMs: 3_600_000,
            source: SharedSourceIdentity(sourceType: .podcastFeed, canonicalURL: long, title: "Example Show")
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "long-link-package", createdAt: fixedDate, item: item, itemTransportSelection: .reference,
            selections: sixMargins(evidenceID: nil)
        )
        let manifest = try exportPacket(prepared, to: root.appendingPathComponent("long-link.spokenmargins"))
        XCTAssertNil(manifest.item.canonicalURL)
        XCTAssertNil(manifest.item.originalURL)
        XCTAssertNil(manifest.item.enclosureURL)
        XCTAssertNil(manifest.item.source)
        XCTAssertEqual(manifest.itemTransport.kind, .recipientSupplied)

        let edge = "https://example.com/" + String(repeating: "e", count: SpokenMarginsPackageBuilder.maximumLinkCharacters - 20)
        let kept = try SpokenMarginsPackageBuilder.prepare(
            packageId: "edge-link-package", createdAt: fixedDate,
            item: SharedItemIdentity(itemType: .text, canonicalURL: edge, title: "Article"), itemTransportSelection: .reference,
            selections: sixMargins(evidenceID: nil)
        )
        XCTAssertEqual(kept.manifest.item.canonicalURL, edge, "a link at the limit is kept")
    }

    /// The failure names what filled the manifest, and the listener is told what to do, not "manifest".
    func testAnExportFailureNamesWhatFilledTheManifest() throws {
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "failure-package", createdAt: fixedDate,
            item: SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/" + String(repeating: "x", count: 300), title: "Article"),
            itemTransportSelection: .reference, selections: sixMargins(evidenceID: nil)
        )
        let failure = SharedPacketExportFailure(error: SpokenMarginsPackageArchiveError.manifestTooLarge, prepared: prepared)
        XCTAssertTrue(failure.diagnostic.hasPrefix("manifestTooLarge;"), failure.diagnostic)
        XCTAssertTrue(failure.diagnostic.contains("artifacts=1;assets=0;longestURL=320;manifestBytes="), failure.diagnostic)
        XCTAssertFalse(failure.listenerMessage.localizedCaseInsensitiveContains("manifest"))
        XCTAssertTrue(failure.listenerMessage.contains("fewer"), failure.listenerMessage)

        let unprepared = SharedPacketExportFailure(error: SessionKitError.persistenceFailed("selected_original_margin_audio_unavailable"), prepared: nil)
        XCTAssertFalse(unprepared.diagnostic.contains("artifacts="))
        XCTAssertFalse(unprepared.listenerMessage.isEmpty)
    }

    // MARK: Helpers

    private func sixMargins(evidenceID: String?) -> [ReviewedInterjectionSelection] {
        (1...6).map { index in
            ReviewedInterjectionSelection(
                packageScopedId: String(format: "margin-%04d", index),
                revision: InterjectionShareRevision(
                    id: "revision-\(index)", interjectionId: "note-\(index)", itemId: "item", sessionId: "session",
                    createdAt: fixedDate, approvedTranscript: "Reviewed thought \(index).", anchorBefore: "", anchorAfter: "",
                    status: .senderApproved
                ),
                anchor: .init(anchorType: .media, mediaTimeMs: index * 60_000,
                              machineEvidenceAssetIds: index == 1 ? [evidenceID].compactMap { $0 } : []),
                representation: .textOnly
            )
        }
    }

    private func proposal(id: String, at offset: Int) -> PortableListeningMapProposalArtifact {
        PortableListeningMapProposalArtifact(
            id: id, createdAt: fixedDate.addingTimeInterval(TimeInterval(offset)),
            generator: "test",
            scenes: [.init(id: "\(id)-scene", order: 0, title: "Part one", summaryText: "Reviewed overview.",
                           summaryProvenance: .senderAuthored, eligibility: .eligible, eligibilityReason: "Reviewed by sender",
                           startAnchor: .init(anchorType: .media, mediaTimeMs: 0),
                           endAnchor: .init(anchorType: .media, mediaTimeMs: 30_000))]
        )
    }

    private func podcastItem() -> SharedItemIdentity {
        SharedItemIdentity(
            itemType: .podcast, canonicalURL: "https://example.com/episodes/one", title: "Episode One",
            episodeGUID: "episode-one", durationMs: 3_600_000
        )
    }

    private func articleItem() -> SharedItemIdentity {
        SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article")
    }

    private func generatedEvidence(in root: URL) async throws -> GeneratedPodcastAnchorEvidence {
        let sourceURL = root.appendingPathComponent("patterned-source.m4a")
        try writePatternedM4A(to: sourceURL, durationSeconds: 30)
        let generated = try await PodcastAnchorEvidenceGenerator.generate(
            sourceURL: sourceURL, anchorMediaTimeMs: 15_000,
            outputDirectory: root.appendingPathComponent("generated-evidence"), idPrefix: "evidence"
        )
        return try XCTUnwrap(generated.first)
    }

    private func writePatternedM4A(to url: URL, durationSeconds: Int) throws {
        #if canImport(AVFoundation)
        let sampleRate = 44_100.0
        let audioFile = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000
        ])
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        for second in 0..<durationSeconds {
            let frameCount = AVAudioFrameCount(sampleRate)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            let baseFrequency = 180.0 + Double((second * 73) % 420)
            for frame in 0..<Int(frameCount) {
                let time = Double(frame) / sampleRate
                let sweep = baseFrequency + (Double(frame) / Double(frameCount)) * 120
                samples[frame] = Float(0.22 * sin(2 * .pi * sweep * time) + 0.12 * sin(2 * .pi * (baseFrequency * 1.7) * time))
            }
            try audioFile.write(from: buffer)
        }
        #else
        throw XCTSkip("AVFoundation is required")
        #endif
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ManifestBoundTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
