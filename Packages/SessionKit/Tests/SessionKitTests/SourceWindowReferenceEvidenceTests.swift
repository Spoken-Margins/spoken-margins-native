#if canImport(AVFoundation)
import AVFoundation
#endif
import Foundation
import SessionKit
import XCTest
@testable import SessionKitAudio

final class SourceWindowReferenceEvidenceTests: XCTestCase {
    private struct FolderUnavailable: LocalizedError {
        var errorDescription: String? { "folder_unavailable" }
    }

    private func analysis(audio: URL?, provenance: EpisodeFingerprintProvenance = .sourceWindowReference) -> SourceAudioWindowTranscription {
        SourceAudioWindowTranscription(
            timeline: TranscriptTimeline(segments: [], chapters: [], durationMs: nil),
            localAudioURL: audio,
            sourceStartMs: 30_000,
            sourceEndMs: 150_000,
            provenance: provenance
        )
    }

    func testAWindowWithNoAudioHasNoEvidenceAndNoFailure() async {
        let outcome = await SourceWindowReferenceEvidence.generate(
            from: analysis(audio: nil),
            anchorMediaTimeMs: 90_000,
            outputDirectory: .failure(FolderUnavailable()),
            idPrefix: "anchor-s-i-source-window"
        )
        XCTAssertEqual(outcome, SourceWindowReferenceEvidence.Outcome(evidence: [], failure: nil))
    }

    func testAFailureIsReportedAndTheTemporaryAudioStillGoesAway() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "source-window-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appending(path: "window.m4a")
        try Data([0, 1, 2]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: folder) }

        let outcome = await SourceWindowReferenceEvidence.generate(
            from: analysis(audio: audio),
            anchorMediaTimeMs: 90_000,
            outputDirectory: .failure(FolderUnavailable()),
            idPrefix: "anchor-s-i-source-window"
        )

        XCTAssertEqual(outcome.evidence, [])
        XCTAssertEqual(outcome.failure, "folder_unavailable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the exported window is deleted even when signing fails")
    }

    #if os(macOS) && canImport(AVFoundation) && canImport(ShazamKit)
    /// The success path (#1133, ANC-01). The window's audio starts 30 s into the episode, so the signatures must
    /// be cut around 60 s of the window, not 90 s, and a recipient holding the whole episode must place the
    /// Margin back at 90 s. The window is cut with `AVAssetExportSession`, as the source-window job cuts it.
    func testSignaturesFromAWindowPlaceTheMarginAtItsEpisodeTime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "source-window-success-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let episode = root.appending(path: "episode.m4a")
        try SeededNoiseAudio.write(to: episode, seconds: 180)
        let windowFolder = root.appending(path: "window-90000-v3", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: windowFolder, withIntermediateDirectories: true)
        let window = windowFolder.appending(path: "source-window.m4a")
        try await Self.export(episode, fromMs: 30_000, toMs: 150_000, to: window)
        let evidenceFolder = root.appending(path: "evidence", directoryHint: .isDirectory)

        let outcome = await SourceWindowReferenceEvidence.generate(
            from: analysis(audio: window),
            anchorMediaTimeMs: 90_000,
            outputDirectory: .success(evidenceFolder),
            idPrefix: "anchor-s-i-source-window"
        )

        XCTAssertNil(outcome.failure)
        XCTAssertEqual(outcome.evidence.map(\.windowRole), [.sourceWindowBefore, .sourceWindowAfter])
        XCTAssertFalse(FileManager.default.fileExists(atPath: windowFolder.path), "the exported window is deleted after signing too")
        let query = PodcastPortableAnchorQuery(
            packageScopedId: "margin",
            senderMediaTimeMs: 90_000,
            evidence: try outcome.evidence.map {
                PodcastAcousticEvidenceQuery(id: $0.id, signatureData: try Data(contentsOf: URL(fileURLWithPath: $0.localPath)),
                                             anchorOffsetMs: $0.anchorOffsetMs)
            }
        )
        let resolution = try await PodcastAcousticAnchorResolver.resolve(
            queries: [query], recipientAudioURL: episode,
            senderExactEditionSHA256: nil, senderDurationMs: 180_000, strongSourceIdentity: true
        )["margin"]
        let placed = try XCTUnwrap(resolution?.localMediaTimeMs, "evidence class: \(String(describing: resolution?.evidenceClass))")
        XCTAssertLessThanOrEqual(abs(placed - 90_000), 1_500, "placed at \(placed) ms")
        XCTAssertEqual(resolution?.evidenceClass, .fused, "both flanks must match and agree")
    }

    private static func export(_ source: URL, fromMs: Int, toMs: Int, to output: URL) async throws {
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A))
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: Double(fromMs) / 1_000, preferredTimescale: 600),
            duration: CMTime(seconds: Double(toMs - fromMs) / 1_000, preferredTimescale: 600)
        )
        try await exporter.export(to: output, as: .m4a)
    }
    #endif

    func testFlanksKeepTheirRoleAndSayWhereTheAudioCameFrom() {
        let before = GeneratedPodcastAnchorEvidence(
            id: "anchor-s-i-source-window-pre",
            archivePath: "assets/evidence/anchor-s-i-source-window-pre.shazamsignature",
            fileURL: URL(fileURLWithPath: "/evidence/anchor-s-i-source-window-pre.shazamsignature"),
            durationMs: 11_000,
            anchorOffsetMs: 11_500
        )
        let after = GeneratedPodcastAnchorEvidence(
            id: "anchor-s-i-source-window-post",
            archivePath: "assets/evidence/anchor-s-i-source-window-post.shazamsignature",
            fileURL: URL(fileURLWithPath: "/evidence/anchor-s-i-source-window-post.shazamsignature"),
            durationMs: 11_000,
            anchorOffsetMs: -500
        )

        let fromDownload = SourceWindowReferenceEvidence.captured(from: [before, after], provenance: .downloadedSourceReference)
        XCTAssertEqual(fromDownload.map(\.windowRole), [.sourceWindowBefore, .sourceWindowAfter])
        XCTAssertEqual(fromDownload.map(\.provenance), [.downloadedSourceReference, .downloadedSourceReference])
        XCTAssertEqual(fromDownload.first?.localPath, "/evidence/anchor-s-i-source-window-pre.shazamsignature")
        XCTAssertEqual(fromDownload.first?.anchorOffsetMs, 11_500)

        let fromWindow = SourceWindowReferenceEvidence.captured(from: [before], provenance: .sourceWindowReference)
        XCTAssertEqual(fromWindow.map(\.provenance), [.sourceWindowReference])
    }
}
