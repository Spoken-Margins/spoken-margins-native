import XCTest
import SessionKit
import UIKit
import SessionKitPersistence
@testable import SpokenMarginsApp

final class PlaybackQualityTests: XCTestCase {
    @MainActor
    func testPreparedTrackMatchesTrackEdgesAndClearsThumb() {
        let slider = TrackingPlaybackSlider(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        slider.preparedFraction = 1
        slider.layoutIfNeeded()
        let track = slider.trackRect(forBounds: slider.bounds)
        let thumb = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: slider.value)
        let prepared = slider.layer.sublayers!.first { $0.name == "prepared-audio-track" }!
        XCTAssertEqual(prepared.frame.minX, track.minX, accuracy: 0.1)
        XCTAssertEqual(prepared.frame.width, track.width, accuracy: 0.1)
        XCTAssertGreaterThan(prepared.frame.minY, thumb.maxY)
    }

    func testFrontierStopsAtMissingChunkAndRejectsStaleSourceOrVoice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appendingPathComponent("chunk"))
        let signature = TTSRenderSignature(engine: "test", modelRevision: "1", assetManifestHash: "assets", voiceStyleHash: "voice", synthesisParametersHash: "params", normalizationVersion: "1", chunkingVersion: "1", digest: "signature")
        let text = "One.\n\nTwo."
        let chunk = PreparedAudioChunk(id: "c", index: 0, sourceRange: SourceLocator(documentId: "source", segmentId: "s", utf8Start: 0, utf8End: 4), relativePath: "chunk", byteCount: 1, checksumSHA256: "committed", durationMs: 1000)
        var manifest = PreparedAudioManifest(id: "m", itemId: "i", sourcePackageId: "source", signature: signature, state: .preparing, plannedChunkCount: 3, chunks: [chunk])
        func value(_ m: PreparedAudioManifest, source: String = "One.\n\nTwo.", expectedSignature: TTSRenderSignature? = nil) -> Double {
            PreparedRenderFrontier.fraction(manifest: m, signature: expectedSignature ?? signature, sourceText: source, canonicalSourceText: text, root: root)
        }
        XCTAssertEqual(value(manifest), 0.4, accuracy: 0.001)
        let restored = try JSONDecoder().decode(PreparedAudioManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(value(restored), 0.4, accuracy: 0.001)
        var later = chunk; later.index = 2; later.sourceRange.utf8Start = 6; later.sourceRange.utf8End = 10
        manifest.chunks.append(later)
        XCTAssertEqual(value(manifest), 0.4, "Out-of-order completion cannot bridge a missing chunk")
        XCTAssertEqual(value(manifest, source: "Changed!!!"), 0)
        var otherVoice = signature; otherVoice.voiceStyleHash = "different"
        XCTAssertEqual(value(manifest, expectedSignature: otherVoice), 0)
        manifest.state = .needsRepreparation
        XCTAssertEqual(value(manifest), 0)
        manifest.state = .preparing
        try FileManager.default.removeItem(at: root.appendingPathComponent("chunk"))
        XCTAssertEqual(value(manifest), 0)
        manifest.state = .readyOffline
        manifest.artifact = PreparedAudioArtifact(relativePath: "whole", byteCount: 2, checksumSHA256: "committed", durationMs: 3000)
        XCTAssertEqual(value(manifest), 0, "Missing complete audio must not appear prepared")
        try Data([1, 2]).write(to: root.appendingPathComponent("whole"))
        XCTAssertEqual(value(manifest), 1)
    }

    func testSkimDestinationFormattingDoesNotInventATarget() {
        XCTAssertEqual(PlaybackQualityPresentation.skimTitle(destinationMs: nil, backward: false), "Skim Forward")
        XCTAssertEqual(PlaybackQualityPresentation.skimTitle(destinationMs: 1_122_000, backward: false), "Skim to 18:42")
        XCTAssertEqual(PlaybackQualityPresentation.skimTitle(destinationMs: 3_662_000, backward: true), "Back to 1:01:02")
    }

    /// The playback screen's frontier needs the article text and the canonical text, and reads them off the main
    /// thread (#2506). The read gives the same answer the old inline reads did: the item's text, the canonical
    /// segments joined by blank lines, and nothing for an item with no text.
    @MainActor
    func testFrontierTextsMatchTheStoredItem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteSessionStore(path: directory.appending(path: "store.sqlite").path)
        try store.saveItem(Item(
            id: "article", title: "Article", mediaType: TargetType.itemTextTTS.rawValue, text: "One.\n\nTwo.",
            externalReference: nil, status: "ready"
        ))
        try store.saveItem(Item(
            id: "empty", title: "Empty", mediaType: TargetType.itemTextTTS.rawValue, text: "",
            externalReference: nil, status: "ready"
        ))
        let model = Gate1AppModel(databaseURLOverride: directory.appending(path: "model.sqlite"))
        let article = try await model.renderFrontierTexts(store: store, itemID: "article")
        XCTAssertEqual(article?.text, "One.\n\nTwo.")
        XCTAssertEqual(article?.canonical, "", "An item with no canonical source package measures against nothing")
        let empty = try await model.renderFrontierTexts(store: store, itemID: "empty")
        XCTAssertNil(empty, "An item with no text has no frontier to measure")
        do {
            _ = try await model.renderFrontierTexts(store: store, itemID: "missing")
            XCTFail("A missing item should throw, as the inline read did")
        } catch {}
    }
}
