import Foundation
import XCTest
import SessionKit
import ShippedSessionKit

/// Prepared audio is stored as JSON and Build 29 has to keep opening it, in both directions: a manifest Build 29
/// wrote must open in this build (an upgraded Library is full of them), and one this build writes must open in
/// Build 29 (the owner can go back). Each test uses Build 29's frozen model on one side (`ShippedSessionKit`,
/// scripts/freeze-shipped-reader.sh) and encodes with the store's own date format.
final class PreparedAudioBuild29Tests: XCTestCase {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private let made = Date(timeIntervalSince1970: 1_777_000_000)

    func testAManifestBuild29WroteStillOpensWithItsChunks() throws {
        let shipped = ShippedSessionKit.PreparedAudioManifest(
            id: "prepared-b29", itemId: "item", sourcePackageId: "source",
            signature: ShippedSessionKit.TTSRenderSignature(
                engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v",
                synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: "d"
            ),
            state: .preparing, plannedChunkCount: 2,
            chunks: (0..<2).map { index in
                ShippedSessionKit.PreparedAudioChunk(
                    id: "chunk-\(index)", index: index,
                    sourceRange: ShippedSessionKit.SourceLocator(documentId: "source", segmentId: "chunk-\(index)", utf8Start: index * 10, utf8End: index * 10 + 10),
                    relativePath: "item/d/chunks/0000\(index).wav", byteCount: 4_096, checksumSHA256: "sum-\(index)", durationMs: 1_500,
                    committedAt: made
                )
            },
            createdAt: made, updatedAt: made
        )
        let stored = try encoder.encode(shipped)

        let opened = try decoder.decode(SessionKit.PreparedAudioManifest.self, from: stored)

        XCTAssertEqual(opened.id, "prepared-b29")
        XCTAssertEqual(opened.chunks.map(\.id), ["chunk-0", "chunk-1"])
        XCTAssertEqual(opened.chunks.map(\.relativePath), ["item/d/chunks/00000.wav", "item/d/chunks/00001.wav"])
        XCTAssertEqual(opened.chunks.map(\.durationMs), [1_500, 1_500])
        XCTAssertEqual(opened.chunks.map(\.committedAt), [made, made])
        XCTAssertNil(opened.chunks[0].engine, "a Build 29 chunk was made by the manifest's own engine")
        XCTAssertNil(opened.articleIdentity, "a Build 29 manifest has no article identity")
    }

    func testAChunkThisBuildTagsWithItsEngineStillOpensInBuild29() throws {
        let manifest = SessionKit.PreparedAudioManifest(
            id: "prepared-new", itemId: "item", sourcePackageId: "source",
            signature: SessionKit.TTSRenderSignature(
                engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v",
                synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: "d"
            ),
            state: .readyOffline, plannedChunkCount: 1,
            chunks: [SessionKit.PreparedAudioChunk(
                id: "chunk-0", index: 0,
                sourceRange: SessionKit.SourceLocator(documentId: "source", segmentId: "chunk-0", utf8Start: 0, utf8End: 10),
                relativePath: "item/d/chunks/00000.wav", byteCount: 4_096, checksumSHA256: "sum-0", durationMs: 1_500,
                committedAt: made, engine: "system_voice"
            )],
            createdAt: made, updatedAt: made, articleIdentity: "plan-identity"
        )
        let stored = try encoder.encode(manifest)
        XCTAssertTrue(String(decoding: stored, as: UTF8.self).contains("system_voice"), "the new field is really written")

        let opened = try decoder.decode(ShippedSessionKit.PreparedAudioManifest.self, from: stored)

        XCTAssertEqual(opened.id, "prepared-new")
        XCTAssertEqual(opened.state, .readyOffline)
        XCTAssertEqual(opened.chunks.map(\.id), ["chunk-0"])
        XCTAssertEqual(opened.chunks[0].relativePath, "item/d/chunks/00000.wav")
        XCTAssertEqual(opened.chunks[0].byteCount, 4_096)
        XCTAssertEqual(opened.chunks[0].durationMs, 1_500)
        XCTAssertEqual(opened.chunks[0].committedAt, made)
    }
}
