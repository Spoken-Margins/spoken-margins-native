import Foundation
import SessionKit
import SessionKitSharing
import XCTest

final class SharingTests: XCTestCase {
    func testCleanupRemovesUnambiguousFillersAndCollapsesLongPause() {
        let transcript = AlignedInterjectionTranscript(
            text: "Um this matters you know because timing matters.",
            segments: [
                .init(id: "1", text: "Um", startMs: 0, endMs: 180, confidence: 0.95),
                .init(id: "2", text: "this", startMs: 220, endMs: 400, confidence: 0.95),
                .init(id: "3", text: "matters", startMs: 430, endMs: 700, confidence: 0.95),
                .init(id: "4", text: "you", startMs: 1_700, endMs: 1_850, confidence: 0.95),
                .init(id: "5", text: "know", startMs: 1_870, endMs: 2_050, confidence: 0.95),
                .init(id: "6", text: "because", startMs: 3_000, endMs: 3_300, confidence: 0.95),
                .init(id: "7", text: "timing", startMs: 3_330, endMs: 3_600, confidence: 0.95),
                .init(id: "8", text: "matters.", startMs: 3_630, endMs: 3_950, confidence: 0.95)
            ]
        )

        let result = DeterministicInterjectionCleanup.propose(transcript)

        XCTAssertEqual(result.cleanedTranscript, "This matters because timing matters.")
        XCTAssertEqual(result.decisions.filter { $0.kind == .filler }.count, 1)
        XCTAssertEqual(result.decisions.filter { $0.kind == .isolatedPhrase }.count, 1)
        XCTAssertEqual(result.decisions.filter { $0.kind == .longPause }.count, 2)
        XCTAssertTrue(result.decisions.allSatisfy(\.accepted))
    }

    func testCleanupPreservesSemanticYouKnowAndAmbiguousLike() {
        let transcript = AlignedInterjectionTranscript(
            text: "You know the answer is like a map.",
            segments: [
                .init(id: "1", text: "You", startMs: 0, endMs: 120),
                .init(id: "2", text: "know", startMs: 140, endMs: 260),
                .init(id: "3", text: "the", startMs: 280, endMs: 350),
                .init(id: "4", text: "answer", startMs: 370, endMs: 550),
                .init(id: "5", text: "is", startMs: 570, endMs: 630),
                .init(id: "6", text: "like", startMs: 650, endMs: 770),
                .init(id: "7", text: "a", startMs: 790, endMs: 830),
                .init(id: "8", text: "map.", startMs: 850, endMs: 1_000)
            ]
        )

        let result = DeterministicInterjectionCleanup.propose(transcript)

        XCTAssertEqual(result.cleanedTranscript, "You know the answer is like a map.")
        XCTAssertTrue(result.decisions.isEmpty)
    }

    func testCleanupProposesYouKnowWhenPunctuationIsolatesPhrase() {
        let transcript = AlignedInterjectionTranscript(
            text: "Well, you know, this matters.",
            segments: [
                .init(id: "1", text: "Well,", startMs: 0, endMs: 160),
                .init(id: "2", text: "you", startMs: 180, endMs: 280),
                .init(id: "3", text: "know,", startMs: 300, endMs: 430),
                .init(id: "4", text: "this", startMs: 450, endMs: 560),
                .init(id: "5", text: "matters.", startMs: 580, endMs: 780)
            ]
        )
        let result = DeterministicInterjectionCleanup.propose(transcript)
        XCTAssertEqual(result.cleanedTranscript, "Well, this matters.")
        XCTAssertEqual(result.decisions.filter { $0.kind == .isolatedPhrase }.count, 1)
    }

    func testAlignedTranscriptPreservesRecognitionChunkOffsetsThroughCoding() throws {
        let transcript = AlignedInterjectionTranscript(
            text: "First second",
            localeIdentifier: "en-US",
            segments: [
                .init(
                    id: "seg-2",
                    text: "second",
                    startMs: 12_300,
                    endMs: 12_700,
                    confidence: 0.82,
                    recognitionChunkId: "chunk-0002",
                    chunkOffsetMs: 12_000
                )
            ]
        )
        let decoded = try JSONDecoder().decode(
            AlignedInterjectionTranscript.self,
            from: JSONEncoder().encode(transcript)
        )
        XCTAssertEqual(decoded, transcript)
        XCTAssertEqual(decoded.segments.first?.chunkOffsetMs, 12_000)
        XCTAssertEqual(decoded.segments.first?.startMs, 12_300)
    }

    func testRestoringCleanupDecisionRestoresTranscriptToken() throws {
        let transcript = AlignedInterjectionTranscript(
            text: "Uh a clear thought.",
            segments: [
                .init(id: "1", text: "Uh", startMs: 0, endMs: 150),
                .init(id: "2", text: "a", startMs: 200, endMs: 240),
                .init(id: "3", text: "clear", startMs: 260, endMs: 400),
                .init(id: "4", text: "thought.", startMs: 420, endMs: 650)
            ]
        )
        let initial = DeterministicInterjectionCleanup.propose(transcript)
        let filler = try XCTUnwrap(initial.decisions.first)
        let restored = DeterministicInterjectionCleanup.propose(
            transcript,
            restoredDecisionIds: [filler.id]
        )
        XCTAssertEqual(restored.cleanedTranscript, "Uh a clear thought.")
        XCTAssertEqual(restored.decisions.first?.accepted, false)
    }

