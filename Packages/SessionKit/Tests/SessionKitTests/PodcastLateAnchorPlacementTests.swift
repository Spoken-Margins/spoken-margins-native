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
        let episode = try Self.writeLongEpisode(to: directory.appending(path: "episode.m4a"), minutes: 40)

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

    /// Low-rate mono AAC keeps generation quick; the noise is seeded so every run is identical.
    private static func writeLongEpisode(to url: URL, minutes: Int) throws -> URL {
        let sampleRate = 16_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000
        ])
        var state: UInt64 = 0x9E3779B97F4A7C15
        let frames = AVAudioFrameCount(sampleRate)
        for second in 0..<(minutes * 60) {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<Int(frames) {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let noise = Double(Int64(bitPattern: state >> 11)) / Double(1 << 52) - 1
                let time = Double(second) + Double(frame) / sampleRate
                let envelope = max(0, sin(time * 5.3) * sin(time * 1.7 + 0.4))
                let tone = sin(2 * .pi * (220 + 180 * sin(time * 0.37 + sin(time * 0.013))) * time)
                samples[frame] = Float(envelope * (0.5 * tone + 0.3 * noise))
            }
            try file.write(from: buffer)
        }
        return url
    }
}
#endif
