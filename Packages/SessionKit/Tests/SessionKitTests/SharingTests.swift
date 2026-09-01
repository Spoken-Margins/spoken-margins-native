import CryptoKit
import Foundation
@testable import SessionKit
@testable import SessionKitAudio
import SessionKitPersistence
import SessionKitSharing
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
        let manifest = try SpokenMarginsPackageArchive.write(embedded, to: url)
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
        let omittedManifest = try SpokenMarginsPackageArchive.write(omitted, to: omittedURL)
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
        let first = try SpokenMarginsPackageArchive.write(prepared, to: firstURL)
        let second = try SpokenMarginsPackageArchive.write(prepared, to: secondURL)
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
        _ = try SpokenMarginsPackageArchive.write(prepared, to: url)
        let verified = try SpokenMarginsPackageArchive.read(from: url, extractingAssetsTo: root.appendingPathComponent("assets"))
        XCTAssertEqual(verified.listeningMapProposals, [proposal])
        XCTAssertEqual(verified.manifest.artifacts.last?.required, false)
        XCTAssertEqual(verified.manifest.assets.first?.anchorOffsetMs, evidence.anchorOffsetMs)
        XCTAssertEqual(
            verified.manifest.assets.first?.provenance,
            PodcastAnchorEvidenceProvenance.decodedPlaybackStream.rawValue
        )

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
        }
        continuation.finish()
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
        XCTAssertEqual(partial.evidenceClass, .ambiguous)
        XCTAssertEqual(partial.localMediaTimeMs, 71_000)
        XCTAssertTrue(partial.isAmbiguous)
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
        XCTAssertEqual(PodcastAcousticAnchorResolver.resolveCandidates(
            [], query: declaredButUnmatched, senderDurationMs: 100_000, recipientDurationMs: 100_000,
            strongSourceIdentity: true, exactDigestContradiction: false
        ).evidenceClass, .absentFromRecipientEdition)
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

        let interpolationQueries = [
            PodcastPortableAnchorQuery(packageScopedId: "start", senderMediaTimeMs: 10_000, evidence: []),
            PodcastPortableAnchorQuery(packageScopedId: "middle", senderMediaTimeMs: 20_000, evidence: []),
            PodcastPortableAnchorQuery(packageScopedId: "end", senderMediaTimeMs: 30_000, evidence: [])
        ]
        let interpolated = PodcastAnchorFusionResolver.interpolatingBetweenVerifiedAnchors(
            queries: interpolationQueries,
            resolutions: [
                "start": .init(evidenceClass: .acousticVerified, localMediaTimeMs: 20_000, confidence: 0.94),
                "middle": .init(evidenceClass: .unresolved),
                "end": .init(evidenceClass: .transcriptVerified, localMediaTimeMs: 45_000, confidence: 0.9)
            ]
        )
        XCTAssertEqual(interpolated["middle"]?.evidenceClass, .mapInterpolated)
        XCTAssertEqual(interpolated["middle"]?.localMediaTimeMs, 32_500)

        let noExtrapolation = PodcastAnchorFusionResolver.interpolatingBetweenVerifiedAnchors(
            queries: interpolationQueries,
            resolutions: [
                "start": .init(evidenceClass: .unresolved),
                "middle": .init(evidenceClass: .acousticVerified, localMediaTimeMs: 32_500),
                "end": .init(evidenceClass: .transcriptVerified, localMediaTimeMs: 45_000)
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

    func testAcousticResolverDeclinesConflictingSyntheticMatchesAcrossInsertedAd() async throws {
        #if canImport(AVFoundation)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let senderURL = root.appendingPathComponent("sender.m4a")
        let adURL = root.appendingPathComponent("recipient-ad.m4a")
        let recipientURL = root.appendingPathComponent("recipient.m4a")
        try writePatternedM4A(to: senderURL, durationSeconds: 75)
        try writePatternedM4A(to: adURL, durationSeconds: 7, frequencyOffset: 900)
        try await composeRecipientEdition(
            senderURL: senderURL,
            insertedAudioURL: adURL,
            insertionTimeMs: 25_000,
            destinationURL: recipientURL
        )
        let generated = try await PodcastAnchorEvidenceGenerator.generate(
            sourceURL: senderURL,
            anchorMediaTimeMs: 42_000,
            outputDirectory: root.appendingPathComponent("evidence"),
            idPrefix: "ad-shift"
        )
        XCTAssertEqual(generated.count, 2)
        let query = PodcastPortableAnchorQuery(
            packageScopedId: "shifted-margin",
            senderMediaTimeMs: 42_000,
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
        let resolution = try XCTUnwrap(resolutions[query.packageScopedId])
        XCTAssertEqual(resolution.evidenceClass, .ambiguous)
        XCTAssertNil(resolution.localMediaTimeMs)
        #else
        throw XCTSkip("AVFoundation is required")
        #endif
    }

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
        _ = try SpokenMarginsPackageArchive.write(optionalPrepared, to: optionalURL)
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
        _ = try SpokenMarginsPackageArchive.write(textPreparedPackage(), to: goodURL)
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
        _ = try SpokenMarginsPackageArchive.write(textPreparedPackage(), to: url)
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
