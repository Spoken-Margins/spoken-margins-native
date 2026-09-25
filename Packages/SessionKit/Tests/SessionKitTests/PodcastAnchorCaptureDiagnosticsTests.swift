import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

final class PodcastAnchorCaptureDiagnosticsTests: XCTestCase {
    func testFailureReasonsKeepTheFirstCauseAndAppendLaterOnes() {
        var trail = PodcastAnchorCaptureDiagnostics.appendingFailureReason("stream_failed:timeout", to: nil)
        trail = PodcastAnchorCaptureDiagnostics.appendingFailureReason("no_exact_local_playback_edition", to: trail)
        XCTAssertEqual(trail, "stream_failed:timeout | no_exact_local_playback_edition")

        trail = PodcastAnchorCaptureDiagnostics.appendingFailureReason("no_exact_local_playback_edition", to: trail)
        XCTAssertEqual(trail, "stream_failed:timeout | no_exact_local_playback_edition", "a repeated reason is not duplicated")

        for index in 0..<10 {
            trail = PodcastAnchorCaptureDiagnostics.appendingFailureReason("retry_\(index)", to: trail)
        }
        let reasons = trail.components(separatedBy: " | ")
        XCTAssertEqual(reasons.count, 6)
        XCTAssertEqual(reasons.first, "stream_failed:timeout")
        XCTAssertEqual(reasons.last, "retry_9")
    }

    func testMarginKeysDoNotCollideAcrossSessionsAndHideSessionIds() {
        let streamed = PodcastAnchorCaptureDiagnostics.marginKey(
            "podcastAnchorEvidence", sessionId: "session-odd-lots-hollywood", interjectionId: "ij-001")
        let downloaded = PodcastAnchorCaptureDiagnostics.marginKey(
            "podcastAnchorEvidence", sessionId: "session-other-episode", interjectionId: "ij-001")
        XCTAssertNotEqual(streamed, downloaded)
        XCTAssertTrue(streamed.hasPrefix("podcastAnchorEvidence:"))
        XCTAssertTrue(streamed.hasSuffix("/ij-001"))
        XCTAssertFalse(streamed.contains("hollywood"))
    }

    func testExportReadsStoredCaptureOutcomesAfterReopeningTheStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "anchor-diagnostics-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "store.sqlite").path

        do {
            let store = try SQLiteSessionStore(path: path)
            for (sessionId, reason) in [("session-a", "stream_failed:timeout | no_exact_local_playback_edition"),
                                        ("session-b", nil as String?)] {
                try store.saveSession(Session(
                    id: sessionId,
                    itemId: "episode",
                    createdAt: Date(),
                    updatedAt: Date(),
                    status: "active",
                    phase: .itemPlayback,
                    currentTargetType: .transcriptBackedMedia,
                    currentTargetId: "episode",
                    position: Position(mediaTimeMs: 60_000),
                    completionPercent: 0,
                    playbackRate: 1
                ))
                try store.saveInterjection(Interjection(
                    id: "ij-001",
                    itemId: "episode",
                    sessionId: sessionId,
                    targetType: .item,
                    targetId: "episode",
                    createdAt: Date(timeIntervalSince1970: 1),
                    roughPercent: 10,
                    anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 60_000),
                    audioPath: "interjections/\(sessionId).m4a",
                    audioStatus: "saved",
                    transcriptionStatus: "complete",
                    transcript: nil,
                    cleanedTranscript: nil,
                    displayText: nil,
                    status: "active",
                    podcastAnchorEvidenceCaptureStatus: reason == nil ? .ready : .unavailable,
                    podcastAnchorEvidenceFailureReason: reason
                ))
            }
        }

        let reopened = try SQLiteSessionStore(path: path)
        let entries = PodcastAnchorCaptureDiagnostics.exportEntries(
            sessions: try reopened.loadSessions(),
            interjections: { try reopened.loadInterjections(sessionId: $0) }
        )
        XCTAssertEqual(entries.count, 2, "the same Margin ID in two sessions produces two entries")
        let failed = try XCTUnwrap(entries[PodcastAnchorCaptureDiagnostics.marginKey(
            "marginCapture", sessionId: "session-a", interjectionId: "ij-001")])
        XCTAssertTrue(failed.contains("status=unavailable"))
        XCTAssertTrue(failed.contains("reasons=stream_failed:timeout | no_exact_local_playback_edition"))
        let ready = try XCTUnwrap(entries[PodcastAnchorCaptureDiagnostics.marginKey(
            "marginCapture", sessionId: "session-b", interjectionId: "ij-001")])
        XCTAssertTrue(ready.contains("status=ready"))
    }
}
