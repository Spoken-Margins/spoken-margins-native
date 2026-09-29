#if os(macOS) && canImport(AVFoundation) && canImport(ShazamKit)
import AVFoundation
import Foundation
import XCTest
@testable import SessionKit
@testable import SessionKitAudio

/// A single reference signature for a whole episode stopped matching partway in: on the 63-minute Doom Scroll
/// DS 55 episode, Margins at 5:00 and 18:30 placed but 36:44 and 55:00 never matched, although the reference
/// covered the full file. This plays the same shape with a generated 40-minute episode.
final class PodcastLateAnchorPlacementTests: XCTestCase {
    func testMarginLateInALongEpisodeIsPlaced() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "late-anchor-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let episode = directory.appending(path: "episode.m4a")
        try SeededNoiseAudio.write(to: episode, seconds: 40 * 60)

        var queries: [PodcastPortableAnchorQuery] = []
        for (index, anchorMs) in [300_000, 2_160_000].enumerated() {
            let generated = try await PodcastAnchorEvidenceGenerator.generate(
                sourceURL: episode, anchorMediaTimeMs: anchorMs,
                outputDirectory: directory.appending(path: "evidence"), idPrefix: "margin-\(index)")
            queries.append(PodcastPortableAnchorQuery(
                packageScopedId: "margin-\(index)",
                senderMediaTimeMs: anchorMs,
                evidence: try generated.map {
                    PodcastAcousticEvidenceQuery(id: $0.id, signatureData: try Data(contentsOf: $0.fileURL),
                                                 anchorOffsetMs: $0.anchorOffsetMs)
                },
                evidenceWasDeclared: true
            ))
        }
        let results = try await PodcastAcousticAnchorResolver.resolve(
            queries: queries, recipientAudioURL: episode,
            senderExactEditionSHA256: nil, senderDurationMs: 2_400_000, strongSourceIdentity: true
        )
        for query in queries {
            let resolution = results[query.packageScopedId]
            let placed = try XCTUnwrap(resolution?.localMediaTimeMs,
                "\(query.packageScopedId) at \(query.senderMediaTimeMs ?? -1) ms: \(String(describing: resolution?.evidenceClass))")
            XCTAssertLessThanOrEqual(abs(placed - (query.senderMediaTimeMs ?? 0)), 1_500)
        }
    }
}
#endif
