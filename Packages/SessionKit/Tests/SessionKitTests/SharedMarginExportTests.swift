import CryptoKit
import Foundation
import SessionKit
import SessionKitSharing
import ShippedPacketReader
import XCTest

final class SharedMarginExportTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_777_000_000)

    func testAnchorWarningsKeepExactCopyAndOnlyWarnForNativeAudioWithoutEvidence() {
        let cases: [(PodcastAnchorEvidenceCaptureStatus?, String?)] = [
            (.pendingPostResumeSample, "High-reliability evidence is capturing. Continue podcast playback for about 12 seconds before sharing this Margin."),
            (.pendingExactLocalCapture, "High-reliability evidence is being prepared from the podcast edition currently playing."),
            (.ready, nil),
            (.unavailable, "High-reliability anchor evidence was unavailable at capture. Transcript context may still resolve this Margin; a timestamp alone will not be treated as verified."),
            (nil, "High-reliability anchor evidence was unavailable at capture. Transcript context may still resolve this Margin; a timestamp alone will not be treated as verified."),
        ]
        for (status, warning) in cases {
            for evidence: [CapturedPodcastAnchorEvidence]? in [nil, [], [capturedEvidence]] {
                var margin = margin()
                margin.podcastAnchorEvidenceCaptureStatus = status
                margin.podcastAnchorEvidence = evidence
                XCTAssertEqual(SharedMarginExport.anchorWarning(for: margin, isNativeAudio: true),
                               (evidence ?? []).isEmpty ? warning : nil, "\(String(describing: status)), \(String(describing: evidence))")
                XCTAssertNil(SharedMarginExport.anchorWarning(for: margin, isNativeAudio: false))
            }
        }
    }

    func testExactTextUsesCharacterOffsetsAndOnlyValidNonemptyRanges() {
        // The emoji and decomposed accent each occupy one Character, but multiple UTF-8 bytes.
        let text = "A👩🏽‍🚀e\u{301}Z"
        XCTAssertEqual(text.count, 4)
        let cases: [(Int, Int, String?)] = [
            (0, 4, text), (1, 3, "👩🏽‍🚀e\u{301}"), (3, 4, "Z"),
            (0, 0, nil), (2, 2, nil), (3, 2, nil), (1, 5, nil),
        ]
        for (start, end, expected) in cases {
            let exported = anchor(margin(start: start, end: end), item: item(text: text))
            XCTAssertEqual(exported.exactText, expected, "\(start)..<\(end)")
            XCTAssertEqual(exported.startChar, start)
            XCTAssertEqual(exported.endChar, end)
        }
        XCTAssertNil(anchor(margin(), item: item(text: nil)).exactText)
        XCTAssertNil(anchor(margin(), item: item(text: "")).exactText)
    }

    func testNativeAudioOmitsTextOffsetsAndKeepsEveryOtherAnchorField() {
        let exported = anchor(margin(), item: item(text: "ABC"), native: true, evidence: ["second", "first"])
        XCTAssertEqual(exported, PortableAnchorEvidence(
            anchorType: .text, exactText: nil, prefix: "Before.", suffix: "After.",
            mediaTimeMs: 30_000, roughPercent: 37, transcriptSegmentId: "segment",
            chapterTitle: "Middle", machineEvidenceAssetIds: ["second", "first"]
        ))
        let textAnchor = anchor(margin(), item: item(text: "ABC"))
        XCTAssertEqual(textAnchor.prefix, "Before.")
        XCTAssertEqual(textAnchor.suffix, "After.")
        XCTAssertEqual(textAnchor.roughPercent, 37)
        XCTAssertEqual(textAnchor.transcriptSegmentId, "segment")
    }

    func testChapterIsLastQualifyingChapterInInputOrderIncludingExactBoundary() {
        let chapters = [chapter("Start", 0), chapter("Later", 50_000), chapter("Middle", 30_000)]
        let cases: [(Int?, String?)] = [
            (nil, nil), (-1, nil), (0, "Start"), (29_999, "Start"),
            (30_000, "Middle"), (50_000, "Middle"), (90_000, "Middle"),
        ]
        for (time, title) in cases {
            XCTAssertEqual(anchor(margin(time: time), item: item(), native: true, chapters: chapters).chapterTitle, title)
        }
        XCTAssertNil(anchor(margin(), item: item(), chapters: []).chapterTitle)
    }

    func testTransportRequiresNonblankTextAndRightsAndPreservesUntrimmedTextAndIdentityType() {
        for text: String? in [nil, "", " \n\t ", "  Private essay.\n"] {
            for authored in [false, true] {
                for rights in [false, true] {
                    let identity = SharedItemIdentity(itemType: .pdf, title: "Local essay")
                    let transport = SharedMarginExport.itemTransport(
                        item: item(text: text), identity: identity,
                        isAppAuthored: authored, confirmsPrivateRights: rights
                    )
                    if text == "  Private essay.\n" && (authored || rights) {
                        guard case .embeddedText(let embedded, let type, let basis) = transport else {
                            XCTFail("Expected embedded text: \(authored), \(rights)"); continue
                        }
                        XCTAssertEqual(embedded, text)
                        XCTAssertEqual(type, identity.itemType.rawValue)
                        XCTAssertEqual(basis, authored ? .appAuthored : .senderConfirmedPrivateRights)
                    } else {
                        guard case .recipientSupplied = transport else { XCTFail("Expected recipient supplied"); continue }
                    }
                }
            }
        }
    }

    func testTransportLinkWinsOverTextAndEitherRightsBasis() {
        for text: String? in [nil, "", "  Essay.\n"] {
            for authored in [false, true] {
                for rights in [false, true] {
                    let transport = SharedMarginExport.itemTransport(
                        item: item(text: text),
                        identity: .init(itemType: .text, canonicalURL: "https://example.com/essay", title: "Essay"),
                        isAppAuthored: authored, confirmsPrivateRights: rights
                    )
                    guard case .reference = transport else { XCTFail("A link must win"); continue }
                }
            }
        }
    }

    func testFileNameSanitizesRunsTrimsHyphensFallsBackAndLimitsTo80Characters() {
        let cases: [(String, String)] = [
            ("AbC_09.pdf-v2", "AbC_09.pdf-v2"), ("  Hello \t world!  ", "Hello-world"),
            ("a///?!b", "a-b"), ("---hello---", "hello"), ("", "Spoken-Margins"),
            (" \n\t ", "Spoken-Margins"), ("é👩🏽‍🚀", "Spoken-Margins"),
            ("e\u{301}", "e"), ("é", "Spoken-Margins"), ("._", "._"),
            (String(repeating: "a", count: 80), String(repeating: "a", count: 80)),
            (String(repeating: "a", count: 81), String(repeating: "a", count: 80)),
            (String(repeating: "a", count: 79) + " ? b", String(repeating: "a", count: 79) + "-"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(SharedMarginExport.fileName(input), expected, input)
        }
        let packageId = "package-12345678"
        XCTAssertEqual("\(SharedMarginExport.fileName("A title"))-\(packageId.suffix(8)).spokenmargins", "A-title-12345678.spokenmargins")
    }

    func testMapProposalsStripEverySummaryAssetAndPreserveAllOtherFields() {
        XCTAssertEqual(SharedMarginExport.mapProposals([]), [])
        let varied = PortableListeningMapProposalArtifact(
            id: "varied", schemaVersion: "custom-schema", createdAt: date, generator: "custom-generator",
            scenes: [PortableSceneEligibility.excluded, .unknown].enumerated().map { index, eligibility in
                .init(id: "varied-\(index)", order: index, summaryText: "Retained text", summaryAssetId: "voice",
                      eligibility: eligibility, eligibilityReason: "Retained reason",
                      startAnchor: .init(anchorType: .media, mediaTimeMs: 0),
                      endAnchor: .init(anchorType: .media, mediaTimeMs: 1))
            }
        )
        let proposals = [proposal(native: false), proposal(native: true), varied]
        let exported = SharedMarginExport.mapProposals(proposals)
        XCTAssertEqual(exported.count, proposals.count)
        for (actual, original) in zip(exported, proposals) {
            XCTAssertEqual(actual.id, original.id)
            XCTAssertEqual(actual.schemaVersion, original.schemaVersion)
            XCTAssertEqual(actual.languageCode, original.languageCode)
            XCTAssertEqual(actual.createdAt, original.createdAt)
            XCTAssertEqual(actual.generator, original.generator)
            XCTAssertEqual(actual.scenes.count, original.scenes.count)
            for (scene, source) in zip(actual.scenes, original.scenes) {
                XCTAssertEqual(scene, PortableListeningMapScene(
                    id: source.id, order: source.order, title: source.title,
                    summaryText: source.summaryText, summaryAssetId: nil, summaryProvenance: source.summaryProvenance,
                    eligibility: source.eligibility, eligibilityReason: source.eligibilityReason,
                    startAnchor: source.startAnchor, endAnchor: source.endAnchor
                ))
            }
        }
    }

    func testPacketsKeepGoldenBytesAndBuild29ImportsEveryMarginAndAnchor() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SharedMarginExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let signature = root.appending(path: "evidence.shazamsignature")
        // Fixed signature from 12 seconds of synthetic in-memory PCM (no audio codec or playback).
        let signatureData = try XCTUnwrap(Data(base64Encoded:
            "gCWAJQIAAAAMAAAAgCX+yhgv5cWEAAAAECDwQgAAAAAAAAAAAAAAAAAAABgAAAAAAAAAAAD9AgAAAHwAAAAAQIQAAABAAANgDwAA" +
            "AP8sAQAAAK+LchBLr4tyEABBAANgSwAAAP+WAQAAAFKKohFgaIqkEQx9i9ES/wIDAAAAfIsvFWl9iy8VDGeKXBZdUopeFiKvi44X" +
            "Y6+Ljhf/YAUAAABBi+sZDMCKGhs0tIobGwBCAANgAAAAAEMAA2AAAAAA"
        ))
        try signatureData.write(to: signature)
        for (name, native, evidence) in [("text", false, false), ("podcast-evidence", true, true), ("podcast-none", true, false)] {
            let prepared = try packet(native: native, evidence: evidence, signature: signature)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let commentaryPath = "artifacts/commentary-layer.json"
            let actualLayer = try decoder.decode(SharedCommentaryLayerArtifact.self, from: XCTUnwrap(prepared.artifactData[commentaryPath]))
            XCTAssertEqual(actualLayer.interjections.count, 2, name)
            var bytes = prepared.artifactData
            bytes["manifest.json"] = try SpokenMarginsPackageArchive.encodeManifest(prepared.manifest)
            let digests = bytes.mapValues { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
            // The goldens come from the verbatim pre-extraction helpers (3fcf206 holds that comparison).
            // The commentary digest covers every complete Margin record.
            XCTAssertEqual(digests, goldenArtifacts[name], name)

            XCTAssertEqual(prepared.manifest.requiredCapabilities, native
                           ? [SharedCommentaryLayerArtifact.schemaVersion]
                           : [SharedCommentaryLayerArtifact.schemaVersion, EmbeddedTextItemArtifact.schemaVersion])
            let url = root.appending(path: "\(name).spokenmargins")
            _ = try exportPacket(prepared, to: url)
            let archiveDigest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(archiveDigest, goldenArchives[name], name)
            XCTAssertEqual(try ShippedPacketReader.importPacket(at: url), ["margin-0001", "margin-0002"], name)
            let imported = try ShippedPacketReader.importedMargins(at: url, includingAnchorEvidence: true).sorted { $0.packageScopedId < $1.packageScopedId }
            XCTAssertEqual(imported.map(\.packageScopedId), ["margin-0001", "margin-0002"], name)
            XCTAssertEqual(imported.map(\.approvedTranscript), ["Reviewed thought 1.", "Reviewed thought 2."], name)
            for saved in imported {
                let savedAnchor = try JSONDecoder().decode(PortableAnchorEvidence.self, from: XCTUnwrap(saved.anchorEvidenceJSON))
                XCTAssertEqual(savedAnchor, PortableAnchorEvidence(
                    anchorType: native ? .media : .text,
                    startChar: native ? nil : 1, endChar: native ? nil : 3, exactText: native ? nil : "BC",
                    prefix: "Before.", suffix: "After.", mediaTimeMs: 30_000, roughPercent: 37,
                    transcriptSegmentId: "segment", chapterTitle: "Middle",
                    machineEvidenceAssetIds: evidence ? ["evidence"] : []
                ), name)
            }
        }
    }

    // Golden bytes from the pre-extraction helpers (fixed ids, dates and signature).
    private let goldenArtifacts: [String: [String: String]] = [
        "text": [
            "artifacts/commentary-layer.json": "cb6ab90ecd0c63872e610c4acfc4a81e45d2197e99eb68799c07d139690e73a4",
            "artifacts/embedded-item.json": "ffee17d44af34d954b9ec500f2ebf7fab4ec4f84661e8782e2cb35562cab6ab2",
            "artifacts/listening-map-proposal-0001.json": "6fc18464fb047b36007cf64409c3878587a4ab094f683028ecea85ac4e7ace85",
            "manifest.json": "70697fc42a1e107dacfb7a79e7027a2cf51c16794f57306593cd2b4e3f4aa9ac",
        ],
        "podcast-evidence": [
            "artifacts/commentary-layer.json": "8f03816330ea241122638145b03e82e49c4a40c4a836c136ffcf5d94fb649be3",
            "artifacts/listening-map-proposal-0001.json": "b825af70ea1e3088d6f2cc61045470ca47f9479b041fdbfa765322dd5a07ed79",
            "manifest.json": "d6de9f7887e8f810545e257c710926439ef25115436a0e0073fe27ca3e147d94",
        ],
        "podcast-none": [
            "artifacts/commentary-layer.json": "8f2f0d4bf2e75736024b583461c96211be98f88a48930ed2053e969cdb2ca689",
            "artifacts/listening-map-proposal-0001.json": "b825af70ea1e3088d6f2cc61045470ca47f9479b041fdbfa765322dd5a07ed79",
            "manifest.json": "f41625d8869f69d672d5d49fec502a29b49c19fce54b2fc29a499fe2b9efab87",
        ],
    ]

    private let goldenArchives: [String: String] = [
        "text": "8aec367e60c60a076e5749e0803c4ad2bdbbe8b3d3900e12feca0cd4061171e2",
        "podcast-evidence": "6e30da7cd1a8c0b5c591a3bc051c6ffd8ce3fffb69335e78d7ce9ec813f734b0",
        "podcast-none": "03b3a83b5a6297e97b8e4327db9c6b42619ccb8e845e6dc224c18d6e43240030",
    ]

    private var capturedEvidence: CapturedPodcastAnchorEvidence {
        .init(id: "evidence", localPath: "/unused", durationMs: 12_000, anchorOffsetMs: 4_000)
    }

    private func item(text: String? = "ABC") -> Item {
        .init(id: "item", title: "A title", mediaType: "text", text: text, externalReference: nil, status: "ready")
    }

    private func margin(id: String = "note", start: Int = 1, end: Int = 3, time: Int? = 30_000, type: AnchorType = .text) -> Interjection {
        .init(id: id, itemId: "item", sessionId: "session", targetType: .item, targetId: "item", createdAt: date,
              roughPercent: 37,
              anchor: .init(anchorType: type, startChar: start, endChar: end, anchorBefore: "Before.", anchorAfter: "After.",
                            mediaTimeMs: time, transcriptSegmentId: "segment"),
              audioPath: nil, audioStatus: "unavailable", transcriptionStatus: "ready", transcript: "Thought.",
              cleanedTranscript: nil, displayText: nil, status: "ready")
    }

    private func chapter(_ title: String, _ start: Int) -> MediaTimelineChapter {
        .init(id: title, title: title, startMs: start, transcriptSegmentId: "chapter-\(title)")
    }

    private var chapters: [MediaTimelineChapter] { [chapter("Start", 0), chapter("Middle", 30_000), chapter("End", 60_000)] }

    private func anchor(_ margin: Interjection, item: Item, native: Bool = false,
                        chapters: [MediaTimelineChapter]? = nil, evidence: [String] = []) -> PortableAnchorEvidence {
        SharedMarginExport.anchor(for: margin, item: item, isNativeAudio: native,
                                  mediaChapters: chapters ?? self.chapters, machineEvidenceAssetIds: evidence)
    }

    private func proposal(native: Bool) -> PortableListeningMapProposalArtifact {
        .init(id: native ? "podcast-map" : "text-map", languageCode: "en-GB", createdAt: date, generator: "sender-test",
              scenes: (0..<2).map { index in
            PortableListeningMapScene(
                id: "scene-\(index)", order: index, title: "Part \(index)", summaryText: "Reviewed overview \(index).",
                summaryAssetId: "unselected-voice-\(index)", summaryProvenance: index == 0 ? .senderAuthored : .modelGenerated,
                eligibility: .eligible, eligibilityReason: "Reviewed by sender",
                startAnchor: .init(anchorType: native ? .media : .text, startChar: native ? nil : index,
                                   mediaTimeMs: native ? index * 30_000 : nil),
                endAnchor: .init(anchorType: native ? .media : .text, endChar: native ? nil : index + 1,
                                 mediaTimeMs: native ? (index + 1) * 30_000 : nil)
            )
        })
    }

    private func packet(native: Bool, evidence: Bool, signature: URL) throws -> PreparedSpokenMarginsPackage {
        let item = item()
        let identity = SharedItemIdentity(itemType: native ? .podcast : .text,
                                          canonicalURL: native ? "https://example.com/episode" : nil, title: item.title,
                                          normalizedContentSHA256: native ? nil : PortableArticleAnchorResolver.normalizedContentSHA256(item.text ?? ""),
                                          exactEditionSHA256: native ? nil : PortableArticleAnchorResolver.exactEditionSHA256(item.text ?? ""))
        let transport = SharedMarginExport.itemTransport(item: item, identity: identity, isAppAuthored: true, confirmsPrivateRights: false)
        let selections = (1...2).map { index in
            let margin = margin(id: "note-\(index)", type: native ? .media : .text)
            let ids = evidence ? ["evidence"] : []
            let anchor = self.anchor(margin, item: item, native: native, evidence: ids)
            return ReviewedInterjectionSelection(
                packageScopedId: String(format: "margin-%04d", index),
                revision: .init(id: "revision-\(index)", interjectionId: margin.id, itemId: margin.itemId, sessionId: margin.sessionId,
                                createdAt: date, approvedTranscript: "Reviewed thought \(index).", anchorBefore: "Before.",
                                anchorAfter: "After.", status: .senderApproved),
                anchor: anchor, representation: .textOnly
            )
        }
        let proposals = SharedMarginExport.mapProposals([proposal(native: native)])
        return try SpokenMarginsPackageBuilder.prepare(
            packageId: "package-fixed-12345678", createdAt: date, item: identity, itemTransportSelection: transport,
            selections: selections, mapProposals: proposals,
            machineEvidence: evidence ? [.init(id: "evidence", path: "assets/evidence/evidence.shazamsignature", sourceURL: signature,
                                              durationMs: 12_000, anchorOffsetMs: 4_000)] : [],
            senderDisplayLabel: "Sender"
        )
    }
}
