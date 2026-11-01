import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #2506: the share export read the item, its map, the fingerprint spine, the phrase sketch and the whole stored
/// transcript with six separate store calls on the main actor. `sharedPacketSource` reads them together so the app
/// can run it through `StoreReader`. It must hand back exactly what the separate calls gave.
final class SharedPacketSourceTests: XCTestCase {
    private func withStore(_ body: (SQLiteSessionStore) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-packet-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(try SQLiteSessionStore(path: root.appendingPathComponent("library.sqlite").path))
    }

    private func item(_ id: String, text: String = "The item's own text.") -> Item {
        Item(id: id, title: "Title \(id)", mediaType: "text", text: text, externalReference: nil, status: "ready")
    }

    private let date = Date(timeIntervalSince1970: 100)

    private func proposal(_ id: String) -> PortableListeningMapProposalArtifact {
        PortableListeningMapProposalArtifact(
            id: id, createdAt: date, generator: "fixture",
            scenes: [.init(
                id: "scene-\(id)", order: 0, title: "Opening", summaryText: "Framing.",
                summaryProvenance: .senderAuthored, eligibility: .eligible,
                startAnchor: .init(anchorType: .transcript, exactText: "opening"),
                endAnchor: .init(anchorType: .transcript, exactText: "question"))])
    }

    private func spine(_ itemId: String) -> EditionFingerprintSpineArtifact {
        EditionFingerprintSpineArtifact(
            id: "spine-\(itemId)", itemId: itemId, createdAt: date,
            landmarks: [.init(
                id: "landmark-1", order: 0, sourceMediaStartMs: 9_000, sourceMediaEndMs: 21_000,
                anchorMediaTimeMs: 15_000, continuityEpoch: 0, trigger: .preInterjection,
                provenance: .observedDecodedPlayback, signatureAssetId: "sig-1", transcriptSketchWindowId: "w")])
    }

    private func sketch(_ itemId: String) -> TranscriptPhraseSketchArtifact {
        TranscriptPhraseSketchArtifact(
            id: "sketch-\(itemId)", itemId: itemId, saltBase64: Data(repeating: 3, count: 32).base64EncodedString(),
            createdAt: date,
            windows: [.init(id: "w", sourceStartMs: 0, sourceEndMs: 30_000, hashes: [String(repeating: "a", count: 32)])])
    }

    private func transcript(_ itemId: String, texts: [String]) -> SourceTranscriptTimeline {
        let segments = texts.enumerated().map { index, text in
            MediaTimelineSegment(id: "\(itemId)-\(index)", startMs: index * 1_000, endMs: (index + 1) * 1_000, text: text)
        }
        return SourceTranscriptTimeline(
            id: "t-\(itemId)", itemId: itemId, createdAt: date,
            timeline: TranscriptTimeline(segments: segments, chapters: [], durationMs: segments.count * 1_000))
    }

    func testTheOneReadGivesWhatTheSeparateCallsGave() async throws {
        try await withStore { store in
            try store.saveItem(item("A"))
            try store.saveItem(item("B", text: "Another item."))
            try store.savePortableListeningMapProposal(proposal("p1"), itemId: "A")
            try store.savePortableListeningMapProposal(proposal("p-other"), itemId: "B")
            try store.saveResolvedListeningMapProjection(ResolvedListeningMapProjection(
                id: "proj-A", itemId: "A", proposalId: "p1", createdAt: date, points: [], intervals: []))
            try store.saveEditionFingerprintSpine(spine("A"))
            try store.saveEditionFingerprintSpine(spine("B"))
            try store.saveTranscriptPhraseSketch(sketch("A"))
            try store.saveTranscriptTimeline(transcript("A", texts: ["First.", "Second.", "Third."]))
            try store.saveTranscriptTimeline(transcript("B", texts: ["Not this one."]))

            let source = try await StoreReader(store).read { try $0.sharedPacketSource(itemId: "A", includesFingerprintSpine: true) }

            XCTAssertEqual(source.item, try store.loadItem(id: "A"))
            XCTAssertEqual(source.mapProposals, try store.loadPortableListeningMapProposals(itemId: "A"))
            XCTAssertEqual(source.mapProposals.map(\.id), ["p1"], "another item's map must not come with it")
            XCTAssertEqual(source.currentMapProposalId, "p1")
            XCTAssertEqual(source.fingerprintSpine, try store.loadEditionFingerprintSpine(itemId: "A"))
            XCTAssertEqual(source.fingerprintSpine?.itemId, "A")
            XCTAssertEqual(source.phraseSketch, try store.loadTranscriptPhraseSketch(itemId: "A"))
            XCTAssertEqual(source.transcriptText, "First. Second. Third.", "the words the export used to join on the main actor")
            XCTAssertEqual(source.localSourceTexts, ["The item's own text.", "First. Second. Third."])
        }
    }

    func testTheFingerprintSpineStaysUnreadUnlessAcousticEvidenceIsIncluded() async throws {
        try await withStore { store in
            try store.saveItem(item("A"))
            try store.saveEditionFingerprintSpine(spine("A"))
            let without = try store.sharedPacketSource(itemId: "A", includesFingerprintSpine: false)
            XCTAssertNil(without.fingerprintSpine, "the sender did not choose to include acoustic evidence")
            let with = try store.sharedPacketSource(itemId: "A", includesFingerprintSpine: true)
            XCTAssertEqual(with.fingerprintSpine?.id, "spine-A")
        }
    }

    func testAnItemWithNothingElseGivesEmptyPiecesAndItsOwnTextOnly() async throws {
        try await withStore { store in
            try store.saveItem(item("A"))
            let source = try store.sharedPacketSource(itemId: "A", includesFingerprintSpine: true)
            XCTAssertTrue(source.mapProposals.isEmpty)
            XCTAssertNil(source.currentMapProposalId)
            XCTAssertNil(source.fingerprintSpine)
            XCTAssertNil(source.phraseSketch)
            XCTAssertNil(source.transcriptText)
            XCTAssertEqual(source.localSourceTexts, ["The item's own text."])
        }
    }

    func testAMissingItemThrowsLikeLoadItem() async throws {
        try await withStore { store in
            XCTAssertThrowsError(try store.sharedPacketSource(itemId: "gone", includesFingerprintSpine: false))
        }
    }
}
