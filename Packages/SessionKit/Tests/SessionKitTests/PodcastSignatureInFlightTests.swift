#if os(macOS) && canImport(AVFoundation) && canImport(ShazamKit)
import AVFoundation
import Foundation
import XCTest
@testable import SessionKitAudio

/// `PodcastAssetSignatureGenerator` promises at most one signature in flight: that is what keeps several long
/// compositions from being read into memory at once. The stress test in PodcastAssetSignatureGeneratorTests checks the
/// cooperative pool stays free, which a generator running every request at once would also pass (#1308, ANC-15).
final class PodcastSignatureInFlightTests: XCTestCase {
    func testRequestsMadeTogetherAreSignedOneAtATime() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "signature-in-flight-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let episodes = try (0..<4).map { index in
            let url = directory.appending(path: "episode-\(index).m4a")
            try SeededNoiseAudio.write(to: url, seconds: 20)
            return url
        }

        PodcastAssetSignatureGenerator.resetPeakInFlight()
        let durations = try await withThrowingTaskGroup(of: TimeInterval.self) { group in
            for episode in episodes {
                group.addTask {
                    try await PodcastAssetSignatureGenerator.signature(from: AVURLAsset(url: episode)).duration
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(durations.count, 4)
        for duration in durations { XCTAssertGreaterThan(duration, 19.5, "each request got its own whole signature") }
        XCTAssertEqual(PodcastAssetSignatureGenerator.peakSignaturesInFlight, 1, "requests made together ran at once")
    }
}
#endif
