#if os(macOS) && canImport(AVFoundation) && canImport(ShazamKit)
import AVFoundation
import Foundation
import ShazamKit
import XCTest
@testable import SessionKit
@testable import SessionKitAudio
import SessionKitTestInputs

/// ShazamKit's custom catalog only accepts query signatures of 1-12 s. Evidence cut to exactly 12,000 ms from
/// 44.1/48 kHz audio came out at 12.01 s, every query errored, and the resolver treated that as "no match": no
/// shared podcast Margin could be placed acoustically. The held-out benchmark's low-bitrate mono audio happened
/// to round under the limit, which is why it kept passing.
final class PodcastEvidenceSignatureLengthTests: XCTestCase {
    func testEvidenceFromStereo48kHzAudioStaysQueryableAndPlacesTheMargin() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "evidence-length-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A 40 s synthetic 48 kHz stereo MP3 (1152-sample frames), like most podcast enclosures. AVFoundation can't
        // write MP3, and AAC files round under the limit, so the fixture is checked in.
        let episode = try TestInputs.url(.contracts, "fixtures/audio/evidence-length-48k-stereo.mp3")

        let generated = try await PodcastAnchorEvidenceGenerator.generate(
            sourceURL: episode, anchorMediaTimeMs: 20_000,
            outputDirectory: directory.appending(path: "evidence"), idPrefix: "margin")
        XCTAssertEqual(generated.count, 2)
        for evidence in generated {
            let signature = try SHSignature(dataRepresentation: Data(contentsOf: evidence.fileURL))
            XCTAssertLessThanOrEqual(signature.duration, 12.0, "\(evidence.id) is \(signature.duration) s")
        }

        let query = PodcastPortableAnchorQuery(
            packageScopedId: "margin-0001",
            senderMediaTimeMs: 20_000,
            evidence: try generated.map {
                PodcastAcousticEvidenceQuery(id: $0.id, signatureData: try Data(contentsOf: $0.fileURL),
                                             anchorOffsetMs: $0.anchorOffsetMs)
            },
            evidenceWasDeclared: true
        )
        let resolution = try await PodcastAcousticAnchorResolver.resolve(
            queries: [query], recipientAudioURL: episode,
            senderExactEditionSHA256: nil, senderDurationMs: 40_032, strongSourceIdentity: true
        )["margin-0001"]
        let placed = try XCTUnwrap(resolution?.localMediaTimeMs, "evidence class: \(String(describing: resolution?.evidenceClass))")
        XCTAssertLessThanOrEqual(abs(placed - 20_000), 1_500)
        XCTAssertEqual(resolution?.evidenceClass, .fused, "both flanks must match and agree")
    }
}
#endif
