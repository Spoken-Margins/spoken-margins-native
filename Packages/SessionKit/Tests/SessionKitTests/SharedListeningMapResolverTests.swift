#if os(macOS) && canImport(AVFoundation) && canImport(ShazamKit)
import AVFoundation
import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// A friend's shared map lands on the listener's own copy of an episode when that copy has a
/// 7 s ad the friend's didn't (#481). Scenes after the ad move by its length; an ad inside the
/// stretch a scene start is matched across refuses the whole map instead of guessing.
final class SharedListeningMapResolverTests: XCTestCase {
    private static let sceneStarts = [0, 25_000, 185_000, 265_000]
    private static let landmarkStarts = [20_000, 100_000, 180_000, 260_000]
    private static let gateMs = 1_500

    func testAMapPlacesOnACopyWithAnAdBetweenScenes() async throws {
        let outcome = try await resolveOnCopy(adInsertedAtMs: 140_000)
        guard case .placed(let projection) = outcome else { return XCTFail("Expected a placed map, got \(outcome)") }
        let expected = [0, 25_000, 192_000, 272_000]
        for (start, recipient) in zip(Self.sceneStarts, expected) {
            let placed = try XCTUnwrap(projection.projectedRecipientTime(for: start), "scene at \(start) ms")
            XCTAssertLessThanOrEqual(abs(placed - recipient), Self.gateMs, "scene at \(start) ms placed at \(placed) ms")
        }
        XCTAssertEqual(projection.proposalId, "friend-map")
    }

    func testAnAdInsideASceneStartsEvidenceRefusesTheMap() async throws {
        let outcome = try await resolveOnCopy(adInsertedAtMs: 80_000)
        guard case .notPlaced(let refusal) = outcome else { return XCTFail("Expected a refusal, got \(outcome)") }
        XCTAssertEqual(refusal.sceneId, "scene-1")
        XCTAssertTrue([.ambiguous, .unresolved].contains(refusal.reason), "\(refusal.reason)")
    }

    /// Scene 4 starts after the last landmark (260 s), inside that landmark's audio, so its
    /// one match covers it: an ad after the scene leaves it where it was.
    func testAnAdAfterTheLastSceneLeavesTheMapInPlace() async throws {
        let outcome = try await resolveOnCopy(adInsertedAtMs: 290_000)
        guard case .placed(let projection) = outcome else { return XCTFail("Expected a placed map, got \(outcome)") }
        let placed = try XCTUnwrap(projection.projectedRecipientTime(for: 265_000))
        XCTAssertLessThanOrEqual(abs(placed - 265_000), Self.gateMs, "scene 4 placed at \(placed) ms")
    }

    private func resolveOnCopy(adInsertedAtMs: Int) async throws -> SharedListeningMapPlacement.Outcome {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "shared-map-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let senderURL = root.appending(path: "sender.m4a")
        let adURL = root.appending(path: "ad.m4a")
        let recipientURL = root.appending(path: "recipient.m4a")
        try SeededNoiseAudio.write(to: senderURL, seconds: 300)
        try SeededNoiseAudio.write(to: adURL, seconds: 7, seed: 0xD1B54A32D192ED03, startSecond: 600)
        try await insert(adURL, into: senderURL, atMs: adInsertedAtMs, writingTo: recipientURL)

        var signatures: [String: Data] = [:]
        var landmarks: [EpisodeFingerprintLandmark] = []
        for (index, start) in Self.landmarkStarts.enumerated() {
            let generated = try await PodcastAnchorEvidenceGenerator.generateLandmark(
                sourceURL: senderURL, sourceStartMs: start,
                outputDirectory: root.appending(path: "evidence"), id: "landmark-\(index)"
            )
            signatures[generated.id] = try Data(contentsOf: generated.fileURL)
            landmarks.append(EpisodeFingerprintLandmark(
                id: "landmark-\(index)", order: index,
                sourceMediaStartMs: start, sourceMediaEndMs: start + generated.durationMs, anchorMediaTimeMs: start,
                continuityEpoch: 0, trigger: .downloadedPreparation, provenance: .downloadedSourceReference,
                signatureAssetId: generated.id
            ))
        }
        let spine = EditionFingerprintSpineArtifact(
            id: "friend-spine", itemId: "friend-episode",
            producingEditionDurationMs: 300_000,
            producingEditionSHA256: try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: senderURL),
            landmarks: landmarks
        )
        let proposal = PortableListeningMapProposalArtifact(
            id: "friend-map", createdAt: Date(), generator: "test",
            scenes: Self.sceneStarts.enumerated().map { index, start in
                PortableListeningMapScene(
                    id: "scene-\(index)", order: index, eligibility: .eligible,
                    startAnchor: PortableAnchorEvidence(anchorType: .transcript, mediaTimeMs: start),
                    endAnchor: PortableAnchorEvidence(anchorType: .transcript, mediaTimeMs: start + 30_000)
                )
            }
        )
        let found = signatures
        return try await SharedListeningMapResolver.resolve(
            proposal: proposal, spine: spine, signatureData: { found[$0] },
            recipientAudioURL: recipientURL,
            recipientEditionSHA256: try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: recipientURL),
            itemId: "my-episode", projectionId: "shared-projection", strongSourceIdentity: true
        )
    }

    private func insert(_ adURL: URL, into senderURL: URL, atMs insertionMs: Int, writingTo destination: URL) async throws {
        let sender = AVURLAsset(url: senderURL)
        let ad = AVURLAsset(url: adURL)
        let senderDuration = try await sender.load(.duration)
        let adDuration = try await ad.load(.duration)
        let senderTracks = try await sender.loadTracks(withMediaType: .audio)
        let adTracks = try await ad.loadTracks(withMediaType: .audio)
        let senderTrack = try XCTUnwrap(senderTracks.first)
        let adTrack = try XCTUnwrap(adTracks.first)
        let insertion = CMTime(value: CMTimeValue(insertionMs), timescale: 1_000)
        let composition = AVMutableComposition()
        let output = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try output.insertTimeRange(CMTimeRange(start: .zero, duration: insertion), of: senderTrack, at: .zero)
        try output.insertTimeRange(CMTimeRange(start: .zero, duration: adDuration), of: adTrack, at: insertion)
        try output.insertTimeRange(
            CMTimeRange(start: insertion, duration: CMTimeSubtract(senderDuration, insertion)),
            of: senderTrack, at: CMTimeAdd(insertion, adDuration)
        )
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A))
        try await exporter.export(to: destination, as: .m4a)
    }
}
#endif
