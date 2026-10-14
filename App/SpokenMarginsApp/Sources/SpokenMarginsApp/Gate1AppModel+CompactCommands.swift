import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitSharing
import SessionKitSupertonic
import SessionKitPersistence
import SessionKitFeeds
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(PDFKit)
import PDFKit
#endif

/// Commands from compact surfaces: the Live Activity, widgets and compact URLs (#1022).
extension Gate1AppModel {
    func dispatchGate2CompactCommand(
        _ command: CompactControlCommand,
        chapterId: String? = nil,
        mediaTimeMs: Int? = nil,
        playbackRate: Double? = nil,
        origin: String = "app_ui"
    ) {
        // A headphone click, car button or Lock Screen play/pause while a Margin records ends it (#1030).
        // Only from Now Playing: a stale queued widget command must not save a Margin. A save already
        // under way from the screen is not asked twice.
        if snapshot.isRecording, command.endsRecordingMargin, origin.hasPrefix("now_playing") {
            guard !isFinishingInterjection else { return }
            recordDeveloperDiagnostic("transport.ends_margin", ["command": command.rawValue, "origin": origin])
            performGate2CompactCommand(.finishInterjection, origin: origin)
            return
        }
        if command == .beginInterjection {
            guard !recordingNavigationIsLocked else { return }
            marginCapture.beginCompactRequest()
            microphoneAccess.recordFromCompactControl(ask: { [weak self] in await self?.requestMicrophonePermission() ?? false }) { [weak self] granted in
                guard let self else { return }
                if granted { performGate2CompactCommand(command, chapterId: chapterId, mediaTimeMs: mediaTimeMs, playbackRate: playbackRate, origin: origin) }
                marginCapture.endCompactRequest()
                if !granted { reportFailure("Microphone access is required to record Margins from compact controls.") }
            }
            return
        }
        performGate2CompactCommand(command, chapterId: chapterId, mediaTimeMs: mediaTimeMs, playbackRate: playbackRate, origin: origin)
    }

    func handleGate2CompactURL(_ url: URL) {
        guard let rawCommand = Gate2CompactCommandURL.command(from: url) else {
            reportFailure("Unsupported compact control URL.")
            return
        }
        guard let command = CompactControlCommand(rawValue: rawCommand) else {
            if !handleGate2CompactApplicationCommand(
                rawCommand,
                targetID: Gate2CompactCommandURL.chapterId(from: url)
            ) {
                reportFailure("Unsupported compact control URL.")
            }
            return
        }
        dispatchGate2CompactCommand(
            command,
            chapterId: Gate2CompactCommandURL.chapterId(from: url),
            origin: "compact_url"
        )
    }

    @discardableResult
    func handleGate2CompactApplicationCommand(_ command: String, targetID: String? = nil) -> Bool {
        switch command {
        case Gate2CompactApplicationCommand.summarizeInterjections:
            guard gate2CompactSnapshot?.availableCommands.contains(.generateInterjectionSummary) == true else {
                reportFailure("Summary is unavailable for the current compact surface state.")
                return false
            }
            summarize()
            return true
        case Gate2CompactApplicationCommand.discussInterjections:
            guard gate2CompactSnapshot?.availableCommands.contains(.submitFollowup) == true else {
                reportFailure("Discuss is unavailable for the current compact surface state.")
                return false
            }
            discuss(followUp: "")
            return true
        case Gate2CompactApplicationCommand.listenToSharedMargin:
            guard pendingImportedCommentary != nil else { return false }
            listenToPendingImportedCommentary()
            screen = .playback
            return true
        case Gate2CompactApplicationCommand.dismissSharedMargin:
            guard pendingImportedCommentary != nil else { return false }
            dismissPendingImportedCommentary()
            return true
        case Gate2CompactApplicationCommand.jumpToSharedMargin:
            guard let targetID, !targetID.isEmpty else { return false }
            return jumpToImportedCommentary(interjectionID: targetID)
        default:
            reportFailure("Unsupported compact application command.")
            return false
        }
    }
}
