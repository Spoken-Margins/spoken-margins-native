import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

@MainActor
final class Gate2CompactControlTests: XCTestCase {
    func testCompactSnapshotIsPublishedForSeededSession() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")

        XCTAssertEqual(model.gate2CompactSnapshot?.surfaceProfileId, "lock-screen-widget")
        XCTAssertEqual(model.gate2CompactSnapshot?.title, "You Can't Inspect the Pill")
        XCTAssertEqual(model.gate2CompactSnapshot?.chapterTitle, "Reasonable distrust")
        XCTAssertEqual(model.gate2CompactSnapshot?.compactSurfaceReady, true)
        XCTAssertTrue(model.gate2CompactSnapshot?.exposedCommands.contains(.play) == true)
        XCTAssertTrue(model.gate2CompactSnapshot?.exposedCommands.contains(.pause) == true)
        XCTAssertTrue(model.gate2CompactSnapshot?.exposedCommands.contains(.togglePlayPause) == true)
        XCTAssertTrue(model.gate2CompactSnapshot?.exposedCommands.contains(.beginInterjection) == true)
    }

    func testCompactTransportCommandsDelegateAndUpdateDiagnostics() {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.startItem(id: "item-pill")

        model.dispatchGate2CompactCommand(.togglePlayPause)

        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(model.diagnostics["gate2LastCommand"], "togglePlayPause")
        XCTAssertEqual(model.diagnostics["gate2LastResult"], "delegated")

        model.dispatchGate2CompactCommand(.play)

        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertEqual(model.diagnostics["gate2LastCommand"], "play")

        model.dispatchGate2CompactCommand(.pause)

        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(model.diagnostics["gate2LastCommand"], "pause")

        model.dispatchGate2CompactCommand(.play)

        model.dispatchGate2CompactCommand(.skipForward)

        XCTAssertEqual(model.diagnostics["gate2LastCommand"], "skipForward")
        XCTAssertEqual(model.gate2CompactSnapshot?.compactSurfaceReady, true)
    }

    func testNowPlayingAvailabilityUsesCompactAvailableCommandsForSeekAndRate() {
        let textSnapshot = compactSnapshot(
            targetType: TargetType.itemTextTTS.rawValue,
            availableCommands: [.togglePlayPause, .skipBack, .skipForward],
            durationMs: 120_000
        )
        let textAvailability = Gate2NowPlayingCommandAvailability(snapshot: textSnapshot)

        XCTAssertTrue(textAvailability.canPause)
        XCTAssertFalse(textAvailability.canSeek)
        XCTAssertFalse(textAvailability.canSetPlaybackRate)

        let mediaSnapshot = compactSnapshot(
            targetType: TargetType.transcriptBackedMedia.rawValue,
            availableCommands: [.togglePlayPause, .seekToMediaTime, .setPlaybackRate],
            durationMs: 120_000
        )
        let mediaAvailability = Gate2NowPlayingCommandAvailability(snapshot: mediaSnapshot)

        XCTAssertTrue(mediaAvailability.canSeek)
        XCTAssertTrue(mediaAvailability.canSetPlaybackRate)
    }

    private func compactSnapshot(
        targetType: String,
        availableCommands: [CompactControlCommand],
        durationMs: Int?
    ) -> CompactControlSnapshot {
        CompactControlSnapshot(
            sessionId: "session-pill",
            itemId: "item-pill",
            targetType: targetType,
            targetId: "item-pill",
            title: "Pill",
            chapterTitle: "Opening",
            status: .playing,
            phase: .itemPlayback,
            progressPercent: 10,
            currentPlaybackProgressPercent: 10,
            sourceProgressPercent: 10,
            currentMediaTimeMs: 1_000,
            currentPlaybackDurationMs: durationMs,
            playbackRate: 1,
            isRecording: false,
            pendingAiJobCount: 0,
            pendingAiJobKind: nil,
            pendingAiJobStatus: nil,
            lastUserTurnType: nil,
            exposedCommands: CompactControlCommand.allCases,
            availableCommands: availableCommands,
            compactSurfaceReady: true,
            surfaceProfileId: "lock-screen-widget"
        )
    }
}
