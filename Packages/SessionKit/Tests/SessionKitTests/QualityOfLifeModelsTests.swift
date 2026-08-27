import Foundation
import XCTest
@testable import SessionKit
import SessionKitFeeds

final class QualityOfLifeModelsTests: XCTestCase {
    func testLegacyPlaybackPositionDecodesWithoutSourceLocator() throws {
        let data = Data(#"{"itemId":"item","targetType":"item_text_tts","targetId":"item","textStart":3,"textEnd":9,"playbackRate":1.25,"anchorConfidence":"local_fallback"}"#.utf8)
        let position = try JSONDecoder().decode(PlaybackPosition.self, from: data)
        XCTAssertNil(position.sourceLocator)
        XCTAssertEqual(position.textRange, 3..<9)
    }

    func testUTF8LocatorRoundTripsUnicodeCharacterOffset() {
        let text = "A café ☕️ closes late."
        let locator = LegacySourceOffsetAdapter.locator(
            documentId: "doc",
            segmentId: "segment",
            characterRange: 2..<8,
            in: text
        )
        XCTAssertEqual(LegacySourceOffsetAdapter.characterOffset(for: locator, in: text), 2)
        XCTAssertGreaterThan(locator.utf8End, locator.utf8Start)
    }

    func testPreparedManifestNeverAdvertisesCompleteDurationWhilePartial() {
        let signature = signatureFixture()
        let manifest = PreparedAudioManifest(
            id: "manifest",
            itemId: "item",
            sourcePackageId: "source",
            signature: signature,
            state: .preparing,
            plannedChunkCount: 3,
            chunks: [chunkFixture(index: 0), chunkFixture(index: 1)]
        )
        XCTAssertTrue(manifest.canStartPartialPlayback)
        XCTAssertFalse(manifest.advertisesCompleteDuration)
        XCTAssertEqual(manifest.progress, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testPreparedLocatorMediaRoundTripIsMonotonic() throws {
        let chunks = [
            PreparedAudioChunk(id: "a", index: 0, sourceRange: SourceLocator(documentId: "doc", segmentId: "a", utf8Start: 0, utf8End: 100), relativePath: "a", byteCount: 1, checksumSHA256: "a", durationMs: 10_000),
            PreparedAudioChunk(id: "b", index: 1, sourceRange: SourceLocator(documentId: "doc", segmentId: "b", utf8Start: 100, utf8End: 200), relativePath: "b", byteCount: 1, checksumSHA256: "b", durationMs: 20_000)
        ]
        var previousTime = -1
        for offset in stride(from: 0, through: 200, by: 10) {
            let locator = SourceLocator(documentId: "doc", segmentId: offset < 100 ? "a" : "b", utf8Start: offset, utf8End: offset)
            let time = try XCTUnwrap(PreparedAudioLocatorMapper.mediaTimeMs(for: locator, chunks: chunks))
            XCTAssertGreaterThanOrEqual(time, previousTime)
            let roundTrip = try XCTUnwrap(PreparedAudioLocatorMapper.sourceLocator(at: time, chunks: chunks))
            XCTAssertLessThanOrEqual(abs(roundTrip.utf8Start - offset), 1)
            previousTime = time
        }
    }

    func testRenderSignatureEncodingContainsNoPlaybackRate() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(signatureFixture())) as? [String: Any])
        XCTAssertNil(object["playbackRate"])
        XCTAssertNil(object["speechRate"])
    }

    func testDeterministicEvictionProtectsIrreplaceableMediaAndOrdersReproducibleAssets() {
        let assets = [
            asset("podcast", .podcast, age: 4),
            asset("prepared", .preparedAudio, age: 3),
            asset("redundant", .preparedChunk, age: 2, redundant: true),
            asset("corrupt", .preparedChunk, age: 1, integrity: .corrupt),
            asset("book", .audiobook, age: 10, reproducible: false, protections: [.importedAudiobook])
        ]
        let plan = OfflineStoragePlanner.evictionPlan(requiredBytes: 4, assets: assets)
        XCTAssertEqual(plan.selectedAssetIds, ["corrupt", "redundant", "prepared", "podcast"])
        XCTAssertFalse(plan.selectedAssetIds.contains("book"))
    }