    func testPackageRoundTripIsDeterministicAndPreservesRedactionBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpokenMarginsSharingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audioURL = root.appendingPathComponent("cleaned.m4a")
        try Data("cleaned-user-audio".utf8).write(to: audioURL)
        let fixedDate = Date(timeIntervalSince1970: 1_777_000_000)
        let manifest = InterjectionPackageManifest(
            packageId: "package-1",
            createdAt: fixedDate,
            conversationId: "conversation-1",
            source: SharedSourceIdentity(
                sourceType: .article,
                canonicalURL: "https://example.com/article",
                title: "Example Article",
                author: "Example Author"
            ),
            interjections: [
                SharedInterjectionPackageRecord(
                    packageScopedId: "margin-1",
                    createdAt: fixedDate,
                    anchor: PortableAnchorEvidence(
                        anchorType: .text,
                        startChar: 12,
                        endChar: 24,
                        exactText: "short context"
                    ),
                    representation: SharedInterjectionRepresentation(
                        approvedTranscript: "An approved thought.",
                        audioPath: "audio/margin-1.m4a",
                        audioMimeType: "audio/mp4",
                        audioDurationMs: 1_000
                    )
                )
            ],
            senderDisplayLabel: "A Friend"
        )
        let firstURL = root.appendingPathComponent("first.spokenmargins")
        let secondURL = root.appendingPathComponent("second.spokenmargins")
        let firstManifest = try InterjectionPackageArchive.write(
            manifest: manifest,
            audioFiles: ["audio/margin-1.m4a": audioURL],
            to: firstURL
        )
        let secondManifest = try InterjectionPackageArchive.write(
            manifest: manifest,
            audioFiles: ["audio/margin-1.m4a": audioURL],
            to: secondURL
        )

        XCTAssertEqual(firstManifest.contentDigest, secondManifest.contentDigest)
        XCTAssertEqual(try Data(contentsOf: firstURL), try Data(contentsOf: secondURL))

        let imported = try InterjectionPackageArchive.read(
            from: firstURL,
            extractingAudioTo: root.appendingPathComponent("imported", isDirectory: true)
        )
        XCTAssertEqual(imported.manifest, firstManifest)
        XCTAssertEqual(imported.manifest.interjections.first?.representation.approvedTranscript, "An approved thought.")
        XCTAssertNil(imported.manifest.source.normalizedContentSHA256)
        XCTAssertTrue(imported.manifest.redactions.fullSourceTextOmitted)
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(imported.extractedAudioURLs["audio/margin-1.m4a"])),
            Data("cleaned-user-audio".utf8)
        )
    }

    func testArticleAnchorPrefersExactEditionRange() {
        let text = "Opening. A durable idea appears here. Closing."
        let anchor = PortableAnchorEvidence(
            anchorType: .text,
            startChar: 9,
            endChar: 37,
            exactText: "stale sender wording"
        )
        let result = PortableArticleAnchorResolver.resolve(
            anchor: anchor,
            in: text,
            expectedContentSHA256: PortableArticleAnchorResolver.normalizedContentSHA256(text)
        )
        XCTAssertEqual(result.evidenceClass, .articleTextVerified)
        XCTAssertEqual(result.localStartChar, 9)
        XCTAssertEqual(result.confidence, 1)
    }

    func testArticleAnchorRecoversUniqueNormalizedQuoteAfterPunctuationChange() {
        let text = "Before. The durable—idea, appears here! After."
        let anchor = PortableAnchorEvidence(
            anchorType: .text,
            exactText: "the durable idea appears here"
        )
        let result = PortableArticleAnchorResolver.resolve(anchor: anchor, in: text, expectedContentSHA256: nil)
        XCTAssertEqual(result.evidenceClass, .articleTextVerified)
        XCTAssertEqual(result.confidence, 0.88)
        XCTAssertFalse(result.isAmbiguous)
    }

    func testArticleAnchorDeclinesRepeatedNormalizedQuoteWithoutClearContextWinner() {
        let text = "The same idea appears here. Later the same idea appears here."
        let anchor = PortableAnchorEvidence(anchorType: .text, exactText: "THE SAME IDEA APPEARS HERE")
        let result = PortableArticleAnchorResolver.resolve(anchor: anchor, in: text, expectedContentSHA256: nil)
        XCTAssertEqual(result.evidenceClass, .ambiguous)
        XCTAssertTrue(result.isAmbiguous)
    }

    func testPackageWriterRejectsMissingRedactionProof() throws {
        var redactions = InterjectionPackageRedactions()
        redactions.sourceAudioOmitted = false
        let manifest = InterjectionPackageManifest(
            packageId: "package-invalid-redaction",
            createdAt: Date(timeIntervalSince1970: 1_777_000_000),
            conversationId: "conversation-1",
            source: SharedSourceIdentity(sourceType: .article, canonicalURL: "https://example.com", title: "Example"),
            interjections: [
                SharedInterjectionPackageRecord(
                    packageScopedId: "margin-1",
                    createdAt: Date(timeIntervalSince1970: 1_777_000_000),
                    anchor: PortableAnchorEvidence(anchorType: .text),
                    representation: SharedInterjectionRepresentation(kind: "text_only", approvedTranscript: "Reviewed", provenance: "sender_approved_text_only")
                )
            ],
            redactions: redactions
        )
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-\(UUID().uuidString).spokenmargins")
        defer { try? FileManager.default.removeItem(at: destination) }
        XCTAssertThrowsError(try InterjectionPackageArchive.write(manifest: manifest, audioFiles: [:], to: destination))
    }
}
