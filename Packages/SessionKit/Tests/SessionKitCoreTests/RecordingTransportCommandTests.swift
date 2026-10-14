import Foundation
import XCTest
@testable import SessionKit

/// #1030: an AirPods click didn't end a Margin that was recording, because the system transport commands were
/// unavailable then and iOS never delivered the click. Now Playing enables them from `transportCommandsEndMargin`.
final class RecordingTransportCommandTests: XCTestCase {
    private func snapshot(
        isRecording: Bool,
        availableCommands: [CompactControlCommand]
    ) -> CompactControlSnapshot {
        CompactControlSnapshot(
            sessionId: "session-1",
            itemId: "item-1",
            targetType: TargetType.itemTextTTS.rawValue,
            targetId: "target-1",
            title: "Article",
            chapterTitle: nil,
            status: isRecording ? .recording : .playing,
            phase: isRecording ? .recordingInterjection : .itemPlayback,
            progressPercent: 10,
            currentPlaybackProgressPercent: 10,
            sourceProgressPercent: 10,
            playbackRate: 1,
            isRecording: isRecording,
            pendingAiJobCount: 0,
            pendingAiJobKind: nil,
            pendingAiJobStatus: nil,
            lastUserTurnType: nil,
            exposedCommands: availableCommands,
            availableCommands: availableCommands,
            compactSurfaceReady: true,
            surfaceProfileId: "lock-screen-widget"
        )
    }

    func testRecordingWithFinishAvailableLetsTheClickEndTheMargin() {
        XCTAssertTrue(snapshot(isRecording: true, availableCommands: [.finishInterjection, .cancelInterjection])
            .transportCommandsEndMargin)
    }

    func testNeighbouringStatesLeaveTransportAlone() {
        XCTAssertFalse(snapshot(isRecording: false, availableCommands: [.togglePlayPause, .beginInterjection])
            .transportCommandsEndMargin, "playing: the click pauses")
        XCTAssertFalse(snapshot(isRecording: true, availableCommands: [])
            .transportCommandsEndMargin, "a surface that can't finish a Margin must not claim the click")
        XCTAssertFalse(snapshot(isRecording: false, availableCommands: [.finishInterjection])
            .transportCommandsEndMargin, "not recording: nothing to end")
    }

    func testOnlyHeadphoneTransportCommandsEndARecordingMargin() {
        let ending = CompactControlCommand.allCases.filter(\.endsRecordingMargin)

        XCTAssertEqual(Set(ending), [.play, .pause, .togglePlayPause, .skipForward])
    }
}
