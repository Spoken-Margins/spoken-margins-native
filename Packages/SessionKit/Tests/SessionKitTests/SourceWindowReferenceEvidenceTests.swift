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
