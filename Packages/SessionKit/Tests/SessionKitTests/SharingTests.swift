import CryptoKit
import Foundation
@testable import SessionKit
@testable import SessionKitAudio
import SessionKitPersistence
import SessionKitSharing
import ShippedPacketReader
import XCTest
import ZIPFoundation
#if canImport(AVFoundation)
import AVFoundation
import AudioToolbox
#endif

final class SharingTests: XCTestCase {
    func testCleanupIsDeterministicAndDoesNotMutatePrivateCapture() {
        let transcript = AlignedInterjectionTranscript(
            text: "Um umbrella matters.",
            segments: [
                .init(id: "1", text: "Um", startMs: 0, endMs: 180),
                .init(id: "2", text: "umbrella", startMs: 220, endMs: 600),
                .init(id: "3", text: "matters.", startMs: 630, endMs: 900)
            ]
        )
        let privateCapture = transcript
        let first = DeterministicInterjectionCleanup.propose(transcript)
        let second = DeterministicInterjectionCleanup.propose(transcript)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.cleanedTranscript, "Umbrella matters.")
        XCTAssertEqual(first.decisions.map(\.kind), [.filler])
        XCTAssertEqual(transcript, privateCapture)
    }

    func testCleanupPreservesSemanticYouKnowAndSupportsPerEditUndo() throws {
        let semantic = AlignedInterjectionTranscript(
            text: "You know the answer.",
            segments: [
                .init(id: "1", text: "You", startMs: 0, endMs: 100),
                .init(id: "2", text: "know", startMs: 120, endMs: 220),
                .init(id: "3", text: "the", startMs: 240, endMs: 300),
                .init(id: "4", text: "answer.", startMs: 320, endMs: 500)
            ]
        )
        XCTAssertEqual(DeterministicInterjectionCleanup.propose(semantic).cleanedTranscript, semantic.text)

        let filler = AlignedInterjectionTranscript(
            text: "Uh a clear thought.",
            segments: [
                .init(id: "1", text: "Uh", startMs: 0, endMs: 150),
                .init(id: "2", text: "a", startMs: 200, endMs: 240),
                .init(id: "3", text: "clear", startMs: 260, endMs: 400),
                .init(id: "4", text: "thought.", startMs: 420, endMs: 650)
            ]
        )
        let initial = DeterministicInterjectionCleanup.propose(filler)
        let decision = try XCTUnwrap(initial.decisions.first)
        let restored = DeterministicInterjectionCleanup.propose(filler, restoredDecisionIds: [decision.id])
        XCTAssertEqual(restored.cleanedTranscript, filler.text)
        XCTAssertEqual(restored.decisions.first?.accepted, false)
    }

    func testCleanupShortensLongPauseButNeverDeletesAllSpeech() {
        let transcript = AlignedInterjectionTranscript(
            text: "Um uh.",
            segments: [
                .init(id: "1", text: "Um", startMs: 0, endMs: 150),
                .init(id: "2", text: "uh", startMs: 1_200, endMs: 1_350)
            ]
        )
        let result = DeterministicInterjectionCleanup.propose(transcript)
        XCTAssertEqual(result.cleanedTranscript, transcript.text)
        XCTAssertEqual(result.decisions.filter { $0.kind == .filler }.map(\.accepted), [false, false])
        XCTAssertEqual(result.decisions.first { $0.kind == .longPause }?.startMs, 400)
    }

    func testManualWordDeletionUsesAlignedRangeAndCanBeRestored() throws {
        let transcript = AlignedInterjectionTranscript(
            text: "Keep unnecessary words.",
            segments: [
                .init(id: "keep", text: "Keep", startMs: 100, endMs: 320),
                .init(id: "unnecessary", text: "unnecessary", startMs: 360, endMs: 780),
                .init(id: "words", text: "words.", startMs: 820, endMs: 1_100)
            ]
        )
        let deleted = DeterministicInterjectionCleanup.propose(
            transcript,
            manuallyDeletedSegmentIds: ["unnecessary"]
        )
        let decision = try XCTUnwrap(deleted.decisions.first { $0.kind == .manualWord })
        XCTAssertEqual(deleted.cleanedTranscript, "Keep words.")
        XCTAssertLessThanOrEqual(decision.startMs, 360)
        XCTAssertGreaterThanOrEqual(decision.endMs, 780)
        XCTAssertEqual(DeterministicInterjectionCleanup.propose(transcript).cleanedTranscript, transcript.text)
    }

    func testAcousticPauseDetectionFindsEdgesAndProtectsAlignedSpeech() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("silence-speech-silence.m4a")
        try writeSilenceSpeechSilenceM4A(to: url)
        let transcript = AlignedInterjectionTranscript(
            text: "A thought.",
            segments: [.init(id: "thought", text: "A thought.", startMs: 1_000, endMs: 2_000)]
        )
        let decisions = try InterjectionSilenceDetector.proposePauseEdits(
            sourceURL: url,
            alignedTranscript: transcript
        )
        XCTAssertGreaterThanOrEqual(decisions.count, 2)
        XCTAssertTrue(decisions.allSatisfy { $0.endMs <= 950 || $0.startMs >= 2_050 })
        XCTAssertTrue(decisions.allSatisfy { $0.kind == .longPause && $0.accepted })
    }

    func testSpeechAwarePauseDetectionRemovesAHighEnergyGapWithoutTouchingWords() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("speech-noise-gap-speech.m4a")
        try writeContinuousNoiseM4A(to: url, durationSeconds: 3)
        let transcript = AlignedInterjectionTranscript(
            text: "First thought. Second thought.",
            segments: [
                .init(id: "first", text: "First thought.", startMs: 200, endMs: 800),
                .init(id: "second", text: "Second thought.", startMs: 2_200, endMs: 2_800)
            ]
        )

        let decisions = try InterjectionSilenceDetector.proposePauseEdits(
            sourceURL: url,
            alignedTranscript: transcript
        )

        XCTAssertTrue(decisions.contains { $0.startMs >= 800 && $0.endMs <= 2_200 && $0.endMs - $0.startMs >= 1_000 })
        XCTAssertTrue(decisions.allSatisfy { decision in
            transcript.segments.allSatisfy { segment in
                decision.endMs <= segment.startMs || decision.startMs >= segment.endMs
            }
        })
    }

    func testAnchorContextKeepsNearestBoundedEvidenceAndMachineReferences() {
        let anchor = PortableAnchorEvidence(
            anchorType: .transcript,
            exactText: String(repeating: "e", count: 1_200),
            prefix: String(repeating: "b", count: 600) + "near",
            suffix: "near" + String(repeating: "a", count: 600),
            mediaTimeMs: 2_000,
            roughPercent: 120,
            machineEvidenceAssetIds: ["signature-pre"]
        ).bounded()
        XCTAssertEqual(anchor.exactText?.count, 1_000)
        XCTAssertEqual(anchor.prefix?.count, 500)
        XCTAssertTrue(anchor.prefix?.hasSuffix("near") == true)
        XCTAssertEqual(anchor.suffix?.count, 500)
        XCTAssertTrue(anchor.suffix?.hasPrefix("near") == true)
        XCTAssertEqual(anchor.roughPercent, 100)
        XCTAssertEqual(anchor.machineEvidenceAssetIds, ["signature-pre"])
    }

    func testBuilderProducesFinalEnvelopeAndTextCommentaryArtifact() throws {
        let prepared = try textPreparedPackage()
        XCTAssertEqual(prepared.manifest.schemaVersion, SpokenMarginsPackageArchive.schemaVersion)
        XCTAssertEqual(prepared.manifest.artifacts.map(\.kind), [SpokenMarginsArtifactKind.commentaryLayer])
        XCTAssertTrue(prepared.manifest.assets.isEmpty)
        XCTAssertTrue(prepared.assetFiles.isEmpty)
        let data = try XCTUnwrap(prepared.artifactData["artifacts/commentary-layer.json"])
        let layer = try JSONDecoder.iso8601.decode(SharedCommentaryLayerArtifact.self, from: data)
        XCTAssertEqual(layer.interjections.first?.defaultRepresentation?.kind, .textOnly)
        XCTAssertTrue(prepared.manifest.redactions.provesPrivateMinimization)
        XCTAssertFalse(String(decoding: try SpokenMarginsPackageArchive.encodeManifest(prepared.manifest), as: UTF8.self).contains("private-note"))
    }

    func testEmbeddedAndRecipientSuppliedItemTransportsDoNotRequireInventedURL() throws {
        let text = "A linkless item whose exact listened-to text can travel with reviewed Margins."
        let item = SharedItemIdentity(
            itemType: .pdf,
            title: "Linkless Reading",
            normalizedContentSHA256: PortableArticleAnchorResolver.normalizedContentSHA256(text),
            exactEditionSHA256: PortableArticleAnchorResolver.exactEditionSHA256(text)
        )
        let embedded = try SpokenMarginsPackageBuilder.prepare(
            packageId: "embedded-package",
            createdAt: fixedDate,
            item: item,
            itemTransportSelection: .embeddedText(
                text: text,
                originalMediaType: "pdf",
                rightsBasis: .senderConfirmedPrivateRights
            ),
            selections: [.init(
                packageScopedId: "margin-001",
                revision: approvedRevision(),
                anchor: .init(anchorType: .text, exactText: "exact listened-to text"),
                representation: .textOnly
            )]
        )
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("embedded.spokenmargins")
        let manifest = try exportPacket(embedded, to: url)
        let verified = try SpokenMarginsPackageArchive.read(
            from: url,
            extractingAssetsTo: root.appendingPathComponent("assets")
        )
        XCTAssertNil(manifest.item.canonicalURL)
        XCTAssertEqual(manifest.itemTransport.kind, .embeddedText)
        XCTAssertEqual(manifest.itemTransport.rightsBasis, .senderConfirmedPrivateRights)
        XCTAssertFalse(manifest.redactions.fullItemOmitted)
        XCTAssertEqual(verified.embeddedTextItems.first?.text, text)

        let omitted = try SpokenMarginsPackageBuilder.prepare(
            packageId: "recipient-supplied-package",
            createdAt: fixedDate,
            item: item,
            itemTransportSelection: .recipientSupplied,
            selections: [.init(
                packageScopedId: "margin-001",
                revision: approvedRevision(),
                anchor: .init(anchorType: .text),
                representation: .textOnly
            )]
        )
        let omittedURL = root.appendingPathComponent("omitted.spokenmargins")
        let omittedManifest = try exportPacket(omitted, to: omittedURL)
        XCTAssertEqual(omittedManifest.itemTransport.kind, .recipientSupplied)
        XCTAssertTrue(omittedManifest.redactions.fullItemOmitted)

        let linkedButOmitted = try SpokenMarginsPackageBuilder.prepare(
            packageId: "linked-but-omitted",
            createdAt: fixedDate,
            item: articleItem,
            itemTransportSelection: .recipientSupplied,
            selections: [.init(
                packageScopedId: "margin-001",
                revision: approvedRevision(),
                anchor: .init(anchorType: .text),
                representation: .textOnly
            )]
        )
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.write(
            linkedButOmitted,
            to: root.appendingPathComponent("linked-but-omitted.spokenmargins")
        ))

        let mismatchedDocumentType = try SpokenMarginsPackageBuilder.prepare(
            packageId: "mismatched-document-type",
            createdAt: fixedDate,
            item: item,
            itemTransportSelection: .embeddedText(
                text: text,
                originalMediaType: "epub",
                rightsBasis: .senderConfirmedPrivateRights
            ),
            selections: [.init(
                packageScopedId: "margin-001",
                revision: approvedRevision(),
                anchor: .init(anchorType: .text),
                representation: .textOnly
            )]
        )
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.write(
            mismatchedDocumentType,
            to: root.appendingPathComponent("mismatched-document-type.spokenmargins")
        ))
    }

    func testBuilderIncludesOnlyExplicitlySelectedOriginalOrCleanedVoice() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("original.m4a")
        let cleanedURL = root.appendingPathComponent("cleaned.m4a")
        try writeSilentM4A(to: originalURL)
        try writeSilentM4A(to: cleanedURL)

        let original = try SpokenMarginsPackageBuilder.prepare(
            packageId: "original-package",
            createdAt: fixedDate,
            item: articleItem,
            itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-original",
                revision: approvedRevision(),
                anchor: .init(anchorType: .text),
                representation: .originalAudio(sourceURL: originalURL, durationMs: 100)
            )]
        )
        XCTAssertEqual(original.manifest.assets.first?.role, SpokenMarginsAssetRole.originalVoice)
        XCTAssertEqual(original.assetFiles.values.first, originalURL)

        let cleaned = try SpokenMarginsPackageBuilder.prepare(
            packageId: "cleaned-package",
            createdAt: fixedDate,
            item: articleItem,
            itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-cleaned",
                revision: approvedRevision(cleanedAudioPath: cleanedURL.path),
                anchor: .init(anchorType: .text),
                representation: .cleanedAudio(sourceURL: cleanedURL)
            )]
        )
        XCTAssertEqual(cleaned.manifest.assets.first?.role, SpokenMarginsAssetRole.cleanedVoice)
        XCTAssertFalse(String(decoding: try SpokenMarginsPackageArchive.encodeManifest(cleaned.manifest), as: UTF8.self).contains(cleanedURL.path))
    }

    func testBuilderRejectsDraftDuplicateAndMismatchedCleanedAudio() throws {
        let draft = InterjectionShareRevision(
            id: "draft", interjectionId: "private", itemId: "item", sessionId: "session",
            createdAt: fixedDate, approvedTranscript: "Draft", anchorBefore: "", anchorAfter: ""
        )
        XCTAssertThrowsError(try SpokenMarginsPackageBuilder.prepare(
            packageId: "package", createdAt: fixedDate, item: articleItem, itemTransportSelection: .reference,
            selections: [.init(packageScopedId: "a", revision: draft, anchor: .init(anchorType: .text), representation: .textOnly)]
        )) { XCTAssertEqual($0 as? InterjectionPackagePreparationError, .unapprovedRevision("draft")) }

        let approved = approvedRevision(cleanedAudioPath: "/tmp/right.m4a")
        XCTAssertThrowsError(try SpokenMarginsPackageBuilder.prepare(
            packageId: "package", createdAt: fixedDate, item: articleItem, itemTransportSelection: .reference,
            selections: [.init(packageScopedId: "a", revision: approved, anchor: .init(anchorType: .text), representation: .cleanedAudio(sourceURL: URL(fileURLWithPath: "/tmp/wrong.m4a")))]
        )) { XCTAssertEqual($0 as? InterjectionPackagePreparationError, .cleanedAudioMismatch(approved.id)) }

        XCTAssertThrowsError(try SpokenMarginsPackageBuilder.prepare(
            packageId: "package", createdAt: fixedDate, item: articleItem, itemTransportSelection: .reference,
            selections: [
                .init(packageScopedId: "same", revision: approvedRevision(), anchor: .init(anchorType: .text), representation: .textOnly),
                .init(packageScopedId: "same", revision: approvedRevision(), anchor: .init(anchorType: .text), representation: .textOnly)
            ]
        )) { XCTAssertEqual($0 as? InterjectionPackagePreparationError, .duplicatePackageScopedId("same")) }
    }

    func testArchiveRoundTripAndBytesAreDeterministic() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try textPreparedPackage()
        let firstURL = root.appendingPathComponent("first.spokenmargins")
        let secondURL = root.appendingPathComponent("second.spokenmargins")
        let first = try exportPacket(prepared, to: firstURL)
        let second = try exportPacket(prepared, to: secondURL)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: firstURL), try Data(contentsOf: secondURL))

        let verified = try SpokenMarginsPackageArchive.read(
            from: firstURL,
            extractingAssetsTo: root.appendingPathComponent("assets")
        )
        XCTAssertEqual(verified.manifest, first)
        XCTAssertEqual(verified.commentaryLayers.first?.interjections.first?.packageScopedId, "margin-001")
        XCTAssertTrue(verified.extractedAssetURLs.isEmpty)
    }

    /// #536: sharing a streamed podcast's Margins failed with "episode fingerprint spine is out of
    /// bounds". The stored spine named the feed's http:// link, held more than 500 landmarks from
    /// long periodic capture, and one landmark whose signature file was gone. The writer now repairs
    /// the spine, and Build 29's reader (exportPacket) imports the packet.
    func testAStreamedEpisodeSpineThePacketRulesRejectIsRepairedOnExport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("patterned-source.m4a")
        try writePatternedM4A(to: sourceURL, durationSeconds: 30)
        let generatedEvidence = try await PodcastAnchorEvidenceGenerator.generate(
            sourceURL: sourceURL,
            anchorMediaTimeMs: 15_000,
            outputDirectory: root.appendingPathComponent("generated-evidence"),
            idPrefix: "evidence"
        )
        let evidence = try XCTUnwrap(generatedEvidence.first)
        func landmark(_ index: Int, asset: String) -> EpisodeFingerprintLandmark {
            EpisodeFingerprintLandmark(
                id: "landmark-\(index)", order: index,
                sourceMediaStartMs: index * 6_000, sourceMediaEndMs: index * 6_000 + 11_000,
                anchorMediaTimeMs: index * 6_000 + 5_500, continuityEpoch: 1,
                trigger: .periodicPlayback, provenance: .observedDecodedPlayback, signatureAssetId: asset
            )
        }
        // Each captured landmark has its own signature, as the app records them. Landmark 621 reuses
        // landmark 3's: Build 29's importer keys a dictionary by signature and traps on a repeat.
        let signatures = (0..<620).map { index in
            ReviewedMachineEvidenceAsset(
                id: "\(evidence.id)-\(index)", path: "assets/evidence/\(evidence.id)-\(index).shazamsignature",
                sourceURL: evidence.fileURL, durationMs: evidence.durationMs, anchorOffsetMs: evidence.anchorOffsetMs,
                provenance: PodcastAnchorEvidenceProvenance.decodedPlaybackStream.rawValue
            )
        }
        let captured = (0..<620).map { landmark($0, asset: signatures[$0].id) }
            + [landmark(620, asset: "episode-signature-missing"), landmark(621, asset: signatures[3].id)]
        let spine = EditionFingerprintSpineArtifact(
            id: "episode-spine-streamed", itemId: "item-source-v2-streamed",
            canonicalURL: "http://example.com/episodes/one", episodeGUID: "episode-one",
            producingEditionDurationMs: podcastItem.durationMs, createdAt: fixedDate, landmarks: captured
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "streamed-package", createdAt: fixedDate, item: podcastItem, itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001", revision: approvedRevision(),
                anchor: .init(anchorType: .media, mediaTimeMs: 401_000, machineEvidenceAssetIds: [evidence.id]),
                representation: .textOnly
            )],
            fingerprintSpines: [spine],
            machineEvidence: [.init(
                id: evidence.id, path: evidence.archivePath, sourceURL: evidence.fileURL,
                durationMs: evidence.durationMs, anchorOffsetMs: evidence.anchorOffsetMs,
                provenance: PodcastAnchorEvidenceProvenance.decodedPlaybackStream.rawValue
            )] + signatures
        )
        let url = root.appendingPathComponent("streamed.spokenmargins")
        _ = try exportPacket(prepared, to: url)
        let shared = try XCTUnwrap(try SpokenMarginsPackageArchive.read(
            from: url, extractingAssetsTo: root.appendingPathComponent("assets")
        ).editionFingerprintSpines.first)
        XCTAssertNil(shared.canonicalURL, "packets carry https links only")
        XCTAssertEqual(shared.episodeGUID, "episode-one")
        XCTAssertEqual(shared.landmarks.count, FingerprintSpineExportRepair.maximumLandmarks)
        XCTAssertEqual(shared.landmarks.map(\.order), Array(0..<FingerprintSpineExportRepair.maximumLandmarks))
        XCTAssertEqual(shared.landmarks.first?.id, "landmark-0")
        XCTAssertEqual(shared.landmarks.last?.id, "landmark-619", "spread over the whole episode")
        XCTAssertFalse(shared.landmarks.contains { $0.signatureAssetId == "episode-signature-missing" })
        XCTAssertEqual(Set(shared.landmarks.map(\.signatureAssetId)).count, shared.landmarks.count, "one landmark per signature")
    }

    /// #536: a spine naming another episode is left out, and the Margins still share.
    func testASpineForAnotherEpisodeIsLeftOutAndTheMarginsStillShare() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let spine = EditionFingerprintSpineArtifact(
            id: "episode-spine-other", itemId: "item-other", episodeGUID: "episode-two", createdAt: fixedDate, landmarks: []
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "other-package", createdAt: fixedDate, item: podcastItem, itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001", revision: approvedRevision(),
                anchor: .init(anchorType: .media, mediaTimeMs: 5_000), representation: .textOnly
            )],
            fingerprintSpines: [spine]
        )
        let url = root.appendingPathComponent("other.spokenmargins")
        _ = try exportPacket(prepared, to: url)
        let verified = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("assets"))
        XCTAssertTrue(verified.editionFingerprintSpines.isEmpty)
        XCTAssertEqual(verified.commentaryLayers.first?.interjections.map(\.packageScopedId), ["margin-001"])
    }

    /// #536: the validator's one message covered nine rules. It now names the rule, so diagnostics
    /// (lastSharedPackageFailure) say which one failed.
    func testASpineThePacketRejectsNamesTheRuleThatFailed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "named-rule", createdAt: fixedDate, item: podcastItem, itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001", revision: approvedRevision(),
                anchor: .init(anchorType: .media, mediaTimeMs: 5_000), representation: .textOnly
            )],
            fingerprintSpines: [EditionFingerprintSpineArtifact(
                id: "spine-1", itemId: "episode-one", canonicalURL: "https://example.com/episodes/one",
                createdAt: fixedDate, landmarks: []
            )]
        )
        // Bypass the export repair, as an older writer would have.
        let spinePath = try XCTUnwrap(prepared.manifest.artifacts.first {
            $0.kind == SpokenMarginsArtifactKind.editionFingerprintSpine
        }?.path)
        var data = prepared.artifactData
        var spine = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data[spinePath])) as? [String: Any])
        spine["canonicalURL"] = "http://example.com/episodes/one"
        data[spinePath] = try JSONSerialization.data(withJSONObject: spine)
        let malformed = PreparedSpokenMarginsPackage(manifest: prepared.manifest, artifactData: data, assetFiles: prepared.assetFiles)
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.write(malformed, to: root.appendingPathComponent("named.spokenmargins"))) { error in
            XCTAssertEqual(
                error as? SpokenMarginsPackageArchiveError,
                .invalidManifest("episode fingerprint spine is out of bounds: canonical_url")
            )
        }
    }

    func testALandmarkWithAnOverflowingSourceRangeIsRejectedNotATrap() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "overflowing-range", createdAt: fixedDate, item: podcastItem, itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001", revision: approvedRevision(),
                anchor: .init(anchorType: .media, mediaTimeMs: 5_000), representation: .textOnly
            )],
            fingerprintSpines: [EditionFingerprintSpineArtifact(
                id: "spine-1", itemId: "episode-one", canonicalURL: "https://example.com/episodes/one",
                createdAt: fixedDate, landmarks: []
            )]
        )
        // Decoding skips the clamping initializer, so a hostile packet can carry this range. Checking the
        // duration rule before the range rule computes 0 - Int.min, which traps.
        let spinePath = try XCTUnwrap(prepared.manifest.artifacts.first {
            $0.kind == SpokenMarginsArtifactKind.editionFingerprintSpine
        }?.path)
        var data = prepared.artifactData
        var spine = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data[spinePath])) as? [String: Any])
        spine["landmarks"] = [[
            "id": "landmark-1", "order": 0, "sourceMediaStartMs": Int.min, "sourceMediaEndMs": 0,
            "anchorMediaTimeMs": 0, "continuityEpoch": 0, "trigger": "initial_playback",
            "provenance": "observed_decoded_playback", "signatureAssetId": "missing", "generatorVersion": "v1",
        ]]
        data[spinePath] = try JSONSerialization.data(withJSONObject: spine)
        let malformed = PreparedSpokenMarginsPackage(manifest: prepared.manifest, artifactData: data, assetFiles: prepared.assetFiles)
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.write(malformed, to: root.appendingPathComponent("overflow.spokenmargins"))) { error in
            XCTAssertEqual(
                error as? SpokenMarginsPackageArchiveError,
                .invalidManifest("episode fingerprint landmark is invalid: source_range")
            )
        }
    }

    func testPortableListeningMapProposalAndPodcastEvidenceImportWithoutActivatingMap() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("patterned-source.m4a")
        try writePatternedM4A(to: sourceURL, durationSeconds: 30)
        let generatedEvidence = try await PodcastAnchorEvidenceGenerator.generate(
            sourceURL: sourceURL,
            anchorMediaTimeMs: 15_000,
            outputDirectory: root.appendingPathComponent("generated-evidence"),
            idPrefix: "evidence"
        )
        let evidence = try XCTUnwrap(generatedEvidence.first)
        let proposal = PortableListeningMapProposalArtifact(
            id: "proposal-1",
            createdAt: fixedDate,
            generator: "hand-authored-fixture",
            scenes: [.init(
                id: "scene-1", order: 0, title: "Opening", summaryText: "The speaker frames the question.",
                summaryProvenance: .senderAuthored, eligibility: .eligible,
                startAnchor: .init(anchorType: .transcript, exactText: "opening"),
                endAnchor: .init(anchorType: .transcript, exactText: "question")
            )]
        )
        let spine = EditionFingerprintSpineArtifact(
            id: "spine-1",
            itemId: "episode-one",
            canonicalURL: podcastItem.canonicalURL,
            producingEditionDurationMs: podcastItem.durationMs,
            createdAt: fixedDate,
            landmarks: [.init(
                id: "landmark-1",
                order: 0,
                sourceMediaStartMs: 9_000,
                sourceMediaEndMs: 21_000,
                anchorMediaTimeMs: 15_000,
                continuityEpoch: 0,
                trigger: .preInterjection,
                provenance: .observedDecodedPlayback,
                signatureAssetId: evidence.id,
                transcriptSketchWindowId: "sketch-window"
            )]
        )
        let sketch = TranscriptPhraseSketchArtifact(
            id: "sketch-1",
            itemId: "episode-one",
            saltBase64: Data(repeating: 3, count: 32).base64EncodedString(),
            createdAt: fixedDate,
            windows: [.init(
                id: "sketch-window",
                sourceStartMs: 0,
                sourceEndMs: 30_000,
                hashes: [String(repeating: "a", count: 32)]
            )]
        )
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "map-package", createdAt: fixedDate, item: podcastItem, itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001",
                revision: approvedRevision(),
                anchor: .init(
                    anchorType: .media,
                    mediaTimeMs: 5_000,
                    machineEvidenceAssetIds: [evidence.id]
                ),
                representation: .textOnly
            )],
            mapProposals: [proposal],
            fingerprintSpines: [spine],
            phraseSketches: [sketch],
            machineEvidence: [.init(
                id: evidence.id,
                path: evidence.archivePath,
                sourceURL: evidence.fileURL,
                durationMs: evidence.durationMs,
                anchorOffsetMs: evidence.anchorOffsetMs,
                provenance: PodcastAnchorEvidenceProvenance.decodedPlaybackStream.rawValue
            )]
        )
        let url = root.appendingPathComponent("map.spokenmargins")
        _ = try exportPacket(prepared, to: url)
        let verified = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("assets"))
        XCTAssertEqual(verified.listeningMapProposals, [proposal])
        XCTAssertEqual(verified.editionFingerprintSpines, [spine])
        XCTAssertEqual(verified.transcriptPhraseSketches, [sketch])
        XCTAssertEqual(verified.manifest.artifacts.last?.required, false)
        XCTAssertEqual(verified.manifest.assets.first?.anchorOffsetMs, evidence.anchorOffsetMs)
        XCTAssertEqual(
            verified.manifest.assets.first?.provenance,
            PodcastAnchorEvidenceProvenance.decodedPlaybackStream.rawValue
        )
        XCTAssertFalse(verified.manifest.artifacts.contains { $0.kind == "full_transcript" })
        XCTAssertFalse(verified.manifest.assets.contains { $0.path.localizedCaseInsensitiveContains("bridge") })

        let spinePath = try XCTUnwrap(prepared.manifest.artifacts.first {
            $0.kind == SpokenMarginsArtifactKind.editionFingerprintSpine
        }?.path)
        var malformedData = prepared.artifactData
        var malformedSpine = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(malformedData[spinePath])) as? [String: Any]
        )
        malformedSpine["unexpectedTranscript"] = "must be rejected"
        malformedData[spinePath] = try JSONSerialization.data(withJSONObject: malformedSpine)
        let malformed = PreparedSpokenMarginsPackage(
            manifest: prepared.manifest,
            artifactData: malformedData,
            assetFiles: prepared.assetFiles
        )
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.write(
            malformed,
            to: root.appendingPathComponent("malformed.spokenmargins")
        ))

        let repository = InMemorySessionRepository()
        _ = try SpokenMarginsPackageImporter.importPackage(
            verified,
            itemId: "recipient-podcast",
            importedAt: fixedDate,
            repository: repository
        )
        let layer = try XCTUnwrap(repository.importedCommentaryLayers.values.first)
        let imported = try XCTUnwrap(repository.importedCommentaryInterjections.values.first)
        XCTAssertEqual(layer.listeningMapProposals, [proposal])
        XCTAssertNil(try repository.loadListeningMap(itemId: "recipient-podcast"))
        XCTAssertEqual(imported.podcastAnchorEvidence?.first?.anchorOffsetMs, evidence.anchorOffsetMs)
        XCTAssertEqual(
            imported.podcastAnchorEvidence?.first?.provenance,
            PodcastAnchorEvidenceProvenance.decodedPlaybackStream.rawValue
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(imported.podcastAnchorEvidence?.first?.localPath)))
    }

    func testPostResumePodcastEvidenceUsesOnlyArmedDecodedAudioWindow() async throws {
        #if canImport(AVFoundation) && canImport(ShazamKit) && canImport(MediaToolbox)
        let (results, continuation) = AsyncStream<PostResumePodcastEvidenceCaptureResult>.makeStream()
        let context = PostResumePodcastEvidenceTapContext(
            resultHandler: { continuation.yield($0) },
            becameIdle: {}
        )
        let request = PostResumeAudioSampleRequest(
            interjectionId: "ij-post-resume",
            sessionId: "session-post-resume",
            itemId: "episode-post-resume",
            anchorMediaTimeMs: 42_000,
            targetDurationMs: PodcastAnchorEvidenceGenerator.minimumEvidenceDurationMs
        )
        XCTAssertTrue(context.arm(request))

        let sampleRate = 44_100.0
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ))
        context.prepare(processingFormat: format.streamDescription)
        let frameCount = AVAudioFrameCount(
            sampleRate * Double(PodcastAnchorEvidenceGenerator.minimumEvidenceDurationMs) / 1_000
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(frameCount) {
            let second = Double(frame) / sampleRate
            let frequency = 190 + (second * 83).truncatingRemainder(dividingBy: 510)
            samples[frame] = Float(
                0.24 * sin(2 * .pi * frequency * second)
                + 0.11 * sin(2 * .pi * frequency * 1.63 * second)
            )
        }
        context.process(
            bufferList: buffer.mutableAudioBufferList,
            frameCount: CMItemCount(frameCount),
            timeRange: CMTimeRange(
                start: CMTime(value: 42_250, timescale: 1_000),
                duration: CMTime(value: 3_000, timescale: 1_000)
            )
        )

        guard let result = await results.first(where: { _ in true }) else {
            return XCTFail("Expected a post-resume evidence result")
        }
        switch result {
        case .captured(let capture):
            XCTAssertEqual(capture.request, request)
            XCTAssertEqual(capture.anchorOffsetMs, -250)
            XCTAssertGreaterThanOrEqual(capture.durationMs, 2_900)
            XCTAssertFalse(capture.signatureData.isEmpty)
            XCTAssertLessThan(capture.signatureData.count, 1_048_576)
        case .failed(_, let reason):
            XCTFail("Post-resume signature failed: \(reason)")
        case .landmark:
            XCTFail("Expected a per-Margin capture, not a sparse landmark")
        }
        continuation.finish()
        #else
        throw XCTSkip("AVFoundation, MediaToolbox, and ShazamKit are required")
        #endif
    }

    func testContinuousEvidenceRingExtractsExactPreWindowAndSeekInvalidatesIt() async throws {
        #if canImport(AVFoundation) && canImport(ShazamKit) && canImport(MediaToolbox)
        let (results, continuation) = AsyncStream<PostResumePodcastEvidenceCaptureResult>.makeStream()
        let context = PostResumePodcastEvidenceTapContext(
            resultHandler: { continuation.yield($0) },
            becameIdle: {},
            continuousCollection: true,
            itemId: "episode-ring"
        )
        let sampleRate = 8_000.0
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ))
        context.prepare(processingFormat: format.streamDescription)
        for second in 20..<40 {
            let frameCount = AVAudioFrameCount(sampleRate)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<Int(frameCount) {
                let phase = Double(frame) / sampleRate
                samples[frame] = Float(0.2 * sin(2 * .pi * (220 + Double(second)) * phase))
            }
            context.process(
                bufferList: buffer.mutableAudioBufferList,
                frameCount: CMItemCount(frameCount),
                timeRange: CMTimeRange(
                    start: CMTime(value: CMTimeValue(second * 1_000), timescale: 1_000),
                    duration: CMTime(value: 1_000, timescale: 1_000)
                )
            )
        }
        let request = PostResumeAudioSampleRequest(
            interjectionId: "ij-pre",
            sessionId: "session-pre",
            itemId: "episode-ring",
            anchorMediaTimeMs: 40_000,
            targetDurationMs: 12_000
        )
        XCTAssertTrue(context.captureBufferedPreInterjection(request))
        guard let result = await results.first(where: {
            if case .captured(let capture) = $0 { return capture.request.interjectionId == request.interjectionId }
            return false
        }) else { return XCTFail("Expected buffered pre-interjection evidence") }
        if case .captured(let capture) = result {
            XCTAssertEqual(capture.windowRole, .preInterjection)
            XCTAssertEqual(capture.provenance, .observedDecodedPlayback)
            XCTAssertEqual(capture.anchorOffsetMs, 17_000)
            XCTAssertGreaterThanOrEqual(capture.durationMs, 11_500)
        }

        context.noteSeek()
        XCTAssertFalse(context.captureBufferedPreInterjection(.init(
            interjectionId: "ij-after-seek",
            sessionId: "session-pre",
            itemId: "episode-ring",
            anchorMediaTimeMs: 40_000,
            targetDurationMs: 12_000
        )))
        continuation.finish()
        #else
        throw XCTSkip("AVFoundation, MediaToolbox, and ShazamKit are required")
        #endif
    }

    // #1872: the integration run stored a pre-Margin window 319 ms short. The check on the first and last media
    // times can't see a buffer the tap never delivered, so a window with a hole inside it passed while holding
    // less audio than it claimed.
    func testPreWindowWithAHoleInsideItIsNotCapturedButAHoleOutsideItIs() async throws {
        #if canImport(AVFoundation) && canImport(ShazamKit) && canImport(MediaToolbox)
        let sampleRate = 8_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        // Feeds 20-40 s as 100 ms buffers, leaving out the ones that start inside `dropped` and starting every
        // other one `jitterMs` late.
        func fill(
            _ context: PostResumePodcastEvidenceTapContext,
            dropping dropped: Range<Int> = 0..<0,
            jitterMs: Int = 0
        ) throws {
            for tenth in 200..<400 where !dropped.contains(tenth * 100) {
                let frameCount = AVAudioFrameCount(sampleRate / 10)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
                buffer.frameLength = frameCount
                let samples = try XCTUnwrap(buffer.floatChannelData?[0])
                for frame in 0..<Int(frameCount) {
                    samples[frame] = Float(0.2 * sin(2 * .pi * (220 + Double(tenth % 40)) * Double(frame) / sampleRate))
                }
                context.process(
                    bufferList: buffer.mutableAudioBufferList,
                    frameCount: CMItemCount(frameCount),
                    timeRange: CMTimeRange(
                        start: CMTime(value: CMTimeValue(tenth * 100 + (tenth.isMultiple(of: 2) ? 0 : jitterMs)), timescale: 1_000),
                        duration: CMTime(value: 100, timescale: 1_000)
                    )
                )
            }
        }
        // The anchor is at 40 s, so the 12 s window runs 23-35 s.
        func request(_ id: String) -> PostResumeAudioSampleRequest {
            PostResumeAudioSampleRequest(
                interjectionId: id, sessionId: "session-hole", itemId: "episode-hole",
                anchorMediaTimeMs: 40_000, targetDurationMs: 12_000
            )
        }
        func makeContext(
            _ handler: @escaping @Sendable (PostResumePodcastEvidenceCaptureResult) -> Void = { _ in }
        ) -> PostResumePodcastEvidenceTapContext {
            let context = PostResumePodcastEvidenceTapContext(
                resultHandler: handler, becameIdle: {}, continuousCollection: true, itemId: "episode-hole"
            )
            context.prepare(processingFormat: format.streamDescription)
            return context
        }

        // Three buffers (300 ms) missing at 30 s: the same size of hole the run saw.
        let holed = makeContext()
        try fill(holed, dropping: 30_000..<30_300)
        XCTAssertFalse(holed.captureBufferedPreInterjection(request("ij-hole-inside")),
                       "a hole inside the window must not be stored as 12 s of audio")

        // Before the window starts (21 s), the audio the window holds is unbroken.
        let (clearResults, clearContinuation) = AsyncStream<PostResumePodcastEvidenceCaptureResult>.makeStream()
        let clear = makeContext { clearContinuation.yield($0) }
        try fill(clear, dropping: 21_000..<21_300)
        XCTAssertTrue(clear.captureBufferedPreInterjection(request("ij-hole-outside")))
        if case .captured(let capture)? = await clearResults.first(where: { _ in true }) {
            XCTAssertEqual(capture.durationMs, 12_000, accuracy: 250)
        } else {
            XCTFail("Expected the unbroken window to be captured")
        }
        clearContinuation.finish()

        // Start times a couple of milliseconds off from where the last buffer ended are rounding, not a hole.
        let (jitterResults, jitterContinuation) = AsyncStream<PostResumePodcastEvidenceCaptureResult>.makeStream()
        let jittery = makeContext { jitterContinuation.yield($0) }
        try fill(jittery, jitterMs: 2)
        XCTAssertTrue(jittery.captureBufferedPreInterjection(request("ij-jitter")))
        if case .captured(let capture)? = await jitterResults.first(where: { _ in true }) {
            XCTAssertEqual(capture.durationMs, 12_000, accuracy: 250)
        } else {
            XCTFail("Expected the jittered window to be captured")
        }
        jitterContinuation.finish()
        #else
        throw XCTSkip("AVFoundation, MediaToolbox, and ShazamKit are required")
        #endif
    }

    func testPodcastResolverFusesConsistentEvidenceAndRejectsAmbiguity() {
        let query = PodcastPortableAnchorQuery(
            packageScopedId: "margin",
            senderMediaTimeMs: 60_000,
            evidence: [],
            evidenceWasDeclared: true
        )
        let fused = PodcastAcousticAnchorResolver.resolveCandidates(
            [(timeMs: 71_000, confidence: 0.92), (timeMs: 71_600, confidence: 0.88)],
            query: query,
            senderDurationMs: 100_000,
            recipientDurationMs: 110_000,
            strongSourceIdentity: true,
            exactDigestContradiction: false
        )
        XCTAssertEqual(fused.evidenceClass, .fused)
        XCTAssertEqual(fused.localMediaTimeMs, 71_600)
        XCTAssertEqual(fused.confidence ?? -1, 0.9, accuracy: 0.0001)

        let ambiguous = PodcastAcousticAnchorResolver.resolveCandidates(
            [(timeMs: 71_000, confidence: 0.95), (timeMs: 80_000, confidence: 0.95)],
            query: query,
            senderDurationMs: 100_000,
            recipientDurationMs: 110_000,
            strongSourceIdentity: true,
            exactDigestContradiction: false
        )
        XCTAssertEqual(ambiguous.evidenceClass, .ambiguous)
        XCTAssertTrue(ambiguous.isAmbiguous)
        XCTAssertNil(ambiguous.localMediaTimeMs)

        let twoFlanks = PodcastPortableAnchorQuery(
            packageScopedId: "partial",
            senderMediaTimeMs: 60_000,
            evidence: [
                .init(id: "pre", signatureData: Data(), anchorOffsetMs: 12_500),
                .init(id: "post", signatureData: Data(), anchorOffsetMs: -500)
            ]
        )
        let partial = PodcastAcousticAnchorResolver.resolveCandidates(
            [(timeMs: 71_000, confidence: 0.92)],
            query: twoFlanks,
            senderDurationMs: 100_000,
            recipientDurationMs: 110_000,
            strongSourceIdentity: true,
            exactDigestContradiction: false
        )
        XCTAssertEqual(partial.evidenceClass, .acousticVerified)
        XCTAssertEqual(partial.localMediaTimeMs, 71_000)
        XCTAssertFalse(partial.isAmbiguous)
        XCTAssertEqual(partial.algorithmVersion, "podcast-anchor-partial-flank.v2")

        let weakPartial = PodcastAcousticAnchorResolver.resolveCandidates(
            [(timeMs: 71_000, confidence: 0.72)],
            query: twoFlanks,
            senderDurationMs: 100_000,
            recipientDurationMs: 110_000,
            strongSourceIdentity: true,
            exactDigestContradiction: false
        )
        XCTAssertEqual(weakPartial.evidenceClass, .ambiguous)
        XCTAssertTrue(weakPartial.isAmbiguous)
    }

    func testPartialFlankRequiresStableMonotonicNeighborCorroboration() {
        let queries = [
            PodcastPortableAnchorQuery(packageScopedId: "lower", senderMediaTimeMs: 100_000, evidence: []),
            PodcastPortableAnchorQuery(packageScopedId: "partial", senderMediaTimeMs: 200_000, evidence: []),
            PodcastPortableAnchorQuery(packageScopedId: "upper", senderMediaTimeMs: 300_000, evidence: [])
        ]
        let stable = PodcastAcousticAnchorResolver.corroboratePartialFlanks(
            queries: queries,
            resolutions: [
                "lower": .init(evidenceClass: .acousticVerified, localMediaTimeMs: 110_000),
                "partial": .init(
                    evidenceClass: .acousticVerified,
                    localMediaTimeMs: 210_000,
                    confidence: 0.92,
                    algorithmVersion: "podcast-anchor-partial-flank.v2"
                ),
                "upper": .init(evidenceClass: .acousticVerified, localMediaTimeMs: 310_000)
            ]
        )
        XCTAssertEqual(stable["partial"]?.evidenceClass, .acousticVerified)
        XCTAssertEqual(
            stable["partial"]?.algorithmVersion,
            "podcast-anchor-partial-flank-neighbor-corroborated.v3"
        )

        let editionChange = PodcastAcousticAnchorResolver.corroboratePartialFlanks(
            queries: queries,
            resolutions: [
                "lower": .init(evidenceClass: .acousticVerified, localMediaTimeMs: 110_000),
                "partial": .init(
                    evidenceClass: .acousticVerified,
                    localMediaTimeMs: 260_000,
                    confidence: 0.92,
                    algorithmVersion: "podcast-anchor-partial-flank.v2"
                ),
                "upper": .init(evidenceClass: .acousticVerified, localMediaTimeMs: 310_000)
            ]
        )
        XCTAssertEqual(editionChange["partial"]?.evidenceClass, .unresolved)
        XCTAssertNil(editionChange["partial"]?.localMediaTimeMs)
    }

    func testPodcastTimestampFallbackStaysDisabledAfterEqualDurationCounterexample() {
        let missingEvidence = PodcastPortableAnchorQuery(
            packageScopedId: "margin",
            senderMediaTimeMs: 60_000,
            evidence: [],
            evidenceWasDeclared: false
        )
        let fallback = PodcastAcousticAnchorResolver.resolveCandidates(
            [], query: missingEvidence, senderDurationMs: 100_000, recipientDurationMs: 100_150,
            strongSourceIdentity: true, exactDigestContradiction: false
        )
        XCTAssertEqual(fallback.evidenceClass, .unresolved)
        XCTAssertNil(fallback.localMediaTimeMs)

        let declaredButUnmatched = PodcastPortableAnchorQuery(
            packageScopedId: "margin",
            senderMediaTimeMs: 60_000,
            evidence: [],
            evidenceWasDeclared: true
        )
        // No acoustic match is insufficient proof that the passage is absent.
        // Preserve the September 14 conservative placement policy and no autoplay.
        let unmatched = PodcastAcousticAnchorResolver.resolveCandidates(
            [], query: declaredButUnmatched, senderDurationMs: 100_000, recipientDurationMs: 100_000,
            strongSourceIdentity: true, exactDigestContradiction: false
        )
        XCTAssertEqual(unmatched.evidenceClass, .unresolved)
        XCTAssertNil(unmatched.localMediaTimeMs)
        XCTAssertEqual(PodcastAcousticAnchorResolver.resolveCandidates(
            [], query: missingEvidence, senderDurationMs: 100_000, recipientDurationMs: 100_000,
            strongSourceIdentity: true, exactDigestContradiction: true
        ).evidenceClass, .unresolved)
        XCTAssertEqual(PodcastAcousticAnchorResolver.resolveCandidates(
            [], query: missingEvidence, senderDurationMs: 100_000, recipientDurationMs: 100_000,
            strongSourceIdentity: false, exactDigestContradiction: false
        ).evidenceClass, .unresolved)
        XCTAssertEqual(PodcastAcousticAnchorResolver.resolveCandidates(
            [], query: missingEvidence, senderDurationMs: 100_000, recipientDurationMs: 104_000,
            strongSourceIdentity: true, exactDigestContradiction: false
        ).evidenceClass, .unresolved)
    }

    /// The Margin's "sent without a position" wording (#872) counts context words in SessionKit, where the
    /// matcher can't be linked. It must say "usable" exactly when the matcher would try the context.
    func testSessionKitUsableContextRuleAgreesWithTheTranscriptResolver() {
        let samples: [String?] = [
            nil, "", "   ", "one two three four five", "one two three four five six", "one two three four, five —",
            "it's 3 o'clock, said José, again", "COVID-19 was 2020 and then 2021 happened", "a b c d e f g",
            "—— … !!! ??? ((( ))) ,,, ...", "naïve café résumé coöperate déjà vu again", "emoji 😀 😀 😀 😀 😀 😀 words",
            // Samples that straddle six words, where a rule that treats marks differently would disagree.
            "one two three four nai\u{308}ve", "one two three four na\u{EF}ve", "one two three four five\u{301}",
            "a\u{2764}\u{FE0F}b c d e f", "\u{2764}\u{FE0F} \u{2764}\u{FE0F} \u{2764}\u{FE0F} \u{2764}\u{FE0F} \u{2764}\u{FE0F} \u{2764}\u{FE0F}",
            "नमस्ते दोस्तों आप सब", "नमस्ते दोस्तों आप", "ก็ได้ ครับ ผม", "x²  y³ z½ 1 2 3",
        ]
        for prefix in samples {
            for suffix in samples {
                let anchor = PortableAnchorEvidence(anchorType: .media, prefix: prefix, suffix: suffix, mediaTimeMs: 1)
                XCTAssertEqual(anchor.hasUsableTextContext, PodcastTranscriptAnchorResolver.hasUsableContext(anchor),
                               "prefix \(prefix ?? "nil") suffix \(suffix ?? "nil")")
            }
        }
    }

    func testPodcastTranscriptResolutionFusionAndMonotonicGuard() {
        let prefix = "the durable prefix has exactly enough unique words here"
        let suffix = "the following suffix is also uniquely present right now"
        let timeline = TranscriptTimeline(segments: [
            .init(id: "pre", startMs: 10_000, endMs: 11_000, text: prefix),
            .init(id: "post", startMs: 12_000, endMs: 13_000, text: suffix)
        ], chapters: [])
        let anchor = PortableAnchorEvidence(
            anchorType: .transcript,
            prefix: prefix,
            suffix: suffix,
            mediaTimeMs: 11_500
        )
        let transcript = PodcastTranscriptAnchorResolver.resolve(
            anchor: anchor,
            recipientTimeline: timeline
        )
        XCTAssertEqual(transcript.evidenceClass, .transcriptVerified)
        XCTAssertEqual(transcript.localMediaTimeMs, 11_500)

        let acoustic = ImportedAnchorResolution(
            evidenceClass: .acousticVerified,
            localMediaTimeMs: 11_700,
            confidence: 0.92
        )
        let fused = PodcastAnchorFusionResolver.fuse(transcript: transcript, acoustic: acoustic)
        XCTAssertEqual(fused.evidenceClass, .fused)
        XCTAssertEqual(fused.localMediaTimeMs, 11_700)
        XCTAssertEqual(PodcastAnchorFusionResolver.fuse(
            transcript: transcript,
            acoustic: .init(evidenceClass: .acousticVerified, localMediaTimeMs: 30_000)
        ).evidenceClass, .ambiguous)

        let repeated = TranscriptTimeline(segments: timeline.segments + [
            .init(id: "repeat-pre", startMs: 30_000, endMs: 31_000, text: prefix),
            .init(id: "repeat-post", startMs: 32_000, endMs: 33_000, text: suffix)
        ], chapters: [])
        XCTAssertEqual(PodcastTranscriptAnchorResolver.resolve(
            anchor: anchor,
            recipientTimeline: repeated
        ).evidenceClass, .ambiguous)

        let fuzzyTimeline = TranscriptTimeline(segments: [
            .init(
                id: "fuzzy-pre",
                startMs: 40_000,
                endMs: 41_000,
                text: "the durable prefix has nearly enough unique words here"
            ),
            .init(
                id: "fuzzy-post",
                startMs: 42_000,
                endMs: 43_000,
                text: "the following suffix was also uniquely present right now"
            )
        ], chapters: [])
        let fuzzy = PodcastTranscriptAnchorResolver.resolve(
            anchor: anchor,
            recipientTimeline: fuzzyTimeline
        )
        XCTAssertEqual(fuzzy.evidenceClass, .transcriptVerified)
        XCTAssertEqual(fuzzy.localMediaTimeMs, 41_500)

        let transcriptOverAbsentAcoustic = PodcastAnchorFusionResolver.fuse(
            transcript: fuzzy,
            acoustic: .init(evidenceClass: .absentFromRecipientEdition)
        )
        XCTAssertEqual(transcriptOverAbsentAcoustic.evidenceClass, .transcriptVerified)
        XCTAssertEqual(transcriptOverAbsentAcoustic.localMediaTimeMs, 41_500)

        let queries = [
            PodcastPortableAnchorQuery(packageScopedId: "one", senderMediaTimeMs: 10_000, evidence: []),
            PodcastPortableAnchorQuery(packageScopedId: "two", senderMediaTimeMs: 20_000, evidence: [])
        ]
        let guarded = PodcastAnchorFusionResolver.enforcingMonotonicOrder(
            queries: queries,
            resolutions: [
                "one": .init(evidenceClass: .fused, localMediaTimeMs: 30_000),
                "two": .init(evidenceClass: .fused, localMediaTimeMs: 20_000)
            ]
        )
        XCTAssertEqual(guarded["one"]?.evidenceClass, .ambiguous)
        XCTAssertEqual(guarded["two"]?.evidenceClass, .ambiguous)

        // #917: Margins at the same moment (or whose sender times tie) are not a contradiction.
        let sameMomentQueries = [
            PodcastPortableAnchorQuery(packageScopedId: "a", senderMediaTimeMs: 10_000, evidence: []),
            PodcastPortableAnchorQuery(packageScopedId: "b", senderMediaTimeMs: 10_000, evidence: []),
            PodcastPortableAnchorQuery(packageScopedId: "c", senderMediaTimeMs: 20_000, evidence: [])
        ]
        let sameRecipientTime = PodcastAnchorFusionResolver.enforcingMonotonicOrder(
            queries: sameMomentQueries,
            resolutions: [
                "a": .init(evidenceClass: .exactEdition, localMediaTimeMs: 12_000),
                "b": .init(evidenceClass: .exactEdition, localMediaTimeMs: 12_000),
                "c": .init(evidenceClass: .exactEdition, localMediaTimeMs: 22_000)
            ]
        )
        for id in ["a", "b", "c"] {
            XCTAssertEqual(sameRecipientTime[id]?.evidenceClass, .exactEdition, id)
        }
        let tiedSenderTimesSwapped = PodcastAnchorFusionResolver.enforcingMonotonicOrder(
            queries: sameMomentQueries,
            resolutions: [
                "a": .init(evidenceClass: .acousticVerified, localMediaTimeMs: 12_400),
                "b": .init(evidenceClass: .transcriptVerified, localMediaTimeMs: 12_000),
                "c": .init(evidenceClass: .exactEdition, localMediaTimeMs: 22_000)
            ]
        )
        XCTAssertEqual(tiedSenderTimesSwapped["a"]?.evidenceClass, .acousticVerified)
        XCTAssertEqual(tiedSenderTimesSwapped["b"]?.evidenceClass, .transcriptVerified)
        XCTAssertEqual(tiedSenderTimesSwapped["c"]?.evidenceClass, .exactEdition)
        // A genuinely reversed pair (both ties against the earlier c) is still questioned.
        let reversedAmongTies = PodcastAnchorFusionResolver.enforcingMonotonicOrder(
            queries: sameMomentQueries,
            resolutions: [
                "a": .init(evidenceClass: .exactEdition, localMediaTimeMs: 12_000),
                "b": .init(evidenceClass: .exactEdition, localMediaTimeMs: 12_000),
                "c": .init(evidenceClass: .exactEdition, localMediaTimeMs: 11_000)
            ]
        )
        for id in ["a", "b", "c"] {
            XCTAssertEqual(reversedAmongTies[id]?.evidenceClass, .ambiguous, id)
        }

        let interpolationQueries = [
            PodcastPortableAnchorQuery(packageScopedId: "start", senderMediaTimeMs: 171_225, evidence: []),
            PodcastPortableAnchorQuery(packageScopedId: "middle-one", senderMediaTimeMs: 286_515, evidence: []),
            PodcastPortableAnchorQuery(packageScopedId: "middle-two", senderMediaTimeMs: 347_671, evidence: []),
            PodcastPortableAnchorQuery(packageScopedId: "end", senderMediaTimeMs: 397_596, evidence: [])
        ]
        let interpolated = PodcastAnchorFusionResolver.interpolatingBetweenVerifiedAnchors(
            queries: interpolationQueries,
            resolutions: [
                "start": .init(evidenceClass: .acousticVerified, localMediaTimeMs: 173_054, confidence: 0.9),
                "middle-one": .init(evidenceClass: .absentFromRecipientEdition),
                "middle-two": .init(evidenceClass: .absentFromRecipientEdition),
                "end": .init(evidenceClass: .fused, localMediaTimeMs: 413_195, confidence: 1)
            ]
        )
        XCTAssertEqual(interpolated["middle-one"]?.evidenceClass, .mapInterpolated)
        XCTAssertEqual(interpolated["middle-one"]?.localMediaTimeMs, 302_114)
        XCTAssertEqual(interpolated["middle-two"]?.evidenceClass, .mapInterpolated)
        XCTAssertEqual(interpolated["middle-two"]?.localMediaTimeMs, 363_270)

        let noExtrapolation = PodcastAnchorFusionResolver.interpolatingBetweenVerifiedAnchors(
            queries: interpolationQueries,
            resolutions: [
                "start": .init(evidenceClass: .unresolved),
                "middle-one": .init(evidenceClass: .unresolved),
                "middle-two": .init(evidenceClass: .acousticVerified, localMediaTimeMs: 363_270),
                "end": .init(evidenceClass: .transcriptVerified, localMediaTimeMs: 413_195)
            ]
        )
        XCTAssertEqual(noExtrapolation["start"]?.evidenceClass, .unresolved)
    }

    func testPodcastResolverMathBenchmarkHasNoFalseConfidentPlacements() {
        var confidentErrors: [Int] = []
        var falseConfidentCount = 0
        for index in 0..<250 {
            let expected = 30_000 + index * 5_000
            let query = PodcastPortableAnchorQuery(
                packageScopedId: "margin-\(index)",
                senderMediaTimeMs: expected,
                evidence: [],
                evidenceWasDeclared: true
            )
            let isAdversarial = index.isMultiple(of: 10)
            let candidates = isAdversarial
                ? [(timeMs: expected - 8_000, confidence: 0.95), (timeMs: expected + 8_000, confidence: 0.95)]
                : [(timeMs: expected - 240, confidence: 0.91), (timeMs: expected + 310, confidence: 0.89)]
            let result = PodcastAcousticAnchorResolver.resolveCandidates(
                candidates,
                query: query,
                senderDurationMs: 2_000_000,
                recipientDurationMs: 2_060_000,
                strongSourceIdentity: true,
                exactDigestContradiction: false
            )
            if isAdversarial {
                if result.localMediaTimeMs != nil { falseConfidentCount += 1 }
                XCTAssertEqual(result.evidenceClass, .ambiguous)
            } else if let resolved = result.localMediaTimeMs {
                confidentErrors.append(abs(resolved - expected))
                if abs(resolved - expected) > PodcastAcousticAnchorResolver.maximumFusionSpreadMs {
                    falseConfidentCount += 1
                }
            }
        }
        let sortedErrors = confidentErrors.sorted()
        let p95Index = Int((Double(sortedErrors.count - 1) * 0.95).rounded(.up))
        XCTAssertEqual(falseConfidentCount, 0)
        XCTAssertGreaterThanOrEqual(confidentErrors.count, 200)
        XCTAssertLessThanOrEqual(sortedErrors[p95Index], 1_500)
    }

    /// The ambiguity rule itself: when a Margin's two flanks place it more than the fusion spread apart,
    /// the resolver declines to place it. An ad inserted between the flanks does exactly this: the "pre"
    /// flank (anchor offset +11.5 s) still lands at 42 s, the "post" flank (−0.5 s) after the 7 s ad.
    ///
    /// Two flanks that agree on the same wrong place look like agreement here. Repeated audio can cause it
    /// (#296), so `resolve` first looks for another copy of each flank's audio (#331; see the repeated-theme test).
    func testAcousticResolverDeclinesFlanksThatDisagreeByMoreThanTheFusionSpread() {
        let query = PodcastPortableAnchorQuery(
            packageScopedId: "margin-at-an-inserted-ad",
            senderMediaTimeMs: 42_000,
            evidence: [
                PodcastAcousticEvidenceQuery(id: "pre", signatureData: Data([1]), anchorOffsetMs: 11_500),
                PodcastAcousticEvidenceQuery(id: "post", signatureData: Data([2]), anchorOffsetMs: -500)
            ]
        )
        func resolve(_ candidates: [(timeMs: Int, confidence: Double)]) -> ImportedAnchorResolution {
            PodcastAcousticAnchorResolver.resolveCandidates(
                candidates,
                query: query,
                senderDurationMs: 75_000,
                recipientDurationMs: 82_000,
                strongSourceIdentity: true,
                exactDigestContradiction: false,
                matchedAnchorOffsets: [11_500, -500]
            )
        }
        let spread = PodcastAcousticAnchorResolver.maximumFusionSpreadMs
        for disagreement in [spread + 1, 7_000, 23_000] {
            let declined = resolve([(42_000, 0.97), (42_000 + disagreement, 0.96)])
            XCTAssertEqual(declined.evidenceClass, .ambiguous, "flanks \(disagreement) ms apart")
            XCTAssertTrue(declined.isAmbiguous)
            XCTAssertNil(declined.localMediaTimeMs, "an ambiguous Margin is not placed")
        }
        let fused = resolve([(49_000, 0.97), (49_000 + spread, 0.96)])
        XCTAssertEqual(fused.evidenceClass, .fused)
        XCTAssertEqual(fused.localMediaTimeMs, 49_000 + spread)
    }

    /// The wrong-episode rule (#456) on its own: when at most half of a packet's flanks found the recipient's
    /// edition, even a Margin whose two flanks agree is not placed. A majority, or a single Margin, is unchanged.
    func testAcousticResolverPlacesNothingWhenMostEvidenceMissesTheEdition() throws {
        let placed = ImportedAnchorResolution(
            evidenceClass: .fused, localMediaTimeMs: 10_000, confidence: 0.95, algorithmVersion: "podcast-anchor.v1"
        )
        let unresolved = ImportedAnchorResolution(evidenceClass: .unresolved, algorithmVersion: "podcast-anchor.v1")
        let packet = ["inside-intro": placed, "after-intro": unresolved, "deep-content": unresolved]

        let wrongEpisode = PodcastAcousticAnchorResolver.requiringEditionConfirmation(
            packet, matchedFlanks: 3, answeredFlanks: 6
        )
        XCTAssertNil(wrongEpisode["inside-intro"]?.localMediaTimeMs)
        XCTAssertEqual(wrongEpisode["inside-intro"]?.evidenceClass, .unresolved)
        XCTAssertEqual(wrongEpisode["inside-intro"]?.algorithmVersion, "podcast-anchor-edition-unconfirmed.v1")
        // Unplaced Margins carry the verdict too, so later evidence can't place them on this edition.
        XCTAssertEqual(wrongEpisode["deep-content"]?.algorithmVersion, "podcast-anchor-edition-unconfirmed.v1")
        XCTAssertTrue(wrongEpisode.values.allSatisfy(PodcastAcousticAnchorResolver.isEditionRejection))

        // One of three Margins inside a replaced ad: most evidence still found the edition.
        XCTAssertEqual(PodcastAcousticAnchorResolver.requiringEditionConfirmation(
            packet, matchedFlanks: 4, answeredFlanks: 6
        ), packet)
        // A single Margin can't show the edition is wrong, so it keeps its placement.
        XCTAssertEqual(PodcastAcousticAnchorResolver.requiringEditionConfirmation(
            ["only": placed], matchedFlanks: 2, answeredFlanks: 2
        ), ["only": placed])
        // No flank matched: no shared audio to guard against, so the transcript still decides.
        XCTAssertEqual(PodcastAcousticAnchorResolver.requiringEditionConfirmation(
            packet, matchedFlanks: 0, answeredFlanks: 6
        ), packet)
        // An ambiguous Margin carries the verdict too, so it can't keep an earlier placement.
        let ambiguous = ImportedAnchorResolution(evidenceClass: .ambiguous, isAmbiguous: true)
        XCTAssertTrue(PodcastAcousticAnchorResolver.isEditionRejection(try XCTUnwrap(
            PodcastAcousticAnchorResolver.requiringEditionConfirmation(
                ["intro-theme": ambiguous, "after-intro": unresolved, "deep-content": unresolved],
                matchedFlanks: 2, answeredFlanks: 6
            )["intro-theme"]
        )))
    }

    /// A Margin's flank can carry two signature variants, one captured during playback and one cut from the
    /// source window. When the playback pair matches and the source pair doesn't, that is one Margin with both
    /// flanks matched, not two of four flanks missing, so the wrong-episode rule leaves it placed (#543 audit).
    func testSignatureVariantsOfOneFlankCountOnceForTheEditionCheck() {
        typealias Answer = PodcastAcousticAnchorResolver.EditionFlankAnswer
        let oneMargin = [
            Answer(marginId: "m1", anchorOffsetMs: 11_500, matched: true),   // playback, before the anchor
            Answer(marginId: "m1", anchorOffsetMs: -500, matched: true),     // playback, after the anchor
            Answer(marginId: "m1", anchorOffsetMs: 11_500, matched: false),  // source window, before
            Answer(marginId: "m1", anchorOffsetMs: -500, matched: false)     // source window, after
        ]
        let counts = PodcastAcousticAnchorResolver.editionFlankCounts(oneMargin)
        XCTAssertEqual(counts.answered, 2)
        XCTAssertEqual(counts.matched, 2)
        let placed = ImportedAnchorResolution(
            evidenceClass: .fused, localMediaTimeMs: 10_000, confidence: 0.95, algorithmVersion: "podcast-anchor.v1"
        )
        XCTAssertEqual(PodcastAcousticAnchorResolver.requiringEditionConfirmation(
            ["m1": placed], matchedFlanks: counts.matched, answeredFlanks: counts.answered
        ), ["m1": placed])

        // Flanks of different Margins still count separately: one placed Margin and two that found nothing.
        let packet = oneMargin + [
            Answer(marginId: "m2", anchorOffsetMs: 11_500, matched: false),
            Answer(marginId: "m2", anchorOffsetMs: -500, matched: false),
            Answer(marginId: "m3", anchorOffsetMs: 11_500, matched: false),
            Answer(marginId: "m3", anchorOffsetMs: -500, matched: false)
        ]
        let packetCounts = PodcastAcousticAnchorResolver.editionFlankCounts(packet)
        XCTAssertEqual(packetCounts.answered, 6)
        XCTAssertEqual(packetCounts.matched, 2)
    }

    /// The wrong-episode verdict (#456) survives the app's pipeline. The shared intro's words match the
    /// recipient's transcript, and fusion alone would place that Margin from the transcript; the final
    /// resolutions carry the verdict instead. A verified placement stored by an earlier pass on the same
    /// edition is withdrawn too, while a listener's own confirmation stays.
    func testEditionRejectionSurvivesTranscriptFusionAndStoredPlacements() throws {
        let placed = ImportedAnchorResolution(
            evidenceClass: .fused, localMediaTimeMs: 10_000, confidence: 0.95, algorithmVersion: "podcast-anchor.v1"
        )
        let unresolved = ImportedAnchorResolution(evidenceClass: .unresolved, algorithmVersion: "podcast-anchor.v1")
        let acoustic = PodcastAcousticAnchorResolver.requiringEditionConfirmation(
            ["inside-intro": placed, "after-intro": unresolved, "deep-content": unresolved],
            matchedFlanks: 2, answeredFlanks: 6
        )
        let introTranscript = ImportedAnchorResolution(
            evidenceClass: .transcriptVerified, localMediaTimeMs: 10_200, confidence: 0.9,
            algorithmVersion: "podcast-transcript-anchor.v1"
        )
        let fused = acoustic.mapValues { acousticResolution in
            PodcastAnchorFusionResolver.fuse(transcript: introTranscript, acoustic: acousticResolution)
        }
        XCTAssertNotNil(fused["inside-intro"]?.localMediaTimeMs, "fusion alone places the intro Margin")

        let final = PodcastAnchorFusionResolver.enforcingEditionRejection(acoustic: acoustic, resolutions: fused)
        for (id, resolution) in final {
            XCTAssertNil(resolution.localMediaTimeMs, id)
            XCTAssertTrue(PodcastAcousticAnchorResolver.isEditionRejection(resolution), id)
        }
        // Without the verdict, fusion's result passes through unchanged.
        XCTAssertEqual(PodcastAnchorFusionResolver.enforcingEditionRejection(acoustic: ["m": placed], resolutions: fused), fused)

        let rejection = try XCTUnwrap(acoustic["inside-intro"])
        XCTAssertEqual(PodcastAnchorFusionResolver.preservingVerifiedPlacement(
            previous: placed, proposed: rejection, previousEdition: "edition-b", currentEdition: "edition-b",
            hasTranscript: false
        ), rejection, "a stored machine placement on the rejected edition is withdrawn")
        let confirmed = ImportedAnchorResolution(
            evidenceClass: .recipientConfirmed, localMediaTimeMs: 10_000, confidence: 1, algorithmVersion: "recipient.v1"
        )
        XCTAssertEqual(PodcastAnchorFusionResolver.preservingVerifiedPlacement(
            previous: confirmed, proposed: rejection, previousEdition: "edition-b", currentEdition: "edition-b",
            hasTranscript: false
        ), confirmed, "a listener's confirmation stays")
        // An ordinary unresolved pass still keeps the stored placement.
        XCTAssertEqual(PodcastAnchorFusionResolver.preservingVerifiedPlacement(
            previous: placed, proposed: unresolved, previousEdition: "edition-b", currentEdition: "edition-b",
            hasTranscript: false
        ), placed)
    }

    /// A stored wrong-episode verdict (#456) survives a later pass on the same edition that lost evidence. With
    /// the acoustic step failed, only the transcript of the shared intro is left (Codex audit on 75b32ad). With
    /// only the intro's flanks answered, the edition check is skipped and the intro fuses (Codex audit on
    /// 2e6228e). Either would place the Margin on the rejected episode. A listener's confirmation, the sender's
    /// exact file or another edition lifts the verdict.
    func testStoredEditionRejectionSurvivesATranscriptOnlyPass() throws {
        let rejection = try XCTUnwrap(PodcastAcousticAnchorResolver.requiringEditionConfirmation(
            ["inside-intro": ImportedAnchorResolution(evidenceClass: .unresolved), "a": .init(evidenceClass: .unresolved),
             "b": .init(evidenceClass: .unresolved)],
            matchedFlanks: 2, answeredFlanks: 6
        )["inside-intro"])
        XCTAssertTrue(PodcastAcousticAnchorResolver.isEditionRejection(rejection))

        // The failed acoustic pass leaves fusion only the transcript of the shared intro.
        let introTranscript = ImportedAnchorResolution(
            evidenceClass: .transcriptVerified, localMediaTimeMs: 10_200, confidence: 0.9,
            algorithmVersion: "podcast-transcript-anchor.v1"
        )
        let transcriptOnly = PodcastAnchorFusionResolver.fuse(
            transcript: introTranscript, acoustic: ImportedAnchorResolution(evidenceClass: .unresolved)
        )
        XCTAssertNotNil(transcriptOnly.localMediaTimeMs, "fusion alone places the intro Margin")
        XCTAssertEqual(PodcastAnchorFusionResolver.preservingVerifiedPlacement(
            previous: rejection, proposed: transcriptOnly, previousEdition: "edition-b", currentEdition: "edition-b",
            hasTranscript: true
        ), rejection, "the stored verdict stays on the same edition")

        // The content flanks error on retry, so only the intro's two flanks answer: too few for the edition
        // check, and the intro fuses on its own.
        let flanks = PodcastAcousticAnchorResolver.editionFlankCounts([
            .init(marginId: "inside-intro", anchorOffsetMs: 11_500, matched: true),
            .init(marginId: "inside-intro", anchorOffsetMs: -500, matched: true)
        ])
        let introFused = ImportedAnchorResolution(
            evidenceClass: .fused, localMediaTimeMs: 10_000, confidence: 0.95, algorithmVersion: "podcast-anchor.v1"
        )
        let retry = PodcastAcousticAnchorResolver.requiringEditionConfirmation(
            ["inside-intro": introFused, "a": .init(evidenceClass: .unresolved), "b": .init(evidenceClass: .unresolved)],
            matchedFlanks: flanks.matched, answeredFlanks: flanks.answered
        )
        XCTAssertEqual(retry["inside-intro"], introFused, "the partial retry places the intro on its own")
        XCTAssertEqual(PodcastAnchorFusionResolver.preservingVerifiedPlacement(
            previous: rejection, proposed: introFused, previousEdition: "edition-b", currentEdition: "edition-b",
            hasTranscript: true
        ), rejection, "a partial acoustic retry doesn't lift the stored verdict")
        let exact = ImportedAnchorResolution(
            evidenceClass: .exactEdition, localMediaTimeMs: 10_000, confidence: 1, algorithmVersion: "exact-edition.v1"
        )
        XCTAssertEqual(PodcastAnchorFusionResolver.preservingVerifiedPlacement(
            previous: rejection, proposed: exact, previousEdition: "edition-b", currentEdition: "edition-b",
            hasTranscript: false
        ), exact, "the sender's exact file lifts the verdict")
        let confirmed = ImportedAnchorResolution(
            evidenceClass: .recipientConfirmed, localMediaTimeMs: 10_000, confidence: 1, algorithmVersion: "recipient.v1"
        )
        XCTAssertEqual(PodcastAnchorFusionResolver.preservingVerifiedPlacement(
            previous: rejection, proposed: confirmed, previousEdition: "edition-b", currentEdition: "edition-b",
            hasTranscript: false
        ), confirmed, "a listener's confirmation lifts the verdict")
        XCTAssertEqual(PodcastAnchorFusionResolver.preservingVerifiedPlacement(
            previous: rejection, proposed: transcriptOnly, previousEdition: "edition-b", currentEdition: "edition-c",
            hasTranscript: true
        ), transcriptOnly, "a different edition starts afresh")
    }

    /// Flanks ShazamKit can't answer for say nothing about the edition. Evidence recorded before Build 29 is
    /// 12 s and every query errors; an unreadable signature is skipped. Such a packet on the right episode must
    /// not be rejected as a different edition, or its transcript placements would be withdrawn.
    func testUnanswerableEvidenceDoesNotRejectTheEdition() async throws {
        #if canImport(AVFoundation)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recipientURL = root.appendingPathComponent("recipient.m4a")
        try SeededNoiseAudio.write(to: recipientURL, seconds: 40)
        let queries = (1...3).map { index in
            PodcastPortableAnchorQuery(
                packageScopedId: "margin-\(index)",
                senderMediaTimeMs: index * 10_000,
                evidence: [
                    PodcastAcousticEvidenceQuery(id: "pre-\(index)", signatureData: Data([1, 2, 3]), anchorOffsetMs: 11_500),
                    PodcastAcousticEvidenceQuery(id: "post-\(index)", signatureData: Data([4, 5, 6]), anchorOffsetMs: -500)
                ]
            )
        }
        let resolutions = try await PodcastAcousticAnchorResolver.resolve(
            queries: queries,
            recipientAudioURL: recipientURL,
            senderExactEditionSHA256: nil,
            senderDurationMs: 40_000,
            strongSourceIdentity: true
        )
        XCTAssertEqual(resolutions.count, 3)
        for (id, resolution) in resolutions {
            XCTAssertFalse(PodcastAcousticAnchorResolver.isEditionRejection(resolution), id)
        }
        #else
        throw XCTSkip("AVFoundation is required")
        #endif
    }

    /// The same rule end to end, on audio that never repeats: a 7 s ad inserted right at the Margin, between
    /// its two flanks, so the flanks honestly disagree by 7 s. (This used a tone fixture that repeated every
    /// 23 s, with the ad before both flanks; its verdict depended on which copy each flank matched, #296.)
    func testAcousticResolverDeclinesConflictingSyntheticMatchesAcrossInsertedAd() async throws {
        #if canImport(AVFoundation)
        let resolution = try await resolveSyntheticAdEdition(adInsertedAtMs: 42_000, anchorMs: 42_000)
        XCTAssertEqual(resolution.evidenceClass, .ambiguous)
        XCTAssertNil(resolution.localMediaTimeMs)
        #else
        throw XCTSkip("AVFoundation is required")
        #endif
    }

    /// The counterpart: an ad before both flanks shifts the Margin by the ad's length, and both flanks agree.
    func testAcousticResolverPlacesAMarginAfterAnInsertedAdByTheAdsLength() async throws {
        #if canImport(AVFoundation)
        let resolution = try await resolveSyntheticAdEdition(adInsertedAtMs: 25_000, anchorMs: 42_000)
        XCTAssertEqual(resolution.evidenceClass, .fused)
        let placed = try XCTUnwrap(resolution.localMediaTimeMs)
        XCTAssertLessThanOrEqual(abs(placed - 49_000), PodcastAcousticAnchorResolver.maximumFusionSpreadMs)
        #else
        throw XCTSkip("AVFoundation is required")
        #endif
    }

    /// The wrong episode (#456): the recipient's copy is another episode of the same show. It shares only a
    /// 20 s intro with the sender's, then has different content, and is the same length, so neither a digest nor
    /// the duration gives it away (the streamed case). No Margin may be placed on it: not one inside the shared
    /// intro, not one just after it, and not one deep in the content.
    func testAcousticResolverPlacesNoMarginOnADifferentEpisodeThatSharesTheIntro() async throws {
        #if canImport(AVFoundation)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let senderURL = root.appendingPathComponent("sender.m4a")
        let introURL = root.appendingPathComponent("intro.m4a")
        let otherContentURL = root.appendingPathComponent("other-episode-content.m4a")
        let recipientURL = root.appendingPathComponent("recipient-other-episode.m4a")
        try SeededNoiseAudio.write(to: senderURL, seconds: 75)
        // The same seed from second 0 gives the sender's first 20 s again: the show's intro.
        try SeededNoiseAudio.write(to: introURL, seconds: 20)
        try SeededNoiseAudio.write(to: otherContentURL, seconds: 55, seed: 0xBF58476D1CE4E5B9, startSecond: 1_200)
        try await concatenateAudio([introURL, otherContentURL], destinationURL: recipientURL)
        let margins = [("inside-intro", 10_000), ("after-intro", 26_000), ("deep-content", 55_000)]
        var queries: [PodcastPortableAnchorQuery] = []
        for (id, anchorMs) in margins {
            let generated = try await PodcastAnchorEvidenceGenerator.generate(
                sourceURL: senderURL,
                anchorMediaTimeMs: anchorMs,
                outputDirectory: root.appendingPathComponent("evidence"),
                idPrefix: id
            )
            XCTAssertEqual(generated.count, 2, id)
            queries.append(PodcastPortableAnchorQuery(
                packageScopedId: id,
                senderMediaTimeMs: anchorMs,
                evidence: try generated.map {
                    PodcastAcousticEvidenceQuery(
                        id: $0.id,
                        signatureData: try Data(contentsOf: $0.fileURL),
                        anchorOffsetMs: $0.anchorOffsetMs
                    )
                }
            ))
        }
        // Strong identity is the worst case: the item match said "same episode", and only the audio disagrees.
        let resolutions = try await PodcastAcousticAnchorResolver.resolve(
            queries: queries,
            recipientAudioURL: recipientURL,
            senderExactEditionSHA256: nil,
            senderDurationMs: 75_000,
            strongSourceIdentity: true
        )
        for (id, _) in margins {
            let resolution = try XCTUnwrap(resolutions[id], id)
            let observed = "\(id): \(resolution.evidenceClass) at \(resolution.localMediaTimeMs.map(String.init) ?? "nil")"
                + " (\(resolution.algorithmVersion))"
            XCTAssertNil(resolution.localMediaTimeMs, observed)
            XCTAssertTrue([.unresolved, .ambiguous].contains(resolution.evidenceClass), observed)
        }
        #else
        throw XCTSkip("AVFoundation is required")
        #endif
    }

    /// A flank that also matches elsewhere in the edition declines the Margin, whatever the flanks agree on.
    func testAcousticResolverDeclinesAMarginWhoseFlankRepeatsElsewhere() {
        let query = PodcastPortableAnchorQuery(
            packageScopedId: "margin-next-to-a-theme",
            senderMediaTimeMs: 49_000,
            evidence: [
                PodcastAcousticEvidenceQuery(id: "pre", signatureData: Data([1]), anchorOffsetMs: 11_500),
                PodcastAcousticEvidenceQuery(id: "post", signatureData: Data([2]), anchorOffsetMs: -500)
            ]
        )
        let declined = PodcastAcousticAnchorResolver.resolveCandidates(
            [(72_000, 0.97), (72_002, 0.96)],
            query: query,
            senderDurationMs: 120_000,
            recipientDurationMs: 120_000,
            strongSourceIdentity: true,
            exactDigestContradiction: false,
            matchedAnchorOffsets: [11_500, -500],
            matchedRepeatedAudio: true
        )
        XCTAssertEqual(declined.evidenceClass, .ambiguous)
        XCTAssertTrue(declined.isAmbiguous)
        XCTAssertNil(declined.localMediaTimeMs)
    }

    /// Repeated audio end to end (#331): a 15 s theme opens the edition and comes back to close it. A Margin
    /// with a flank wholly inside either copy could be placed at the other copy, so none of them is placed;
    /// Margins whose flanks are clear of the theme still are. Sender and recipient have the same audio, but
    /// the exact-edition shortcut is off, so every Margin goes through acoustic matching.
    func testAcousticResolverDoesNotPlaceMarginsNextToRepeatedAudio() async throws {
        #if canImport(AVFoundation)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let editionURL = root.appendingPathComponent("edition.m4a")
        let theme = SeededNoiseAudio.Section(seed: 0xA0761D6478BD642F, startSecond: 900, seconds: 15)
        try SeededNoiseAudio.write(to: editionURL, sections: [theme, SeededNoiseAudio.Section(seconds: 70), theme])
        // The theme plays at 0–15 s and 85–100 s. Flanks are 11 s, 0.5 s either side of the Margin.
        let nextToRepeat = [
            2_000,  // only a post flank (2.5–13.5 s), inside the first copy
            14_000, // pre flank 2.5–13.5 s inside the first copy
            86_000, // post flank 86.5–97.5 s inside the second copy
            99_000  // only a pre flank (87.5–98.5 s), inside the second copy
        ]
        let controls = [40_000, 55_000, 70_000] // both flanks inside 15–85 s, which plays once
        var queries: [PodcastPortableAnchorQuery] = []
        for anchorMs in nextToRepeat + controls {
            let generated = try await PodcastAnchorEvidenceGenerator.generate(
                sourceURL: editionURL,
                anchorMediaTimeMs: anchorMs,
                outputDirectory: root.appendingPathComponent("evidence"),
                idPrefix: "margin-\(anchorMs)"
            )
            queries.append(PodcastPortableAnchorQuery(
                packageScopedId: "margin-\(anchorMs)",
                senderMediaTimeMs: anchorMs,
                evidence: try generated.map {
                    PodcastAcousticEvidenceQuery(
                        id: $0.id,
                        signatureData: try Data(contentsOf: $0.fileURL),
                        anchorOffsetMs: $0.anchorOffsetMs
                    )
                }
            ))
        }
        let resolutions = try await PodcastAcousticAnchorResolver.resolve(
            queries: queries,
            recipientAudioURL: editionURL,
            senderExactEditionSHA256: nil,
            senderDurationMs: 100_000,
            strongSourceIdentity: true
        )
        let tolerance = PodcastAcousticAnchorResolver.maximumFusionSpreadMs
        var falseConfident: [String] = []
        for anchorMs in nextToRepeat + controls {
            let resolution = try XCTUnwrap(resolutions["margin-\(anchorMs)"])
            if let placed = resolution.localMediaTimeMs, abs(placed - anchorMs) > tolerance {
                falseConfident.append("\(anchorMs) ms placed at \(placed) ms (\(resolution.evidenceClass))")
            }
        }
        XCTAssertEqual(falseConfident, [], "no Margin is placed more than 1.5 s from where it was recorded")
        for anchorMs in nextToRepeat {
            let resolution = try XCTUnwrap(resolutions["margin-\(anchorMs)"])
            XCTAssertTrue(
                resolution.evidenceClass == .ambiguous || resolution.evidenceClass == .unresolved,
                "Margin at \(anchorMs) ms next to the repeat came back \(resolution.evidenceClass)"
            )
            XCTAssertNil(resolution.localMediaTimeMs, "Margin at \(anchorMs) ms next to the repeat is not placed")
        }
        for anchorMs in controls {
            let resolution = try XCTUnwrap(resolutions["margin-\(anchorMs)"])
            let placed = try XCTUnwrap(resolution.localMediaTimeMs, "control Margin at \(anchorMs) ms is placed")
            XCTAssertLessThanOrEqual(abs(placed - anchorMs), tolerance, "control Margin at \(anchorMs) ms")
        }
        #else
        throw XCTSkip("AVFoundation is required")
        #endif
    }

    #if canImport(AVFoundation)
    /// A 75 s sender edition of seeded noise, and a recipient edition with a 7 s ad of other audio inserted.
    private func resolveSyntheticAdEdition(adInsertedAtMs: Int, anchorMs: Int) async throws -> ImportedAnchorResolution {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let senderURL = root.appendingPathComponent("sender.m4a")
        let adURL = root.appendingPathComponent("recipient-ad.m4a")
        let recipientURL = root.appendingPathComponent("recipient.m4a")
        try SeededNoiseAudio.write(to: senderURL, seconds: 75)
        try SeededNoiseAudio.write(to: adURL, seconds: 7, seed: 0xD1B54A32D192ED03, startSecond: 600)
        try await composeRecipientEdition(
            senderURL: senderURL,
            insertedAudioURL: adURL,
            insertionTimeMs: adInsertedAtMs,
            destinationURL: recipientURL
        )
        let generated = try await PodcastAnchorEvidenceGenerator.generate(
            sourceURL: senderURL,
            anchorMediaTimeMs: anchorMs,
            outputDirectory: root.appendingPathComponent("evidence"),
            idPrefix: "ad-shift"
        )
        XCTAssertEqual(generated.count, 2)
        let query = PodcastPortableAnchorQuery(
            packageScopedId: "shifted-margin",
            senderMediaTimeMs: anchorMs,
            evidence: try generated.map {
                PodcastAcousticEvidenceQuery(
                    id: $0.id,
                    signatureData: try Data(contentsOf: $0.fileURL),
                    anchorOffsetMs: $0.anchorOffsetMs
                )
            }
        )
        let resolutions = try await PodcastAcousticAnchorResolver.resolve(
            queries: [query],
            recipientAudioURL: recipientURL,
            senderExactEditionSHA256: nil,
            senderDurationMs: 75_000,
            strongSourceIdentity: true
        )
        return try XCTUnwrap(resolutions[query.packageScopedId])
    }
    #endif

    func testHeldOutPublicDomainPodcastAnchorCorpus() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SPOKEN_MARGINS_RUN_ANCHOR_CORPUS"] == "1",
              let senderPath = environment["SPOKEN_MARGINS_BENCHMARK_SENDER_AUDIO"],
              let recipientPath = environment["SPOKEN_MARGINS_BENCHMARK_RECIPIENT_AUDIO"],
              let senderTranscriptPath = environment["SPOKEN_MARGINS_BENCHMARK_SENDER_TRANSCRIPT"],
              let recipientTranscriptPath = environment["SPOKEN_MARGINS_BENCHMARK_RECIPIENT_TRANSCRIPT"] else {
            throw XCTSkip("Run scripts/run-podcast-anchor-benchmark.sh to execute the held-out corpus.")
        }
        let senderURL = URL(fileURLWithPath: senderPath)
        let recipientURL = URL(fileURLWithPath: recipientPath)
        let senderTimeline = try whisperTimeline(from: URL(fileURLWithPath: senderTranscriptPath))
        let recipientTimeline = try whisperTimeline(from: URL(fileURLWithPath: recipientTranscriptPath))
        let evidenceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpokenMarginsHeldOutEvidence-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: evidenceDirectory) }

        let senderTimes = Array(stride(from: 20_000, through: 1_175_000, by: 5_000))
        var expectedRecipientTimes: [String: Int] = [:]
        var queries: [PodcastPortableAnchorQuery] = []
        var anchors: [String: PortableAnchorEvidence] = [:]
        let generationStarted = Date()
        for (index, senderTime) in senderTimes.enumerated() {
            let id = "held-out-\(String(format: "%04d", index + 1))"
            let context = try XCTUnwrap(SourceAnchorContextResolver.resolve(
                mediaTimeMs: senderTime,
                timeline: senderTimeline
            ))
            anchors[id] = PortableAnchorEvidence(
                anchorType: .transcript,
                prefix: context.anchorBefore,
                suffix: context.anchorAfter,
                mediaTimeMs: senderTime
            ).bounded()
            let generated = try await PodcastAnchorEvidenceGenerator.generate(
                sourceURL: senderURL,
                anchorMediaTimeMs: senderTime,
                outputDirectory: evidenceDirectory,
                idPrefix: id
            )
            queries.append(PodcastPortableAnchorQuery(
                packageScopedId: id,
                senderMediaTimeMs: senderTime,
                evidence: try generated.map {
                    PodcastAcousticEvidenceQuery(
                        id: $0.id,
                        signatureData: try Data(contentsOf: $0.fileURL),
                        anchorOffsetMs: $0.anchorOffsetMs
                    )
                }
            ))
            expectedRecipientTimes[id] = expectedRecipientTime(forBenchmarkSenderTime: senderTime) ?? -1
        }
        let generationSeconds = Date().timeIntervalSince(generationStarted)
        let resolutionStarted = Date()
        let acousticResolutions = try await PodcastAcousticAnchorResolver.resolve(
            queries: queries,
            recipientAudioURL: recipientURL,
            senderExactEditionSHA256: nil,
            senderDurationMs: 1_200_000,
            strongSourceIdentity: true
        )
        let resolutionSeconds = Date().timeIntervalSince(resolutionStarted)
        let transcriptResolutions = Dictionary(uniqueKeysWithValues: queries.map { query in
            (
                query.packageScopedId,
                PodcastTranscriptAnchorResolver.resolve(
                    anchor: anchors[query.packageScopedId] ?? .init(anchorType: .transcript),
                    recipientTimeline: recipientTimeline
                )
            )
        })
        let unguardedFused = Dictionary(uniqueKeysWithValues: queries.map { query in
            (
                query.packageScopedId,
                PodcastAnchorFusionResolver.fuse(
                    transcript: transcriptResolutions[query.packageScopedId]
                        ?? .init(evidenceClass: .unresolved),
                    acoustic: acousticResolutions[query.packageScopedId]
                        ?? .init(evidenceClass: .unresolved)
                )
            )
        })
        let fusedResolutions = PodcastAnchorFusionResolver.enforcingMonotonicOrder(
            queries: queries,
            resolutions: unguardedFused
        )
        let timestampResolutions = Dictionary(uniqueKeysWithValues: queries.map { query in
            (
                query.packageScopedId,
                ImportedAnchorResolution(
                    evidenceClass: .timestampFallback,
                    localMediaTimeMs: query.senderMediaTimeMs,
                    confidence: 0.6,
                    algorithmVersion: "benchmark-timestamp-only.v1"
                )
            )
        })

        let eligibleCount = expectedRecipientTimes.values.filter { $0 >= 0 }.count
        let absentCount = expectedRecipientTimes.count - eligibleCount
        let timestampMetrics = benchmarkMetrics(
            queries: queries,
            expectedRecipientTimes: expectedRecipientTimes,
            resolutions: timestampResolutions
        )
        let transcriptMetrics = benchmarkMetrics(
            queries: queries,
            expectedRecipientTimes: expectedRecipientTimes,
            resolutions: transcriptResolutions
        )
        let acousticMetrics = benchmarkMetrics(
            queries: queries,
            expectedRecipientTimes: expectedRecipientTimes,
            resolutions: acousticResolutions
        )
        let fusedMetrics = benchmarkMetrics(
            queries: queries,
            expectedRecipientTimes: expectedRecipientTimes,
            resolutions: fusedResolutions
        )
        let result: [String: Any] = [
            "schemaVersion": "spoken-margins.anchor-benchmark-result.v1",
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "corpus": [
                "source": "LibriVox / Internet Archive: The Adventures of Sherlock Holmes (version 5), chapter 4",
                "license": "Public Domain Mark 1.0",
                "partition": "held_out_after_rule_freeze",
                "pairedEditionTransformations": [
                    "45-second inserted speech advertisement",
                    "20-second publisher correction deletion",
                    "40-second repeated source passage",
                    "6-second silence/edit deletion",
                    "MP3-to-AAC re-encoding"
                ]
            ],
            "anchors": [
                "total": queries.count,
                "eligible": eligibleCount,
                "absent": absentCount
            ],
            "timestampOnly": timestampMetrics.dictionary,
            "transcript": transcriptMetrics.dictionary,
            "acoustic": acousticMetrics.dictionary.merging([
                "evidenceGenerationSeconds": generationSeconds,
                "resolutionSeconds": resolutionSeconds
            ]) { _, runtime in runtime },
            "fusedMonotonic": fusedMetrics.dictionary
        ]
        if let resultPath = environment["SPOKEN_MARGINS_BENCHMARK_RESULT_PATH"] {
            let outputURL = URL(fileURLWithPath: resultPath)
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: outputURL, options: .atomic)
        }

        XCTAssertGreaterThanOrEqual(eligibleCount, 200)
        XCTAssertEqual(acousticMetrics.falseConfident, 0)
        XCTAssertLessThanOrEqual(acousticMetrics.p95ErrorMs ?? .max, 1_500)
        XCTAssertEqual(fusedMetrics.falseConfident, 0)
        XCTAssertLessThanOrEqual(fusedMetrics.p95ErrorMs ?? .max, 1_500)
    }

    func testExistingPrivateInterjectionDecodesWithoutNewSharingFields() throws {
        let original = Interjection(
            id: "private", itemId: "item", sessionId: "session", targetType: .item,
            targetId: "item", createdAt: fixedDate, roughPercent: 50,
            anchor: .init(
                anchorType: .media,
                startChar: 0,
                endChar: 0,
                anchorBefore: "",
                anchorAfter: "",
                mediaTimeMs: 5_000
            ),
            audioPath: "/private/capture.m4a", audioStatus: "recorded",
            transcriptionStatus: "transcribed", transcript: "A thought.", cleanedTranscript: nil,
            displayText: "A thought.", status: "captured"
        )
        let encoded = try JSONEncoder.iso8601.encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "alignedTranscript")
        object.removeValue(forKey: "podcastAnchorEvidence")
        object.removeValue(forKey: "sourceExactEditionSHA256")
        object.removeValue(forKey: "isStarredForSharing")
        object.removeValue(forKey: "privateSharingNote")
        let legacyData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decoded = try JSONDecoder.iso8601.decode(Interjection.self, from: legacyData)
        XCTAssertEqual(decoded.transcript, "A thought.")
        XCTAssertNil(decoded.alignedTranscript)
        XCTAssertNil(decoded.podcastAnchorEvidence)
        XCTAssertNil(decoded.isStarredForSharing)
        XCTAssertNil(decoded.privateSharingNote)
    }

    func testPrivateShareCurationPersistsButCannotEnterReviewedRevisionOrSessionExport() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteSessionStore(path: root.appendingPathComponent("curation.sqlite").path)
        let privateNote = "Use this Margin to explain the key tradeoff."
        let interjection = Interjection(
            id: "private-curated", itemId: "item", sessionId: "session", targetType: .item,
            targetId: "item", createdAt: fixedDate, roughPercent: 50,
            anchor: .init(
                anchorType: .text,
                startChar: 0,
                endChar: 8,
                anchorBefore: "Before",
                anchorAfter: "After"
            ),
            audioPath: nil, audioStatus: "saved", transcriptionStatus: "transcribed",
            transcript: "A curated thought.", cleanedTranscript: nil,
            displayText: "A curated thought.", status: "active",
            isStarredForSharing: true,
            privateSharingNote: privateNote
        )

        try store.saveInterjection(interjection)
        let restored = try XCTUnwrap(store.loadInterjections(sessionId: "session").first)

        XCTAssertEqual(restored.isStarredForSharing, true)
        XCTAssertEqual(restored.privateSharingNote, privateNote)
        let revisionJSON = String(
            decoding: try JSONEncoder.iso8601.encode(approvedRevision()),
            as: UTF8.self
        )
        XCTAssertFalse(revisionJSON.contains(privateNote))
        XCTAssertFalse(revisionJSON.contains("privateSharingNote"))
        XCTAssertFalse(revisionJSON.contains("isStarredForSharing"))
        let exportJSON = String(
            decoding: try JSONEncoder.iso8601.encode(ExportInterjection(
                id: restored.id,
                sessionId: restored.sessionId,
                targetType: restored.targetType.rawValue,
                targetId: restored.targetId,
                roughPercent: restored.roughPercent,
                anchorBefore: restored.anchor.anchorBefore,
                anchorAfter: restored.anchor.anchorAfter,
                mediaTimeMs: restored.anchor.mediaTimeMs,
                transcriptionStatus: restored.transcriptionStatus,
                transcript: restored.transcript,
                audioPath: nil
            )),
            as: UTF8.self
        )
        XCTAssertFalse(exportJSON.contains(privateNote))
        XCTAssertFalse(exportJSON.contains("privateSharingNote"))
        XCTAssertFalse(exportJSON.contains("isStarredForSharing"))
    }

    func testExistingImportedLayerDecodesLegacySourceIdentityWithoutLosingTheLibraryRecord() throws {
        let data = Data(#"{"id":"legacy-layer","itemId":"item","packageDigest":"digest","packageId":"legacy-package","sourceIdentity":{"sourceType":"article","canonicalURL":"https://example.com/article","originalURL":"https://example.com/article","feedURL":null,"title":"Legacy article","author":null,"publisher":null,"showTitle":null,"episodeGUID":null,"enclosureURL":null,"publishedAt":null,"durationMs":null,"normalizedContentSHA256":null,"exactEditionSHA256":null,"languageCode":null},"displayLabel":null,"suggestedRevealMode":null,"importedAt":"2026-08-29T00:00:00Z","integrityStatus":"integrity_checked_unsigned","sourceResolutionStatus":"resolved","isEnabled":true,"isMuted":false,"revealMode":"companion","deletedAt":null,"listeningMapProposals":null}"#.utf8)

        let decoded = try JSONDecoder.iso8601.decode(ImportedCommentaryLayer.self, from: data)

        XCTAssertEqual(decoded.id, "legacy-layer")
        XCTAssertEqual(decoded.itemIdentity.itemType, .text)
        XCTAssertEqual(decoded.itemIdentity.canonicalURL, "https://example.com/article")
        let reencoded = try JSONEncoder.iso8601.encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        XCTAssertNotNil(object["itemIdentity"])
        XCTAssertNil(object["sourceIdentity"])
    }

    func testAlignedTranscriptionPersistsTimingAndLegacyCompletionClearsIt() throws {
        let interjection = Interjection(
            id: "private", itemId: "item", sessionId: "session", targetType: .item,
            targetId: "item", createdAt: fixedDate, roughPercent: 50,
            anchor: .init(
                anchorType: .media, startChar: 0, endChar: 0,
                anchorBefore: "", anchorAfter: "", mediaTimeMs: 5_000
            ),
            audioPath: "/private/capture.m4a", audioStatus: "recorded",
            transcriptionStatus: "pending", transcript: nil, cleanedTranscript: nil,
            displayText: nil, status: "captured"
        )
        let repository = InMemorySessionRepository(interjections: [interjection.id: interjection])
        let engine = SessionEngine(
            profile: .init(id: "test", displayName: "Test", capabilities: [:]),
            repository: repository
        )
        let aligned = AlignedInterjectionTranscript(
            text: "Um, a useful thought.",
            segments: [
                .init(id: "one", text: "Um", startMs: 0, endMs: 170),
                .init(id: "two", text: "a useful thought.", startMs: 320, endMs: 1_100)
            ]
        )
        _ = try engine.transcriptionCompleted(interjectionId: interjection.id, alignedTranscript: aligned)
        XCTAssertEqual(repository.interjections[interjection.id]?.alignedTranscript, aligned)
        XCTAssertEqual(repository.interjections[interjection.id]?.displayText, aligned.text)

        _ = try engine.transcriptionCompleted(interjectionId: interjection.id, transcript: "Fallback text")
        XCTAssertNil(repository.interjections[interjection.id]?.alignedTranscript)
        XCTAssertEqual(repository.interjections[interjection.id]?.transcript, "Fallback text")
    }

    func testUnknownOptionalArtifactIsSkippedAndUnknownRequiredArtifactIsRejected() throws {
        let base = try textPreparedPackage()
        var optionalManifest = base.manifest
        optionalManifest.artifacts.append(.init(
            id: "future", kind: "future_artifact", schemaVersion: "future.v1",
            path: "artifacts/future.json", required: false
        ))
        var optionalData = base.artifactData
        optionalData["artifacts/future.json"] = Data("{}".utf8)
        let optionalPrepared = PreparedSpokenMarginsPackage(manifest: optionalManifest, artifactData: optionalData, assetFiles: [:])
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let optionalURL = root.appendingPathComponent("optional.spokenmargins")
        _ = try exportPacket(optionalPrepared, to: optionalURL)
        XCTAssertNoThrow(try SpokenMarginsPackageArchive.read(from: optionalURL, extractingAssetsTo: root.appendingPathComponent("optional-assets")))

        var requiredManifest = base.manifest
        requiredManifest.artifacts.append(.init(
            id: "future", kind: "future_artifact", schemaVersion: "future.v1",
            path: "artifacts/future.json", required: true
        ))
        let requiredPrepared = PreparedSpokenMarginsPackage(manifest: requiredManifest, artifactData: optionalData, assetFiles: [:])
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.write(requiredPrepared, to: root.appendingPathComponent("required.spokenmargins"))) {
            XCTAssertEqual($0 as? SpokenMarginsPackageArchiveError, .unsupportedRequiredCapability("future_artifact"))
        }
    }

    func testArchiveRejectsPreReleaseV1AndTamperedArtifact() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldURL = root.appendingPathComponent("old.spokenmargins")
        try writeRawArchive(entries: [
            "manifest.json": Data(#"{"schemaVersion":"spoken-margins.interjection-package.v1"}"#.utf8),
            "preview.md": Data()
        ], to: oldURL)
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.read(from: oldURL, extractingAssetsTo: root.appendingPathComponent("old-assets"))) {
            XCTAssertEqual($0 as? SpokenMarginsPackageArchiveError, .unsupportedSchema("spoken-margins.interjection-package.v1"))
        }

        let goodURL = root.appendingPathComponent("good.spokenmargins")
        _ = try exportPacket(textPreparedPackage(), to: goodURL)
        var entries = try readRawArchive(goodURL)
        entries["artifacts/commentary-layer.json"] = Data("{}".utf8)
        let tamperedURL = root.appendingPathComponent("tampered.spokenmargins")
        try writeRawArchive(entries: entries, to: tamperedURL)
        XCTAssertThrowsError(try SpokenMarginsPackageArchive.read(from: tamperedURL, extractingAssetsTo: root.appendingPathComponent("tampered-assets"))) {
            XCTAssertEqual($0 as? SpokenMarginsPackageArchiveError, .invalidDigest)
        }
    }

    func testImportUsesDistinctLocalIDsAndIsIdempotentInMemoryAndSQLite() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = try verifiedTextPackage(in: root)
        let memory = InMemorySessionRepository()
        let provider: SpokenMarginsPackageImporter.LocalIDProvider = { kind, packageID in "recipient-\(kind)-\(packageID)" }
        let first = try SpokenMarginsPackageImporter.importPackage(contents, itemId: "recipient-item", importedAt: fixedDate, repository: memory, makeLocalID: provider)
        let second = try SpokenMarginsPackageImporter.importPackage(contents, itemId: "recipient-item", importedAt: fixedDate, repository: memory, makeLocalID: provider)
        XCTAssertEqual(first, .imported(layerId: "recipient-layer-package-article-001", interjectionIds: ["recipient-interjection-margin-001"]))
        XCTAssertEqual(second, .duplicate(existingLayerId: "recipient-layer-package-article-001"))
        XCTAssertTrue(memory.interjections.isEmpty)
        XCTAssertTrue(try XCTUnwrap(memory.importedCommentaryLayers.values.first).isEnabled)

        let sqlite = try SQLiteSessionStore(path: root.appendingPathComponent("sharing.sqlite").path)
        _ = try SpokenMarginsPackageImporter.importPackage(contents, itemId: "recipient-item", importedAt: fixedDate, repository: sqlite, makeLocalID: provider)
        XCTAssertEqual(try sqlite.loadImportedCommentaryLayers(itemId: "recipient-item").count, 1)
        XCTAssertEqual(try sqlite.loadImportedCommentaryInterjections(layerId: "recipient-layer-package-article-001").count, 1)
        XCTAssertEqual(try sqlite.quarantinedRecordCount(), 0)
    }

    func testArticleResolverDistinguishesWrongAmbiguousAndVerified() throws {
        let prepared = try textPreparedPackage()
        let layerData = try XCTUnwrap(prepared.artifactData["artifacts/commentary-layer.json"])
        let layer = try JSONDecoder.iso8601.decode(SharedCommentaryLayerArtifact.self, from: layerData)
        let wrong = SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/wrong", title: "Wrong")
        XCTAssertEqual(ImportedItemResolver.resolve(item: prepared.manifest.item, interjections: layer.interjections, against: wrong, itemText: "anything").status, .wrongSource)
        XCTAssertEqual(ImportedItemResolver.resolve(item: prepared.manifest.item, interjections: layer.interjections, against: articleItem, itemText: nil).status, .contextOnly)
        let repeated = "Before this passage. The durable idea that prompted this note. After this passage. Before this passage. The durable idea that prompted this note. After this passage."
        XCTAssertEqual(ImportedItemResolver.resolve(item: prepared.manifest.item, interjections: layer.interjections, against: articleItem, itemText: repeated).status, .ambiguous)
        let unique = "Before this passage. The durable idea that prompted this note. After this passage."
        let resolved = ImportedItemResolver.resolve(item: prepared.manifest.item, interjections: layer.interjections, against: articleItem, itemText: unique)
        XCTAssertEqual(resolved.status, .resolved)
        XCTAssertEqual(resolved.anchorsByPackageScopedId["margin-001"]?.evidenceClass, .articleTextVerified)
    }

    func testShareRevisionIDsRemainImmutableInMemoryAndSQLite() throws {
        let original = approvedRevision()
        let conflicting = InterjectionShareRevision(
            id: original.id, interjectionId: original.interjectionId, itemId: original.itemId,
            sessionId: original.sessionId, createdAt: original.createdAt, approvedTranscript: "Changed",
            anchorBefore: original.anchorBefore, anchorAfter: original.anchorAfter, status: original.status
        )
        let expected = SessionKitError.persistenceFailed("interjection_share_revision_immutable_conflict")
        let memory = InMemorySessionRepository()
        try memory.saveInterjectionShareRevision(original)
        XCTAssertThrowsError(try memory.saveInterjectionShareRevision(conflicting)) { XCTAssertEqual($0 as? SessionKitError, expected) }

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sqlite = try SQLiteSessionStore(path: root.appendingPathComponent("immutable.sqlite").path)
        try sqlite.saveInterjectionShareRevision(original)
        XCTAssertThrowsError(try sqlite.saveInterjectionShareRevision(conflicting)) { XCTAssertEqual($0 as? SessionKitError, expected) }
    }

    private var fixedDate: Date { Date(timeIntervalSince1970: 1_777_000_000) }
    private var articleItem: SharedItemIdentity {
        SharedItemIdentity(itemType: .text, canonicalURL: "https://example.com/article", title: "A Useful Article")
    }
    private var podcastItem: SharedItemIdentity {
        SharedItemIdentity(
            itemType: .podcast, canonicalURL: "https://example.com/episodes/one",
            title: "Episode One", publisher: "Example", showTitle: "Example Show", episodeGUID: "episode-one",
            enclosureURL: "https://example.com/audio/one.mp3", durationMs: 3_600_000, languageCode: "en",
            source: SharedSourceIdentity(
                sourceType: .podcastFeed,
                canonicalURL: "https://example.com/feed.xml",
                title: "Example Show",
                publisher: "Example"
            )
        )
    }

    private func approvedRevision(cleanedAudioPath: String? = nil) -> InterjectionShareRevision {
        InterjectionShareRevision(
            id: "revision-approved", interjectionId: "private-note", itemId: "private-item",
            sessionId: "private-session", createdAt: fixedDate, approvedTranscript: "A sender-reviewed thought.",
            cleanedAudioPath: cleanedAudioPath, cleanedAudioDurationMs: cleanedAudioPath == nil ? nil : 100,
            anchorBefore: "Before this passage.", anchorAfter: "After this passage.", status: .senderApproved
        )
    }

    // MARK: Crafted descriptors (#913)

    private func voicePackage(in root: URL) throws -> PreparedSpokenMarginsPackage {
        let audioURL = root.appendingPathComponent("voice.m4a")
        try writeSilentM4A(to: audioURL)
        return try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-voice-001", createdAt: fixedDate, item: articleItem, itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-voice", revision: approvedRevision(),
                anchor: .init(anchorType: .text), representation: .originalAudio(sourceURL: audioURL, durationMs: 100)
            )]
        )
    }

    /// Exports `prepared`, rewrites the manifest inside the archive the way a hostile sender could, and reads it back.
    private func readPacket(
        tampering prepared: PreparedSpokenMarginsPackage, in root: URL, _ tamper: (inout SpokenMarginsPackageManifest) -> Void
    ) throws -> VerifiedSpokenMarginsPackage {
        let goodURL = root.appendingPathComponent("good-\(UUID().uuidString).spokenmargins")
        _ = try exportPacket(prepared, to: goodURL)
        var entries = try readRawArchive(goodURL)
        var manifest = try SpokenMarginsPackageArchive.decodeManifest(XCTUnwrap(entries["manifest.json"]))
        tamper(&manifest)
        entries["manifest.json"] = try SpokenMarginsPackageArchive.encodeManifest(manifest)
        let tamperedURL = root.appendingPathComponent("tampered-\(UUID().uuidString).spokenmargins")
        try writeRawArchive(entries: entries, to: tamperedURL)
        return try SpokenMarginsPackageArchive.read(
            from: tamperedURL, extractingAssetsTo: root.appendingPathComponent("assets-\(UUID().uuidString)")
        )
    }

    /// The entry check compares a Set, so a path listed twice passes it; building a dictionary from the descriptors
    /// then trapped and took the app down before the import review appeared.
    func testAnArtifactPathListedTwiceIsRejectedNotATrap() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try readPacket(tampering: try textPreparedPackage(), in: root) { manifest in
            let first = manifest.artifacts[0]
            manifest.artifacts.append(SpokenMarginsArtifactDescriptor(
                id: "\(first.id)-again", kind: first.kind, schemaVersion: first.schemaVersion, path: first.path,
                required: false, byteCount: first.byteCount, sha256: first.sha256
            ))
        }) { error in
            XCTAssertEqual(error as? SpokenMarginsPackageArchiveError, .invalidManifest("descriptor identities are not unique"))
        }
    }

    func testAnAssetPathListedTwiceIsRejectedNotATrap() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try readPacket(tampering: try voicePackage(in: root), in: root) { manifest in
            let first = manifest.assets[0]
            manifest.assets.append(SpokenMarginsAssetDescriptor(
                id: "\(first.id)-again", role: first.role, path: first.path, mimeType: first.mimeType,
                durationMs: first.durationMs, anchorOffsetMs: first.anchorOffsetMs, provenance: first.provenance,
                byteCount: first.byteCount, sha256: first.sha256
            ))
        }) { error in
            XCTAssertEqual(error as? SpokenMarginsPackageArchiveError, .invalidManifest("descriptor identities are not unique"))
        }
    }

    /// `voice/a` and `voice?a` both became `voice-a.m4a`, so the second recording overwrote the first and both
    /// Margins played it. A case-insensitive disk does the same to `Voice-a` and `voice-a`.
    func testAnExportWhoseAssetIDsWouldExtractToOneFileIsRefused() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var selections: [ReviewedInterjectionSelection] = []
        for number in 1...2 {
            let audioURL = root.appendingPathComponent("voice-\(number).m4a")
            try writeSilentM4A(to: audioURL)
            selections.append(.init(
                packageScopedId: "margin-\(number)",
                revision: InterjectionShareRevision(
                    id: "revision-\(number)", interjectionId: "private-note-\(number)", itemId: "private-item",
                    sessionId: "private-session", createdAt: fixedDate, approvedTranscript: "A sender-reviewed thought \(number).",
                    anchorBefore: "Before this passage.", anchorAfter: "After this passage.", status: .senderApproved
                ),
                anchor: .init(anchorType: .text), representation: .originalAudio(sourceURL: audioURL, durationMs: 100)
            ))
        }
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-two-voices", createdAt: fixedDate, item: articleItem, itemTransportSelection: .reference,
            selections: selections
        )
        let oldIDs = prepared.manifest.assets.map(\.id)
        XCTAssertEqual(oldIDs.count, 2)
        // Rename the two assets everywhere they are named, so the packet stays consistent apart from the clash.
        for (firstID, secondID) in [("voice/a", "voice?a"), ("Voice-a", "voice-a")] {
            let newIDs = [oldIDs[0]: firstID, oldIDs[1]: secondID]
            var manifest = prepared.manifest
            manifest.assets = manifest.assets.map { asset in
                SpokenMarginsAssetDescriptor(
                    id: newIDs[asset.id] ?? asset.id, role: asset.role, path: asset.path, mimeType: asset.mimeType,
                    durationMs: asset.durationMs, anchorOffsetMs: asset.anchorOffsetMs, provenance: asset.provenance
                )
            }
            var artifactData = prepared.artifactData
            for (path, data) in artifactData {
                var text = String(decoding: data, as: UTF8.self)
                for (old, new) in newIDs { text = text.replacingOccurrences(of: "\"\(old)\"", with: "\"\(new)\"") }
                artifactData[path] = Data(text.utf8)
            }
            let clashing = PreparedSpokenMarginsPackage(manifest: manifest, artifactData: artifactData, assetFiles: prepared.assetFiles)
            XCTAssertThrowsError(try SpokenMarginsPackageArchive.write(clashing, to: root.appendingPathComponent("clash-\(UUID().uuidString).spokenmargins")),
                "\(firstID) and \(secondID)"
            ) { error in
                XCTAssertEqual(error as? SpokenMarginsPackageArchiveError, .invalidManifest("asset ids would extract to the same file"))
            }
        }
    }

    /// The same clash in a packet someone else wrote. The manifest is tampered after export, so it also fails the
    /// digest and entry checks; the point is that the clash is refused first, before anything is written to disk.
    func testAnImportWhoseAssetIDsWouldExtractToOneFileIsRefusedBeforeAnythingIsWritten() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try voicePackage(in: root)
        let destination = root.appendingPathComponent("assets-clash")
        let goodURL = root.appendingPathComponent("good.spokenmargins")
        _ = try exportPacket(prepared, to: goodURL)
        var entries = try readRawArchive(goodURL)
        var manifest = try SpokenMarginsPackageArchive.decodeManifest(XCTUnwrap(entries["manifest.json"]))
        let first = manifest.assets[0]
        func asset(_ id: String, path: String) -> SpokenMarginsAssetDescriptor {
            SpokenMarginsAssetDescriptor(
                id: id, role: first.role, path: path, mimeType: first.mimeType, durationMs: first.durationMs,
                anchorOffsetMs: first.anchorOffsetMs, provenance: first.provenance, byteCount: first.byteCount, sha256: first.sha256
            )
        }
        manifest.assets = [asset("voice/a", path: first.path), asset("voice?a", path: "assets/audio/second.m4a")]
        entries["manifest.json"] = try SpokenMarginsPackageArchive.encodeManifest(manifest)
        let tamperedURL = root.appendingPathComponent("clash.spokenmargins")
        try writeRawArchive(entries: entries, to: tamperedURL)

        XCTAssertThrowsError(try SpokenMarginsPackageArchive.read(from: tamperedURL, extractingAssetsTo: destination)) { error in
            XCTAssertEqual(error as? SpokenMarginsPackageArchiveError, .invalidManifest("asset ids would extract to the same file"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// The shipped build's reader is really in the loop (#317): one manifest key it doesn't know, as a new
    /// packet field would add, is enough for it to refuse a packet it otherwise imports.
    func testTheShippedBuildRejectsAManifestKeyItDoesNotKnow() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let goodURL = root.appendingPathComponent("good.spokenmargins")
        try exportPacket(textPreparedPackage(), to: goodURL)
        var entries = try readRawArchive(goodURL)
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(entries["manifest.json"])) as? [String: Any])
        manifest["addedAfterBuild29"] = true
        entries["manifest.json"] = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let changedURL = root.appendingPathComponent("new-field.spokenmargins")
        try writeRawArchive(entries: entries, to: changedURL)
        XCTAssertThrowsError(try ShippedPacketReader.importPacket(at: changedURL)) { error in
            XCTAssertTrue("\(error)".contains("unknown manifest fields: addedAfterBuild29"), "\(error)")
        }
    }

    private func textPreparedPackage() throws -> PreparedSpokenMarginsPackage {
        try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-article-001", createdAt: fixedDate, item: articleItem, itemTransportSelection: .reference,
            selections: [.init(
                packageScopedId: "margin-001", revision: approvedRevision(),
                anchor: .init(anchorType: .text, exactText: "The durable idea that prompted this note."),
                representation: .textOnly
            )],
            senderDisplayLabel: "A Friend", suggestedRevealMode: .companion
        )
    }

    private func verifiedTextPackage(in root: URL) throws -> VerifiedSpokenMarginsPackage {
        let url = root.appendingPathComponent("verified.spokenmargins")
        _ = try exportPacket(textPreparedPackage(), to: url)
        return try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("verified-assets"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpokenMarginsSharingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSilentM4A(to url: URL) throws {
        #if canImport(AVFoundation)
        let sampleRate = 44_100.0
        let audioFile = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate / 10)))
        buffer.frameLength = buffer.frameCapacity
        try audioFile.write(from: buffer)
        #else
        throw XCTSkip("AVFoundation is required")
        #endif
    }

    private func writeSilenceSpeechSilenceM4A(to url: URL) throws {
        #if canImport(AVFoundation)
        let sampleRate = 44_100.0
        let audioFile = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        for second in 0..<3 {
            let frameCount = AVAudioFrameCount(sampleRate)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<Int(frameCount) {
                samples[frame] = second == 1
                    ? Float(0.25 * sin(2 * .pi * 220 * Double(frame) / sampleRate))
                    : 0
            }
            try audioFile.write(from: buffer)
        }
        #else
        throw XCTSkip("AVFoundation is required")
        #endif
    }

    private func writeContinuousNoiseM4A(to url: URL, durationSeconds: Int) throws {
        #if canImport(AVFoundation)
        let sampleRate = 44_100.0
        let audioFile = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        for second in 0..<durationSeconds {
            let frameCount = AVAudioFrameCount(sampleRate)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<Int(frameCount) {
                let time = Double(frame + second * Int(frameCount)) / sampleRate
                samples[frame] = Float(
                    0.18 * sin(2 * .pi * 173 * time)
                    + 0.12 * sin(2 * .pi * 431 * time)
                )
            }
            try audioFile.write(from: buffer)
        }
        #else
        throw XCTSkip("AVFoundation is required")
        #endif
    }

    private func writePatternedM4A(
        to url: URL,
        durationSeconds: Int,
        frequencyOffset: Double = 0
    ) throws {
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
            let baseFrequency = 180.0 + frequencyOffset + Double((second * 73) % 420)
            for frame in 0..<Int(frameCount) {
                let time = Double(frame) / sampleRate
                let sweep = baseFrequency + (Double(frame) / Double(frameCount)) * 120
                samples[frame] = Float(
                    0.22 * sin(2 * .pi * sweep * time)
                    + 0.12 * sin(2 * .pi * (baseFrequency * 1.7) * time)
                    + 0.06 * sin(2 * .pi * (37 + Double(second)) * time)
                )
            }
            try audioFile.write(from: buffer)
        }
        #else
        throw XCTSkip("AVFoundation is required")
        #endif
    }

    private func concatenateAudio(_ parts: [URL], destinationURL: URL) async throws {
        #if canImport(AVFoundation)
        let composition = AVMutableComposition()
        let outputTrack = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        var cursor = CMTime.zero
        for url in parts {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let track = try XCTUnwrap(tracks.first)
            try outputTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: cursor)
            cursor = CMTimeAdd(cursor, duration)
        }
        let exporter = try XCTUnwrap(AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ))
        try await exporter.export(to: destinationURL, as: .m4a)
        #else
        throw XCTSkip("AVFoundation is required")
        #endif
    }

    private func composeRecipientEdition(
        senderURL: URL,
        insertedAudioURL: URL,
        insertionTimeMs: Int,
        destinationURL: URL
    ) async throws {
        #if canImport(AVFoundation)
        let sender = AVURLAsset(url: senderURL)
        let inserted = AVURLAsset(url: insertedAudioURL)
        let senderDuration = try await sender.load(.duration)
        let insertedDuration = try await inserted.load(.duration)
        let senderTracks = try await sender.loadTracks(withMediaType: .audio)
        let insertedTracks = try await inserted.loadTracks(withMediaType: .audio)
        let senderTrack = try XCTUnwrap(senderTracks.first)
        let insertedTrack = try XCTUnwrap(insertedTracks.first)
        let insertion = CMTime(value: CMTimeValue(insertionTimeMs), timescale: 1_000)
        let composition = AVMutableComposition()
        let outputTrack = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        try outputTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: insertion),
            of: senderTrack,
            at: .zero
        )
        try outputTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: insertedDuration),
            of: insertedTrack,
            at: insertion
        )
        try outputTrack.insertTimeRange(
            CMTimeRange(start: insertion, duration: CMTimeSubtract(senderDuration, insertion)),
            of: senderTrack,
            at: CMTimeAdd(insertion, insertedDuration)
        )
        let exporter = try XCTUnwrap(AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ))
        try await exporter.export(to: destinationURL, as: .m4a)
        #else
        throw XCTSkip("AVFoundation is required")
        #endif
    }

    private func expectedRecipientTime(forBenchmarkSenderTime senderTime: Int) -> Int? {
        switch senderTime {
        case ..<240_000: return senderTime
        case 240_000..<480_000: return senderTime + 45_000
        case 480_000..<500_000: return nil
        case 500_000..<700_000: return senderTime + 25_000
        case 700_000..<900_000: return senderTime + 65_000
        case 900_000..<906_000: return nil
        default: return senderTime + 59_000
        }
    }

    private func percentile95(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * 0.95).rounded(.up))
        return sorted[index]
    }

    private func whisperTimeline(from url: URL) throws -> TranscriptTimeline {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let transcription = try XCTUnwrap(object["transcription"] as? [[String: Any]])
        let segments = try transcription.enumerated().map { index, value -> MediaTimelineSegment in
            let offsets = try XCTUnwrap(value["offsets"] as? [String: Any])
            let startMs = try XCTUnwrap(offsets["from"] as? Int)
            let endMs = try XCTUnwrap(offsets["to"] as? Int)
            let text = try XCTUnwrap(value["text"] as? String)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return MediaTimelineSegment(
                id: "whisper-\(String(format: "%05d", index + 1))",
                startMs: startMs,
                endMs: max(startMs + 1, endMs),
                text: text
            )
        }.filter { !$0.text.isEmpty }
        return TranscriptTimeline(
            segments: segments,
            chapters: [],
            durationMs: segments.map(\.endMs).max()
        )
    }

    private func benchmarkMetrics(
        queries: [PodcastPortableAnchorQuery],
        expectedRecipientTimes: [String: Int],
        resolutions: [String: ImportedAnchorResolution]
    ) -> AnchorBenchmarkMetrics {
        var errors: [Int] = []
        var falseConfident = 0
        var declinedEligible = 0
        var correctlyDeclinedAbsent = 0
        var evidenceCounts: [String: Int] = [:]
        for query in queries {
            let expected = expectedRecipientTimes[query.packageScopedId] ?? -1
            let resolution = resolutions[query.packageScopedId]
                ?? ImportedAnchorResolution(evidenceClass: .unresolved)
            evidenceCounts[resolution.evidenceClass.rawValue, default: 0] += 1
            if expected >= 0 {
                if let actual = resolution.localMediaTimeMs {
                    let error = abs(actual - expected)
                    errors.append(error)
                    if error > 1_500 { falseConfident += 1 }
                } else {
                    declinedEligible += 1
                }
            } else if resolution.localMediaTimeMs != nil {
                falseConfident += 1
            } else {
                correctlyDeclinedAbsent += 1
            }
        }
        return AnchorBenchmarkMetrics(
            confident: errors.count,
            declinedEligible: declinedEligible,
            correctlyDeclinedAbsent: correctlyDeclinedAbsent,
            falseConfident: falseConfident,
            p95ErrorMs: percentile95(errors),
            placementsOver1500Ms: errors.filter { $0 > 1_500 }.count,
            evidenceClasses: evidenceCounts
        )
    }

    private func readRawArchive(_ url: URL) throws -> [String: Data] {
        let archive = try Archive(url: url, accessMode: .read)
        var result: [String: Data] = [:]
        for entry in archive {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            result[entry.path] = data
        }
        return result
    }

    private func writeRawArchive(entries: [String: Data], to url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for path in entries.keys.sorted() {
            let data = try XCTUnwrap(entries[path])
            try archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(data.count),
                modificationDate: Date(timeIntervalSince1970: 315_532_800), permissions: 0o644,
                compressionMethod: path.hasPrefix("assets/") ? .none : .deflate
            ) { position, size in
                let start = Int(position)
                guard start < data.count else { return Data() }
                return data.subdata(in: start..<min(data.count, start + size))
            }
        }
    }
}

private struct AnchorBenchmarkMetrics {
    let confident: Int
    let declinedEligible: Int
    let correctlyDeclinedAbsent: Int
    let falseConfident: Int
    let p95ErrorMs: Int?
    let placementsOver1500Ms: Int
    let evidenceClasses: [String: Int]

    var dictionary: [String: Any] {
        [
            "confident": confident,
            "declinedEligible": declinedEligible,
            "correctlyDeclinedAbsent": correctlyDeclinedAbsent,
            "falseConfident": falseConfident,
            "p95ErrorMs": p95ErrorMs ?? NSNull(),
            "placementsOver1500Ms": placementsOver1500Ms,
            "evidenceClasses": evidenceClasses
        ]
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