    func testBatteryHorizonStopsAtThirtyMinutesAndNextChapter() {
        let segments = (0..<5).map { index in
            SpeakableSegment(
                id: "s\(index)",
                text: "segment",
                locator: SourceLocator(documentId: "doc", segmentId: "s\(index)", utf8Start: index, utf8End: index + 1)
            )
        }
        let horizon = PreparationHorizonPolicy.select(
            segments: segments,
            activeSegmentId: "s1",
            currentChapterSegmentIds: ["s1", "s2"],
            nextChapterSegmentIds: ["s3"],
            estimatedDuration: { _ in 10 * 60 * 1_000 },
            estimatedBytes: { _ in 10 * 1_024 * 1_024 },
            environment: PreparationEnvironment(isOnExternalPower: false, isLowPowerModeEnabled: false, thermalStateAllowsWork: true, availableBytes: 1_000_000_000),
            explicitFullRequest: false
        )
        XCTAssertEqual(horizon.segmentIds, ["s1", "s2", "s3"])
        XCTAssertEqual(horizon.estimatedDurationMs, 30 * 60 * 1_000)
    }

    func testLibraryPersistedSelectionDropsSearchQuery() {
        let query = LibraryQuery(query: "résumé", contentType: .epub, listeningState: .inProgress, offlineState: .readyOffline, sort: .title)
        XCTAssertEqual(query.persistedSelection.query, "")
        XCTAssertEqual(query.persistedSelection.contentType, .epub)
    }

    func testFeedParserBoundsEntriesAndSanitizesMarkup() throws {
        let data = Data("""
        {"version":"https://jsonfeed.org/version/1.1","title":"Example","items":[
        {"id":"1","url":"https://example.com/1","title":"<b>One</b>","content_html":"<p>Hello &amp; goodbye</p>"},
        {"id":"2","url":"https://example.com/2","title":"Two"}]}
        """.utf8)
        let parsed = try FeedParser(limits: FeedParserLimits(maximumBytes: 10_000, maximumEntries: 1, maximumXMLDepth: 64)).parse(data: data)
        XCTAssertEqual(parsed.items.count, 1)
        XCTAssertEqual(parsed.items[0].title, "One")
        XCTAssertEqual(parsed.items[0].summary, "Hello & goodbye")
    }

    private func signatureFixture() -> TTSRenderSignature {
        TTSRenderSignature(
            engine: "supertonic", modelRevision: "3", assetManifestHash: "a",
            voiceStyleHash: "v", synthesisParametersHash: "p",
            normalizationVersion: "n", chunkingVersion: "c", digest: "digest"
        )
    }

    private func chunkFixture(index: Int) -> PreparedAudioChunk {
        PreparedAudioChunk(
            id: "chunk-\(index)", index: index,
            sourceRange: SourceLocator(documentId: "doc", segmentId: "s\(index)", utf8Start: index, utf8End: index + 1),
            relativePath: "chunk-\(index).wav", byteCount: 1,
            checksumSHA256: "hash", durationMs: 1
        )
    }

    private func asset(
        _ id: String,
        _ category: OfflineAssetCategory,
        age: TimeInterval,
        redundant: Bool = false,
        integrity: OfflineAssetIntegrity = .valid,
        reproducible: Bool = true,
        protections: Set<OfflineProtectionReason> = []
    ) -> OwnedOfflineAsset {
        OwnedOfflineAsset(
            id: id, category: category, relativePath: id, byteCount: 1,
            isReproducible: reproducible, integrity: integrity,
            isRedundant: redundant, protections: protections,
            lastAccessedAt: Date(timeIntervalSince1970: age)
        )
    }
}
